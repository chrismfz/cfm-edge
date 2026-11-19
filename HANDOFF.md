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
  ships. On a node with just `libmaxminddb` (the runtime package), `cfm_geo`
  silently has no geo. cfm-edge patches the soname
  (`patches/lua-resty-maxminddb/`). **Check the Angie and OpenResty nodes:**
  `ls /usr/lib64/libmaxminddb.so`. If it is missing, they have no geo.
- **Stock ngx_lua has no `ngx.hmac_sha256`.** On this edge `cfm_clearance`
  uses `resty.sha256`, which works only because nginx exports the static
  OpenSSL's symbols (`-Wl,-E`). The smoke test pins it.

## Next steps (in order)

1. **First CI run.** Push, then watch `ci` go green. If `chrismfz/cfm` is
   private, add the `CFM_READ_TOKEN` secret (read-only, fine-grained). For
   check-deps PRs to trigger CI, add `DEPS_PR_TOKEN`
   (`.github/workflows/check-deps.yml` explains why).
2. **Devbox build + publish.** Run `make package test-all` on the devbox,
   sign, and push to a new `cfm-edge-testing` channel on repo.nixpal.com,
   alongside cfm, ngm, gsc-mcp and argus. Then add a `make sync`, like
   cfm's.
3. **CFM integration** (cfm repo, one small PR each):
   - `scripts/install-edge.sh`, modelled on `install-angie.sh`. It renders
     `configs/openresty.conf` with the path map `tests/cfm-conf.sh` already
     proves (`/usr/local/openresty/nginx/{conf,logs}` → `/etc/cfm-edge`,
     `/var/log/cfm-edge`), rather than adding a third template that would
     drift. Then: stop the old edge, `cfm-edge -t`, start, and roll back on
     failure.
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

- **Server banner.** Stock nginx with `server_tokens off` sends
  `Server: nginx`, which is the most generic value there is. Recommendation:
  keep it, with no patch to maintain. A unique string like `cfm` would make
  the fleet a single Shodan query.
- **Mainline vs stable nginx.** We track mainline (1.31.x), like OpenResty
  and Angie. check-deps reports a newer minor line but never moves to it on
  its own.
- **Real JA4.** Needs the ClientHello extension list, which is a module or a
  patch (`cfm/configs/lua/cfm_tlsfp.lua` header). This repo is now where it
  would live. It should be its own design, not a quick add.
