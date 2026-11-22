#!/bin/sh
# elf-hardening-check.sh — run by the spec's check section on every build
# (Source24, not installed).
#
# 1. ENFORCES (exit 1): every ELF the package ships carries the distro's link
#    hardening: a non-executable GNU_STACK, GNU_RELRO and BIND_NOW (full
#    RELRO), and PIE for the cfm-edge binary. LuaJIT and lua-cjson build with their
#    own Makefiles, so a bump that stops passing LDFLAGS fails the build here
#    instead of shipping a library with lazy binding or an executable stack.
# 2. REPORTS: how much of the static OpenSSL got the compile-time hardening.
#    nginx's --with-openssl runs OpenSSL's own Configure, which does not read
#    the distro optflags, so nothing proves that libcrypto / libssl carry the
#    stack protector or FORTIFY. Per object it counts references to
#    __stack_chk_fail (stack protector) and to any __*_chk (FORTIFY), next to
#    nginx's own objects (built with optflags) for comparison. Report only:
#    ROADMAP.md §3 decides what to do with it. An archive that cannot be found
#    or read fails (a measurement that cannot run must fail).
#
# Usage: elf-hardening-check.sh BUILDROOT BIN OPENSSL_SRC_DIR NGINX_OBJS_DIR
#   Every ELF file under BUILDROOT is checked (so a new library or module is
#   covered without editing this list); BIN, libluajit-5.1.so.* and cjson.so
#   must be among them. PIE is enforced on BIN and reported for any other
#   executable (the luajit CLI, used only by CFM's Lua selftests).
set -u
if [ "$#" -ne 4 ]; then
    echo "usage: $0 BUILDROOT BIN OPENSSL_SRC_DIR NGINX_OBJS_DIR" >&2
    exit 2
fi
root="$1"; bin="$2"; ossl_dir="$3"; ngx_objs="$4"
fail=0
ok()   { echo "  ok    $*"; }
bad()  { echo "  FAIL  $*"; fail=1; }
note() { echo "  note  $*"; }

echo "== ELF link hardening (enforced)"
elfs="$(mktemp)"
# Not the debuginfo split (find-debuginfo puts *.debug ELFs, which carry no
# dynamic section, under /usr/lib/debug before the check section runs).
find "$root" -path "$root/usr/lib/debug" -prune -o -path "$root/usr/src/debug" -prune -o -type f -exec sh -c 'for f; do readelf -h "$f" >/dev/null 2>&1 && echo "$f"; done' sh {} + | sort >"$elfs"
for want in "$bin" '/libluajit-5\.1\.so\.' '/cjson\.so$'; do
    if [ "$want" = "$bin" ]; then grep -qxF "$bin" "$elfs"; else grep -q "$want" "$elfs"; fi \
        || bad "expected ELF missing under the buildroot: $want"
done
while IFS= read -r f; do
    name="${f#"$root"}"
    stack="$(readelf -lW "$f" | awk '$1 == "GNU_STACK" {print $(NF-1)}')"
    case "$stack" in
        RW) ok "$name: non-executable stack (GNU_STACK RW)" ;;
        "") bad "$name: no GNU_STACK header (the loader then makes the stack executable)" ;;
        *) bad "$name: GNU_STACK is $stack (executable stack)" ;;
    esac
    if readelf -lW "$f" | grep -q GNU_RELRO; then ok "$name: GNU_RELRO"; else bad "$name: no GNU_RELRO"; fi
    if readelf -dW "$f" | grep -qE 'BIND_NOW|FLAGS.*[[:space:]]NOW'; then
        ok "$name: BIND_NOW (full RELRO)"
    else
        bad "$name: no BIND_NOW (lazy binding: partial RELRO only)"
    fi
    # An executable has a program interpreter; PIE = such a file of type DYN.
    if readelf -lW "$f" | grep -q 'INTERP'; then
        if readelf -hW "$f" | grep -q 'Type:.*DYN'; then ok "$name: PIE"
        elif [ "$f" = "$bin" ]; then bad "$name: not PIE"
        else note "$name: not PIE (not enforced)"; fi
    fi
done <"$elfs"
rm -f "$elfs"

# count SYMBOL_ERE FILE...: prints "<objects referencing SYMBOL> <objects>".
# nm -A prefixes each line with "archive:member:" or "file:", then the address
# (blank for an undefined symbol); stripping a trailing ":<hex>" leaves the
# object's name for both kinds of line.
count() {
    sym="$1"; shift
    nm -A "$@" 2>/dev/null | awk -v re="$sym" '
        { o = $1; sub(/:[0-9a-f]*$/, "", o); all[o] = 1 }
        $(NF-1) == "U" && $NF ~ re { hit[o] = 1 }
        END { n = 0; h = 0; for (o in all) n++; for (o in hit) h++; print h, n }'
}
report() { # LABEL FILE...
    label="$1"; shift
    # shellcheck disable=SC2046  # two "<hits> <objects>" pairs, split on purpose
    set -- $(count '^__stack_chk_fail$' "$@") $(count '^__.*_chk$' "$@")
    if [ "${2:-0}" = 0 ]; then
        bad "$label: nm read no objects"
        return
    fi
    echo "  $label: $2 objects with symbols; stack protector in $1 ($(( $1 * 100 / $2 ))%); FORTIFY (__*_chk) in $3 ($(( $3 * 100 / $2 ))%)"
}

echo "== OpenSSL compile hardening (report only)"
find_a() { # NAME: the archive nginx's build installed (.openssl/lib*), else the source tree's
    a="$(find "$ossl_dir" -path '*/.openssl/*' -name "$1" 2>/dev/null | head -1)"
    [ -n "$a" ] || a="$(find "$ossl_dir" -name "$1" 2>/dev/null | head -1)"
    echo "$a"
}
crypto="$(find_a libcrypto.a)"
ssl="$(find_a libssl.a)"
if [ -z "$crypto" ] || [ -z "$ssl" ]; then
    bad "no libcrypto.a / libssl.a under $ossl_dir: the OpenSSL hardening cannot be measured"
else
    # The flags OpenSSL's Configure chose (what every crypto/ and ssl/ object
    # was compiled with): the direct answer, the counts below corroborate it.
    if [ -f "$ossl_dir/Makefile" ]; then
        echo "  OpenSSL's Makefile (its Configure's choice):"
        grep -E '^(CNF_)?(CFLAGS|CPPFLAGS|LDFLAGS)=' "$ossl_dir/Makefile" | sed 's/^/    /'
    else
        note "no $ossl_dir/Makefile: OpenSSL's compile flags not shown"
    fi
    report libcrypto.a "$crypto"
    report libssl.a "$ssl"
    # nginx's own objects, built with optflags: what "hardened" looks like here.
    ngx_list="$(mktemp)"
    find "$ngx_objs" -name '*.o' >"$ngx_list" 2>/dev/null
    if [ -s "$ngx_list" ]; then
        # shellcheck disable=SC2046  # object paths from nginx's objs/, no spaces
        report "nginx objects (optflags, for comparison)" $(cat "$ngx_list")
    else
        bad "no nginx objects under $ngx_objs: nothing to compare with"
    fi
    rm -f "$ngx_list"
    echo "  An object with no local array needs no canary, and one without a fortifiable"
    echo "  call no __*_chk: compare the shares with nginx's. 0% for OpenSSL = not passed."
    if command -v annocheck >/dev/null 2>&1; then
        echo "  annocheck ${bin##*/} (the static OpenSSL is linked into it):"
        annocheck "$bin" 2>&1 | tail -20 | sed 's/^/    /'
    else
        echo "  (no annocheck in the build container: stack-clash / CET notes not measured)"
    fi
fi

if [ "$fail" = 0 ]; then echo "ELF HARDENING OK"; else echo "ELF HARDENING FAILED"; fi
exit "$fail"
