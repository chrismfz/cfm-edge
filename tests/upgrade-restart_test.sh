#!/bin/bash
# upgrade-restart_test.sh — the rpm's post-upgrade restart, every branch, with
# stubs for systemctl / systemd-run / cfm / cfm-edge / ss / curl (no root, no
# container). Run by `make lint`. It pins:
#   - an edge in the path is never restarted unless the DNAT reads OFF;
#   - a stopped edge is never started;
#   - a config the new binary refuses (in the unit's sandbox too) never
#     restarts it;
#   - another engine's DNAT is never touched;
#   - the web DNAT comes back with the live priority and ports;
#   - a failed restart, or one that never serves, leaves the DNAT off.
# The script never reaches the host's cfm or systemctl: CFM_BIN and the PATH
# point at stubs only (a test run as root on a CFM node must not move its DNAT).
set -euo pipefail
cd "$(dirname "$0")/.."
SCRIPT=packaging/rpm/cfm-edge-upgrade-restart.sh
[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT missing" >&2; exit 1; }
sh -n "$SCRIPT" || { echo "FAIL: $SCRIPT does not parse (sh -n)" >&2; exit 1; }
if command -v dash >/dev/null 2>&1; then dash -n "$SCRIPT" || { echo "FAIL: $SCRIPT is not POSIX (dash -n)" >&2; exit 1; }; fi

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin"

# Per-scenario state in $STUB_STATE: unit (active|inactive), web / panel
# (ON|OFF|UNKNOWN), engine (the Engine: text), and knobs (files):
#   cfgbad      cfm-edge -t fails everywhere
#   sandboxbad  -t fails only inside systemd-run (a sandbox the unit adds)
#   runrw       the sandbox leaves /run writable (the read-only probe succeeds)
#   nosdrun     systemd-run unusable (no bus): plain -t is used
#   oldcfm      `cfm edge` is an unknown command
#   offfail     `cfm edge off` fails and the DNAT reads UNKNOWN after it
#   offstuck    `cfm edge off` / `panel off` do nothing
#   panelstuck  only `cfm edge panel off` does nothing
#   startfail   restart/start leave the unit down
#   notserving  the unit is active but does not listen / answer
#   nolisten    active and answers, but nothing listens on :9043 as cfm-edge
#   noanswer    listens, but https://127.0.0.1:9043/ gets no answer (000)
#   offrc       `cfm edge off` turns it OFF but exits non-zero
#   bypass      CFM prints a bypass note right after the state ("OFF; 1 bypass source(s)")
#   optout      the opt-out file exists
#   nocfm       CFM_BIN points at nothing
#   pidline     the live config (cfm-edge -T) sets its own pid
#   onfails     a number: `cfm edge on` fails that many times first (the cfm
#               daemon restarting in the same yum transaction holds nft)
#   offfails    a number: `cfm edge off` fails that many times first
#   panelbackn  a number: `cfm edge panel off` succeeds but the panel stays ON
#               that many times (the cfm daemon putting it back as it starts)
#   cfmage      a number: the cfm daemon (pid 4242) has run that many seconds
#   cfmstate    what `systemctl is-active cfm.service` prints (default active);
#               the first sleep turns "activating" into "active"
#   cfmmarker   cfm.service carries Markers=needs-restart (EL9+: its restart
#               comes at the end of the transaction)
#   cfmrestarts the first sleep restarts it (the marker clears)
#   deferred    run the script as its transient unit does (--deferred)
#   lockheld    another run holds the lock (and CFM_EDGE_DEFER_MAX is 1)
#   killonrestart  the script gets SIGTERM during the restart
cat >"$W/bin/systemctl" <<'EOF'
#!/bin/sh
S="$STUB_STATE"; echo "systemctl $*" >>"$S/calls"
case "$1" in
  is-active) case "$*" in
               *cfm.service*) st="$(cat "$S/cfmstate" 2>/dev/null || echo active)"; echo "$st"; [ "$st" = active ] ;;
               *) [ "$(cat "$S/unit")" = active ] ;;
             esac ;;
  daemon-reload) : ;;
  show) case "$*" in
          *"cfm.service -p Markers"*) [ -e "$S/cfmmarker" ] && echo needs-restart ;;
          *"cfm.service -p MainPID"*) if [ -e "$S/cfmage" ]; then echo 4242; else echo 0; fi ;;
        esac ;;
  cat) printf '[Service]\nProtectSystem=strict\nReadWritePaths=/var/log/cfm-edge /var/cache/nginx\nNoNewPrivileges=yes\nProtectClock=yes\n' ;;
  restart|start) if [ -e "$S/startfail" ]; then echo inactive >"$S/unit"; exit 1; fi
                 # The restart must never happen while cfm-edge is in the path.
                 if [ "$(cat "$S/enginename")" = cfm-edge ] && ! { grep -qx OFF "$S/web" && grep -qx OFF "$S/panel"; }; then
                   echo "RESTART-WHILE-IN-PATH" >>"$S/calls"; fi
                 if [ -e "$S/killonrestart" ] && [ ! -e "$S/killed" ]; then : >"$S/killed"; kill -TERM "$PPID"; fi
                 echo active >"$S/unit" ;;
esac
EOF
cat >"$W/bin/systemd-run" <<'EOF'
#!/bin/sh
S="$STUB_STATE"; echo "systemd-run $*" >>"$S/calls"
[ -e "$S/nosdrun" ] && { echo "Failed to connect to bus" >&2; exit 1; }
case "$*" in
  *--deferred*) exit 0 ;;   # the handoff to a transient unit
  *ProtectClock*/bin/true) exit 1 ;;   # as EL8: refused transiently
  */bin/true) exit 0 ;;
  *cfm-edge-ro-probe*) [ -e "$S/runrw" ] && exit 0; exit 1 ;;   # EROFS, as the unit's sandbox
  *" -t -q") [ -e "$S/sandboxbad" ] && { echo "nginx: [emerg] open() failed (30: Read-only file system)" >&2; exit 1; }
             [ -e "$S/cfgbad" ] && exit 1; exit 0 ;;
esac
exit 0
EOF
cat >"$W/bin/cfm" <<'EOF'
#!/bin/sh
S="$STUB_STATE"; echo "cfm $*" >>"$S/calls"
[ -e "$S/oldcfm" ] && { echo "unknown command: edge"; exit 2; }
w="$(cat "$S/web")"; p="$(cat "$S/panel")"
case "$*" in
  "edge")
    echo "Edge"; echo "  Engine:      $(cat "$S/engine")"
    b=""; [ -e "$S/bypass" ] && b="; 1 bypass source(s)"   # cfm's bypassNote(), as on orion
    case "$w" in
      ON) echo "  Web DNAT:    ON   priority -101, tcp/80 -> :9080, tcp+udp/443 -> :9043$b" ;;
      OFF) echo "  Web DNAT:    OFF  (the origin serves 80/443 directly)$b" ;;
      *) echo "  Web DNAT:    UNKNOWN (nft: resource busy, ON maybe)"; rc=1 ;;
    esac
    case "$p" in ON) echo "  Panel DNAT:  ON   priority -101, mode auto$b" ;; OFF) echo "  Panel DNAT:  OFF$b" ;; *) echo "  Panel DNAT:  UNKNOWN"; rc=1 ;; esac
    exit "${rc:-0}" ;;
  "edge off") if [ -s "$S/offfails" ] && [ "$(cat "$S/offfails")" -gt 0 ]; then
                echo $(( $(cat "$S/offfails") - 1 )) >"$S/offfails"; echo "Error: nft: timed out (slot busy)" >&2; exit 1; fi
              [ -e "$S/offfail" ] && { echo UNKNOWN >"$S/web"; exit 1; }
              [ -e "$S/offrc" ] && { echo OFF >"$S/web"; exit 1; }
              [ -e "$S/offstuck" ] || echo OFF >"$S/web" ;;
  "edge on"*) if [ -s "$S/onfails" ] && [ "$(cat "$S/onfails")" -gt 0 ]; then
                echo $(( $(cat "$S/onfails") - 1 )) >"$S/onfails"; echo "Error: nft: timed out (slot busy)" >&2
                printf '  add rule inet cfm input ct original ip daddr 1.2.3.4\n  } }\n  } } );\n' >&2; exit 1; fi
              echo ON >"$S/web" ;;
  "edge panel off") if [ -s "$S/panelbackn" ] && [ "$(cat "$S/panelbackn")" -gt 0 ]; then
                      echo $(( $(cat "$S/panelbackn") - 1 )) >"$S/panelbackn"; exit 0; fi
                    [ -e "$S/offstuck" ] || [ -e "$S/panelstuck" ] || echo OFF >"$S/panel" ;;
  "edge panel on") echo ON >"$S/panel" ;;
esac
EOF
cat >"$W/bin/cfm-edge" <<'EOF'
#!/bin/sh
echo "cfm-edge $*" >>"$STUB_STATE/calls"
[ -e "$STUB_STATE/cfgbad" ] && { echo "nginx: [emerg] unknown directive" >&2; exit 1; }
if [ "$1" = -T ]; then
  # Always an inline-Lua "pid =" line: it must never read as a pid directive.
  printf '# configuration file /etc/cfm-edge/nginx.conf:\nworker_processes 6;\n'
  [ -e "$STUB_STATE/pidline" ] && printf 'pid       /run/cfm-edge.pid;\n'
  printf 'http {\n    init_worker_by_lua_block {\n        local t = { pid = ngx.worker.pid() }\n        pid = t.pid\n    }\n}\n'
fi
exit 0
EOF
cat >"$W/bin/ss" <<'EOF'
#!/bin/sh
[ "$(cat "$STUB_STATE/unit")" = active ] && [ ! -e "$STUB_STATE/notserving" ] && [ ! -e "$STUB_STATE/nolisten" ] && echo 'LISTEN 0 511 0.0.0.0:9043 0.0.0.0:* users:(("cfm-edge",pid=1,fd=12))'
exit 0
EOF
cat >"$W/bin/curl" <<'EOF'
#!/bin/sh
echo "curl $*" >>"$STUB_STATE/calls"
if [ "$(cat "$STUB_STATE/unit")" = active ] && [ ! -e "$STUB_STATE/notserving" ] && [ ! -e "$STUB_STATE/noanswer" ]; then printf 200; else printf 000; fi
EOF
printf '#!/bin/sh\nexit 0\n' >"$W/bin/logger"
cat >"$W/bin/sleep" <<'STUB'
#!/bin/sh
echo "sleep $*" >>"$STUB_STATE/calls"
# cfm's restart, later in the same transaction, happens while the deferred run waits
[ -e "$STUB_STATE/cfmrestarts" ] && rm -f "$STUB_STATE/cfmmarker"
[ "$(cat "$STUB_STATE/cfmstate" 2>/dev/null)" = activating ] && echo active >"$STUB_STATE/cfmstate"
exit 0
STUB
cat >"$W/bin/ps" <<'STUB'
#!/bin/sh
cat "$STUB_STATE/cfmage" 2>/dev/null || echo 999
STUB
chmod +x "$W/bin/"*

n=0
fail() { echo "FAIL: $*"; echo "--- output:"; echo "$OUT"; echo "--- calls:"; echo "$CALLS"; exit 1; }
# run NAME UNIT WEB PANEL ENGINE [knob...]   (ENGINE: cfm-edge | openresty | ambiguous)
run() {
  CURRENT="$1"; local unit="$2" web="$3" panel="$4" engine="$5"; shift 5
  n=$((n + 1)); S="$W/s$n"; mkdir -p "$S"
  echo "$unit" >"$S/unit"; echo "$web" >"$S/web"; echo "$panel" >"$S/panel"; : >"$S/calls"
  echo "$engine" >"$S/enginename"
  case "$engine" in
    ambiguous) echo "WARNING: more than one of angie, openresty, cfm-edge is active" >"$S/engine" ;;
    *) echo "$engine (running)" >"$S/engine" ;;
  esac
  local cfmbin="$W/bin/cfm" k arg="" defermax=600
  for k in "$@"; do
    case "$k" in *=*) echo "${k#*=}" >"$S/${k%%=*}" ;; *) : >"$S/$k" ;; esac   # knob=N sets a count
    if [ "$k" = nocfm ]; then cfmbin="$W/does-not-exist/cfm"; fi
    if [ "$k" = deferred ]; then arg=--deferred; fi
    if [ "$k" = lockheld ]; then defermax=1; fi
  done
  if [ -e "$S/lockheld" ]; then flock "$S/lock" sleep 5 & sleep 0.3; fi
  set +e
  OUT="$(env -i PATH="$W/bin:/usr/bin:/bin" STUB_STATE="$S" CFM_EDGE_BIN="$W/bin/cfm-edge" CFM_BIN="$cfmbin" \
         CFM_EDGE_OPTOUT="$S/optout" CFM_EDGE_UPGRADE_WAIT=3 CFM_EDGE_LOCK="$S/lock" CFM_EDGE_RUNDIR="$S/rundir" CFM_EDGE_DEFER_MAX="$defermax" sh "$SCRIPT" $arg 2>&1)"
  RC=$?
  set -e
  CALLS="$(cat "$S/calls")"
  [ "$RC" = 0 ] || fail "$CURRENT: exit $RC (must always be 0, never fail the rpm transaction)"
  if grep -q RESTART-WHILE-IN-PATH <<<"$CALLS"; then fail "$CURRENT: restarted while the DNAT was not OFF"; fi
}
has()   { grep -qF -- "$1" <<<"$CALLS" || fail "$CURRENT: expected call: $1"; }
hasnt() { if grep -qF -- "$1" <<<"$CALLS"; then fail "$CURRENT: unexpected call: $1"; fi; }
state() { [ "$(cat "$S/$1")" = "$2" ] || fail "$CURRENT: $1 is $(cat "$S/$1"), want $2"; }
says()  { grep -qF -- "$1" <<<"$OUT" || fail "$CURRENT: expected output: $1"; }
order() { # the first call A happens before the first call B
  local a b; a="$(grep -nF -- "$1" <<<"$CALLS" | head -1 | cut -d: -f1)"; b="$(grep -nF -- "$2" <<<"$CALLS" | head -1 | cut -d: -f1)"
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ] || fail "$CURRENT: '$1' must come before '$2'"; }
lastorder() { # the last call A happens after the last call B
  local a b; a="$(grep -nF -- "$1" <<<"$CALLS" | tail -1 | cut -d: -f1)"; b="$(grep -nF -- "$2" <<<"$CALLS" | tail -1 | cut -d: -f1)"
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -gt "$b" ] || fail "$CURRENT: the last '$1' must come after the last '$2'"; }

run "not running" inactive ON ON cfm-edge
has "systemctl is-active"   # the stubs ran, not the host's systemctl
hasnt "systemctl restart"; hasnt "systemctl start"; hasnt "cfm edge off"; hasnt "cfm-edge -t"; hasnt "systemd-run"

run "opt-out" active ON ON cfm-edge optout
hasnt "systemctl restart"; hasnt "cfm edge off"; says "not restarting"

run "config refused" active ON ON cfm-edge cfgbad
hasnt "systemctl restart"; hasnt "cfm edge off"; state web ON; says "refuses the live config"

run "config refused only in the sandbox" active ON ON cfm-edge sandboxbad
hasnt "systemctl restart"; hasnt "cfm edge off"; state web ON; says "Read-only file system"
has "-p ProtectSystem=strict"; has "-p ReadWritePaths=/var/log/cfm-edge /var/cache/nginx"   # the unit's own properties, spaces intact
if grep -- ' -t -q' <<<"$CALLS" | grep -q 'ProtectClock'; then fail "$CURRENT: a property systemd-run refuses transiently must be dropped from the -t run"; fi

run "live config sets its own pid" active ON ON cfm-edge pidline
hasnt "systemctl restart"; hasnt "cfm edge off"; state web ON; state panel ON; says "sets its own pid"
has "cfm-edge -T"

run "a config pid is reported as such, before the config test" active ON ON cfm-edge pidline sandboxbad
says "sets its own pid"; hasnt "refuses the live config"; hasnt "systemctl restart"; state web ON

# rigel / qualityweb, 2026-11-23: /run stayed rw in the sandbox on EL9/EL10
# until the unit listed ReadOnlyPaths=/run; the probe catches it coming back.
run "/run writable in the sandbox: a warning, the restart still happens" active ON ON cfm-edge runrw
says "WARNING: /run is writable inside cfm-edge's sandbox"; has "systemctl restart"; state web ON; state panel ON
has "cfm-edge-ro-probe"

run "/run read-only in the sandbox: no warning" active ON ON cfm-edge
hasnt "/run is writable"; has "cfm-edge-ro-probe"; has "systemctl restart"

# virgo, 2026-11-23 (the canary): nginx -t opens the pid file, and the
# transient -t has no RuntimeDirectory, so its dir comes as a write path; the
# script makes the dir when the boot's tmpfiles.d has not yet.
run "the sandboxed -t gets the pid dir as a write path" active ON ON cfm-edge
[ -d "$S/rundir" ] || fail "$CURRENT: the pid dir was not made"
grep -- ' -t -q' <<<"$CALLS" | grep -qF -- "-p ReadWritePaths=$S/rundir" || fail "$CURRENT: the -t run lacks ReadWritePaths=<pid dir>"
has "systemctl restart"

run "inline Lua 'pid =' is not a pid directive" active OFF OFF cfm-edge
has "cfm-edge -T"; has "systemctl restart"

run "no systemd-run: plain -t" active OFF OFF cfm-edge nosdrun
has "cfm-edge -t -q"; has "systemctl restart cfm-edge.service"

run "old cfm" active ON ON cfm-edge oldcfm
hasnt "systemctl restart"; hasnt "cfm edge off"; says "older than 2026.11.20"

run "no cfm" active ON ON cfm-edge nocfm
hasnt "systemctl restart"; says "no cfm on this node"

run "DNAT state unreadable" active UNKNOWN ON cfm-edge
hasnt "systemctl restart"; hasnt "cfm edge off"; says "cannot read the DNAT state"

run "dnat off" active OFF OFF cfm-edge
has "systemctl restart cfm-edge.service"; hasnt "cfm edge off"; hasnt "cfm edge on"; order "cfm-edge -t" "systemctl restart"

run "another engine in the path" active ON ON openresty
has "systemctl restart cfm-edge.service"; hasnt "cfm edge off"; hasnt "cfm edge panel off"; hasnt "cfm edge on"; state web ON; state panel ON

run "engine ambiguous" active ON ON ambiguous
hasnt "systemctl restart"; hasnt "cfm edge off"; says "cannot tell which engine"

run "web on, panel off" active ON OFF cfm-edge
order "cfm edge off" "systemctl restart"; lastorder "cfm edge on" "systemctl restart"; hasnt "cfm edge panel"; state web ON; state panel OFF
has "cfm edge on --priority -101 --http-port 9080 --https-port 9043"   # the live priority comes back
has "https://127.0.0.1:9043/"; has "--noproxy"

run "web + panel on" active ON ON cfm-edge
order "cfm edge off" "systemctl restart"; order "cfm edge panel off" "systemctl restart"
lastorder "cfm edge on --priority" "systemctl restart"; lastorder "cfm edge panel on" "systemctl restart"; state web ON; state panel ON
order "cfm-edge -t" "cfm edge off"; order "systemctl daemon-reload" "systemctl restart"

run "panel only" active OFF ON cfm-edge
order "cfm edge panel off" "systemctl restart"; hasnt "cfm edge off"; hasnt "cfm edge on"; state panel ON; state web OFF

run "off did not take" active ON ON cfm-edge offstuck
hasnt "systemctl restart"; state web ON; state panel ON; says "did not turn off"

run "panel off did not take" active ON ON cfm-edge panelstuck
hasnt "systemctl restart"; state web ON; state panel ON; says "did not turn off"

run "off failed, state unknown" active ON ON cfm-edge offfail
hasnt "systemctl restart"; state web ON; says "did not turn off"

run "restart fails" active ON ON cfm-edge startfail
has "systemctl start cfm-edge.service"; state web OFF; state panel OFF; says "DNAT STAYS OFF"; hasnt "cfm edge on"

run "active but never serves" active ON ON cfm-edge notserving
hasnt "systemctl start"; state web OFF; state panel OFF; says "DNAT STAYS OFF"; hasnt "cfm edge on"

run "off reads OFF but its command failed" active ON OFF cfm-edge offrc
hasnt "systemctl restart"; state web ON; says "did not turn off"

run "active, answers, but not listening as cfm-edge" active ON ON cfm-edge nolisten
state web OFF; says "DNAT STAYS OFF"; hasnt "cfm edge on"

run "listening but no answer" active ON ON cfm-edge noanswer
state web OFF; says "DNAT STAYS OFF"; hasnt "cfm edge on"

run "bypass sources noted after the state" active ON ON cfm-edge bypass
order "cfm edge off" "systemctl restart"; order "cfm edge panel off" "systemctl restart"
lastorder "cfm edge on --priority -101 --http-port 9080 --https-port 9043" "systemctl restart"; lastorder "cfm edge panel on" "systemctl restart"
state web ON; state panel ON

# earth, 2026-11-22: the same yum transaction restarted the cfm daemon, whose
# firewall setup held nft, and the one `cfm edge on` failed: the web DNAT
# stayed off 53 minutes. It is retried, and the CLI's error is logged.
run "cfm edge on fails twice, then works" active ON ON cfm-edge onfails=2
state web ON; state panel ON; says "retrying in"; says "timed out (slot busy)"
if grep -qF "failed; run it by hand" <<<"$OUT"; then fail "$CURRENT: gave up although the third try worked"; fi
[ "$(grep -c '^cfm edge on --priority' <<<"$CALLS")" = 3 ] || fail "$CURRENT: want 3 tries of cfm edge on, got $(grep -c '^cfm edge on --priority' <<<"$CALLS")"
says "restarted;"

run "cfm edge on never works" active ON ON cfm-edge onfails=99
state web OFF; says "still failing after retries"; says "timed out (slot busy)"
says "ERROR: cfm-edge restarted, but the DNAT is not back"; says "Run: cfm edge on --priority -101 --http-port 9080 --https-port 9043"
if grep -qF "restarted; " <<<"$OUT"; then fail "$CURRENT: reported a plain restart with the web DNAT off"; fi

run "cfm edge off fails once, then works" active ON ON cfm-edge offfails=1
has "systemctl restart"; order "cfm edge off" "systemctl restart"; state web ON; state panel ON; says "retrying in"

# rigel, 2026-11-23 (EL9): the old cfm package's %postun marks cfm.service
# needs-restart, and systemd restarts it at the end of the transaction, after
# this script: the daemon put the panel DNAT back as it started, the off never
# read OFF, and the edge was not restarted.
run "cfm's restart still to come (needs-restart): handed to a transient unit" active ON ON cfm-edge cfmmarker
has "systemd-run --no-block --quiet --collect --unit cfm-edge-upgrade-restart-"; has " --deferred"
hasnt "cfm edge off"; hasnt "systemctl restart"; state web ON; state panel ON; says "in the background"

run "the deferred run waits for cfm's restart, then restarts the edge" active ON ON cfm-edge cfmmarker cfmrestarts deferred
has "sleep 5"; order "sleep 5" "cfm edge off"; has "systemctl restart"; state web ON; state panel ON
hasnt "systemd-run --no-block"

run "the cfm daemon between stop and start: wait until it runs" active ON ON cfm-edge cfmstate=activating
says "the cfm daemon is starting"; has "sleep 2"; order "sleep 2" "cfm edge off"; has "systemctl restart"; state web ON

run "another run holds the lock: no restart" active ON ON cfm-edge lockheld
says "another cfm-edge upgrade restart still holds"; hasnt "cfm edge off"; hasnt "systemctl restart"; state web ON

run "SIGTERM during the restart, the new edge serves: the DNAT goes back" active ON ON cfm-edge killonrestart
says "interrupted with the DNAT taken out: putting it back"; state web ON; state panel ON

run "SIGTERM during the restart, the new edge does not serve: the DNAT stays off" active ON ON cfm-edge killonrestart notserving
says "interrupted after the restart, and cfm-edge does not serve"; state web OFF; state panel OFF

run "a cfm daemon 10 s old: wait for its firewall setup" active ON ON cfm-edge cfmage=10
says "the cfm daemon is starting (or started less than 30s ago)"; has "sleep 20"; order "sleep 20" "cfm edge off"; has "systemctl restart"; state web ON

run "a cfm daemon that has run long: no wait" active ON ON cfm-edge cfmage=500
hasnt "sleep 20"; hasnt "the cfm daemon is starting"; has "systemctl restart"

run "panel off succeeds but reads ON once (the daemon put it back)" active ON ON cfm-edge panelbackn=1
says "does not read OFF"; has "systemctl restart"; state web ON; state panel ON
[ "$(grep -c '^cfm edge panel off' <<<"$CALLS")" = 2 ] || fail "$CURRENT: want 2 panel offs, got $(grep -c '^cfm edge panel off' <<<"$CALLS")"

run "a CLI error is logged by its error line, not the script's tail" active ON ON cfm-edge onfails=1
says "Error: nft: timed out (slot busy)"

echo "OK: upgrade-restart: $n scenarios (restarts only on a DNAT read OFF, never starts a stopped edge, refused config / sandbox / a config pid / old cfm / unreadable state / opt-out keep the old edge, another engine's DNAT untouched, live priority restored, a restart that does not serve keeps the DNAT off, a failing cfm edge on/off retried and a DNAT not back reported as an ERROR, an off that does not read OFF retried, a cfm daemon just started waited for, its restart still to come handed to a transient unit, one run at a time, a signal after the off puts the DNAT back only to an edge that serves)"
