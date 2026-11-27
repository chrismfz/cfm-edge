#!/bin/bash
# config-files_test.sh — packaging/config-files.list == the spec's
# %config(noreplace) files (make lint). The .deb seeds exactly the listed
# files from postinst (no dpkg conffile), the rpm marks exactly them
# %config(noreplace); a file added to one and not the other would be a plain
# file overwritten on every deb upgrade, or a .deb that misses a default.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

spec=packaging/rpm/cfm-edge.spec
list=packaging/config-files.list

from_spec="$(grep -E '^%config\(noreplace\)' "$spec" | awk '{print $2}' \
    | sed -e 's|%{edge_confdir}|/etc/cfm-edge|' -e 's|%{_sysconfdir}|/etc|' \
    | sed 's|^/||' | sort)"
from_list="$(grep -Ev '^[[:space:]]*(#|$)' "$list" | awk '{print $1}' | sort)"

if printf '%s\n' "$from_spec" | grep -q '%{'; then
    echo "FAIL: a %config(noreplace) path uses a macro this test does not expand:" >&2
    printf '%s\n' "$from_spec" | grep '%{' >&2
    exit 1
fi
if [ -z "$from_spec" ] || [ -z "$from_list" ]; then
    echo "FAIL: read nothing (spec: ${from_spec:-none}; list: ${from_list:-none})" >&2
    exit 1
fi
if [ "$from_spec" != "$from_list" ]; then
    echo "FAIL: $list and the spec's %config(noreplace) files differ:" >&2
    diff <(printf '%s\n' "$from_spec") <(printf '%s\n' "$from_list") >&2 || true
    exit 1
fi
# Every listed mode is an octal mode.
if grep -Ev '^[[:space:]]*(#|$)' "$list" | awk '$2 !~ /^0[0-7]{3}$/ {bad=1} END {exit !bad}'; then
    echo "FAIL: a line of $list has no octal mode (path 0644)" >&2
    exit 1
fi
echo "config-files: OK ($(printf '%s\n' "$from_list" | wc -l) files, spec == list)"
