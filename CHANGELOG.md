# Changelog

What changes in the cfm-edge package, for the operator. The package version
is nginx's plus a build stamp (`versions.env`, `make package`), so entries go
under `[Unreleased]` and move under the build's date when it ships
(`YYYY-MM-DD`, UTC, as the rpm Release). Group by **Added / Changed /
Fixed / Hardened / Security / Removed**.

## [Unreleased]

### Added
- **`make release`** runs the whole pre-publish chain in order (`lint`,
  `package`, `test-all`), so a release is `make release && make sync`;
  **`make distclean`** also drops the fetched `SOURCES/`.
- **An upgrade now applies itself to a running edge, without refusing
  connections** (`/usr/lib/cfm-edge/upgrade-restart.sh`, run by the rpm's
  `%posttrans`).
  - **Before:** the new binary and unit waited for a restart by hand, so a
    security fix (an OpenSSL CVE) did not apply until then.
  - **The steps, for a running cfm-edge:**
    1. Test the new binary on the live config, inside the new unit's sandbox
       where systemd-run can apply it.
    2. If CFM's web or panel DNAT is on *for cfm-edge*, take it out of the
       path: `cfm edge off`, and continue only when it reads OFF.
    3. Restart, and wait up to 30 s until it serves (it must listen on :9043
       as cfm-edge and answer).
    4. Put it back, with the web DNAT's live priority and ports (an Imunify
       node's `-101` is kept).
  - **What it costs:** while the old workers drain (up to `TimeoutStopSec`,
    90 s, with a long-lived connection open), the sites go straight to the
    origin, with no WAF/challenge. yum waits that long. No connection is
    refused.
  - **It does nothing when:**
    - the edge is stopped;
    - the new binary refuses the config (the old edge keeps serving);
    - the DNAT state cannot be read;
    - the node's cfm has no `cfm edge` (older than 2026.11.20);
    - the DNAT does not turn off;
    - `/etc/cfm-edge/no-upgrade-restart` exists.
  - **Another engine in the path:** a plain restart, and that engine's DNAT is
    never touched.
  - **If the restart fails or never serves:** the DNAT stays off (the origin
    serves) and the script logs a loud warning to the yum output and the
    journal (`journalctl -t cfm-edge-upgrade`).
  - The transaction never fails because of it.

### Fixed
- **The post-upgrade restart no longer collides with cfm's own restarts.**
  cfm's rpm restarts its daemon in its `%post` (before this script), and its
  old package's `%postun` asks again: on EL9/EL10 that second restart is
  queued to the END of the transaction (the unit is marked
  `Markers=needs-restart`), so it came while this script ran (rigel,
  2026-11-23: the daemon put the panel DNAT back as it started, `panel off`
  never read OFF, and the edge was left unrestarted, safely). Now:
  - a cfm unit marked needs-restart hands the restart to a transient systemd
    unit, which runs after the transaction, once cfm has restarted
    (`journalctl -t cfm-edge-upgrade`);
  - a cfm daemon that is starting, stopping, or has run less than 30 s is
    waited for (its firewall setup), at most 10 minutes;
  - one run at a time (`/run/cfm-edge-upgrade.lock`), so a deferred run, a
    second transaction or a run by hand cannot turn the DNAT off and on
    across each other's restart;
  - a signal after the DNAT was taken out (the unit stopped, a reboot right
    after yum) puts it back, unless the new edge does not serve, in which
    case it stays off with an ERROR, as before;
  - an off that succeeded but does not read OFF is tried again, and a failed
    CLI call is logged by its error line (an nft failure prints its refused
    script after the error, which is all the log showed on virgo).
- **The post-upgrade restart no longer leaves the web DNAT off when one
  `cfm edge on` fails.** The same yum transaction often upgrades cfm too, and
  its post-install restarts the cfm daemon, whose firewall setup on EL8 holds
  nft for 30–55 s. `upgrade-restart.sh` tried `cfm edge on` once, threw its
  error away, and left the DNAT off (earth, 2026-11-22: 53 minutes with the
  origin serving directly, no WAF; orion's `panel off` failed the same way,
  so it was left unrestarted, safely). Now every `cfm edge off/on` and
  `panel off/on` is tried again after 10, 20, 30 and 60 s, each failure is
  logged with the CLI's own message (yum output and `journalctl -t
  cfm-edge-upgrade`), and the DNAT is read back after the restart: one that
  was on and is not ends in an ERROR naming the command to run, not in
  "restarted". The cost: up to 2 more minutes of the transaction while the
  daemon starts (longer only if the CLI hangs to its 60 s timeout each try).
- **The smoke test no longer touches a live edge's logs.** Its two forced log
  rotations ran `logrotate -f` on the packaged rule, which rotated every live
  `/var/log/cfm-edge/*.log` and sent USR1 to the master on a host with a
  live edge. They now run on a copy pointed at a scratch dir; the test fails
  if the copy still names a live path.
- **`upgrade-restart.sh` reads a DNAT state followed by a bypass note.** CFM
  prints `Panel DNAT:  OFF; 1 bypass source(s)` on a node with bypass
  sources.
  - **What went wrong:** the script read that line as unknown. On orion (the
    2026-11-21 fleet upgrade) it put the DNAT back as it was and did not
    restart, so the new binary and sandbox waited for a manual restart.
  - **Now:** a `;` after ON/OFF is read like a space.

### Hardened
- **The static OpenSSL is now built with the stack protector, stack-clash
  protection, CET and FORTIFY.** Its own `Configure` ignores the distro
  flags, so until now libcrypto/libssl, the code every TLS handshake runs,
  were compiled with `-Wall -O3 -fPIC` only: the new `%check` counted 0% of
  their objects protected, against 69% of nginx's. The flags go in through
  `--with-openssl-opt`, and `%check` now fails a build without them.
- **Every build proves the link hardening of everything it ships.** The
  rpm's `%check` (`packaging/rpm/elf-hardening-check.sh`) fails the build
  when any ELF in the package (the binary, LuaJIT, `cjson.so`, the luajit
  CLI) lacks a non-executable stack, full RELRO (`GNU_RELRO` + `BIND_NOW`),
  or, for `/usr/sbin/cfm-edge`, PIE. LuaJIT and lua-cjson build with their
  own Makefiles, so a bump that stopped passing the distro's LDFLAGS would
  otherwise ship unnoticed. The same step reports, without failing, what
  compile hardening the static OpenSSL got (its own `Configure` does not
  read the distro flags): its Makefile's `CFLAGS` and the share of
  `libcrypto`/`libssl` objects with the stack protector and FORTIFY, next to
  nginx's own.
- **`cfm-edge.service` runs sandboxed** (ROADMAP.md §2, round 1):
  - the filesystem is read-only except the paths the edge writes (logs, Site
    Cache, the body/proxy temp dirs of CFM's config, the ClamAV pending dir,
    `/run`), and `/home` is not visible;
  - private `/tmp` and `/dev`, `NoNewPrivileges`, 7 capabilities, only
    unix/IPv4/IPv6 sockets, no new namespaces, the kernel and cgroup
    settings read-only.

  `systemd-analyze security` goes from 9.2 UNSAFE to 4.4 (EL8) / 4.5 (EL9)
  OK. Measured live on virgo (EL8) and rigel (EL9) first: restart, reload,
  uploads, Site Cache, WAF, sslcollector, panel listeners, IPv4 + IPv6.
  - **Takes effect at the next restart of the edge**, not at the rpm upgrade
    (the package never restarts a running edge).
  - EL8's systemd ignores `ProtectKernelLogs` / `ProtectClock` /
    `ProtectHostname` with an "Unknown lvalue" line in the journal.
  - **If CFM's edge config ever writes to a new path**, that path must be
    added to the unit's `ReadWritePaths=`, or requests that need it fail with
    "Read-only file system" while the edge looks healthy.
