# CLAUDE.md

Guidance for agents and humans working on cfm-edge. Keep it current: when a
rule below changes or a lesson is learnt, update it in the same change.

cfm-edge packages nginx.org's nginx plus CFM's Lua stack as `cfm-edge`
(README.md). It serves every CFM node's traffic once adopted. A bad build
takes WAF, challenge and every site down at once, so **every change is
tested in a container before it ships, and nothing ships fleet-wide without
a canary**.

## Rules

- **Pins live only in `versions.env`.** The Makefile `include`s it, the spec
  gets every pin as a `--define`, and `tools/fetch-sources.sh` and
  `tools/check-deps.py` read it. Never repeat a version anywhere else, and
  never make a build fetch "latest". A pin changes through a reviewed diff
  (usually the check-deps PR).
- **Verify before trust.**
  - nginx: sha256 AND a PGP signature by a key in `keys/nginx/`, the signers
    nginx.org publishes. A new signer key is a reviewed commit.
  - OpenSSL: sha256 from OpenSSL's own `.sha256`.
  - Git components: the tag must resolve to the pinned commit, and a moved
    tag fails the fetch.

  Don't add an input without one of these.
- **The OpenResty Lua set moves as one.** LuaJIT2, NDK, lua-nginx-module,
  lua-resty-core, lua-resty-lrucache, lua-cjson and lua-resty-string come
  from `openresty/openresty` master's `util/mirror-tarballs`. Never bump one
  of them alone: lua-resty-core refuses a lua-nginx-module it was not
  released with, and OpenResty CI-tests only their combination.
- **The OpenSSL pin follows chrismfz/php.** Same 3.5 LTS line, so bump both
  together. It is static, so an OpenSSL CVE means a cfm-edge rebuild:
  check-deps reports it.
- **A module goes in when CFM needs it.** Before adding an nginx module, a
  `--with-*`, or a Lua library, show where CFM uses it (`configs/`, or Go
  that renders edge config). Every module is attack surface nobody audits for
  us. Experiments go on a branch or behind a build flag, never into `stable`.
- **Source changes are patches**, one change each, in
  `patches/<component>/NNNN-name.patch` with a header saying why. The spec
  lists them as `PatchNNN` and the Makefile stages them as
  `<component>-<file>`. No `sed` on sources in the spec.
- **RPM spec comments:** never write a bare percent-macro in a comment.
  EL's redhat macros expand them inside comments (CFM's spec broke on it), so
  escape them with a double percent.
- **Keep LTO off** (`_lto_cflags %{nil}` in the spec). LuaJIT's VM does not
  survive it.
- **FFI needs exported symbols.** OpenSSL is static, so `resty.sha256`
  (cfm_clearance's HMAC backend on this edge) and every `ffi.C` user reach it
  only because nginx links with `-Wl,-E`. The smoke test checks `nm -D` and a
  sha256 vector. If they fail, clearance cookies fail on every node.
- **The package never takes the live edge's ports.** The placeholder
  `nginx.conf` listens on 127.0.0.1:9099 only. The unit has no `Conflicts=`
  (a stray start would stop openresty or angie) and is not enabled. Switching
  edges belongs to CFM's install script. Nor does an rpm upgrade restart it
  (`%systemd_postun`, not `_with_restart`): a restart drops every connection,
  and a new binary that refuses the live config would leave the edge down.
- **A test that cannot run must fail.** `cfm-conf.sh` fails when CFM's
  checkout is missing. Its only skips are written-down environment limits:
  the resty.openssl mTLS WARN (also present on OpenResty nodes), and the
  `setrlimit` alert only when the hard nofile really is below what CFM asks
  for.

## Before you push

```sh
make lint
make package test-all      # build on EL8; smoke + cfm-conf on EL8/9/10 (CFM_DIR=../cfm)
```

- **One package, built on the oldest EL.** The shipped rpm is built on EL8
  (glibc 2.28) and tested unchanged on EL8, EL9 and EL10. Never ship a
  per-EL build: built on EL9 it needs GLIBC_2.34 and refuses EL8. When EL8
  leaves the fleet, move the build to the next-oldest EL in one change.
- **Keep the system dependencies at glibc, pcre2 and zlib** (+ libmaxminddb
  through the FFI). A module that adds a shared library (auth_basic added
  libcrypt.so.1, which EL9+ only has in libxcrypt-compat) needs a reason.
  Private paths stay under `/usr/lib/cfm-edge`, never `%{_libdir}`: they are
  compiled in, and the same binary must fit a Debian layout.

## Environment notes

- Docker Hub rate-limits anonymous pulls: images come from
  `quay.io/almalinuxorg/almalinux`.
- In a Claude cloud session, outbound traffic is HTTPS-only through a proxy,
  and GitHub's `codeload` (archive tarballs) is blocked while `git` works. That
  is one reason modules are git-pinned. `EDGE_CA` makes the containers trust
  the proxy and use HTTPS baseurls. The sandbox also caps nofile at 20000;
  `EDGE_NOFILE` is opt-in for that reason.
- The CFM side (edge detection, install script, logrotate coverage): see
  HANDOFF.md, "CFM integration".
