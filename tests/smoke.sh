#!/bin/bash
# smoke.sh — prove an INSTALLED cfm-edge can do what CFM's edge asks of it.
#
# Run as root on a host (or container) where the rpm is installed and nothing
# listens on 127.0.0.1:9099/9443/9081. It starts its own instance from a
# scratch prefix (never /etc/cfm-edge), so it is safe next to a live edge.
#
# Covers the edge features CFM depends on (checked against cfm's configs/):
#   - every non-CFM Lua module CFM requires: cjson(.safe), bit, ngx.ssl,
#     ngx.balancer, resty.http, resty.maxminddb (+ resty.core/lrucache);
#   - TLS + HTTP/2, and the QUIC/HTTP/3 listener parses and binds;
#   - ssl_certificate_by_lua (sslcollector's path: clear + set cert from PEM);
#   - balancer_by_lua (cfm.lua's origin-keepalive upstreams);
#   - the binary's linkage: private LuaJIT, no system libssl/libcrypto.
set -euo pipefail

# Everything here is loopback: never route it through an egress proxy.
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy

BIN="${BIN:-/usr/sbin/cfm-edge}"
fail=0
ok()   { printf '  ok    %s\n' "$*"; }
bad()  { printf '  FAIL  %s\n' "$*"; fail=1; }
check(){ local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }

P="$(mktemp -d /tmp/cfm-edge-smoke.XXXXXX)"
trap '"$BIN" -p "$P" -c "$P/conf/nginx.conf" -s stop >/dev/null 2>&1 || true; rm -rf "$P"' EXIT
mkdir -p "$P"/{conf,logs,certs}

echo "== binary"
"$BIN" -V 2>"$P/V" || true
cat "$P/V"
check "nginx -V names lua-nginx-module" grep -q 'lua-nginx-module' "$P/V"
check "built with OpenSSL 3.5" grep -qE 'built with OpenSSL 3\.5\.' "$P/V"
check "http_v3 compiled in" grep -q -- '--with-http_v3_module' "$P/V"
# -v keeps the stock "nginx/X" (CFM's edgeengine.ParseVersionToken reads it);
# only what clients see says cfm-edge (patches/nginx/0001).
check "-v still reports nginx/<version>" grep -qE '^nginx version: nginx/[0-9]' "$P/V"
ldd "$BIN" >"$P/ldd"
check "links the private LuaJIT" grep -qE 'libluajit-5\.1\.so\.2 => /usr/lib/cfm-edge/luajit/lib/' "$P/ldd"
check "no unresolved libraries" bash -c "! grep -q 'not found' '$P/ldd'"
check "no system libssl/libcrypto" bash -c "! grep -qE 'lib(ssl|crypto)\.so' '$P/ldd'"
# The static OpenSSL must not look for its config (openssl.cnf, which can load
# providers/engines) under a build directory. Its MODULESDIR/ENGINESDIR still
# name the build tree (nginx fixes OpenSSL's --prefix), but they are only used
# when a config or OPENSSL_MODULES asks for a module.
check "OPENSSLDIR is the private /usr/lib/cfm-edge/ssl" bash -c \
    "strings '$BIN' | grep -q '^/usr/lib/cfm-edge/ssl\$' && ! strings '$BIN' | grep -qE '\.openssl/ssl\$'"
# OpenSSL is static, so LuaJIT FFI users (resty.sha256 = cfm_clearance's
# HMAC backend on this edge: there is no ngx.hmac_sha256 in stock ngx_lua)
# reach it only if the binary exports its symbols (nginx links with -Wl,-E).
for sym in SHA256_Init SHA256_Update SHA256_Final ngx_http_lua_ffi_get_ctx_ref; do
    check "exports $sym for FFI" bash -c "nm -D --defined-only '$BIN' | grep -qw $sym"
done

echo "== systemd unit"
U=/usr/lib/systemd/system/cfm-edge.service
check "unit installed" test -f "$U"
# A graceful stop (SIGQUIT) needs time to finish open uploads and websockets.
check "TimeoutStopSec=90 (graceful stop)" grep -qx 'TimeoutStopSec=90' "$U"
check "LimitNOFILE=262144 (as openresty.service)" grep -qx 'LimitNOFILE=262144' "$U"
check "KillSignal=SIGQUIT" grep -qx 'KillSignal=SIGQUIT' "$U"
# The pid is in the unit's RuntimeDirectory and equals the compiled default
# (CFM's config sets none): a mismatch gets the edge killed at start.
check "PIDFile=/run/cfm-edge/cfm-edge.pid" grep -qx 'PIDFile=/run/cfm-edge/cfm-edge.pid' "$U"
check "RuntimeDirectory=cfm-edge" grep -qx 'RuntimeDirectory=cfm-edge' "$U"
check "compiled --pid-path = PIDFile" bash -c "'$BIN' -V 2>&1 | grep -q -- '--pid-path=/run/cfm-edge/cfm-edge.pid '"
# The pid dir exists while the edge is stopped: `cfm-edge -t` opens the pid
# file, and CFM runs -t before the edge starts (cfm-edge-listen-v6.service,
# the install script). tmpfiles.d makes it at boot, %post at install.
check "RuntimeDirectoryPreserve=yes" grep -qx 'RuntimeDirectoryPreserve=yes' "$U"
check "tmpfiles.d makes /run/cfm-edge" grep -qxE 'd /run/cfm-edge 0755 root root -' /usr/lib/tmpfiles.d/cfm-edge.conf
check "/run/cfm-edge exists after install (edge never started)" test -d /run/cfm-edge
check "cfm-edge -t passes with the edge stopped" "$BIN" -t -q
check "no Conflicts= with the live edge" bash -c "! grep -q '^Conflicts=' '$U'"
# Hardening (ROADMAP.md §2): the write paths the edge needs, or a large
# upload/response fails with EROFS at run time while the edge looks healthy.
check "ProtectSystem=strict" grep -qx 'ProtectSystem=strict' "$U"
for p in /var/log/cfm-edge /var/cache/nginx /var/lib/cfm-edge /var/lib/cfm/nginx /var/lib/cfm/scanner; do
    check "ReadWritePaths has $p" bash -c "grep '^ReadWritePaths=' '$U' | tr ' =' '\n\n' | grep -qx '$p'"
done
# /run stays read-only: /run/systemd/system is a unit load path.
check "ReadWritePaths has no /run" bash -c "! grep '^ReadWritePaths=' '$U' | tr ' =' '\n\n' | grep -qxE '/run|/var/run'"
# ...and it is read-only, explicitly: on EL9/EL10 systemd leaves the /run
# tmpfs rw when ProtectSystem=strict comes with ProtectKernelTunables= or
# ProtectControlGroups= (both in the unit); strict alone, or EL8, makes it ro.
check "ReadOnlyPaths=/run" grep -qx 'ReadOnlyPaths=/run' "$U"
check "UMask=0027 (logs not world-readable)" grep -qx 'UMask=0027' "$U"
check "ProtectHome=yes" grep -qx 'ProtectHome=yes' "$U"
check "NoNewPrivileges=yes" grep -qx 'NoNewPrivileges=yes' "$U"
check "no MemoryDenyWriteExecute (LuaJIT JIT)" bash -c "! grep -q '^MemoryDenyWriteExecute' '$U'"

echo "== post-upgrade restart"
R=/usr/lib/cfm-edge/upgrade-restart.sh
check "upgrade-restart.sh installed, executable" test -x "$R"
check "upgrade-restart.sh parses as sh" sh -n "$R"
# The rpm runs it after the transaction, and never restarts in postun itself.
if command -v rpm >/dev/null 2>&1 && rpm -q cfm-edge >/dev/null 2>&1; then
    check "posttrans runs upgrade-restart.sh" bash -c "rpm -q --scripts cfm-edge | sed -n '/^posttrans/,/^[a-z]* scriptlet/p' | grep -q '$R'"
    check "no restart-on-upgrade in postun" bash -c "! rpm -q --scripts cfm-edge | sed -n '/^postun/,/^[a-z]* scriptlet/p' | grep -qE 'try-restart|restart |mark-restart'"
fi
# Not running here (the smoke test runs its own instance, not the unit):
# the script must do nothing and exit 0.
check "upgrade-restart.sh is a no-op for a stopped edge (no output, exit 0)" bash -c "systemctl is-active --quiet cfm-edge 2>/dev/null || [ -z \"\$('$R' 2>&1)\" ]"

echo "== logrotate"
L=/etc/logrotate.d/cfm-edge
check "logrotate config installed" test -f "$L"
# CFM's hourly pass runs this file so the cap fires between daily runs.
check "maxsize 2G (size cap, as CFM's OpenResty logs)" grep -qE '^\s*maxsize\s+2G\s*$' "$L"
check "rotate 7" grep -qE '^\s*rotate\s+7\s*$' "$L"
check "create 0640 (as the unit's UMask)" grep -qE '^\s*create\s+0640\s*$' "$L"
# USR1 through systemd, never a pid file (a stale one can name another process).
check "postrotate signals the unit's main process" grep -qF 'systemctl kill --kill-who=main -s USR1 cfm-edge.service' "$L"
check "postrotate reads no pid file" bash -c "! grep -qE '\.pid' '$L'"
check "dateext with a to-the-second dateformat" grep -qE '^\s*dateformat\s+-%Y%m%d-%H%M%S\s*$' "$L"
if command -v logrotate >/dev/null 2>&1; then
    check "logrotate -d parses it" logrotate -d "$L"
    # Two forced rotations a second apart, with ONLY this file (as CFM's
    # hourly pass runs it): both succeed, and name their generations by
    # date, never .1 (which the distro's daily run would not count).
    # They run on a COPY of the packaged rule whose log glob and pid file
    # point into $P: `logrotate -f` on the real file would rotate every live
    # /var/log/cfm-edge/*.log and USR1 the production master next to a live
    # edge (this script promises it is safe there).
    lr_dir="$P/lr"; lr_conf="$P/logrotate-cfm-edge.conf"; lr_state="$P/logrotate.state"
    mkdir -p "$lr_dir"
    # (comments dropped: they name the live paths too)
    sed -e '/^[[:space:]]*#/d' -e "s|/var/log/cfm-edge/\*\.log|$lr_dir/*.log|" -e "s|cfm-edge\.service|cfm-edge-smoke-none.service|g" "$L" >"$lr_conf"
    check "the rotation copy points at the scratch dir, not the live logs" bash -c \
        "grep -qF '$lr_dir/*.log' '$lr_conf' && grep -qF 'cfm-edge-smoke-none.service' '$lr_conf' && ! grep -qE '/var/log/cfm-edge|/run/cfm-edge|cfm-edge\.service' '$lr_conf'"
    if grep -qE '/var/log/cfm-edge|/run/cfm-edge|cfm-edge\.service' "$lr_conf"; then
        bad "rotation copy still names a live path: not forcing a rotation"
    else
        echo one > "$lr_dir/smoke.log"
        check "forced rotation 1" logrotate -f -s "$lr_state" "$lr_conf"
        sleep 1
        echo two > "$lr_dir/smoke.log"
        check "forced rotation 2 in the same day (no name clash)" logrotate -f -s "$lr_state" "$lr_conf"
        check "generations are date-named, not .1" bash -c \
            "ls '$lr_dir/' | grep -qE '^smoke\.log-[0-9]{8}-[0-9]{6}' && ! ls '$lr_dir/' | grep -qE '^smoke\.log\.[0-9]'"
    fi
fi

echo "== package placeholder config"
check "cfm-edge -t on /etc/cfm-edge/nginx.conf" "$BIN" -t -q

# Two certificates: the static default, and the one Lua swaps in by SNI.
mkcert() { openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=$1" \
           -keyout "$P/certs/$1.key" -out "$P/certs/$1.crt" >/dev/null 2>&1; }
mkcert default.test
mkcert lua.test
# Workers run as nobody: let them read the scratch prefix (test certs only).
chmod 0755 "$P" "$P/certs"; chmod 0644 "$P"/certs/*

cat >"$P/conf/nginx.conf" <<EOF
worker_processes 1;
error_log $P/logs/error.log info;
pid $P/logs/nginx.pid;
events { worker_connections 256; }
http {
    access_log off;
    server_tokens off;        # as CFM's edge config sets it
    client_body_temp_path $P/logs/cb;
    proxy_temp_path       $P/logs/px;
    lua_shared_dict smoke 1m;

    upstream lua_balanced {
        server 0.0.0.1;
        balancer_by_lua_block {
            local b = require "ngx.balancer"
            assert(b.set_current_peer("127.0.0.1", 9099))
        }
    }

    server {
        listen 127.0.0.1:9099;
        location = /requires {
            default_type application/json;
            content_by_lua_block {
                local cjson = require "cjson.safe"
                local res = {}
                for _, m in ipairs({"cjson", "cjson.safe", "bit", "ngx.ssl", "ngx.balancer",
                                    "resty.core", "resty.lrucache", "resty.string", "resty.http", "resty.maxminddb"}) do
                    local ok, err = pcall(require, m)
                    res[m] = ok and "ok" or tostring(err)
                end
                -- maxminddb: init() must get as far as MMDB_open (a missing file),
                -- i.e. ffi.load found libmaxminddb by its runtime soname.
                local mm = require "resty.maxminddb"
                local ok, err = pcall(mm.init, "/nonexistent/GeoLite2-City.mmdb")
                res.maxminddb_ffi = (not ok and tostring(err):find("load", 1, true))
                                    and ("ffi: " .. tostring(err)) or "ok"
                res.shdict = ngx.shared.smoke:set("k", 1) and "ok" or "set failed"
                -- resty.sha256 over the FFI (cfm_clearance's HMAC-SHA256 backend here)
                local sha = require("resty.sha256"):new()
                sha:update("abc")
                local hex = require("resty.string").to_hex(sha:final())
                res.sha256 = (hex == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
                             and "ok" or ("got " .. hex)
                ngx.say(cjson.encode(res))
            }
        }
        location = /hello { return 200 "hello\n"; }
        location = /e404  { return 404; }
        location = /tokens { server_tokens on; return 404; }
    }

    server {
        listen 127.0.0.1:9081;
        location / { proxy_pass http://lua_balanced/hello; }
    }

    server {
        listen 127.0.0.1:9443 ssl;
        listen 127.0.0.1:9443 quic reuseport;
        http2 on;
        http3 on;
        ssl_certificate     $P/certs/default.test.crt;
        ssl_certificate_key $P/certs/default.test.key;
        ssl_certificate_by_lua_block {
            local ssl = require "ngx.ssl"
            if ssl.server_name() ~= "lua.test" then return end
            local function slurp(p) local f = assert(io.open(p)); local s = f:read("*a"); f:close(); return s end
            assert(ssl.clear_certs())
            assert(ssl.set_cert(assert(ssl.parse_pem_cert(slurp("$P/certs/lua.test.crt")))))
            assert(ssl.set_priv_key(assert(ssl.parse_pem_priv_key(slurp("$P/certs/lua.test.key")))))
        }
        location / { return 200 "proto=\$server_protocol\n"; }
    }
}
EOF

echo "== CFM-shaped config"
check "-t on the smoke config (quic listener included)" "$BIN" -p "$P" -c "$P/conf/nginx.conf" -t -q
"$BIN" -p "$P" -c "$P/conf/nginx.conf"
for _ in $(seq 1 50); do [ -s "$P/logs/nginx.pid" ] && break; sleep 0.1; done
check "started" test -s "$P/logs/nginx.pid"

req="$(curl -fsS http://127.0.0.1:9099/requires || true)"
echo "  requires: $req"
for m in cjson cjson.safe bit ngx.ssl ngx.balancer resty.core resty.lrucache resty.string resty.http resty.maxminddb maxminddb_ffi shdict sha256; do
    check "lua: $m" grep -q "\"$m\":\"ok\"" <<<"$req"
done


check "balancer_by_lua proxies" bash -c "curl -fsS http://127.0.0.1:9081/ | grep -q hello"
check "Server: cfm-edge on HTTP/1.1 (server_tokens off)" bash -c \
    "curl -sSI http://127.0.0.1:9099/hello | grep -qi '^server: cfm-edge.$'"
check "Server: cfm-edge on HTTP/2" bash -c \
    "curl -sSkI --http2 https://127.0.0.1:9443/ | grep -qi '^server: cfm-edge.$'"
check "server_tokens on: Server: cfm-edge/<nginx version>" bash -c \
    "curl -sSI http://127.0.0.1:9099/tokens | grep -qiE '^server: cfm-edge/[0-9]+\.[0-9]+\.[0-9]+.$'"
check "error page footer says cfm-edge, never nginx" bash -c \
    "body=\$(curl -sS http://127.0.0.1:9099/e404); grep -q '<center>cfm-edge</center>' <<<\"\$body\" && ! grep -qi 'nginx' <<<\"\$body\""
check "TLS + HTTP/2" bash -c "curl -fsSk --http2 https://127.0.0.1:9443/ | grep -q 'proto=HTTP/2.0'"
check "ssl_certificate_by_lua swaps the cert by SNI" bash -c \
    "curl -sSkv --resolve lua.test:9443:127.0.0.1 https://lua.test:9443/ 2>&1 | grep -q 'CN=lua.test'"
check "default cert without that SNI" bash -c \
    "curl -sSkv --resolve other.test:9443:127.0.0.1 https://other.test:9443/ 2>&1 | grep -q 'CN=default.test'"
check "UDP 9443 bound for QUIC" bash -c "grep -qi ':24E3 ' /proc/net/udp"
if curl --version | grep -q HTTP3; then
    check "HTTP/3 request" bash -c "curl -fsSk --http3-only https://127.0.0.1:9443/ | grep -q 'proto=HTTP/3.0'"
else
    echo "  skip  HTTP/3 request (this curl has no HTTP/3)"
fi
check "no [alert]/[emerg]/lua errors in error.log" bash -c \
    "! grep -E '\[(alert|emerg|crit)\]|lua entry thread aborted|runtime error' '$P/logs/error.log'"

"$BIN" -p "$P" -c "$P/conf/nginx.conf" -s quit || true
if [ "$fail" = 0 ]; then echo "SMOKE OK"; else echo "SMOKE FAILED"; sed -n '1,80p' "$P/logs/error.log"; exit 1; fi
