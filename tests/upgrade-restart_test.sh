#!/bin/bash
# upgrade-restart_test.sh — the rpm's post-upgrade restart, every branch, with
# stubs for systemctl / cfm / cfm-edge / ss / curl (no root, no container).
# Run by `make lint`. What it pins: an edge in the path is never restarted
# while it takes traffic, a stopped edge is never started, a config the new
# binary refuses never restarts it, and a failed restart leaves the DNAT off.
set -euo pipefail
cd "$(dirname "$0")/.."
SCRIPT=packaging/rpm/cfm-edge-upgrade-restart.sh
[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT missing" >&2; exit 1; }
sh -n "$SCRIPT" || { echo "FAIL: $SCRIPT does not parse (sh -n)" >&2; exit 1; }
if command -v dash >/dev/null 2>&1; then dash -n "$SCRIPT" || { echo "FAIL: $SCRIPT is not POSIX (dash -n)" >&2; exit 1; }; fi

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin"

# State files: unit (active|inactive), web/panel (ON|OFF), and knobs:
#   cfgbad (cfm-edge -t fails), oldcfm (no `cfm edge`), offstuck (off does
#   nothing), startfail (restart/start leave the unit down), nocfm, optout
#   (the opt-out file exists).
cat >"$W/bin/systemctl" <<'EOF'
#!/bin/sh
S="$STUB_STATE"; echo "systemctl $*" >>"$S/calls"
case "$1" in
  is-active) [ "$(cat "$S/unit")" = active ] ;;
  daemon-reload) : ;;
  restart|start) if [ -e "$S/startfail" ]; then echo inactive >"$S/unit"; exit 1; fi
                 # The restart must never happen while the edge is in the path.
                 if grep -q ON "$S/web" "$S/panel"; then echo "RESTART-WHILE-IN-PATH" >>"$S/calls"; fi
                 echo active >"$S/unit" ;;
esac
EOF
cat >"$W/bin/cfm" <<'EOF'
#!/bin/sh
S="$STUB_STATE"; echo "cfm $*" >>"$S/calls"
[ -e "$S/oldcfm" ] && { echo "unknown command: edge"; exit 2; }
case "$*" in
  "edge") echo "Edge"; echo "  Web DNAT:    $(cat "$S/web")   priority -101"; echo "  Panel DNAT:  $(cat "$S/panel")" ;;
  "edge off") [ -e "$S/offstuck" ] || echo OFF >"$S/web" ;;
  "edge on") echo ON >"$S/web" ;;
  "edge panel off") [ -e "$S/offstuck" ] || echo OFF >"$S/panel" ;;
  "edge panel on") echo ON >"$S/panel" ;;
esac
EOF
cat >"$W/bin/cfm-edge" <<'EOF'
#!/bin/sh
echo "cfm-edge $*" >>"$STUB_STATE/calls"
[ -e "$STUB_STATE/cfgbad" ] && { echo "nginx: [emerg] unknown directive" >&2; exit 1; }
exit 0
EOF
cat >"$W/bin/ss" <<'EOF'
#!/bin/sh
[ "$(cat "$STUB_STATE/unit")" = active ] && echo 'LISTEN 0 511 0.0.0.0:9043 0.0.0.0:* users:(("cfm-edge",pid=1,fd=12))'
exit 0
EOF
cat >"$W/bin/curl" <<'EOF'
#!/bin/sh
if [ "$(cat "$STUB_STATE/unit")" = active ]; then printf 200; else printf 000; fi
EOF
printf '#!/bin/sh\nexit 0\n' >"$W/bin/logger"
printf '#!/bin/sh\nexit 0\n' >"$W/bin/sleep"
chmod +x "$W/bin/"*

n=0
# scenario NAME UNIT WEB PANEL [knob...] -- expected: rc 0 always
run() {
  local name="$1" unit="$2" web="$3" panel="$4"; shift 4
  n=$((n + 1)); S="$W/s$n"; mkdir -p "$S"
  echo "$unit" >"$S/unit"; echo "$web" >"$S/web"; echo "$panel" >"$S/panel"; : >"$S/calls"
  for k in "$@"; do : >"$S/$k"; done
  local path="$W/bin:/usr/bin:/bin"
  [ -e "$S/nocfm" ] && { mkdir -p "$S/nocfmbin"; for f in "$W/bin/"*; do [ "$(basename "$f")" = cfm ] || ln -s "$f" "$S/nocfmbin/"; done; path="$S/nocfmbin:/usr/bin:/bin"; }
  set +e
  OUT="$(env -i PATH="$path" STUB_STATE="$S" CFM_EDGE_BIN="$W/bin/cfm-edge" CFM_EDGE_OPTOUT="$S/optout" sh "$SCRIPT" 2>&1)"
  RC=$?
  set -e
  CALLS="$(cat "$S/calls")"
  [ "$RC" = 0 ] || fail "$name: exit $RC (must always be 0, never fail the rpm transaction)"
  grep -q RESTART-WHILE-IN-PATH <<<"$CALLS" && fail "$name: restarted while the DNAT was on"
  return 0
}
fail() { echo "FAIL: $*"; echo "--- output:"; echo "$OUT"; echo "--- calls:"; echo "$CALLS"; exit 1; }
has()   { grep -qF -- "$1" <<<"$CALLS" || fail "$CURRENT: expected call: $1"; }
hasnt() { ! grep -qF -- "$1" <<<"$CALLS" || fail "$CURRENT: unexpected call: $1"; }
state() { [ "$(cat "$S/$1")" = "$2" ] || fail "$CURRENT: $1 is $(cat "$S/$1"), want $2"; }
says()  { grep -qF -- "$1" <<<"$OUT" || fail "$CURRENT: expected output: $1"; }
order() { # order A B: call A happens before call B
  local a b; a="$(grep -nF -- "$1" <<<"$CALLS" | head -1 | cut -d: -f1)"; b="$(grep -nF -- "$2" <<<"$CALLS" | head -1 | cut -d: -f1)"
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ] || fail "$CURRENT: '$1' must come before '$2'"; }

CURRENT="not running"; run "$CURRENT" inactive ON ON
has "systemctl is-active"   # the stubs ran, not the host's systemctl
hasnt "systemctl restart"; hasnt "systemctl start"; hasnt "cfm edge off"; hasnt "cfm-edge -t"

CURRENT="opt-out"; run "$CURRENT" active ON ON optout
hasnt "systemctl restart"; hasnt "cfm edge off"; says "not restarting"

CURRENT="config refused"; run "$CURRENT" active ON ON cfgbad
hasnt "systemctl restart"; hasnt "cfm edge off"; state web ON; says "refuses the live config"

CURRENT="old cfm"; run "$CURRENT" active ON ON oldcfm
hasnt "systemctl restart"; hasnt "cfm edge off"; says "NOT restarting"

CURRENT="no cfm"; run "$CURRENT" active ON ON nocfm
hasnt "systemctl restart"; says "NOT restarting"

CURRENT="dnat off"; run "$CURRENT" active OFF OFF
has "systemctl restart cfm-edge.service"; hasnt "cfm edge off"; hasnt "cfm edge on"; order "cfm-edge -t" "systemctl restart"

CURRENT="web on, panel off"; run "$CURRENT" active ON OFF
order "cfm edge off" "systemctl restart"; order "systemctl restart" "cfm edge on"; hasnt "cfm edge panel"; state web ON; state panel OFF

CURRENT="web + panel on"; run "$CURRENT" active ON ON
order "cfm edge off" "systemctl restart"; order "cfm edge panel off" "systemctl restart"
order "systemctl restart" "cfm edge on"; order "systemctl restart" "cfm edge panel on"; state web ON; state panel ON
order "cfm-edge -t" "cfm edge off"; order "systemctl daemon-reload" "systemctl restart"

CURRENT="panel only"; run "$CURRENT" active OFF ON
order "cfm edge panel off" "systemctl restart"; hasnt "cfm edge off"; state panel ON; state web OFF

CURRENT="off did not take"; run "$CURRENT" active ON ON offstuck
hasnt "systemctl restart"; state web ON; state panel ON; says "did not turn off"

CURRENT="restart fails"; run "$CURRENT" active ON ON startfail
has "systemctl start cfm-edge.service"; state web OFF; state panel OFF; says "DNAT STAYS OFF"; hasnt "cfm edge on"

echo "OK: upgrade-restart: $n scenarios (never restarts in the path, never starts a stopped edge, refused config / old cfm / opt-out keep the old edge, failed restart keeps the DNAT off)"
