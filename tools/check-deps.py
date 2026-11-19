#!/usr/bin/env python3
"""
check-deps.py — is anything cfm-edge pins behind upstream?

Detection is automatic, adoption is not: this reports what is behind and
`--bump` rewrites versions.env so a human reviews the diff (the scheduled
GitHub Action opens it as a PR). A build never fetches "latest".

Checked:

    nginx        newest release on our nginx.org line (1.<minor>.x; mainline is
                 the odd minor, which is what OpenResty and Angie track). A
                 newer minor is reported, never bumped to. The CHANGES entries
                 between the pin and the new release are read: any "Security:"
                 line makes this a SECURITY bump (exit 4, summary says so).
                 --bump downloads the tarball and PGP-verifies it against
                 keys/nginx/ BEFORE recording its sha256.
    openssl      newest 3.5.x (the LTS line chrismfz/php pins too), sha256 from
                 OpenSSL's own .sha256 next to the release tarball.
    openresty    the Lua set (LuaJIT2, NDK, lua-nginx-module, lua-resty-core,
                 lua-resty-lrucache, lua-cjson, lua-resty-string) exactly as
                 openresty/openresty master's util/mirror-tarballs pins it:
                 they CI that combination, so we take it whole, never per
                 module. Their util/ver says which nginx they validated it
                 against; a set validated against an OLDER nginx than ours is
                 reported (it is what we run until they catch up).
    resty-http / maxminddb
                 newest release tag (no rc) of ledgetech/lua-resty-http and
                 anjia0532/lua-resty-maxminddb.

Every git pin is recorded as tag + the commit it resolves to.

    tools/check-deps.py                    # report
    tools/check-deps.py --bump             # also rewrite versions.env
    tools/check-deps.py --only nginx,openssl
    tools/check-deps.py --summary f.md     # also write a markdown report

Exit: 0 current, 3 behind, 4 behind with an nginx SECURITY fix, 2 error.
Stdlib only, plus the git CLI and (for --bump of nginx) gpg/gpgv.
"""
import argparse, hashlib, os, re, subprocess, sys, tempfile, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VERSIONS = os.path.join(ROOT, "versions.env")
UA = {"User-Agent": "cfm-edge-check-deps"}
CHECKS = ("nginx", "openssl", "openresty", "resty-http", "maxminddb")

# versions.env key prefix -> (github repo, tag prefix, mirror-tarballs name)
OPENRESTY_SET = {
    "LUAJIT":             ("openresty/luajit2",            "v", "luajit2"),
    "NDK":                ("openresty/ngx_devel_kit",      "v", "ngx_devel_kit"),
    "LUA_NGINX_MODULE":   ("openresty/lua-nginx-module",   "v", "lua-nginx-module"),
    "LUA_RESTY_CORE":     ("openresty/lua-resty-core",     "v", "lua-resty-core"),
    "LUA_RESTY_LRUCACHE": ("openresty/lua-resty-lrucache", "v", "lua-resty-lrucache"),
    "LUA_CJSON":          ("openresty/lua-cjson",          "",  "lua-cjson"),
    "LUA_RESTY_STRING":   ("openresty/lua-resty-string",   "v", "lua-resty-string"),
}
STANDALONE = {
    "resty-http": ("LUA_RESTY_HTTP",      "ledgetech/lua-resty-http"),
    "maxminddb":  ("LUA_RESTY_MAXMINDDB", "anjia0532/lua-resty-maxminddb"),
}


def get(url, timeout=120):
    with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=timeout) as r:
        return r.read()


def vkey(v):
    return [int(x) if x.isdigit() else x for x in re.split(r"[.\-]", v)]


def read_env():
    env = {}
    with open(VERSIONS) as f:
        for line in f:
            m = re.match(r"^([A-Z0-9_]+)=(.*)$", line.strip())
            if m:
                env[m.group(1)] = m.group(2)
    return env


def write_env(changes):
    with open(VERSIONS) as f:
        text = f.read()
    for k, v in changes.items():
        text, n = re.subn(rf"(?m)^{k}=.*$", f"{k}={v}", text)
        if n != 1:
            raise SystemExit(f"versions.env: expected exactly one {k}= line, found {n}")
    with open(VERSIONS, "w") as f:
        f.write(text)


def git_tags(repo):
    out = subprocess.run(["git", "ls-remote", "--tags", f"https://github.com/{repo}"],
                         check=True, capture_output=True, text=True).stdout
    tags = {}
    for line in out.splitlines():
        sha, ref = line.split("\t")
        name = ref[len("refs/tags/"):]
        if name.endswith("^{}"):
            tags[name[:-3]] = sha          # peeled: the commit an annotated tag points at
        else:
            tags.setdefault(name, sha)
    return tags


def commit_of(repo, tag):
    c = git_tags(repo).get(tag)
    if not c:
        raise RuntimeError(f"{repo}: tag {tag} not found")
    return c


class Report:
    def __init__(self):
        self.rows, self.changes, self.notes = [], {}, []
        self.behind = self.security = False

    def row(self, name, pinned, latest, status):
        self.rows.append((name, pinned, latest, status))
        if status.startswith("behind"):
            self.behind = True


# --------------------------------------------------------------------- nginx
def check_nginx(env, rep, bump):
    pinned = env["NGINX_VERSION"]
    major_minor = ".".join(pinned.split(".")[:2])
    listing = get("https://nginx.org/download/").decode()
    rels = sorted(set(re.findall(r"nginx-(\d+\.\d+\.\d+)\.tar\.gz\"", listing)), key=vkey)
    line = [v for v in rels if v.startswith(major_minor + ".")]
    latest = line[-1] if line else pinned
    newer_minor = [v for v in rels if vkey(v)[:2] > vkey(pinned)[:2]]
    if newer_minor:
        rep.notes.append(f"nginx: a newer line exists ({newer_minor[-1]}); staying on {major_minor}.x "
                         "until OpenResty's set moves (see the openresty row).")
    if vkey(latest) <= vkey(pinned):
        rep.row("nginx", pinned, latest, "current")
        return
    changes = get("https://nginx.org/en/CHANGES").decode(errors="replace")
    sec = []
    for ver, body in re.findall(r"Changes with nginx (\S+)\s+[^\n]*\n(.*?)(?=\nChanges with nginx |\Z)", changes, re.S):
        if vkey(pinned) < vkey(ver) <= vkey(latest):
            sec += [f"{ver}: " + " ".join(m.split()) for m in re.findall(r"\*\) Security: (.*?)(?=\n\s*\*\)|\Z)", body, re.S)]
    status = "behind (SECURITY)" if sec else "behind"
    rep.row("nginx", pinned, latest, status)
    if sec:
        rep.security = True
        rep.notes += ["nginx security: " + s for s in sec]
    if bump:
        rep.changes.update(NGINX_VERSION=latest, NGINX_SHA256=fetch_verified_nginx(latest), EDGE_RELEASE="1")


def fetch_verified_nginx(ver):
    tb = get(f"https://nginx.org/download/nginx-{ver}.tar.gz", timeout=600)
    asc = get(f"https://nginx.org/download/nginx-{ver}.tar.gz.asc")
    with tempfile.TemporaryDirectory() as d:
        open(os.path.join(d, "t.tar.gz"), "wb").write(tb)
        open(os.path.join(d, "t.asc"), "wb").write(asc)
        kr = os.path.join(d, "keys.gpg")
        with open(kr, "wb") as out:
            for k in sorted(os.listdir(os.path.join(ROOT, "keys", "nginx"))):
                with open(os.path.join(ROOT, "keys", "nginx", k), "rb") as kf:
                    out.write(subprocess.run(["gpg", "--dearmor"], input=kf.read(), check=True,
                                             capture_output=True).stdout)
        r = subprocess.run(["gpgv", "--keyring", kr, os.path.join(d, "t.asc"), os.path.join(d, "t.tar.gz")],
                           capture_output=True, text=True)
        if r.returncode != 0:
            raise RuntimeError(f"nginx {ver}: PGP signature does NOT verify against keys/nginx/ — not bumping\n{r.stderr}")
    return hashlib.sha256(tb).hexdigest()


# ------------------------------------------------------------------- openssl
def check_openssl(env, rep, bump):
    pinned = env["OPENSSL_VERSION"]
    line = ".".join(pinned.split(".")[:2])
    tags = [t[len("openssl-"):] for t in git_tags("openssl/openssl")
            if re.fullmatch(rf"openssl-{re.escape(line)}\.\d+", t)]
    latest = max(tags, key=vkey) if tags else pinned
    if vkey(latest) <= vkey(pinned):
        rep.row("openssl", pinned, latest, "current")
        return
    rep.row("openssl", pinned, latest, "behind")
    if bump:
        base = f"https://github.com/openssl/openssl/releases/download/openssl-{latest}/openssl-{latest}.tar.gz"
        sha = get(base + ".sha256").decode().split()[0]
        if not re.fullmatch(r"[0-9a-f]{64}", sha):
            raise RuntimeError(f"openssl {latest}: unexpected .sha256 content")
        rep.changes.update(OPENSSL_VERSION=latest, OPENSSL_SHA256=sha)
        rep.notes.append(f"openssl {latest}: bump chrismfz/php's OPENSSL pin in the same week (one LTS line, two repos).")


# ----------------------------------------------------------------- openresty
def check_openresty(env, rep, bump):
    with tempfile.TemporaryDirectory() as d:
        subprocess.run(["git", "clone", "-q", "--depth", "1", "https://github.com/openresty/openresty", d],
                       check=True)
        head = subprocess.run(["git", "-C", d, "rev-parse", "--short", "HEAD"],
                              check=True, capture_output=True, text=True).stdout.strip()
        mt = open(os.path.join(d, "util", "mirror-tarballs")).read().splitlines()
        uv = open(os.path.join(d, "util", "ver")).read()
    or_nginx = re.search(r"^main_ver=(\S+)", uv, re.M).group(1)
    if vkey(or_nginx) < vkey(env["NGINX_VERSION"]):
        rep.notes.append(f"openresty master ({head}) still validates its Lua set against nginx {or_nginx}; "
                         f"we run it on {env['NGINX_VERSION']} (the smoke + cfm-conf tests are the check).")
    for key, (repo, prefix, name) in OPENRESTY_SET.items():
        ver = None
        for i, l in enumerate(mt):
            if "get-tarball" in l and name in l:
                vs = [x for x in mt[:i] if re.match(r"^ver=", x)]
                ver = vs[-1].split("=", 1)[1].strip() if vs else None
                break
        if not ver:
            raise RuntimeError(f"openresty mirror-tarballs: no ver= for {name} (layout changed?)")
        pinned = env[f"{key}_VERSION"]
        label = f"openresty:{name}"
        if ver == pinned:
            rep.row(label, pinned, ver, "current")
            continue
        rep.row(label, pinned, ver, "behind")
        if bump:
            rep.changes[f"{key}_VERSION"] = ver
            rep.changes[f"{key}_COMMIT"] = commit_of(repo, prefix + ver)
    if bump and any(k.endswith("_VERSION") and k[:-8] in OPENRESTY_SET for k in rep.changes):
        rep.notes.append(f"openresty set taken from openresty/openresty@{head}: update the comment above it in versions.env.")


def check_standalone(env, rep, bump, which):
    key, repo = STANDALONE[which]
    tags = [t[1:] for t in git_tags(repo) if re.fullmatch(r"v\d+\.\d+\.\d+", t)]
    latest = max(tags, key=vkey)
    pinned = env[f"{key}_VERSION"]
    if vkey(latest) <= vkey(pinned):
        rep.row(which, pinned, latest, "current")
        return
    rep.row(which, pinned, latest, "behind")
    if bump:
        rep.changes[f"{key}_VERSION"] = latest
        rep.changes[f"{key}_COMMIT"] = commit_of(repo, "v" + latest)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--bump", action="store_true")
    ap.add_argument("--only", default=",".join(CHECKS))
    ap.add_argument("--summary")
    a = ap.parse_args()
    only = [c.strip() for c in a.only.split(",") if c.strip()]
    for c in only:
        if c not in CHECKS:
            ap.error(f"unknown check {c!r} (have: {', '.join(CHECKS)})")

    env, rep = read_env(), Report()
    errors = []
    for c in only:
        try:
            if c == "nginx":
                check_nginx(env, rep, a.bump)
            elif c == "openssl":
                check_openssl(env, rep, a.bump)
            elif c == "openresty":
                check_openresty(env, rep, a.bump)
            else:
                check_standalone(env, rep, a.bump, c)
        except Exception as e:                       # one broken check must not hide the others
            errors.append(f"{c}: {e}")

    if a.bump and rep.changes:
        if "NGINX_VERSION" not in rep.changes:       # same nginx, new inputs: next package release
            rep.changes["EDGE_RELEASE"] = str(int(env["EDGE_RELEASE"]) + 1)
        write_env(rep.changes)

    w = max([len(r[0]) for r in rep.rows] + [10])
    for name, pinned, latest, status in rep.rows:
        print(f"{name:<{w}}  {pinned:<20} {latest:<20} {status}")
    for n in rep.notes:
        print("note:", n)
    for e in errors:
        print("ERROR:", e, file=sys.stderr)

    if a.summary:
        title = "SECURITY: nginx security release" if rep.security else ("pins behind upstream" if rep.behind else "all pins current")
        with open(a.summary, "w") as f:
            f.write(f"## cfm-edge deps: {title}\n\n| input | pinned | latest | status |\n|---|---|---|---|\n")
            for r in rep.rows:
                f.write("| " + " | ".join(r) + " |\n")
            if rep.notes:
                f.write("\n" + "\n".join(f"- {n}" for n in rep.notes) + "\n")
            if errors:
                f.write("\n**Check errors:**\n" + "\n".join(f"- {e}" for e in errors) + "\n")
            if rep.behind:
                f.write("\nMerge only after CI is green (build + smoke + cfm-conf on EL8/9/10), "
                        "then canary before promoting to stable (README, Release flow).\n")

    if errors:
        return 2
    if rep.security:
        return 4
    return 3 if rep.behind else 0


if __name__ == "__main__":
    sys.exit(main())
