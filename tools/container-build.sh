#!/bin/bash
# container-build.sh — build or smoke-test cfm-edge inside a clean AlmaLinux.
#
#   tools/container-build.sh <8|9|10> build    -> dist/el<N>/*.rpm
#   tools/container-build.sh <8|9|10> smoke    install dist/el<N> rpm in a
#                                              fresh container, run tests/smoke.sh
#   tools/container-build.sh <8|9|10> cfm-conf same, then run CFM's real edge
#                                              config + Lua (tests/cfm-conf.sh; CFM_DIR=)
#
# The repo is mounted read-only and copied inside, so the build never leaves
# root-owned files in the checkout. Needs docker (or podman: ENGINE=podman).
#
# Behind an HTTPS-only egress proxy (a cloud dev session): set EDGE_CA to the
# proxy's CA bundle; the container then trusts it and its dnf uses HTTPS
# baseurls instead of the (http) mirrorlist. Unset on a normal host / CI.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EL="${1:?usage: $0 <8|9|10> <build|smoke|cfm-conf>}"
MODE="${2:?usage: $0 <8|9|10> <build|smoke|cfm-conf>}"
ENGINE="${ENGINE:-docker}"
IMAGE="${IMAGE:-quay.io/almalinuxorg/almalinux:${EL}}"
OUT="${REPO_DIR}/dist/el${EL}"

# SELinux hosts (EL with podman, e.g. the devbox) refuse unlabelled bind
# mounts: add the shared relabel option there.
Z=""
if [ "$ENGINE" = podman ] && command -v getenforce >/dev/null && [ "$(getenforce)" = Enforcing ]; then Z=",z"; fi
args=(run --rm --network host -v "${REPO_DIR}:/src:ro${Z}")
# CFM sets worker_rlimit_nofile 65535. Where the host allows it, give the
# container that much (EDGE_NOFILE=1048576); a sandbox that caps it lower
# refuses to even start the container, so it is opt-in.
[ -n "${EDGE_NOFILE:-}" ] && args+=(--ulimit "nofile=${EDGE_NOFILE}:${EDGE_NOFILE}")
if [ -n "${EDGE_CA:-}" ]; then
    args+=(-e HTTPS_PROXY -e https_proxy -e EDGE_CA=1
           -v "${EDGE_CA}:/etc/pki/ca-trust/source/anchors/edge-ca.crt:ro")
fi

# shellcheck disable=SC2016  # expanded inside the container
prologue='
set -euo pipefail
if [ -n "${EDGE_CA:-}" ]; then
    update-ca-trust
    grep -q "^proxy=" /etc/dnf/dnf.conf || echo "proxy=${HTTPS_PROXY}" >> /etc/dnf/dnf.conf
    for f in /etc/yum.repos.d/almalinux*.repo; do
        sed -i -E "s|^mirrorlist=|#mirrorlist=|; s|^# ?baseurl=https?://|baseurl=https://|" "$f"
    done
fi
'

case "$MODE" in
build)
    mkdir -p "$OUT"
    # Never leave an older build next to this one: smoke installs every
    # cfm-edge-<v>-<r>.x86_64.rpm it finds here.
    rm -f "$OUT"/cfm-edge*.rpm
    # shellcheck disable=SC2016
    "$ENGINE" "${args[@]}" -v "${OUT}:/out${Z:+:z}" "$IMAGE" bash -c "$prologue"'
        dnf -q -y install rpm-build make gcc git gnupg2 findutils binutils which >/dev/null
        cp -a /src /work && cd /work && rm -rf build dist
        . ./versions.env
        # BuildRequires straight from the spec, with the same defines make uses.
        reqs=$(rpmspec -q --buildrequires \
            --define "nginx_version $NGINX_VERSION" --define "build_stamp 0" \
            --define "openssl_version x" --define "luajit_version x" --define "ndk_version x" \
            --define "lua_nginx_module_version x" --define "lua_resty_core_version x" \
            --define "lua_resty_lrucache_version x" --define "lua_cjson_version x" \
            --define "lua_resty_string_version x" --define "lua_resty_http_version x" --define "lua_resty_maxminddb_version x" \
            --define "edge_changelog_date $(LC_ALL=C date -u "+%a %b %d %Y")" packaging/rpm/cfm-edge.spec)
        # shellcheck disable=SC2086
        dnf -q -y install $reqs >/dev/null
        make rpm
        cp -p dist/*.rpm /out/
        chown -R --reference=/src /out
    '
    ls -1 "$OUT"
    ;;
smoke)
    ls "$OUT"/cfm-edge-[0-9]*.x86_64.rpm >/dev/null 2>&1 || { echo "no rpm in $OUT; run: $0 $EL build" >&2; exit 1; }
    # shellcheck disable=SC2016
    "$ENGINE" "${args[@]}" -v "${OUT}:/rpms:ro${Z}" "$IMAGE" bash -c "$prologue"'
        dnf -q -y install --allowerasing curl procps-ng openssl binutils /rpms/cfm-edge-[0-9]*.x86_64.rpm >/dev/null
        bash /src/tests/smoke.sh
    '
    ;;
cfm-conf)
    # CFM_DIR: a cfm checkout (default ../cfm next to this repo).
    CFM_DIR="${CFM_DIR:-$(cd "$REPO_DIR/.." && pwd)/cfm}"
    [ -f "$CFM_DIR/configs/openresty.conf" ] || { echo "CFM_DIR=$CFM_DIR is not a cfm checkout" >&2; exit 2; }
    # shellcheck disable=SC2016
    "$ENGINE" "${args[@]}" -v "${OUT}:/rpms:ro${Z}" -v "${CFM_DIR}:/cfm:ro${Z}" "$IMAGE" bash -c "$prologue"'
        dnf -q -y install --allowerasing curl procps-ng openssl /rpms/cfm-edge-[0-9]*.x86_64.rpm >/dev/null
        bash /src/tests/cfm-conf.sh /cfm
    '
    ;;
*) echo "unknown mode: $MODE" >&2; exit 2 ;;
esac
