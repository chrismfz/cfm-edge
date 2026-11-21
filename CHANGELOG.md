# Changelog

What changes in the cfm-edge package, for the operator. The package version
is nginx's plus a build stamp (`versions.env`, `make package`), so entries go
under `[Unreleased]` and move under the build's date when it ships
(`YYYY-MM-DD`, UTC, as the rpm Release). Group by **Added / Changed /
Fixed / Hardened / Security / Removed**.

## [Unreleased]

### Added
- **An upgrade now applies itself to a running edge, without refusing
  connections** (`/usr/lib/cfm-edge/upgrade-restart.sh`, run by the rpm's
  `%posttrans`).
  - **Before:** the new binary and unit waited for a restart by hand, so a
    security fix (an OpenSSL CVE) did not apply until then.
  - **Now:** if cfm-edge runs, the script tests the new binary on the live
    config (`cfm-edge -t`) and restarts the edge. When CFM's web or panel
    DNAT is on, it takes the edge out of the path first: `cfm edge off`,
    restart, check that it serves, `cfm edge on`. The sites go straight to
    the origin for a few seconds (no WAF meanwhile), and no connection is
    refused.
  - **It does nothing when:**
    - the edge is stopped;
    - the new binary refuses the config (the old edge keeps serving);
    - the node's cfm has no `cfm edge` (older than 2026.11.20);
    - `/etc/cfm-edge/no-upgrade-restart` exists.
  - **If the restart fails:** the DNAT stays off (the origin serves) and the
    script logs a loud warning to the yum output and the journal
    (`journalctl -t cfm-edge-upgrade`).
  - The transaction never fails because of it.

### Hardened
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
