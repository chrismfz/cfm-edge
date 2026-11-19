# HANDOFF

Where cfm-edge stands, what is proven, and what comes next. Update it when a
step lands; delete a section once the code and README say the same thing.

## State (2026-11-19)

**Pilot: built and tested, not yet on any node.**

- `versions.env` pins nginx **1.31.9**, the release that fixes nginx2root and
  nine other CVEs. With it go OpenSSL **3.5.9** and the OpenResty Lua set
  that `openresty/openresty` master has validated against 1.31.9:
  lua-nginx-module 0.10.32rc8, lua-resty-core 0.1.35rc3 and LuaJIT2
  2.1-20261117.
- The rpm built in AlmaLinux 8 passes `tests/smoke.sh` and
  `tests/cfm-conf.sh` (CFM's real `configs/openresty.conf` and `configs/lua`)
  on **EL8, EL9 and EL10**. Native per-EL builds (`make rpms`) also pass all
  three tests.
- `tools/check-deps.py` is verified on a stale copy (nginx 1.31.8 →
  1.31.9). It flagged SECURITY (exit 4), PGP-verified the tarball, and
  wrote exactly today's pins.
- CI has not run on GitHub yet: the first push will be its first run.

### Found on the way (worth knowing beyond this repo)

- **nginx 1.31.9 fixes more than h2/h3.** CVE-2026-118899 (endless loop
  reading a request body over SSL) hits every TLS edge, h2 off or not. The
  CFM edge template uses no `resolver`, `try_files`/`alias` or
  `proxy_protocol`, so four other CVEs don't apply.
- **lua-resty-maxminddb loads `libmaxminddb.so`**, which only `-devel`
  ships. This is a known issue, fixed fleet-wide on 2026-04-15: geo failed at
  the first lookup.
  - cfm commit `44f45016` made `libmaxminddb-devel` (-dev on Debian) a
    dependency of the cfm package, and `e673aedc` added it to
    `install-openresty.sh`.
  - virgo got a manual install the same hour. earth, mars and orion pulled
    it in with the next `dnf update` of cfm. rigel, titan, speedhost and
    qualityweb already had it through cPanel's installer.
  - Checked 2026-11-19: all 8 edge nodes have the symlink.

  cfm-edge still carries `patches/lua-resty-maxminddb/0001` (runtime soname
  first), so it does not depend on a -devel package being present.
- **Stock ngx_lua has no `ngx.hmac_sha256`.** On this edge `cfm_clearance`
  uses `resty.sha256`, which works only because nginx exports the static
  OpenSSL's symbols (`-Wl,-E`). The smoke test pins it.

## Next steps (in order)

1. **First CI run.** Push, then watch `ci` go green. If `chrismfz/cfm` is
   private, add the `CFM_READ_TOKEN` secret (read-only, fine-grained). For
   check-deps PRs to trigger CI, add `DEPS_PR_TOKEN`
   (`.github/workflows/check-deps.yml` explains why).
2. **Devbox build + publish.** The devbox is AlmaLinux 10 with podman, which
   is enough: EL8 is only the container image, so no EL8 machine is needed.
   `ENGINE=podman make package test-all`, then `make sync`. That is the same
   upload as cfm's, and `make sync` refuses untested or already-published
   rpms. Then, as root on repo.nixpal.com, run
   `/root/repos-update.sh --rpm-only` to sign and publish to `/el/`
   (README, "Release flow").
3. **CFM integration** (cfm repo, one small PR each):
   - `scripts/install-edge.sh`, modelled on `install-angie.sh`. It renders
     `configs/openresty.conf` with the path map `tests/cfm-conf.sh` already
     proves (`/usr/local/openresty/nginx/{conf,logs}` → `/etc/cfm-edge`,
     `/var/log/cfm-edge`), rather than adding a third template that would
     drift. One addition to that map: the `pid` line must become
     `/run/cfm-edge.pid`, the unit's `PIDFile=`. Otherwise systemd waits for a
     pid file that never appears and kills the edge. Then: stop the old edge,
     `cfm-edge -t`, start, and roll back on failure. The same script does
     upgrades: the rpm deliberately does not restart the edge.
   - `internal/edgeengine/edgeengine.go`: add `cfm-edge` to
     `ServiceCandidates` and `BinaryPaths` (`/usr/sbin/cfm-edge`). Then
     check the other hard-coded edge paths: `internal/dnat/cpanel_off.go`
     (panel listeners conf), `internal/edgelog`, `internal/healthmodel`,
     `internal/dnat/cli.go detectEdgeService`, `internal/status`,
     `internal/mcpserver/whats_wrong.go` and `cmd/cfm/edgeban_reconcile.go`.
   - `scripts/tests/check_logrotate_coverage.sh`: `/var/log/cfm-edge/` is
     rotated by the package's own `/etc/logrotate.d/cfm-edge`. List it as
     vendor-rotated and never declare it twice.
4. **Canary** on qualityweb (Angie today, light traffic): run
   `install-edge.sh` with h2/h3 back on, check `edge_health`, and compare its
   error log with what Angie logged. Then roll out to the other Angie nodes,
   which already run the same module set, and to the OpenResty nodes last.
5. **The .deb.** Package the same EL8-built tree with `dpkg-deb`, the way
   cfm's Makefile builds its deb. The paths are already distro-neutral
   (`/usr/lib/cfm-edge`). Test it on Debian 12 and Ubuntu 24.04 containers
   with the same smoke and cfm-conf tests.

## Open decisions

- **A testing channel on repo.nixpal.com?** Today `/el/` is one channel for
  every nixpal package, and `make sync` lands there. That is safe while no
  node runs cfm-edge, and the rpm never restarts a running edge. Once the
  fleet runs it, a `cfm-edge-testing` repo (or an `includepkgs`/`exclude`
  rule in `nixpal.repo`) would let one canary see a build before the rest.

- **Server banner: decided, `Server: cfm-edge`** (no version; patch
  `patches/nginx/0001`). CFM is already identifiable by its challenge page and
  `cfm_*` cookies, so a generic banner hid little, while knowing at a glance
  that the edge answered rather than the origin helps every debug session.
  `-v` is untouched.
- **Mainline vs stable nginx.** We track mainline (1.31.x), like OpenResty
  and Angie. check-deps reports a newer minor line but never moves to it on
  its own.
- **Real JA4.** Needs the ClientHello extension list, which is a module or a
  patch (`cfm/configs/lua/cfm_tlsfp.lua` header). This repo is now where it
  would live. It should be its own design, not a quick add.
