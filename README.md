# cfm-edge

CFM's own in-path edge proxy: the **pristine nginx.org release** plus exactly
the Lua stack CFM's edge needs, packaged under its own name so it conflicts
with nothing (OpenResty, Angie, ea-nginx).

Why it exists: on 2026-11-18 nginx 1.31.9 fixed ten CVEs (among them the
nginx2root HTTP/2 RCE, CVE-2026-123007). A day later neither OpenResty nor
Angie had shipped it, and every CFM edge waited on two third parties. With
cfm-edge the wait is the time from nginx.org's release to our own build.

What comes next (hardening, the fleet blockers): ROADMAP.md. The
integration state and next steps: HANDOFF.md.

## A hardened edge

**Why.** The edge parses every request to every site on the server, before
WAF or challenge. An RCE in it (nginx2root, CVE-2026-123007, was one; there
will be others) hands the attacker that process. Two things then decide the
damage: how soon the fix runs, and what the process may touch until it does.
On a cPanel server `/home` is every customer's site, and the access logs hold
every visitor's IP and full URL.

**Against what the fleet ran before** (measured 2026-11-23):

| | OpenResty / WebShield, as packaged | cfm-edge |
|---|---|---|
| Time to an nginx security fix | the vendor's: nginx 1.31.9 shipped 2026-11-18, OpenResty 1.31.9.1 reached the nodes 2026-11-23 | our own build from nginx.org; `check-deps` looks every 2 h and flags a `Security:` release |
| Inputs | the vendor's | nginx sha256 + PGP, OpenSSL sha256, git tags pinned to commits (`versions.env`) |
| `systemd-analyze security` | 9.2 UNSAFE (`openresty.service`, rigel), 9.6 UNSAFE (`imunify360-webshield`, titan) | 4.3 (EL8) / 4.2 (EL9+) OK |
| Filesystem | writable wherever root can write | read-only but the 5 measured write paths; `/home` hidden; `/run` read-only, so a compromised root master cannot write a unit into `/run/systemd/system` |
| Workers | the vendor's user | `cfm` (`/sbin/nologin`), `NoNewPrivileges`, 6 capabilities in the bounding set (no `CAP_NET_BIND_SERVICE`: every listener is above 1024); `/proc` shows them only their own processes |
| Logs | the vendor's modes (cfm-edge's own were 0644 until round 2: on virgo, 352 shell accounts could read them) | 0640 (`UMask=0027`, logrotate `create 0640`) |
| Modules | the vendor's set | 12 modules and `stub_status`, threads, file AIO left out; without `mirror` and `ssi` the CVE-2026-123634 path does not exist |
| OpenSSL | the vendor's build | built with the stack protector, FORTIFY and CET flags; `%check` fails a build whose ELFs lack PIE, RELRO, BIND_NOW or a non-exec stack |
| An upgrade | restarts in the path | `%posttrans` takes a running edge out of CFM's DNAT, `-t`s the new binary, restarts, puts it back; a failed start leaves the origin serving |

**What it does not cover** (ROADMAP.md §2, "Decided"):
- The workers, as `cfm`, still read what `cfm` reads (CFM's state, the
  `root:cfm 0640` Lua token files) and reach CFM's sockets.
- The master stays root: a non-root master guards only against a master
  compromise, which needs a worker RCE and then an escalation, and it
  coupled the two repos at too many places (measured, 2026-11-23).
- No `SystemCallFilter=` and no `MemoryDenyWriteExecute=` (LuaJIT's JIT
  writes code at run time).

Every sandbox line was measured live on a canary before it went into the
unit (the recipe: ROADMAP.md §2); a missing write path does not stop the
edge, it fails a large upload later.

## What is built

| Component | Source | Pin |
|---|---|---|
| nginx | nginx.org release tarball | sha256 + PGP (`keys/nginx/`) |
| OpenSSL 3.5 LTS (static, QUIC) | GitHub release tarball | sha256 (same pin as `chrismfz/php`) |
| LuaJIT2, NDK, lua-nginx-module, lua-resty-core, lua-resty-lrucache, lua-cjson, lua-resty-string | the OpenResty set, as `openresty/openresty` master pins it | tag + commit |
| lua-resty-http, lua-resty-maxminddb | upstream tags | tag + commit |

All pins live in **`versions.env`**, and nothing else repeats a version.

**nginx modules:** `http_ssl`, `http_v2`, `http_v3`, `realip` and
`auth_request` are added, plus the defaults (proxy, `limit_req`, geo/map,
gzip, upstream keepalive, cache). Left out, because CFM's edge uses none of
them: fastcgi, uwsgi, scgi, grpc, memcached, ssi, autoindex, userid, mirror,
empty_gif, split_clients, auth_basic (also drops the libcrypt dependency),
`stub_status`, and thread pools / file AIO (`--with-threads`,
`--with-file-aio`: CFM's config has no `aio` or `thread_pool`). A module
goes in when CFM needs it, not because it exists (CLAUDE.md).

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
| `cfm-edge.service` | systemd unit: **not** enabled, **no** `Conflicts=` with openresty/angie; an rpm upgrade restarts it only when it is running, out of the path (`upgrade-restart.sh`) |

Installing the rpm never takes the live edge's ports. Switching a node over
is the job of CFM's `install-edge.sh`.

## Build

**One rpm for every EL.** It is built on EL8, the oldest glibc we serve
(2.28; glibc is backward compatible), and the same rpm is installed and tested
on EL8, EL9 and EL10. It needs only glibc, pcre2 and zlib from the system,
plus libmaxminddb (FFI); OpenSSL is static and LuaJIT is private. The same
binary also runs on Debian and Ubuntu, which is why private files live under
`/usr/lib/cfm-edge` and not `/usr/lib64`. **`make deb`** repacks that rpm as
`dist/deb/cfm-edge_<v>-<r>_amd64.deb` for Debian 12+ / Ubuntu 22.04+ (the
unit's `ProtectProc=` needs systemd 247): the same files, with no dpkg
conffile (`/etc` is seeded by postinst from `/usr/share/cfm-edge/defaults/`,
`packaging/config-files.list`) and the upgrade restart as a dpkg trigger;
`tools/build-deb.sh` lists every difference. A *fully* static nginx is not an option: `cjson.so` is
dlopen'ed, `libmaxminddb` comes in through the FFI, and `user cfm;` needs
NSS. All three break in a static binary.

**What a build host needs.** Any Linux works, as long as it can run
containers. Everything that compiles (gcc, rpm-build, perl, the pcre2/zlib
headers) lives inside the AlmaLinux 8/9/10 containers. The host only fetches
and verifies sources and drives those containers:

- `podman` or `docker`: `ENGINE=podman` on the devbox, docker is the default.
- `make`, `git`, `curl`, `gpg` + `gpgv` (nginx PGP check), `gzip`,
  `sha256sum`, `python3` (check-deps).
- A cfm checkout next to this repo (`../cfm`) or `CFM_DIR=`, for `test-all`.
- Network to nginx.org, github.com (git over HTTPS + release downloads),
  quay.io and the AlmaLinux mirrors.
- `shellcheck` (`make lint`, which `make release` runs first; EL: `dnf
  install ShellCheck` from EPEL).
- `rpm2cpio`, `cpio` and `dpkg-deb` for `make deb` (EL: `dnf install cpio
  dpkg`, dpkg from EPEL).
- Optional: `ssh` + `rsync` and a key for repo.nixpal.com (`make sync`).
- About 3 GB of disk for images and the build tree.

On a new VM, `make doctor` checks all of this and names what is missing.

```sh
make help               # every target, one line each
make doctor             # does this host have what a build needs?
make package            # THE rpm: built in AlmaLinux 8 -> dist/el8/cfm-edge-<nginx>-<YYYYMMDD.HHMMSS>.x86_64.rpm
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

On the devbox (AlmaLinux 10 + podman; EL8 is only the container image):

```sh
make check                              # what is behind upstream (changes nothing)
make update                             # rewrite versions.env; review git diff
ENGINE=podman make package test-all     # build on EL8, test on EL8/9/10
make sync                               # upload to repo.nixpal.com (like cfm)
```

The usual way in is the check-deps PR (CI green, then merge); `make update`
does the same locally when you won't wait for it.

`make sync` uploads only `cfm-edge-<v>-<r>.x86_64.rpm` (no debuginfo or src)
to `chris@repo.nixpal.com:~/packages/rpm`, plus
`~/packages/cfm-edge-checksums.txt`. It never touches cfm's `checksums.txt`.
It **refuses**:

- an rpm whose exact bytes did not pass `make test-all` (`dist/el8/.tested`);
- a filename the repo already has, in `~/packages/rpm` or under
  `https://repo.nixpal.com/el/`. Every build has its own timestamp, so this
  catches only a `BUILD_STAMP=` reuse that would silently change a published
  package.

`FORCE=1` overrides both, knowingly.

Publishing is the same as for cfm. As root on repo.nixpal.com, run
`/root/repos-update.sh --rpm-only`. It signs with the NixPal key, runs
createrepo into `/el/`, and signs the repomd. Nodes see it there
(`gpgcheck=1`).

Then **canary** on one host (qualityweb) and keep `edge_health` clean for N
hours before any other node upgrades. The rpm never restarts blindly
(`%systemd_postun`, not `_with_restart`): `%posttrans` runs
`upgrade-restart.sh`, which restarts only a running edge, after the new
binary passes `-t`, and out of CFM's DNAT (`cfm edge off` → restart → check
→ `cfm edge on`). `/etc/cfm-edge/no-upgrade-restart` opts a node out. Today `/el/` is a single channel
for every nixpal package. A separate `cfm-edge-testing` channel is an open
decision (HANDOFF.md).

**Versioning, like cfm's packages:** Version is the nginx version and
Release is the build time in UTC, e.g. `cfm-edge-1.31.9-20261119.182233`.
Every build sorts newer than the last, so a fixed or experimental rebuild is
an update `dnf` sees, with nothing to bump by hand. `rpm -q cfm-edge` still
shows the nginx version first. There is no dist tag: the same file installs
on every EL. `BUILD_STAMP=` pins it to rebuild an exact release.
