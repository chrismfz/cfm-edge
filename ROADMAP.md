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
- [x] **qualityweb: h2/h3 back on** (`http2 on`, `http3 on`, QUIC listening, 2026-11-23). That node carries our local
  "http2/http3 off" change. With cfm-edge 1.31.9, `http2 on`, `http3 on`
  and `quic` go back into the template, which was the reason for building
  cfm-edge in the first place.
- [x] **cfm repo, the packaging change that adopts cfm-edge** (cfm PR #1725
  lists them; in place on the fleet, 2026-11-23):
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
- `/run` (pid + lock; since round 2 only `/run/cfm-edge`).

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

### Round 2: done (rpm 1.31.9-20261123, on the fleet 2026-11-23)

`/run` read-only to the master (`ReadOnlyPaths=/run`, only `/run/cfm-edge`
writable) and `UMask=0027` (logs `0640`), read back on all 8 nodes. Two facts
that would otherwise be relearnt:
- On systemd 252 / 257 (EL9 / EL10), `ProtectSystem=strict` together with
  `ProtectKernelTunables=` or `ProtectControlGroups=` leaves the `/run`
  tmpfs rw; strict alone, and EL8's 239 with all three, make it ro. Hence
  the explicit `ReadOnlyPaths=/run`.
- `nginx -t` opens the pid file, and CFM runs `-t` while the edge is
  stopped, so `/run/cfm-edge` must exist then: tmpfiles.d makes it and
  `RuntimeDirectoryPreserve=yes` keeps it. nginx's `umask(0)` at daemonize
  means `UMask` covers only what it opens first; logrotate's `create 0640`
  keeps rotated logs 0640.

### Next

Ranked 2026-11-22 by win against risk. "Loud" means a mistake fails `-t`,
the start or a test with the path or directive named; "silent" means it
fails later, somewhere else, with nothing pointing back here. Silent risks
are what we avoid.

- [decided] **The master stays root** (2026-11-23), with the sandbox above.
  Not: a non-root master (`User=cfm`, no capabilities), dropping
  `CAP_DAC_OVERRIDE` alone, or `InaccessiblePaths=` for `/var/lib/mysql`,
  `/home2`, backups and the like. Each would protect only against a
  compromised MASTER, which needs a worker RCE and then an escalation: the
  workers, which parse every request and run the Lua, already run as `cfm`.
  Measured, 2026-11-23:
  - A non-root master is feasible: every listener is above 1024, and
    `cfm-edge -t` as `cfm` with no capabilities passes. But the canary on
    virgo failed its start: the pid file left by a root `-t` (CFM runs `-t`
    as root while the edge is stopped: the IPv6 listen check at every boot,
    the install script) is root-owned, and systemd re-owns the
    RuntimeDirectory, not the files in it. Making it work couples the two
    repos at more places (the pid, the log ownership via `LogsDirectory=`,
    the `cfm` user in this rpm, the modes of every file CFM writes into
    `/etc/cfm-edge`), each failing as a start that does not happen.
  - Without `CAP_DAC_OVERRIDE`, root cannot reopen the logs (`cfm:root
    0640`): `upgrade-restart.sh`'s sandboxed `-t` refused it at once.
  - For comparison: Imunify360's WebShield (also nginx, on titan) has no
    sandbox at all (`ProtectSystem=no`, root master with
    `dac_override`/`dac_read_search`, workers as its own user).

  Reopen with a new fact: a master-side RCE class in nginx, or CFM no
  longer running `-t` as root.
- [x] Dropped `CAP_NET_BIND_SERVICE` and set `ProtectProc=invisible`
  (canary on rigel, 2026-11-23; CHANGELOG). Every listener is above 1024 on
  all 8 nodes, and the edge Lua reads only `/proc/self`. On the fleet since
  2026-11-23 (virgo, EL8, first). No guard against a future listen below
  1024, on purpose: it fails loud (the start names the port,
  `upgrade-restart.sh` leaves the origin serving, `edge_health` flags it),
  and every listener is a DNAT target above 1024 by design.

## 3. Compile hardening

**Measure before adding.** The spec already passes `%{optflags}` and
`%{build_ldflags}` (redhat-rpm-config) to nginx and LuaJIT. On EL8 these
already include:
- the stack protector (`-fstack-protector-strong`);
- `-D_FORTIFY_SOURCE=2`;
- `-fstack-clash-protection` and `-fcf-protection`;
- PIE, RELRO and `-z now`.

- [x] **What every shipped ELF is built with** (2026-11-24, rpm
  1.31.9-20261123.015907, the same spec and flags as the fleet's .195237):
  `readelf -n` for the CET property note, and each compile unit's
  `DW_AT_producer` from the debuginfo rpm (EL records `-grecord-gcc-switches`).

  | | `cfm-edge` (nginx, modules, static OpenSSL) | `libluajit-5.1.so.2` | `cjson.so` |
  |---|---|---|---|
  | PIE/PIC, full RELRO, BIND_NOW, NX | yes (`%check` enforces) | yes | yes |
  | stack protector | 225/225 units | **0/70**: `-fno-stack-protector` | 3/3 |
  | stack-clash | 225/225 | 70/70 | 3/3 |
  | CET SHSTK / IBT | both, whole binary | SHSTK only | both |
  | FORTIFY (`__*_chk`) | yes | yes | yes |

  OpenSSL's objects carry no debuginfo, so they are not among the 225 units,
  but the linker sets IBT only when every object has `-fcf-protection`, so
  OpenSSL has it too (and `%check` enforces its flags). LuaJIT's IBT gap is its
  hand-written asm VM (no ENDBR), an upstream exception. `annocheck` 13.28
  hangs on `cfm-edge` (all kernel time; system binaries finish at once), so it
  is not the tool here.
- [ ] **LuaJIT without the stack protector.** Its Makefile appends
  `-fno-stack-protector` (and `-fomit-frame-pointer`) after the distro flags,
  so it wins: none of its 70 C units has a canary. Win: its C parts (string
  library, `string.format`, the parser, the GC) handle request data through
  CFM's Lua. Cost: only C functions with local arrays; the hot path (the asm VM
  and JIT'd code) is untouched. Before a patch (`patches/luajit2/`): find why
  upstream turns it off (its Makefile / history, not memory), then `test-all`
  (CFM's Lua in a real nginx), a CPU A/B on the same traffic, and a canary.
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

- [x] Workers run as `cfm` (`/sbin/nologin`, home `/var/lib/cfm`); the config
  is `root:root 0644` and the Lua token files `root:cfm 0640`; CFM's config
  keeps `worker_rlimit_nofile 65535` (read on virgo, 2026-11-23).
- [ ] **Later: a hot binary upgrade, so an update needs no time out of the
  path.** Today `upgrade-restart.sh` takes the edge out of the path, then
  restarts it. The graceful stop waits for every in-flight request, and
  CFM's config has none of `worker_shutdown_timeout` and allows requests up
  to an hour long (`proxy_read_timeout 1h` / `600s`: account transfers,
  uploads). So the stop often runs to `TimeoutStopSec=90` and a SIGKILL.
  Measured on the 2026-11-23 rollout: 27 to 129 s out of the path. The
  origin serves meanwhile, without WAF or challenge; no request is refused.
  The OpenResty and WebShield units restart the same way, but in the path.
  - **The idea:** nginx's own USR2 / WINCH / QUIT. The new binary inherits
    the listening sockets, the old workers drain in the background, and
    the DNAT never moves.
  - **Limits:**
    - the new master is forked from the old one, so it keeps the old
      unit's sandbox: only for an upgrade that changes no unit file, with a
      real restart otherwise;
    - systemd (`Type=forking`, `PIDFile=`) must follow the MainPID change;
    - every path needs its own canary.
  - **Not** `worker_shutdown_timeout`: it would also cut long requests (an
    account transfer) on every reload, and CFM reloads the edge often.

## 6. Tests

- [x] **The smoke test's forced log rotation runs on a copy** (2026-11-21).
  - **The bug:** `logrotate -f` on the packaged `/etc/logrotate.d/cfm-edge`
    rotated every live `/var/log/cfm-edge/*.log` and sent USR1 to the master
    in `/run/cfm-edge.pid`, on a host with a live edge (which the script
    promises it is safe next to).
  - **Now:** the two forced runs use a copy whose glob and pid file point into
    the scratch dir, and the test fails if the copy still names a live path.
    `logrotate -d` still parses the packaged file.
- [x] **The QUIC path in every test run** (2026-11-24). No EL curl has
  HTTP/3, so the smoke test's HTTP/3 request was always skipped and QUIC was
  never exercised. `smoke.sh` now does a real QUIC handshake with `openssl
  s_client -quic -alpn h3` on EL9 and EL10 (OpenSSL 3.5): ALPN h3, and the
  cert picked by `ssl_certificate_by_lua` (sslcollector's path) or the default
  one. Skipped on EL8 only (OpenSSL 1.1.1 has no QUIC client), so every
  `test-all` runs it; a missing `-quic` on EL9/EL10 fails. It is the handshake,
  not an HTTP/3 request: a full request still needs a curl with HTTP/3.
  HTTP/3 is off by default in CFM's config (an open nginx bug,
  nginx/nginx#1407), on per knob, so the binary must keep it working.

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
  - **RSA-2048 → ECDSA P-256, rigel, 2026-11-23** (233 of 253 certs
    converted by AutoSSL; recipe and raw numbers in `/root/p256bench/` on
    rigel). Full handshakes on loopback, medians:
    - edge CPU per handshake ~405 → ~290 µs (−28%); LiteSpeed (the 443
      origin hop, a full handshake per request) ~560 → ~160 µs (−70%);
    - 30 min of live traffic: edge + LiteSpeed CPU per request 3.37 →
      3.09 ms (−8%), edge alone 1.20 → 1.29 ms (51 vs 73 req/s, not the
      same mix);
    - **the client pays ~+0.8 ms per full handshake** (A/B, same run: 0.80
      → 1.56 ms, client CPU 0.55 → 1.46 ms): Let's Encrypt's ECDSA chain
      (YE2 → Root YE → ISRG Root X2) is P-384-signed at every link, and a
      P-384 verify costs ~0.27 ms. The edge pays it too as the origin hop's
      client. Open: whether a shorter alternate chain exists and AutoSSL
      can select it.
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

## 8. The .deb (last: no node runs CFM's edge on Debian yet)

- [ ] **A .deb of the same EL8-built tree**, built with `dpkg-deb` the way
  cfm's Makefile builds its own (HANDOFF.md step 6). The paths are already
  distro-neutral (`/usr/lib/cfm-edge`), and the binary needs only glibc,
  pcre2, zlib and libmaxminddb (`libmaxminddb0` on Debian). Tested on Debian
  12 and Ubuntu 24.04 containers with the same smoke and cfm-conf tests.
  - **No dpkg conffiles for anything CFM writes** (cfm PR #1770). CFM
    rewrites `/etc/cfm-edge/nginx.conf` and its sidecars, so as conffiles
    every upgrade that changed the placeholder would stop dpkg at the
    "Configuration file … (Y/I/N/O/D/Z)" question: `apt upgrade -y` cannot
    answer it, a broadcast multi-host session hangs on it, and
    unattended-upgrades silently skips the package. Ship the defaults under
    `/usr/share/cfm-edge/` and seed `/etc/cfm-edge` from postinst, like the
    rpm's `%config(noreplace)`: a missing file gets the default, an
    unchanged one (recorded sha256) the new default, an edited or symlinked
    one stays, with the new default beside it as `.dpkg-dist`. One list of
    those files for both packages, pinned by a gate as in cfm.
  - **The upgrade restart:** postinst `configure` on an upgrade runs the same
    `upgrade-restart.sh` (`tests/upgrade-restart_test.sh` covers it), never
    `deb-systemd-invoke restart`; the unit stays not enabled.
  - The logrotate file is not a conffile either (a changed `maxsize` would
    prompt the same way); the tmpfiles.d entry and the `/run/cfm-edge` dir
    come with it.

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
