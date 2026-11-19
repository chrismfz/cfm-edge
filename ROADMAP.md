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
  - Still open, in CFM's edge config: `worker_shutdown_timeout`, for a clean
    upper bound that does not depend on the unit.
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

Mostly free to add, but each line restricts what the edge may touch, so a
missing write path takes the edge down. Every step needs a canary run with
a real reload, a log rotation, a certificate refresh (sslcollector) and the
panel listeners.

Paths CFM's edge writes or binds today:
- `/var/lib/cfm` (Lua, body/proxy temp, state);
- `/var/cache/nginx` (Site Cache);
- `/run/cfm` and `/var/run/cfm_nginx.sock`, `/var/run/sslcollector.sock`
  (bridge and sslcollector sockets);
- `/var/log/cfm-edge`;
- `/run/cfm-edge.pid`.

Measure the list on the canary rather than trust it.

First step (the one discussed):
- [ ] `NoNewPrivileges=yes`
- [ ] `ProtectSystem=full` (`/usr`, `/boot`, `/etc` read-only)
- [ ] `ProtectHome=yes`. This one matters most on cPanel servers: the edge
  has no reason to see `/home`, where every customer's site lives.
- [ ] `RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX`

Later, each measured on its own:
- [ ] `ProtectSystem=strict` with explicit `ReadWritePaths=` (the list
  above).
- [ ] `PrivateDevices=yes`, `ProtectKernelTunables=yes`,
  `ProtectKernelModules=yes`, `ProtectControlGroups=yes`.
- [ ] `CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_SETUID CAP_SETGID
  CAP_CHOWN CAP_DAC_OVERRIDE`, then drop whichever turns out unneeded.
- [ ] `SystemCallFilter=@system-service` (and `SystemCallArchitectures=native`).
- [ ] `MemoryDenyWriteExecute=yes` **only if LuaJIT's JIT is off**. The JIT
  writes machine code at run time, which is exactly what this forbids.
  Measure whether CFM's Lua needs the JIT before choosing one or the other.

`systemd-analyze security cfm-edge.service` gives the score before and
after each step.

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
