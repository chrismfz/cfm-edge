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
- [ ] **`worker_shutdown_timeout` in the config `install-edge.sh` renders**
  (cfm repo), e.g. 10-15s. On a stop, nginx closes its listening sockets at
  once and waits for open connections. CFM's config proxies streams with
  `proxy_read_timeout 1h`, so a single websocket holds a stop for the unit's
  full 90s, and new connections are refused until the next start. This
  setting is the real bound on that window; `TimeoutStopSec` is only the
  backstop.
  - `install-edge.sh`'s switch should not sit in that window either: the old
    edge has closed its ports as soon as it got SIGQUIT, so the new one can
    start while the old one drains. Measure it on the canary.
  - Decide whether OpenResty/Angie get the same line: their units have the
    same 90s today.
- [x] **`LimitNOFILE=262144`** in the unit, to match `openresty.service`
  (smoke test pins it).
  - CFM's config sets `worker_rlimit_nofile 65535`. The workers apply it
    before they drop privileges, so the workers are covered today.
  - The unit limit means we no longer depend on that line if the config
    ever changes.
- [ ] **`install-edge.sh` (cfm repo): the `pid` line becomes
  `/run/cfm-edge.pid`**, the unit's `PIDFile=`. With `Type=forking`,
  systemd otherwise waits for a pid file that never appears and kills the
  edge after the timeout (HANDOFF.md, step 3).
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

- [ ] **Narrow `/run`**: move the pid and lock to `/run/cfm-edge/`
  (`RuntimeDirectory=cfm-edge`, `--pid-path`/`--lock-path` in the spec, CFM's
  `pid` line and `PIDFile=`), then `ReadWritePaths=` names only that.
- [ ] **Round 2**, each measured on its own as above:
  - `SystemCallFilter=@system-service` + `SystemCallArchitectures=native`,
    first with `SystemCallLog=` / `SystemCallErrorNumber=EPERM` on the
    canary so a missing call shows in the log instead of killing a worker;
  - `ProtectProc=invisible` (EL9+; check that no Lua reads `/proc` of
    another process);
  - `UMask=0027`.
- [ ] Drop capabilities that turn out unneeded (`CAP_DAC_OVERRIDE` if every
  file the master opens is root's; `CAP_NET_BIND_SERVICE` while every
  listener is above 1024).
- [ ] `MemoryDenyWriteExecute=yes` **only if LuaJIT's JIT is off**. The JIT
  writes machine code at run time, which is exactly what this forbids.
  Measure whether CFM's Lua needs the JIT before choosing one or the other.
- [ ] Once the rpm carries round 1, remove the test drop-in
  `zz-hardening.conf` from virgo and rigel (it duplicates the unit).

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
- [ ] **OpenSSL is built by its own `Configure`** (static, through
  `--with-openssl`), so it does not necessarily get the same flags. Measure
  it, and if needed pass them through `--with-openssl-opt`.
- [ ] `_FORTIFY_SOURCE=3` once EL8 leaves the fleet (the build moves to the
  next-oldest EL, CLAUDE.md).
- [ ] An `-fzero-call-used-regs` / `-ftrivial-auto-var-init=zero` check:
  cost against benefit, measured.
- **LTO stays off** (LuaJIT, CLAUDE.md).

## 4. Attack surface: modules

Done (spec `--without-*`):
- auth_basic, fastcgi, uwsgi, scgi, grpc, memcached, ssi, autoindex,
  userid, mirror, empty_gif, split_clients.
- Removing `http_mirror_module` and `http_ssi_module` removes the
  CVE-2026-123634 path entirely.

- [ ] Review what remains against "a module goes in when CFM needs it"
  (CLAUDE.md): `threads`, `file-aio`, `stub_status`, `auth_request`,
  `realip`, `compat`. Keep each only if CFM's config or Go uses it.

## 5. Runtime

- [ ] Workers run as `cfm`, with no shell and no home that means anything.
- [ ] The config is root-owned and read-only to the workers. The generated
  Lua token files keep `root:cfm 0640` (cfm CLAUDE.md §5).
- [ ] Confirm `worker_rlimit_nofile` stays in CFM's config (it covers the
  workers today, §1).

## Decided

- Hardening is a canary-first change, never a fleet-wide flip: one unit
  directive too many takes every site on a node down at once.
- The JIT and `MemoryDenyWriteExecute` are a pair: choose one after
  measuring, never both by assumption.
