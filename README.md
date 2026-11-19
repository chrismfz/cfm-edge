# cfm-edge

CFM's own in-path edge proxy: the **pristine nginx.org release** plus exactly
the Lua stack CFM's edge needs, packaged under its own name so it conflicts
with nothing (OpenResty, Angie, ea-nginx).

Why it exists: on 2026-11-18 nginx 1.31.9 fixed ten CVEs (among them the
nginx2root HTTP/2 RCE, CVE-2026-123007). A day later neither OpenResty nor
Angie had shipped it, and every CFM edge waited on two third parties. With
cfm-edge the wait is the time from nginx.org's release to our own build.

## What is built

| Component | Source | Pin |
|---|---|---|
| nginx | nginx.org release tarball | sha256 + PGP (`keys/nginx/`) |
| OpenSSL 3.5 LTS (static, QUIC) | GitHub release tarball | sha256 (same pin as `chrismfz/php`) |
| LuaJIT2, NDK, lua-nginx-module, lua-resty-core, lua-resty-lrucache, lua-cjson, lua-resty-string | the OpenResty set, as `openresty/openresty` master pins it | tag + commit |
| lua-resty-http, lua-resty-maxminddb | upstream tags | tag + commit |

All pins live in **`versions.env`**, and nothing else repeats a version.

**nginx modules:** `http_ssl`, `http_v2`, `http_v3`, `realip`,
`auth_request` and `stub_status` are added, plus the defaults (proxy,
`limit_req`, geo/map, gzip, upstream keepalive, cache). Left out, because
CFM's edge uses none of them: fastcgi, uwsgi, scgi, grpc, memcached, ssi,
autoindex, userid, mirror, empty_gif, split_clients and auth_basic (also drops
the libcrypt dependency). A module goes in when
CFM needs it, not because it exists (CLAUDE.md).

**Not included:** lua-resty-openssl. lua-resty-http logs one WARN that mTLS
to upstreams is unavailable; OpenResty nodes log the same, since their
install script does not add it either. cfm_clearance's HMAC runs on
`resty.sha256` over the FFI here, because stock ngx_lua has no
`ngx.hmac_sha256`; the smoke test pins that path.

**Our patches:**

- `patches/nginx/0001`: the edge answers as **`Server: cfm-edge`** (no
  version with `server_tokens off`) on HTTP/1, HTTP/2 and HTTP/3 and in the
  default error pages, so a curl shows at once that the edge, not the origin,
  answered. `-v` still prints `nginx/X` for tools that parse it.
- `patches/lua-resty-maxminddb/0001`: upstream loads `libmaxminddb.so`,
  which only the -devel package ships. CFM solved that on 2026-04-15 by
  making its own package require `libmaxminddb-devel`. cfm-edge loads the
  runtime soname `.so.0` first, so the edge does not depend on a -devel
  package.

## Layout on a node

| Path | What |
|---|---|
| `/usr/sbin/cfm-edge` | the binary |
| `/etc/cfm-edge/nginx.conf` | config; the package ships a **loopback-only placeholder** (127.0.0.1:9099) |
| `/usr/lib/cfm-edge/luajit/` | private LuaJIT (lib, `bin/luajit` for Lua selftests) |
| `/usr/lib/cfm-edge/lualib/` | C Lua modules (`cjson.so`) |
| `/usr/share/cfm-edge/lualib/` | pure-Lua libs (`resty/*`, `ngx/*`); compiled-in default `package.path` |
| `/usr/share/cfm-edge/site/lualib/` | operator-added Lua, searched first |
| `/var/log/cfm-edge/` | logs (rotated by the package's own `/etc/logrotate.d/cfm-edge`) |
| `/var/lib/cfm-edge/` | temp paths |
| `cfm-edge.service` | systemd unit: **not** enabled, **no** `Conflicts=` with openresty/angie, and **not** restarted by an rpm upgrade |

Installing the rpm never touches the live edge. Switching a node over is
the job of CFM's `install-edge.sh` (to be written, HANDOFF.md).

## Build

**One rpm for every EL.** It is built on EL8, the oldest glibc we serve
(2.28; glibc is backward compatible), and the same rpm is installed and tested
on EL8, EL9 and EL10. It needs only glibc, pcre2 and zlib from the system,
plus libmaxminddb (FFI); OpenSSL is static and LuaJIT is private. The same
binary also runs on Debian 10+ and Ubuntu 20.04+, which is why private files
live under `/usr/lib/cfm-edge` and not `/usr/lib64`. The .deb is a later step
(HANDOFF.md). A *fully* static nginx is not an option: `cjson.so` is
dlopen'ed, `libmaxminddb` comes in through the FFI, and `user cfm;` needs
NSS. All three break in a static binary.

```sh
make package            # THE rpm: built in AlmaLinux 8 -> dist/el8/cfm-edge-<v>-<r>.x86_64.rpm
make test-all           # that rpm: smoke + cfm-conf on EL8, EL9, EL10
make sources            # fetch + verify everything into SOURCES/
make rpm-el9            # build in a clean AlmaLinux 9 container -> dist/el9/
make smoke-el9          # install it in a fresh container, run tests/smoke.sh
make cfm-conf-el9       # run CFM's real edge config + Lua on it (CFM_DIR=../cfm)
make rpms               # a native build per EL (diagnostics only)
make rpm                # on an EL host with rpm-build, no container
```

Containers are `quay.io/almalinuxorg/almalinux:<8|9|10>` (Docker Hub
rate-limits anonymous pulls). Behind an HTTPS-only egress proxy, set
`EDGE_CA=/path/to/proxy-ca.pem`; see `tools/container-build.sh`.

## Tests

- **`tests/smoke.sh`** (installed rpm, scratch prefix) checks:
  - the binary: linkage (private LuaJIT, no system libssl) and the exported
    OpenSSL symbols that FFI users need;
  - Lua: every non-CFM module CFM requires, `resty.sha256`, the shared dict,
    and maxminddb's FFI load;
  - TLS + HTTP/2, the QUIC listener, `ssl_certificate_by_lua` cert swap by
    SNI (sslcollector's path), and `balancer_by_lua`.
- **`tests/cfm-conf.sh CFM_DIR`** is the contract with CFM. It runs
  `configs/openresty.conf`, changing only its paths, and:
  - `-t`s it;
  - starts it and sends HTTP and HTTPS/h2 requests through `cfm.lua`;
  - `require`s every `configs/lua` module inside a real nginx.

  When CFM adds something the edge lacks, this test fails rather than a node.

On every PR, CI runs lint, builds the rpm once on EL8, then runs smoke and
cfm-conf on that same rpm on EL8, EL9 and EL10. The rpm is kept as an
artifact.

## The watcher

`tools/check-deps.py` reports what is behind; `--bump` rewrites
`versions.env`. The `check-deps` workflow runs it **every 2 hours** and opens
or updates one PR (`deps/auto-update`). An nginx release whose CHANGES has a
`Security:` entry exits 4 and puts **SECURITY** in the PR title. The Lua set
moves only as OpenResty's master moves it. nginx is PGP-verified before its
sha256 is recorded.

## Release flow

1. Merge the bump PR after CI is green.
2. Build on the devbox (`make package test-all`), sign, and publish to the
   **`cfm-edge-testing`** channel of repo.nixpal.com.
3. Canary on one host (qualityweb): `edge_health` stays clean for N hours.
4. Promote to **`stable`**. Nodes take it from there; the edge is never
   unattended-upgraded fleet-wide straight from a build.

`EDGE_RELEASE` is the package release. It resets to 1 on a new nginx and
goes up by one for any other pin or packaging change, so `rpm -q cfm-edge`
always shows the nginx version first (`1.31.9-1`). There is no dist tag: the
same file installs on every EL.
