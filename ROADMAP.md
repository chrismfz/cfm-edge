# cfm-edge roadmap

What comes after the first build. HANDOFF.md holds the integration steps
(the CFM side and the canary); this file holds what makes the edge harder
to break into, and what must change before it reaches the fleet.

The guiding idea: cfm-edge is ours alone, and it does one job: proxy plus
Lua. It runs no PHP, no FastCGI and no third-party modules. That lets us
lock it down far tighter than a general-purpose nginx package could be. If
someone finds a bug in nginx or our Lua, they should land in a process that
can reach as little as possible.

Every item is tested on the canary before the fleet, and nothing here is
promised as done until the code says so.

## 1. Before the fleet (canary blockers)

Small changes, but each is visible the first time `install-edge.sh` stops
and starts an edge.

- [x] **`TimeoutStopSec=5` → `90`** in `cfm-edge.service` (smoke test
  pins it).
  - `openresty.service` on the fleet has 1min 30s today.
  - With 5 seconds, every `systemctl stop` or `restart` SIGKILLs whatever
    has not finished: large uploads, websockets, cPanel/webmail sessions
    that pass through the edge. `install-edge.sh` stops and starts on
    every switch, so that is where it would show.
- [x] **An upgrade applies itself without refusing connections**:
  `upgrade-restart.sh` from `%posttrans` (CHANGELOG, CLAUDE.md). It restarts
  a running edge out of CFM's DNAT, after `-t`. `tests/upgrade-restart_test.sh`
  pins every branch.
- [decided, not adding] **`worker_shutdown_timeout`** (measured 2026-11-21).
  It caps the drain on a reload as well as on a stop, so every reload would
  cut whatever long request is in flight. The fleet reloads its edge 3-8
  times a day, and has thousands of requests a day over 10 s (5-9k per
  node), hundreds over 60 s, the longest at 300 s (downloads, panel
  transfers).
  - The stop it would have shortened no longer refuses connections:
    `upgrade-restart.sh` takes the edge out of the path first. What a long
    drain costs is only the time without WAF: 17-90 s in the fleet upgrade
    of 2026-11-21.
  - `TimeoutStopSec=90` already bounds a stop.
  - Revisit only if old workers pile up across reloads (none were draining
    when measured).
- [x] **`LimitNOFILE=262144`** in the unit, to match `openresty.service`
  (smoke test pins it).
  - CFM's config sets `worker_rlimit_nofile 65535`. The workers apply it
    before they drop privileges, so the workers are covered today.
  - The unit limit means we no longer depend on that line if the config
    ever changes.
- [x] **CFM's cfm-edge config and the unit agree on the pid.** First by
  mapping the `pid` line to `/run/cfm-edge.pid`; since cfm PR #1755
  (2026-11-22) by setting no `pid` at all, so the package's compiled
  `--pid-path` (= its `PIDFile=`) applies and cfm-edge can move it (§2,
  "Narrow `/run`"). With `Type=forking`, a mismatch makes systemd wait for
  a pid file that never appears and kill the edge.
- [ ] **qualityweb: h2/h3 back on.** That node carries our local
  "http2/http3 off" change. With cfm-edge 1.31.9, `http2 on`, `http3 on`
  and `quic` go back into the template, which was the reason for building
  cfm-edge in the first place.
- [ ] **cfm repo, the packaging change that adopts cfm-edge** (cfm PR #1725
  lists them):
  - the sidecar deploy refreshes `/etc/cfm-edge/` too;
  - `cfm-edge-listen-v6.sh` writes `/etc/cfm-edge/cfm-listen-v6-*.conf`;
  - the panel Lua guard's `-t` probe prefers the active engine.

## 2. Hardened systemd unit

Each line restricts what the edge may touch, and a missing write path does
not stop the edge from starting: it fails a large upload or response later
with "Read-only file system" while every health check is green. So every
step gets a live run on a canary before the unit changes.

### Round 1: done (in `cfm-edge.service`, 2026-11-20)

Measured live on virgo (CloudLinux 8, systemd 239) and rigel (CloudLinux 9,
systemd 252), as a drop-in (`/etc/systemd/system/cfm-edge.service.d/
zz-hardening.conf`) before it went into the unit. `systemd-analyze security`:
**9.2 UNSAFE → 4.4 (EL8) / 4.5 (EL9) OK**.

- [x] `ProtectSystem=strict` + `ReadWritePaths=` (the measured list below)
- [x] `ProtectHome=yes` (on cPanel, `/home` is every customer's site)
- [x] `PrivateTmp`, `PrivateDevices`, `NoNewPrivileges`
- [x] `CapabilityBoundingSet=` 7 capabilities: `CAP_NET_BIND_SERVICE
  CAP_SETUID CAP_SETGID CAP_CHOWN CAP_DAC_OVERRIDE CAP_KILL CAP_SYS_RESOURCE`
- [x] `RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6`, `RestrictNamespaces`,
  `RestrictRealtime`, `RestrictSUIDSGID`, `LockPersonality`
- [x] `ProtectKernelTunables`, `ProtectKernelModules`, `ProtectControlGroups`
- [x] `ProtectKernelLogs`, `ProtectClock`, `ProtectHostname`: EL8's systemd
  239 logs "Unknown lvalue" and ignores them; they apply on EL9/EL10
  (measured on rigel).

What the live run checked: restart and reload; IPv4 and IPv6; a 5 MB POST
(written to `client_body_temp`); Site Cache HIT/MISS and new cache files;
WAF challenge (XSS) and block (traversal); the sslcollector load
(4070 / 682 certs); the panel listeners; the workers run as `cfm` with
`NoNewPrivs=1`; `/etc` and `/usr` read-only and `/home` empty inside the
namespace; 0 "Read-only / Permission denied" in the error log.

**The write paths, measured** (not the config's compiled-in defaults):
- `/var/log/cfm-edge` (logs);
- `/var/cache/nginx` (Site Cache, `proxy_cache_path`);
- `/var/lib/cfm-edge` (compiled-in temp paths);
- `/var/lib/cfm/nginx` (`client_body_temp_path` / `proxy_temp_path` in
  CFM's config; first missed, see below);
- `/var/lib/cfm/scanner` (ClamAV inline scan, `cfm_clamav.lua` pending file);
- `/run` (pid + lock).

Unix sockets (bridge, sslcollector, ingest, clamd) need no write path.

**How to measure** (repeat for any new write path or directive):
1. List what the config and Lua write: `grep -nE 'temp_path|cache_path|
   access_log|error_log|pid' nginx.conf`, `cfm-edge -V` (compiled-in paths),
   `io.open(..., "w")` in `/var/lib/cfm/lua`.
2. Config test inside the sandbox, the live edge untouched:
   `systemd-run --wait --pipe -p <each directive> /usr/sbin/cfm-edge -t`.
   EL8's 239 refuses some directives transiently even when a unit file
   accepts them; test those on EL9.
3. Take the edge **out of the path first** (`cfm edge off`, `cfm edge panel
   off`; on an older cfm `cfm dnat off`, `cfm dnat cpanel off`): a restart
   closes the ports at once and drains for up to 90 s (§1). Check that the
   off took effect before restarting (virgo, 2026-11-20: the command did not
   exist, DNAT stayed on, and new connections were refused for 30 s).
4. Drop-in, `daemon-reload`, restart (on failure: remove it, restart).
5. As the `cfm` user inside the worker's namespace, write to every path:
   `nsenter -t <worker> -m -- setpriv --reuid=cfm --regid=cfm --init-groups
   touch <dir>/.rw`. This catches what the config test cannot: virgo ran
   3 minutes with the temp dirs read-only, and one large proxied response
   failed with EROFS before this check found it.
6. Edge back on, then live traffic, a reload and the error log.

### Next

Ranked 2026-11-22 by win against risk. "Loud" means a mistake fails `-t`,
the start or a test with the path or directive named; "silent" means it
fails later, somewhere else, with nothing pointing back here. Silent risks
are what we avoid.

- [ ] **Narrow `/run`** (in the unit since this rpm; canary first, below).
  Win: real. The master is root, and `/run/systemd/system`
  is a unit load path, so a compromised master with `/run` writable could
  write an unsandboxed unit there. Measured on virgo: the edge writes only
  its pid under `/run`. `/run/cfm/*.sock` and `/var/run/sslcollector.sock`
  are only connected to, which a read-only mount allows. Risk: loud (a pid
  path the sandbox refuses fails the start), but it crosses repos: the
  unit's `PIDFile=`, CFM's `pid` line and the logrotate `postrotate` must
  agree. Done in order: CFM's conf sets no `pid` (cfm PR #1755), then this
  rpm moves the compiled `--pid-path` and `PIDFile=` into
  `RuntimeDirectory=cfm-edge` and drops `/run` from `ReadWritePaths=`.
  `upgrade-restart.sh` refuses to restart while the live config still sets
  its own `pid`; logrotate tries the new pid path, then the old.
  **The pid dir must exist while the edge is stopped** (found by the canary,
  virgo, 2026-11-23): `nginx -t` (and `-T`) opens the pid file
  (create-or-open), and CFM runs `-t` outside the unit with the edge stopped
  (`cfm-edge-listen-v6.service` before every start, boot included; the
  install script; the panel self-test). A `RuntimeDirectory` alone is removed
  at stop and made only at start, so those would fail with "No such file or
  directory". The rpm ships a tmpfiles.d entry (`d /run/cfm-edge`, made at
  boot, and by `%post` at install) and the unit keeps the dir at stop
  (`RuntimeDirectoryPreserve=yes`). The same open is why the sandboxed `-t`
  of `upgrade-restart.sh`, which has no `RuntimeDirectory` (a transient one
  would remove the live dir at exit), gets `ReadWritePaths=/run/cfm-edge`:
  without it every upgrade refused its restart ("Read-only file system").
- [ ] **`UMask=0027`** (same rpm), and `%post` drops the world bits of the
  existing logs once; logrotate `create 0640`. The log dir stays 0755: the
  workers reopen the logs on USR1 as `cfm`, and the package cannot name a
  `cfm` group (it does not create that user). 0640 files are enough.
  Why: the logs were 0644 in a 0755 dir: on virgo, 352 accounts with a shell
  could read every visitor's IP and full URL, query strings included (reset
  tokens). CageFS hides `/var/log` from jailed users, but nothing in the
  package relies on that.
  **What `UMask` covers, measured on the canary:** only what nginx opens
  before it daemonizes (the logs at start, the pid: 0640). nginx calls
  `umask(0)` when it daemonizes (master and workers read `Umask: 0000`), so
  a file it creates later takes nginx's own mode: a log reopened on USR1 or
  HUP that does not exist yet is 0644. logrotate's `create 0640` makes every
  rotated log before the USR1, which is what keeps them 0640. Files the Lua
  writes (ClamAV `pending`) are under umask 0 as before; their dir is
  root:cfm 0770.
- **Canary for both, before the rpm** (CLAUDE.md: a drop-in first). Passed
  on virgo (EL8, systemd 239), 2026-11-23: EL8 makes a `RuntimeDirectory`
  writable under `ProtectSystem=strict` without listing it. The drop-in for
  a node whose binary still has the old compiled pid path:
  ```ini
  # /etc/systemd/system/cfm-edge.service.d/zz-canary-pr13.conf
  [Service]
  PIDFile=/run/cfm-edge/cfm-edge.pid
  RuntimeDirectory=cfm-edge
  RuntimeDirectoryMode=0755
  RuntimeDirectoryPreserve=yes
  # nginx -t opens the pid file too: every -t needs the -g as well
  ExecStartPre=
  ExecStartPre=/usr/sbin/cfm-edge -t -q -g "pid /run/cfm-edge/cfm-edge.pid;"
  ExecStart=
  ExecStart=/usr/sbin/cfm-edge -g "pid /run/cfm-edge/cfm-edge.pid;"
  ExecReload=
  ExecReload=/usr/sbin/cfm-edge -t -q -g "pid /run/cfm-edge/cfm-edge.pid;"
  ExecReload=/bin/kill -s HUP $MAINPID
  ReadWritePaths=
  ReadWritePaths=/var/log/cfm-edge /var/cache/nginx /var/lib/cfm-edge /var/lib/cfm/nginx /var/lib/cfm/scanner
  UMask=0027
  ```
  plus the new `/etc/logrotate.d/cfm-edge` (it tries both pid paths). The
  installed `upgrade-restart.sh` runs `-t` without the `-g`, so the canary's
  restart ran it with `CFM_EDGE_BIN` pointing at a wrapper that adds
  `-g "pid /tmp/cfm-edge-test.pid;"` (the sandbox has `PrivateTmp`). Then
  the recipe above. Results: `/run` and `/run/systemd/system` read-only to
  the root master, `/run/cfm-edge` writable, the pid there, reload OK, a
  forced logrotate made 0640 files and the workers reopened them (USR1
  through the new path), 200 on live https, out of the path 89 s.
  Remove the drop-in, the logrotate backup and the wrapper once the rpm is
  installed.
- [ ] Drop `CAP_NET_BIND_SERVICE` (every listener is above 1024) and check
  `CAP_DAC_OVERRIDE`. Win: small (root without them still owns almost
  everything). Risk: loud (bind or open fails at `-t`/start). One canary
  pass, together with:
- [ ] `ProtectProc=invisible` (EL9+; EL8's systemd ignores it). Win: small, a
  worker no longer sees other users' processes. Risk: low; check first that
  no edge Lua reads another process's `/proc`.

## 3. Compile hardening

**Measure before adding.** The spec already passes `%{optflags}` and
`%{build_ldflags}` (redhat-rpm-config) to nginx and LuaJIT. On EL8 these
already include:
- the stack protector (`-fstack-protector-strong`);
- `-D_FORTIFY_SOURCE=2`;
- `-fstack-clash-protection` and `-fcf-protection`;
- PIE, RELRO and `-z now`.

- [ ] Run `checksec` (or `readelf`/`hardening-check`) on `/usr/sbin/cfm-edge`,
  `libluajit-5.1.so` and `cjson.so`, and record the result here.
  - First read, `/usr/sbin/cfm-edge` 1.31.9-20261120 on rigel (`readelf`):
    PIE (`DYN`, `FLAGS_1 NOW PIE`), full RELRO (`GNU_RELRO` + `BIND_NOW`),
    non-executable stack (`GNU_STACK RW`), stack protector
    (`__stack_chk_fail`), FORTIFY in use (4 `__*_chk` symbols). Not yet
    checked: `-fcf-protection` / `-fstack-clash-protection` (need
    `annobin`/`annocheck`), LuaJIT and `cjson.so`.
- [x] **`%check` asserts the hardening of every ELF we ship**
  (`packaging/rpm/elf-hardening-check.sh`): every ELF under the buildroot
  (`/usr/sbin/cfm-edge`, `libluajit-5.1.so.2`, `cjson.so`, the luajit CLI,
  anything added later) needs a non-executable `GNU_STACK`, `GNU_RELRO` and
  `BIND_NOW`; the binary also PIE (reported, not enforced, for the luajit
  CLI). The first three must be present, or the build fails.
- [x] **OpenSSL is built by its own `Configure`** (static, through
  `--with-openssl`), so it did not get the distro flags. Measured by the
  `%check` script on 2026-11-22 (OpenSSL 3.5.9, EL8): its Makefile read
  `CFLAGS=-Wall -O3 -fPIC`, and 0 of 1000 `libcrypto.a` / 94 `libssl.a`
  objects had the stack protector or FORTIFY (nginx's own objects: 69% / 6%).
  The C code of every TLS handshake (parsers, ASN.1, X.509) ran unprotected.
  Now passed through `--with-openssl-opt`: `-fstack-protector-strong
  -fstack-clash-protection -fcf-protection -D_FORTIFY_SOURCE=2`, OpenSSL's
  assembly kept on. `%check` enforces the flags and a nonzero share.
  - [x] Handshake CPU before/after on virgo (2026-11-22, live node, RSA-2048
    cert, TLS 1.3 + X25519): worker CPU per new handshake, 3 rounds of 20 s
    with 8 `openssl s_time -new` clients, an idle window of the same length
    subtracted. Before 1.378 / 1.391 / 1.373 ms (mean 1.381), after 1.402 /
    1.427 / 1.355 ms (mean 1.395): +1%, inside the after-rounds' own ±3%
    spread. No measurable cost. Script: `/root/cfm-edge-hardening/hs-bench.sh`
    on virgo.
- [ ] `_FORTIFY_SOURCE=3` once EL8 leaves the fleet (the build moves to the
  next-oldest EL, CLAUDE.md).
- [ ] An `-fzero-call-used-regs` / `-ftrivial-auto-var-init=zero` check:
  cost against benefit, measured.
- **LTO stays off** (LuaJIT, CLAUDE.md).
- [decided] `-O3` / `-march=native` stay out of the release rpm: it keeps the
  EL8 CPU baseline and the distro flags. A host-specific build (an R630) is an
  experiment outside the repo, measured on handshake CPU (§6) with nginx,
  cert, TLS group and client held constant.

## 4. Attack surface: modules

Done (spec `--without-*`):
- auth_basic, fastcgi, uwsgi, scgi, grpc, memcached, ssi, autoindex,
  userid, mirror, empty_gif, split_clients.
- Removing `http_mirror_module` and `http_ssi_module` removes the
  CVE-2026-123634 path entirely.

- [x] Review what remains against "a module goes in when CFM needs it"
  (CLAUDE.md). Read on virgo's live config, 2026-11-22: `auth_request` (2
  uses) and `realip` are used; no `aio`, `thread_pool` or `stub_status`, so
  `--with-threads`, `--with-file-aio` and `stub_status` are dropped (same
  rpm as the `/run` change). `compat` stays while a dynamic module (Brotli, §7) is possible.
  Win: small (less code). Risk: loud, since CFM's real config runs `-t` in
  `make test-all` (cfm-conf). CFM's Go, Lua, confs and scripts use none of
  the three either (grep, 2026-11-22).

## 5. Runtime

- [ ] Workers run as `cfm`, with no shell and no home that means anything.
- [ ] The config is root-owned and read-only to the workers. The generated
  Lua token files keep `root:cfm 0640` (cfm CLAUDE.md §5).
- [ ] Confirm `worker_rlimit_nofile` stays in CFM's config (it covers the
  workers today, §1).

## 6. Tests

- [x] **The smoke test's forced log rotation runs on a copy** (2026-11-21).
  - **The bug:** `logrotate -f` on the packaged `/etc/logrotate.d/cfm-edge`
    rotated every live `/var/log/cfm-edge/*.log` and sent USR1 to the master
    in `/run/cfm-edge.pid`, on a host with a live edge (which the script
    promises it is safe next to).
  - **Now:** the two forced runs use a copy whose glob and pid file point into
    the scratch dir, and the test fails if the copy still names a live path.
    `logrotate -d` still parses the packaged file.
- [ ] **A real HTTP/3 request in the test run, never skipped.** The smoke test
  checks the QUIC listener binds, but skips the `--http3-only` request when
  the container's curl has no HTTP/3, which EL's curl does not. That breaks
  "a test that cannot run must fail". The private OpenSSL is what QUIC rides
  on, so every OpenSSL bump needs this.
  - Simplest: a QUIC handshake with ALPN `h3` through `openssl s_client
    -quic` built from the same pinned OpenSSL.
  - Or a pinned curl with HTTP/3 in one test container.

## 7. Performance (measure first)

The goal is less CPU per connection and fewer bytes. Each item is measured
before and after on the same traffic; nothing ships on reasoning alone.

- [ ] **TLS handshakes: full vs resumed, per connection.** Baseline today:
  `ssl_session_cache shared:cfm_ssl:20m`, `ssl_session_timeout 4h` (CFM's
  conf).
  - Count per connection, not per access-log line: `sslr="r"` repeats on
    every request of an HTTP/2 connection and overstates resumption.
  - Report CPU-seconds per 1,000 handshakes (and joules if measured).
  - This is the first measurement for "less CPU per handshake", and the
    baseline for §3's OpenSSL flags.
- [ ] **Compression today**, read-only: Accept-Encoding, the upstream and the
  final Content-Encoding, MIME type and bytes.
  - It tells how many compressible bytes leave uncompressed to clients that
    accept br.
  - Where the origin (LiteSpeed) already sends br, the edge only passes it
    through.
  - It decides the Brotli item below.
- [ ] **`pcre_jit on;`** in the main context: a cheap, reversible A/B.
  - **What it covers:** the regexes of the nginx config only, about 6
    `location ~` and 40 regex `map` / `if` in CFM's conf.
  - **What it does not:** CFM's Lua makes no `ngx.re` call (measured
    2026-11-21: its ~1,000 searches are Lua patterns, run by LuaJIT, not
    PCRE), so the WAF/challenge logic is untouched.
  - **Expectation:** small. Measure CPU per 1,000 requests on representative
    traffic. PCRE's JIT needs W+X memory, like LuaJIT's (§2: no
    `MemoryDenyWriteExecute` either way).
- [ ] **Brotli (dynamic module, opt-in)**, only if the compression read shows
  enough uncompressed bytes. It is a new module, so attack surface
  ("a module goes in when CFM needs it", CLAUDE.md).
  - First A/B on public assets: Brotli 4 against gzip 1, on bytes and worker
    CPU for the same content.
  - Test br, gzip and identity on cache HIT and MISS, and check
    `Vary: Accept-Encoding`.
  - Scope it to the assets locations (`brotli on` covers HTML too).
- [ ] **`quic_gso on;`**, only on a node with real HTTP/3 download traffic.
  Judge it by worker CPU per GiB and throughput on the same download. Read the
  H3 share with the TLS item first.
- [ ] **`proxy_cache_revalidate on;`** for Site Cache's static tier, only if
  EXPIRED/STALE are frequent there. A 304 avoids re-sending the body; measure
  REVALIDATED, origin bytes and origin CPU.
  - It changes Site Cache, so it goes through CFM's cache guards and parity
    tests (cfm CLAUDE.md §6), never as a lone conf edit.

## Decided

- [decided, 2026-11-22] **No seccomp syscall filter (`SystemCallFilter=`).**
  - **Why:** the win is small on top of what the unit already has
    (`NoNewPrivileges`, 7 capabilities, `ProtectKernel*`,
    `RestrictNamespaces`, `RestrictAddressFamilies`: most dangerous calls,
    such as mount, module loading, reboot or the clock, already fail for lack
    of a capability). The failure mode is silent: a call outside the list
    returns EPERM, which systemd does not audit, so a CFM change months later
    (a new FFI call, a module, an nginx feature) breaks in one code path with
    "Operation not permitted" and nothing points at the unit. Half the fleet
    (EL8, systemd 239) cannot measure in log mode, so it would be enforced
    blind there, and the list needs re-measuring at every glibc, kernel or
    nginx change.
  - **How it was tried:** a measurement-only drop-in
    (`SystemCallLog=~@system-service`) on the four EL9/EL10 nodes; logging
    confirmed working on rigel (audit `type=SECCOMP`, `code=0x7ffc0000`;
    `ausearch` does not show these, `grep` the audit log). Removed the same
    day, before it took effect. Reopen only with a concrete exploit class it
    would stop that the capabilities do not.
- [decided, 2026-11-22] **No `MemoryDenyWriteExecute=`.** It needs LuaJIT's JIT
  (and PCRE's) off, a CPU cost on every request of the WAF/challenge logic,
  to stop W+X memory, while the JIT itself needs exactly that. Reopen only
  with a measurement that the JIT gains nothing on CFM's Lua.
- Hardening is a canary-first change, never a fleet-wide flip: one unit
  directive too many takes every site on a node down at once.
- [decided, 2026-11-21] No `buffer=`/`flush=` on the access logs.
  - The busiest node writes about 30 requests/s (2.7M a day), so the
    `write()` calls it would save are negligible.
  - A buffer delays the lines CFM's webdetector reacts to, and loses the last
    buffer on a crash.
- [decided, 2026-11-21] No `brotli_static`: the edge serves no local assets of
  its own (only the challenge page). Customer files come through
  `proxy_pass`, where the origin pass-through and dynamic Brotli (§7) apply.
