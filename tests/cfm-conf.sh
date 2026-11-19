#!/bin/bash
# cfm-conf.sh — run CFM's REAL edge config and Lua on an installed cfm-edge.
#
#   tests/cfm-conf.sh /path/to/cfm-checkout
#
# This is the contract between the two repos: when CFM adds a directive, a
# module or a Lua dependency the edge does not have, THIS fails, not a node.
#
#   1. render cfm's configs/openresty.conf into a scratch prefix (paths only:
#      /usr/local/openresty/nginx, /var/lib/cfm, /var/cache/nginx are moved;
#      `user cfm` becomes nobody; nothing else is edited) and `-t` it;
#   2. start it and send HTTP (9080) and HTTPS (9043, h2) requests through
#      cfm.lua; the CFM daemon is absent, so this proves the Lua LOADS and runs
#      its fail paths, not what it decides;
#   3. `require` every configs/lua module inside real nginx (the same
#      "LuaJIT require smoke-test of all modules" CFM's release checklist asks).
#
# Run as root where 9080/9043/9097 are free. Never touches /etc/cfm-edge or
# /var/lib/cfm.
set -euo pipefail
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy

CFM="${1:?usage: $0 /path/to/cfm-checkout}"
BIN="${BIN:-/usr/sbin/cfm-edge}"
CONF_SRC="${CONF_SRC:-$CFM/configs/openresty.conf}"
[ -f "$CONF_SRC" ] || { echo "no $CONF_SRC" >&2; exit 2; }

fail=0
ok()   { printf '  ok    %s\n' "$*"; }
bad()  { printf '  FAIL  %s\n' "$*"; fail=1; }
check(){ local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }

R="$(mktemp -d /tmp/cfm-edge-cfmconf.XXXXXX)"
stop_all() {
    "$BIN" -p "$R" -c "$R/conf/nginx.conf" -s stop >/dev/null 2>&1 || true
    "$BIN" -p "$R/req" -c "$R/req/nginx.conf" -s stop >/dev/null 2>&1 || true
}
trap 'stop_all; rm -rf "$R"' EXIT
mkdir -p "$R"/{conf,logs,lua-legacy,cache,lib/lua,lib/nginx,lib/certs/selfsigned,req/logs}
chmod 0755 "$R"

cp -p "$CFM"/configs/lua/*.lua "$R/lib/lua/"
# The Lua names a few daemon-written files by absolute path (the sslcollector
# token): point the copies at the scratch prefix too, and stand in for the
# daemon's token so sslcollector loads and the TLS path can be exercised.
sed -i "s#/var/lib/cfm/#$R/lib/#g" "$R"/lib/lua/*.lua
printf 'return "%s"\n' "$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')" >"$R/lib/lua/cfm_token.lua"
cp -p "$CFM"/configs/trusted_proxies.conf "$CFM"/configs/challenge_waf_bypass.conf "$R/conf/"
cp -p /etc/cfm-edge/mime.types "$R/conf/"
: >"$R/conf/cfm-panel-listeners.conf"     # rendered by the daemon (DNAT on); empty = panel ports off
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=cfm-edge-selftest" \
    -keyout "$R/lib/certs/selfsigned/privkey.pem" -out "$R/lib/certs/selfsigned/fullchain.pem" >/dev/null 2>&1
chmod -R a+rX "$R/lib" "$R/conf"

sed -e "s#/usr/local/openresty/nginx/conf/#$R/conf/#g" \
    -e "s#/usr/local/openresty/nginx/logs/#$R/logs/#g" \
    -e "s#/usr/local/openresty/nginx/lua/#$R/lua-legacy/#g" \
    -e "s#/var/lib/cfm/#$R/lib/#g" \
    -e "s#/var/cache/nginx/#$R/cache/#g" \
    -e 's#^user cfm;#user nobody;#' \
    "$CONF_SRC" >"$R/conf/nginx.conf"

echo "== cfm config ($(basename "$CONF_SRC")) on $("$BIN" -v 2>&1)"
left="$(grep -nE '/usr/local/openresty|/etc/angie|/var/lib/cfm/' "$R/conf/nginx.conf" | grep -vE '^\s*[0-9]+:\s*#' || true)"
[ -z "$left" ] || { echo "  note: unrendered live paths (comments excluded):"; echo "$left" | sed 's/^/        /'; }
if "$BIN" -p "$R" -c "$R/conf/nginx.conf" -t 2>"$R/t.out"; then ok "-t on the real CFM config"; else
    bad "-t on the real CFM config"; cat "$R/t.out"; exit 1; fi

"$BIN" -p "$R" -c "$R/conf/nginx.conf"
for _ in $(seq 1 50); do [ -s "$R/logs/nginx.pid" ] && break; sleep 0.1; done
check "started" test -s "$R/logs/nginx.pid"

code80="$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: example.com' http://127.0.0.1:9080/ || true)"
code443="$(curl -sk -o /dev/null -w '%{http_code} %{http_version}' --http2 --resolve example.com:9043:127.0.0.1 https://example.com:9043/ || true)"
echo "  http  :9080 -> $code80"
echo "  https :9043 -> $code443"
check "HTTP answered through cfm.lua" bash -c "[[ '$code80' =~ ^[1-5][0-9][0-9]$ ]]"
check "HTTPS/h2 answered through cfm.lua" bash -c "[[ '$code443' =~ ^[1-5][0-9][0-9]\ 2$ ]]"

# Every CFM module, required inside a real nginx (same lua_package_path shape).
mods=""
for f in "$R"/lib/lua/*.lua; do m="$(basename "$f" .lua)"; mods="$mods\"$m\","; done
cat >"$R/req/nginx.conf" <<EOF
worker_processes 1;
error_log $R/req/logs/error.log warn;
pid $R/req/logs/nginx.pid;
events { worker_connections 64; }
http {
    access_log off;
    lua_package_path '$R/lib/lua/?.lua;;';
    $(grep -E '^\s*lua_shared_dict\s' "$R/conf/nginx.conf" | sort -u | tr '\n' ' ')
    server {
        listen 127.0.0.1:9097;
        location = /req {
            default_type text/plain;
            content_by_lua_block {
                -- Entry SCRIPTS (cfm.lua, log-cfm.lua, ...) run request logic at
                -- load; for them only "it compiled and its requires resolved"
                -- matters, so a runtime error after loadfile is reported apart.
                local out = {}
                for _, m in ipairs({${mods%,}}) do
                    local ok, err = pcall(require, m)
                    if ok then
                        out[#out+1] = "ok " .. m
                    elseif tostring(err):find("module '[^']+' not found") then
                        out[#out+1] = "MISSING " .. m .. ": " .. tostring(err):match("module '[^']+' not found")
                    else
                        local chunk, cerr = loadfile("$R/lib/lua/" .. m .. ".lua")
                        out[#out+1] = (chunk and "script " or "BROKEN ") .. m .. (chunk and "" or (": " .. tostring(cerr)))
                    end
                end
                ngx.say(table.concat(out, "\n"))
            }
        }
    }
}
EOF
"$BIN" -p "$R/req" -c "$R/req/nginx.conf"
for _ in $(seq 1 50); do [ -s "$R/req/logs/nginx.pid" ] && break; sleep 0.1; done
res="$(curl -fsS http://127.0.0.1:9097/req || true)"
echo "$res" | sed 's/^/  lua   /'
check "every CFM Lua module resolves its requires" bash -c "! grep -qE '^(MISSING|BROKEN)' <<<'$res'"
check "the module list is not empty" bash -c "grep -q '^ok cfm_waf' <<<'$res'"

# Load errors are what this test exists for; runtime errors from the missing
# daemon (connect() to /run/cfm/*.sock) are expected and listed separately.
# worker_rlimit_nofile needs a hard limit this environment may not have (a
# container / sandbox); that alert is the host's, not the edge's, so it is
# skipped ONLY when the hard limit really is below what CFM asks for.
want_nofile="$(grep -oE '^\s*worker_rlimit_nofile\s+[0-9]+' "$R/conf/nginx.conf" | grep -oE '[0-9]+' | head -1 || true)"
nofile_skip='^$'
if [ -n "$want_nofile" ] && [ "$(ulimit -Hn)" != unlimited ] && [ "$(ulimit -Hn)" -lt "$want_nofile" ]; then
    nofile_skip='setrlimit\(RLIMIT_NOFILE'
    echo "  note  hard nofile here is $(ulimit -Hn) < worker_rlimit_nofile $want_nofile: its setrlimit alert is skipped"
fi
# Known and expected: lua-resty-http's optional mTLS support warns that
# lua-resty-openssl is absent (same on OpenResty nodes, whose install script
# does not add it either; CFM uses no upstream client certs).
grep -hE "module '[^']+' not found|failed to load|attempt to call|\[emerg\]|\[alert\]" \
    "$R"/logs/*.log "$R"/req/logs/error.log 2>/dev/null \
    | grep -vE 'resty\.openssl' \
    | grep -vE "$nofile_skip" | sort -u | head -20 >"$R/loaderr" || true
check "no Lua load errors in the edge's error logs" test ! -s "$R/loaderr"
[ -s "$R/loaderr" ] && sed 's/^/        /' "$R/loaderr"
echo "  (expected without a daemon:) $(cat "$R"/logs/*.log 2>/dev/null | grep -c 'connect() to unix:' || true) unix-socket connect failures"

stop_all
if [ "$fail" = 0 ]; then echo "CFM CONF OK"; else echo "CFM CONF FAILED"; tail -40 "$R"/logs/error.log 2>/dev/null; exit 1; fi
