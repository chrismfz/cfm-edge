#!/bin/bash
# fetch-sources.sh — download and VERIFY every pinned input into one directory.
#
#   tools/fetch-sources.sh [DEST]        (default: ./SOURCES)
#
# Everything comes from versions.env and nothing is trusted unverified:
#   nginx    release tarball: sha256 pin AND a PGP signature by a key in
#            keys/nginx/ (the signers nginx.org publishes);
#   OpenSSL  release tarball: sha256 pin (taken from OpenSSL's own .sha256);
#   modules  git clone of the tag, which must resolve to the pinned commit,
#            then `git archive` into <name>-<version>.tar.gz for rpmbuild.
# Pinning modules by commit rather than by GitHub's generated tag tarball keeps
# the pin byte-exact (those tarballs are not guaranteed stable) and works on
# hosts that reach GitHub only over git.
#
# Idempotent: a file already present is re-hashed (tarballs) or skipped only
# if its .pin stamp names the same commit (modules). Exit non-zero on ANY
# mismatch; a partial download never survives under the final name.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${1:-${REPO_DIR}/SOURCES}"
# shellcheck source=../versions.env
. "${REPO_DIR}/versions.env"

log()  { printf '==> %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

mkdir -p "$DEST"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

sha_ok() { [ -f "$1" ] && [ "$(sha256sum "$1" | cut -d' ' -f1)" = "$2" ]; }

fetch_tarball() {   # name url sha256
    local name="$1" url="$2" sum="$3"
    if sha_ok "$DEST/$name" "$sum"; then log "$name: ok (cached)"; return; fi
    log "$name: downloading"
    curl -fsSL --retry 3 --max-time 600 -o "$TMP/$name" "$url" || die "$name: download failed ($url)"
    sha_ok "$TMP/$name" "$sum" || die "$name: sha256 mismatch (got $(sha256sum "$TMP/$name" | cut -d' ' -f1), pinned $sum)"
    mv -f "$TMP/$name" "$DEST/$name"
}

verify_nginx_sig() {
    local tb="$DEST/nginx-${NGINX_VERSION}.tar.gz"
    curl -fsSL --retry 3 -o "$TMP/nginx.asc" "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz.asc" \
        || die "nginx: signature download failed"
    command -v gpgv >/dev/null || die "gpgv not found (install gnupg2): refusing an unverified nginx"
    local kr="$TMP/nginx-keys.gpg"
    # gpgv wants a keyring, not armored keys: dearmor each into one file.
    for k in "$REPO_DIR"/keys/nginx/*.key; do gpg --dearmor <"$k"; done >"$kr"
    gpgv --keyring "$kr" "$TMP/nginx.asc" "$tb" >/dev/null 2>&1 \
        || die "nginx: PGP signature does NOT verify against keys/nginx/"
    log "nginx-${NGINX_VERSION}: PGP signature ok"
}

fetch_git() {   # name version repo tag commit
    local name="$1" ver="$2" repo="$3" tag="$4" commit="$5"
    local out="$DEST/${name}-${ver}.tar.gz" stamp="$DEST/${name}-${ver}.pin"
    if [ -f "$out" ] && [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$commit" ]; then
        log "${name}-${ver}: ok (cached, $commit)"; return
    fi
    log "${name}-${ver}: git $repo @ $tag"
    git -c advice.detachedHead=false clone -q --depth 1 --branch "$tag" \
        "https://github.com/${repo}.git" "$TMP/$name" || die "$name: clone of tag $tag failed"
    local got; got="$(git -C "$TMP/$name" rev-parse HEAD)"
    [ "$got" = "$commit" ] || die "$name: tag $tag is $got, pinned $commit (tag moved? review before bumping)"
    git -C "$TMP/$name" archive --format=tar --prefix="${name}-${ver}/" HEAD | gzip -n >"$TMP/$name.tar.gz"
    mv -f "$TMP/$name.tar.gz" "$out"
    printf '%s\n' "$commit" >"$stamp"
}

fetch_tarball "nginx-${NGINX_VERSION}.tar.gz" \
    "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz" "$NGINX_SHA256"
verify_nginx_sig
fetch_tarball "openssl-${OPENSSL_VERSION}.tar.gz" \
    "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz" \
    "$OPENSSL_SHA256"

fetch_git luajit2             "$LUAJIT_VERSION"              openresty/luajit2              "v$LUAJIT_VERSION"              "$LUAJIT_COMMIT"
fetch_git ngx_devel_kit       "$NDK_VERSION"                 openresty/ngx_devel_kit        "v$NDK_VERSION"                 "$NDK_COMMIT"
fetch_git lua-nginx-module    "$LUA_NGINX_MODULE_VERSION"    openresty/lua-nginx-module     "v$LUA_NGINX_MODULE_VERSION"    "$LUA_NGINX_MODULE_COMMIT"
fetch_git lua-resty-core      "$LUA_RESTY_CORE_VERSION"      openresty/lua-resty-core       "v$LUA_RESTY_CORE_VERSION"      "$LUA_RESTY_CORE_COMMIT"
fetch_git lua-resty-lrucache  "$LUA_RESTY_LRUCACHE_VERSION"  openresty/lua-resty-lrucache   "v$LUA_RESTY_LRUCACHE_VERSION"  "$LUA_RESTY_LRUCACHE_COMMIT"
fetch_git lua-cjson           "$LUA_CJSON_VERSION"           openresty/lua-cjson            "$LUA_CJSON_VERSION"            "$LUA_CJSON_COMMIT"
fetch_git lua-resty-string    "$LUA_RESTY_STRING_VERSION"    openresty/lua-resty-string     "v$LUA_RESTY_STRING_VERSION"    "$LUA_RESTY_STRING_COMMIT"
fetch_git lua-resty-http      "$LUA_RESTY_HTTP_VERSION"      ledgetech/lua-resty-http       "v$LUA_RESTY_HTTP_VERSION"      "$LUA_RESTY_HTTP_COMMIT"
fetch_git lua-resty-maxminddb "$LUA_RESTY_MAXMINDDB_VERSION" anjia0532/lua-resty-maxminddb  "v$LUA_RESTY_MAXMINDDB_VERSION" "$LUA_RESTY_MAXMINDDB_COMMIT"

log "all sources verified in $DEST"
