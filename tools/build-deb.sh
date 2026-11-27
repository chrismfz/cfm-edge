#!/bin/bash
# build-deb.sh — repack THE shipped rpm (built on EL8) as a .deb.
#
#   tools/build-deb.sh [<rpm>] [<outdir>]   (defaults: dist/el8/cfm-edge-*.rpm, dist/deb)
#
# Not a second build: the .deb carries the very files the rpm carries, so
# the binary that passed the EL8 build's checks (ELF hardening, OpenSSL, the
# exported symbols) is the one Debian runs. That works because the paths are
# distro-neutral (/usr/lib/cfm-edge, /usr/sbin, /usr/lib/systemd/system) and
# the binary needs only glibc >= 2.28, libpcre2-8, libz and (through the FFI)
# libmaxminddb, which Debian 12+ and Ubuntu 22.04+ ship under the same sonames.
#
# What changes from the rpm:
#   - every file under /etc moves to /usr/share/cfm-edge/defaults/: no dpkg
#     conffile; postinst seeds /etc (packaging/config-files.list says why).
#     Any other /etc file in the rpm fails the build;
#   - the EL-only /usr/lib/.build-id links are dropped;
#   - the placeholder nginx.conf names Debian's nogroup (see below);
#   - maintainer scripts from packaging/deb/ (the rpm's post / preun / postun /
#     posttrans, the last as a dpkg trigger).
#
# Needs rpm2cpio, cpio and dpkg-deb (make doctor checks them).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RPM="${1:-}"
OUT="${2:-$REPO_DIR/dist/deb}"

if [ -z "$RPM" ]; then
    shopt -s nullglob
    rpms=("$REPO_DIR"/dist/el8/cfm-edge-[0-9]*.x86_64.rpm)
    shopt -u nullglob
    [ "${#rpms[@]}" = 1 ] || { echo "build-deb: want exactly one rpm in dist/el8, found ${#rpms[@]}: run make package" >&2; exit 1; }
    RPM="${rpms[0]}"
fi
[ -f "$RPM" ] || { echo "build-deb: no such rpm: $RPM" >&2; exit 1; }
for t in rpm2cpio cpio dpkg-deb sha256sum; do
    command -v "$t" >/dev/null || { echo "build-deb: $t not found (make doctor)" >&2; exit 1; }
done

# cfm-edge-1.31.10-20261126.210440.x86_64.rpm -> 1.31.10-20261126.210440: the
# rpm's Version-Release is a valid Debian version (upstream-revision), and the
# build-stamp revision sorts every new build after the last, as on EL.
base="$(basename "$RPM" .x86_64.rpm)"
version="${base#cfm-edge-}"
case "$version" in
    [0-9]*.[0-9]*-[0-9]*.[0-9]*) ;;
    *) echo "build-deb: cannot read the version from $(basename "$RPM")" >&2; exit 1 ;;
esac

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
root="$work/root"
mkdir -p "$root"
(cd "$root" && rpm2cpio "$RPM" | cpio -idm --quiet --no-absolute-filenames)

# EL's build-id links: debuginfo plumbing Debian neither needs nor knows.
rm -rf "$root/usr/lib/.build-id"

# /etc: every file must be on the list; each moves to the defaults tree.
list="$REPO_DIR/packaging/config-files.list"
listed="$(grep -Ev '^[[:space:]]*(#|$)' "$list" | awk '{print $1}')"
stray="$(cd "$root" && find etc -type f -o -type l 2>/dev/null | sort | grep -vxF "$listed" || true)"
if [ -n "$stray" ]; then
    echo "build-deb: files under /etc that packaging/config-files.list does not name (they would be plain files, overwritten on every upgrade):" >&2
    printf '  /%s\n' $stray >&2
    exit 1
fi
defaults="$root/usr/share/cfm-edge/defaults"
for rel in $listed; do
    [ -f "$root/$rel" ] || { echo "build-deb: listed but not in the rpm: /$rel" >&2; exit 1; }
    mkdir -p "$defaults/$(dirname "$rel")"
    mv "$root/$rel" "$defaults/$rel"
done
install -m 0644 "$list" "$root/usr/share/cfm-edge/config-files.list"

# The placeholder's `user nobody;` takes the group of the same name, which EL
# has and Debian does not (its nobody's group is nogroup): there `-t` fails
# with getgrnam("nobody"). Name Debian's group. CFM's real config runs as
# `user cfm;` (cfm's package creates that group), so only the placeholder
# needs it.
ph="$defaults/etc/cfm-edge/nginx.conf"
grep -qx 'user nobody;' "$ph" || { echo "build-deb: the placeholder has no 'user nobody;' line to adapt for Debian" >&2; exit 1; }
sed -i 's/^user nobody;$/user nobody nogroup;/' "$ph"
# Keep /etc/cfm-edge itself (empty): CFM and postinst write into it.
find "$root/etc" -depth -mindepth 1 -type d -empty ! -path "$root/etc/cfm-edge" -delete

mkdir -p "$root/DEBIAN"
size_kb="$(du -sk --exclude=DEBIAN "$root" | cut -f1)"
sed -e "s/@VERSION@/$version/" -e "s/@INSTALLED_SIZE@/$size_kb/" \
    "$REPO_DIR/packaging/deb/control.in" >"$root/DEBIAN/control"
for s in postinst prerm postrm; do
    install -m 0755 "$REPO_DIR/packaging/deb/$s" "$root/DEBIAN/$s"
done
install -m 0644 "$REPO_DIR/packaging/deb/triggers" "$root/DEBIAN/triggers"
(cd "$root" && find . -path ./DEBIAN -prune -o -type f -printf '%P\0' \
    | sort -z | xargs -0 md5sum >DEBIAN/md5sums)

mkdir -p "$OUT"
rm -f "$OUT"/cfm-edge_*.deb
deb="$OUT/cfm-edge_${version}_amd64.deb"
dpkg-deb --root-owner-group -Zxz --build "$root" "$deb" >/dev/null
echo "$deb"
