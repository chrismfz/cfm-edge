#!/bin/bash
# container-build.sh — build or smoke-test cfm-edge inside a clean AlmaLinux.
#
#   tools/container-build.sh <8|9|10> build    -> dist/el<N>/*.rpm
#   tools/container-build.sh <8|9|10> smoke    install dist/el<N> rpm in a
#                                              fresh container, run tests/smoke.sh
#   tools/container-build.sh <8|9|10> cfm-conf same, then run CFM's real edge
#                                              config + Lua (tests/cfm-conf.sh; CFM_DIR=)
#   tools/container-build.sh deb <smoke|cfm-conf>
#                                              the same two tests on the .deb
#                                              (dist/deb) in IMAGE, a Debian or
#                                              Ubuntu image (default Debian 13)
#
# The repo is mounted read-only and copied inside, so the build never leaves
# root-owned files in the checkout. Needs docker (or podman: ENGINE=podman).
#
# Behind an HTTPS-only egress proxy (a cloud dev session): set EDGE_CA to the
# proxy's CA bundle; the container then trusts it and its dnf uses HTTPS
# baseurls instead of the (http) mirrorlist. Unset on a normal host / CI.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EL="${1:?usage: $0 <8|9|10|deb> <build|smoke|cfm-conf>}"
MODE="${2:?usage: $0 <8|9|10|deb> <build|smoke|cfm-conf>}"
ENGINE="${ENGINE:-docker}"
if [ "$EL" = deb ]; then
    # Docker Hub rate-limits anonymous pulls; mirror.gcr.io is Google's
    # mirror of its library images (debian, ubuntu), not rate-limited.
    IMAGE="${IMAGE:-mirror.gcr.io/library/debian:13}"
    OUT="${REPO_DIR}/dist/deb"
    case "$MODE" in smoke|cfm-conf) ;; *) echo "deb: only smoke and cfm-conf (make deb builds the .deb)" >&2; exit 2 ;; esac
else
    IMAGE="${IMAGE:-quay.io/almalinuxorg/almalinux:${EL}}"
    OUT="${REPO_DIR}/dist/el${EL}"
fi

# SELinux hosts (EL with podman, e.g. the devbox) refuse unlabelled bind
# mounts: add the shared relabel option there.
Z=""
if [ "$ENGINE" = podman ] && command -v getenforce >/dev/null && [ "$(getenforce)" = Enforcing ]; then Z=",z"; fi
args=(run --rm --network host -v "${REPO_DIR}:/src:ro${Z}")
# The package Release: the Makefile computes it once on the host; the
# container's own `make rpm` must use the same value.
[ -n "${BUILD_STAMP:-}" ] && args+=(-e BUILD_STAMP)
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

# The .deb: install it with apt (which pulls its Depends) plus what the tests
# use, then run the same tests the rpm gets. Behind the proxy, apt reads the
# CA from the mounted file (no ca-certificates in the image yet) and the
# mirrors over HTTPS.
# shellcheck disable=SC2016  # expanded inside the container
deb_prologue='
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
if [ -n "${EDGE_CA:-}" ]; then
    printf "Acquire::https::Proxy \"%s\";\nAcquire::https::CAInfo \"/etc/pki/ca-trust/source/anchors/edge-ca.crt\";\n" "$HTTPS_PROXY" >/etc/apt/apt.conf.d/99edge-proxy
    for f in /etc/apt/sources.list.d/*.sources /etc/apt/sources.list; do
        [ -f "$f" ] && sed -i "s|http://|https://|g" "$f"
    done
fi
apt-get -qq update >/dev/null
apt-get -qq install -y --no-install-recommends curl openssl binutils logrotate /debs/cfm-edge_*_amd64.deb >/dev/null
'
if [ "$EL" = deb ]; then
    ls "$OUT"/cfm-edge_*_amd64.deb >/dev/null 2>&1 || { echo "no .deb in $OUT; run: make package deb" >&2; exit 1; }
    case "$MODE" in
    smoke)
        # shellcheck disable=SC2016
        "$ENGINE" "${args[@]}" -v "${OUT}:/debs:ro${Z}" "$IMAGE" bash -c "$deb_prologue"'
            CFM_EDGE_PKG=deb bash /src/tests/smoke.sh
        '
        ;;
    cfm-conf)
        CFM_DIR="${CFM_DIR:-$(cd "$REPO_DIR/.." && pwd)/cfm}"
        [ -f "$CFM_DIR/configs/openresty.conf" ] || { echo "CFM_DIR=$CFM_DIR is not a cfm checkout" >&2; exit 2; }
        # shellcheck disable=SC2016
        "$ENGINE" "${args[@]}" -v "${OUT}:/debs:ro${Z}" -v "${CFM_DIR}:/cfm:ro${Z}" "$IMAGE" bash -c "$deb_prologue"'
            bash /src/tests/cfm-conf.sh /cfm
        '
        ;;
    esac
    exit 0
fi

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
        dnf -q -y install --allowerasing curl procps-ng openssl binutils logrotate /rpms/cfm-edge-[0-9]*.x86_64.rpm >/dev/null
        CFM_EDGE_PKG=rpm bash /src/tests/smoke.sh
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
