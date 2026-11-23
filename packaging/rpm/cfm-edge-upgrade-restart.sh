#!/bin/sh
# cfm-edge-upgrade-restart.sh — after an rpm upgrade, restart a RUNNING
# cfm-edge so the new binary and unit apply, without refusing connections.
#
# Installed as /usr/lib/cfm-edge/upgrade-restart.sh; the spec's posttrans
# runs it on every install/upgrade. It never fails the transaction (exit 0
# always) and never starts an edge that was not running.
#
# Why not restart in postun: a plain restart of an edge in the path (CFM's
# web/panel DNAT on) closes its ports at once and drains for up to
# TimeoutStopSec; every new connection meanwhile is refused (virgo,
# 2026-11-20: 30 s). With the DNAT off the edge gets no traffic, so the
# restart costs nothing (the sites are served by the origin meanwhile, with
# no WAF, for as long as the old workers drain). So:
#
#   cfm-edge not running             -> nothing
#   /etc/cfm-edge/no-upgrade-restart -> nothing (the operator restarts it)
#   new binary refuses the config    -> nothing: the old edge keeps serving
#   live config sets its own pid     -> nothing (the start would fail: the
#                                       pid path is the package's)
#     (tested inside the new unit's sandbox when systemd-run can, so a
#     sandbox change that would fail the restart is caught here too)
#   DNAT state not readable          -> nothing, warning (no blind restart)
#   another engine is in the path    -> plain restart (cfm-edge takes no traffic)
#   cfm-edge is in the path, DNAT on -> cfm edge off (checked OFF), restart,
#                                       wait until it serves, cfm edge on with
#                                       the priority and ports that were live
#   DNAT off                         -> plain restart
#   restart failed / never serves    -> the DNAT STAYS off (the origin serves,
#                                       no WAF), loud warning
#
# Everything goes to stdout (yum shows it) and the journal
# (journalctl -t cfm-edge-upgrade).
#
# Appended, not prepended: a minimal scriptlet PATH still finds them, and a
# caller's PATH (the test's stubs) wins.
PATH="${PATH:+$PATH:}/usr/sbin:/usr/bin:/sbin:/bin"
BIN="${CFM_EDGE_BIN:-/usr/sbin/cfm-edge}"
CFM="${CFM_BIN:-cfm}"
OPTOUT="${CFM_EDGE_OPTOUT:-/etc/cfm-edge/no-upgrade-restart}"
WAIT="${CFM_EDGE_UPGRADE_WAIT:-30}"   # seconds to wait for the new edge to serve
# Waits between tries of a failed `cfm edge on/off` (seconds). The same yum
# transaction often upgrades cfm too, and its post-install restarts the cfm daemon:
# on EL8 the daemon's firewall setup then holds nft for 30-55 s, and a
# one-shot `cfm edge on` in that window fails (earth, 2026-11-22: one try,
# the web DNAT stayed off for 53 minutes). 10+20+30+60 s covers it.
RETRY_DELAYS="${CFM_EDGE_RETRY_DELAYS:-10 20 30 60}"
# The cfm daemon must have run this long before the DNAT is touched: a daemon
# that just started is still setting up the firewall (EnsureBase, the ports
# policy: 10-20 s on EL8).
SETTLE="${CFM_EDGE_CFM_SETTLE:-30}"
DEFER_MAX="${CFM_EDGE_DEFER_MAX:-600}"   # longest wait for cfm's restart / start
LOCK="${CFM_EDGE_LOCK:-/run/cfm-edge-upgrade.lock}"
RUNDIR="${CFM_EDGE_RUNDIR:-/run/cfm-edge}"   # the compiled pid dir (tmpfiles.d)
UNIT=cfm-edge.service

say() {
    echo "cfm-edge upgrade: $*"
    logger -t cfm-edge-upgrade -- "$*" 2>/dev/null || :
}
# A hung CLI (an nft lock) must not hang the yum transaction.
cfm_run() {
    if command -v timeout >/dev/null 2>&1; then timeout 60 "$CFM" "$@"; else "$CFM" "$@"; fi
}
# why OUTPUT RC: the CLI's error lines, else its last two (an nft failure
# prints the refused script after the error: its tail is `} } );`, virgo
# 2026-11-23). Not CFM's structured log lines that carry an empty error
# (`[firewall] ... status=ok error=""`): "error" matched them, and two of
# them hid the real `dnat cpanel off failed: ...` line (virgo, 2026-11-23).
# RC 124 is cfm_run's timeout, which leaves no error line of its own.
why() {
    e="$(printf '%s\n' "$1" | grep -v 'error=""')"
    w="$(printf '%s\n' "$e" | grep -iE 'error|fail|refus|timed out|denied|busy' | head -2 | tr '\n' ' ')"
    if [ "${2:-}" = 124 ]; then
        # What it printed before the hang is the clue to why it hung.
        printf 'no answer within 60s, stopped by the timeout%s' "${w:+ (before it: $w)}"
        return
    fi
    [ -n "$w" ] || w="$(printf '%s\n' "$e" | tail -2 | tr '\n' ' ')"
    printf '%s' "$w"
}
# cfm_retry ARGS...: `cfm ARGS`, tried again after each of RETRY_DELAYS while
# it fails. Every failure is logged with the CLI's own error: it used to go
# to /dev/null, so a failed `cfm edge on` said nothing about why.
cfm_retry() {
    out="$(cfm_run "$@" 2>&1)" && return 0
    rc=$?
    for d in $RETRY_DELAYS; do
        say "cfm $* failed ($(why "$out" "$rc")); retrying in ${d}s (the cfm daemon may still be starting)"
        sleep "$d"
        out="$(cfm_run "$@" 2>&1)" && return 0
        rc=$?
    done
    say "WARNING: cfm $* still failing after retries: $(why "$out" "$rc")"
    return 1
}

# The cfm daemon restarting in the same yum transaction. cfm's rpm restarts
# it in its %post (before any %posttrans, so before this script, whatever
# order rpm installs the two in), and its old package's %postun asks again:
#   - EL8 (systemd 239): `systemctl try-restart`, right there, also before us;
#   - EL9/EL10: systemd-update-helper marks the unit (Markers=needs-restart)
#     and systemd restarts it at the END of the transaction, after every
#     %posttrans, so after (or during) this script.
# rigel, 2026-11-23 (EL9): that second restart came while `cfm edge panel
# off` ran; the daemon put the panel DNAT back as it started, the off never
# read OFF, and the edge was not restarted.
cfm_pid() { systemctl show cfm.service -p MainPID --value 2>/dev/null; }
# cfm_pending: a restart of the cfm daemon is still to come after this
# transaction (EL9+: the unit carries the needs-restart marker).
cfm_pending() {
    systemctl show cfm.service -p Markers --value 2>/dev/null | grep -qw needs-restart
}
# cfm_age: seconds the cfm daemon has run (a large number when it does not).
cfm_age() {
    pid="$(cfm_pid)"
    case "$pid" in "" | 0) echo 999999; return ;; esac
    a="$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ')"
    echo "${a:-999999}"
}
# settle: wait while the cfm daemon is starting, stopping, or has run less
# than SETTLE seconds (it is setting up the firewall: EnsureBase, the ports
# policy), at most DEFER_MAX. A daemon that is not running (and not about to)
# is not waited for.
settle() {
    i=0
    said=""
    while [ "$i" -lt "$DEFER_MAX" ]; do
        case "$(systemctl is-active cfm.service 2>/dev/null)" in
            activating | deactivating | reloading) w=2 ;;
            active)
                a="$(cfm_age)"
                [ "$a" -lt "$SETTLE" ] 2>/dev/null || return 0
                w=$((SETTLE - a)) ;;
            *) return 0 ;;
        esac
        [ -n "$said" ] || say "the cfm daemon is starting (or started less than ${SETTLE}s ago): waiting for its firewall setup"
        said=1
        sleep "$w"
        i=$((i + w))
    done
    say "WARNING: the cfm daemon did not settle within ${DEFER_MAX}s; going on"
}

systemctl is-active --quiet "$UNIT" 2>/dev/null || exit 0

if [ -e "$OPTOUT" ]; then
    say "$OPTOUT exists: not restarting; restart cfm-edge yourself (cfm edge off first if it is in the path)"
    exit 0
fi

# cfm's restart is still to come, after this transaction: waiting here would
# wait for something that runs after us. Hand the restart to a transient
# unit, which runs after the transaction, once the daemon has restarted.
if [ "${1:-}" != --deferred ] && cfm_pending; then
    say "the cfm daemon is to be restarted at the end of this yum run: cfm-edge will be restarted after it, in the background (journalctl -t cfm-edge-upgrade)"
    if command -v systemd-run >/dev/null 2>&1 \
        && systemd-run --no-block --quiet --collect --unit "cfm-edge-upgrade-restart-$$" "$0" --deferred >/dev/null 2>&1; then
        exit 0
    fi
    setsid nohup "$0" --deferred >/dev/null 2>&1 </dev/null &
    exit 0
fi

# One run at a time (a deferred run and a second transaction, or a run by
# hand): two would turn the DNAT off and on across each other's restart.
if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK"
    if ! flock -w "$DEFER_MAX" 9; then
        say "WARNING: another cfm-edge upgrade restart still holds $LOCK; NOT restarting. Restart cfm-edge out of the path yourself."
        exit 0
    fi
fi
if [ "${1:-}" = --deferred ]; then
    i=0
    while cfm_pending && [ "$i" -lt "$DEFER_MAX" ]; do sleep 5; i=$((i + 5)); done
    if cfm_pending; then
        say "WARNING: the cfm daemon was not restarted within ${DEFER_MAX}s; going on with it as it is"
    fi
fi
settle

systemctl daemon-reload 2>/dev/null || :

# The pid path is the package's (its compiled default, in the unit's
# RuntimeDirectory; /run itself is read-only in the sandbox). A live config
# that still sets its own pid (a cfm without PR #1755, or a hand-written
# one) fails the start with "Read-only file system". Checked before the
# config test, which would fail on it with a less useful message. The regex
# wants a value after "pid", never "=": inline Lua says `pid = ...`.
# -T (like -t) opens the pid file, so its dir must exist. The rpm's %post
# makes it (tmpfiles.d, as every boot does); this covers a run by hand, or a
# %post whose systemd-tmpfiles failed (its errors are not fatal there).
[ -d "$RUNDIR" ] || mkdir -m 0755 "$RUNDIR" 2>/dev/null || :
if "$BIN" -T 2>/dev/null | grep -qE '^[[:space:]]*pid[[:space:]]+[^=[:space:]]'; then
    say "WARNING: the live config sets its own pid; this cfm-edge owns that path (/run/cfm-edge/), and the start would fail. NOT restarting, the running edge keeps serving. Update cfm (its config sets no pid since PR #1755) or drop the pid line, then restart cfm-edge out of the path."
    exit 0
fi

# The config test, inside the new unit's sandbox where systemd-run can apply
# its properties (each one is tried alone first: EL8's systemd refuses some
# transiently that its unit files accept).
config_test() {
    # systemd-run usable at all (a bus, a running systemd)? Then any failure
    # of the sandboxed -t is the config's, never systemd-run's.
    if command -v systemd-run >/dev/null 2>&1 && systemd-run --wait --quiet --pipe /bin/true >/dev/null 2>&1; then
        props="$(mktemp)"
        systemctl cat "$UNIT" 2>/dev/null | grep -E '^(Protect[A-Za-z]*|Private[A-Za-z]*|ReadWritePaths|ReadOnlyPaths|InaccessiblePaths|NoNewPrivileges|CapabilityBoundingSet|RestrictAddressFamilies|RestrictNamespaces|RestrictRealtime|RestrictSUIDSGID|LockPersonality|SystemCall[A-Za-z]*|MemoryDenyWriteExecute|UMask|LimitNOFILE)=' >"$props"
        set --
        while IFS= read -r kv; do
            if systemd-run --wait --quiet --pipe -p "$kv" /bin/true >/dev/null 2>&1; then
                set -- "$@" -p "$kv"
            fi
        done <"$props"
        rm -f "$props"
        # -t opens the pid file (create-or-open): in the unit, RuntimeDirectory
        # makes its dir writable; this transient run has no RuntimeDirectory
        # (one of its own would remove the live pid dir at exit), so it gets
        # the dir as a write path instead.
        if [ -d "$RUNDIR" ]; then set -- "$@" -p "ReadWritePaths=$RUNDIR"; fi
        if out="$(systemd-run --wait --quiet --pipe "$@" "$BIN" -t -q 2>&1)"; then
            # Does the sandbox still keep /run read-only? systemd 252/257 left
            # it rw under ProtectSystem=strict with ProtectKernelTunables= /
            # ProtectControlGroups= until the unit listed ReadOnlyPaths=/run;
            # a later systemd or directive could undo it without failing
            # anything. A missing hardening, not a broken config: warn, and
            # restart all the same.
            probe="/run/.cfm-edge-ro-probe-$$"
            if systemd-run --wait --quiet --pipe "$@" /bin/sh -c "touch '$probe'" >/dev/null 2>&1; then
                rm -f "$probe"
                say "WARNING: /run is writable inside cfm-edge's sandbox on this systemd (ReadOnlyPaths=/run does not hold): its master could write a unit into /run/systemd/system. Restarting anyway; report it."
            fi
            return 0
        fi
        printf '%s\n' "$out" | tail -5 | sed 's/^/  /'
        return 1
    fi
    "$BIN" -t -q >/dev/null 2>&1 && return 0
    "$BIN" -t 2>&1 | tail -5 | sed 's/^/  /'
    return 1
}
if ! config_test; then
    say "WARNING: the new cfm-edge refuses the live config (cfm-edge -t, in the unit's sandbox); NOT restarting, the running edge keeps serving. Fix it, then restart it out of the path."
    exit 0
fi

# Is cfm-edge in the path? Only CFM knows (cfm edge, cfm >= 2026.11.20).
if ! command -v "$CFM" >/dev/null 2>&1; then
    say "WARNING: no cfm on this node: cannot tell whether the edge is in the path; NOT restarting. Restart cfm-edge yourself."
    exit 0
fi
st="$(cfm_run edge 2>&1)"
if printf '%s\n' "$st" | grep -q 'unknown command: edge'; then
    say "WARNING: this cfm has no \`cfm edge\` (older than 2026.11.20): NOT restarting. Restart cfm-edge out of the path yourself (cfm dnat off, restart, cfm dnat on)."
    exit 0
fi
web_line="$(printf '%s\n' "$st" | grep -m1 'Web DNAT:')"
panel_line="$(printf '%s\n' "$st" | grep -m1 'Panel DNAT:')"
engine_line="$(printf '%s\n' "$st" | grep -m1 'Engine:')"
# The state word is followed by a space, the end of the line, or ";" when a
# bypass note follows it directly ("Panel DNAT:  OFF; 1 bypass source(s)":
# read as unknown, it stopped orion's upgrade on 2026-11-21, safely).
state_of() { # ON -> 1, OFF -> 0, anything else (UNKNOWN, missing) -> x
    if printf '%s\n' "$1" | grep -qE "^ *$2: +ON( |;|\$)"; then echo 1
    elif printf '%s\n' "$1" | grep -qE "^ *$2: +OFF( |;|\$)"; then echo 0
    else echo x; fi
}
web_on="$(state_of "$web_line" 'Web DNAT')"
panel_on="$(state_of "$panel_line" 'Panel DNAT')"
if [ "$web_on" = x ] || [ "$panel_on" = x ]; then
    say "WARNING: cannot read the DNAT state from \`cfm edge\` (${web_line:-no web line}; ${panel_line:-no panel line}); NOT restarting. Restart cfm-edge out of the path yourself."
    exit 0
fi

if [ "$web_on" = 0 ] && [ "$panel_on" = 0 ]; then
    say "DNAT is off (the edge is not in the path): restarting cfm-edge"
    systemctl restart "$UNIT" || say "WARNING: systemctl restart cfm-edge failed (the DNAT is off: the origin serves)"
    exit 0
fi

case "$engine_line" in
    *"Engine:"*" cfm-edge (running)"*) ;;
    *"Engine:"*" openresty (running)"*|*"Engine:"*" angie (running)"*)
        # The DNAT is another engine's: cfm-edge takes no traffic here.
        say "the edge in the path is another engine (${engine_line#*Engine: }); restarting cfm-edge without touching the DNAT"
        systemctl restart "$UNIT" || say "WARNING: systemctl restart cfm-edge failed (it is not the edge in the path)"
        exit 0 ;;
    *)
        say "WARNING: cannot tell which engine is in the path (${engine_line:-no engine line}); NOT restarting. Restart cfm-edge out of the path yourself."
        exit 0 ;;
esac

# What was live, to put it back exactly (the priority matters: an Imunify
# node runs -101, ahead of WebShield, and may not have it in cfm.conf).
web_args=""
if [ "$web_on" = 1 ]; then
    prio="$(printf '%s\n' "$web_line" | sed -n 's/.*priority \(-\{0,1\}[0-9][0-9]*\).*/\1/p')"
    hport="$(printf '%s\n' "$web_line" | sed -n 's/.*tcp\/80 -> :\([0-9][0-9]*\).*/\1/p')"
    sport="$(printf '%s\n' "$web_line" | sed -n 's/.*443 -> :\([0-9][0-9]*\).*/\1/p')"
    if [ -z "$prio" ] || [ -z "$hport" ] || [ -z "$sport" ]; then
        say "WARNING: cannot read the live web DNAT priority/ports ($web_line); NOT restarting. Restart cfm-edge out of the path yourself."
        exit 0
    fi
    web_args="--priority $prio --http-port $hport --https-port $sport"
fi
port="${sport:-9043}"

back_in() {
    rc=0
    if [ "$web_on" = 1 ]; then
        # shellcheck disable=SC2086  # web_args is numbers and flags only
        cfm_retry edge on $web_args || { say "WARNING: cfm edge on $web_args failed; run it by hand"; rc=1; }
    fi
    if [ "$panel_on" = 1 ]; then
        cfm_retry edge panel on || { say "WARNING: cfm edge panel on failed; run it by hand"; rc=1; }
    fi
    return "$rc"
}

say "cfm-edge is in the path (web DNAT $web_on, panel DNAT $panel_on): taking it out, restarting, putting it back"
# Off, then read back OFF for both. An off that succeeded but does not read
# OFF (the daemon putting the DNAT back as it starts) is tried again; an off
# that keeps failing was already retried by cfm_retry.
reads_off() {
    [ "$(state_of "$(printf '%s\n' "$st" | grep -m1 'Web DNAT:')" 'Web DNAT')" = 0 ] \
        && [ "$(state_of "$(printf '%s\n' "$st" | grep -m1 'Panel DNAT:')" 'Panel DNAT')" = 0 ]
}
take_out() {
    off_rc=0
    if [ "$web_on" = 1 ]; then cfm_retry edge off || off_rc=1; fi
    if [ "$panel_on" = 1 ]; then cfm_retry edge panel off || off_rc=1; fi
    st="$(cfm_run edge 2>&1)"
}
# From the first off on, a signal (the transient unit stopped, a reboot after
# yum returned) must not leave the edge out of the path: `cfm edge off`
# persists OFF, so nothing else would put it back.
interrupted() {
    trap '' TERM INT HUP
    # Past the restart, an edge that does not serve must not be put back in
    # the path (that would take the sites down): the DNAT stays off, as below.
    if command -v healthy >/dev/null 2>&1 && ! healthy; then
        say "ERROR: interrupted after the restart, and cfm-edge does not serve: the DNAT STAYS OFF (the origin serves, without WAF). Fix the edge, then: cfm edge on${web_args:+ $web_args}"
        exit 0
    fi
    say "interrupted with the DNAT taken out: putting it back"
    back_in
    exit 0
}
trap interrupted TERM INT HUP
take_out
if [ "$off_rc" = 0 ] && ! reads_off; then
    for d in $RETRY_DELAYS; do
        say "the off succeeded but the DNAT does not read OFF ($(printf '%s\n' "$st" | grep -E 'Web DNAT|Panel DNAT' | sed 's/  */ /g' | tr '\n' ';')); again in ${d}s"
        sleep "$d"
        take_out
        { [ "$off_rc" = 0 ] && ! reads_off; } || break
    done
fi
# Restart only on a positive OFF for both: never while it may take traffic.
if [ "$off_rc" != 0 ] || ! reads_off; then
    if back_in; then put="put back as it was"; else put="putting it back FAILED (warnings above)"; fi
    trap - TERM INT HUP
    say "WARNING: the DNAT did not turn off ($(printf '%s\n' "$st" | grep -E 'Web DNAT|Panel DNAT' | sed 's/  */ /g' | tr '\n' ';')); NOT restarting, $put. Restart cfm-edge out of the path yourself."
    exit 0
fi

healthy() {
    systemctl is-active --quiet "$UNIT" || return 1
    ss -ltnp 2>/dev/null | grep -E ":$port\\b" | grep -q cfm-edge || return 1
    command -v curl >/dev/null 2>&1 || return 0   # no curl: the listen check is all we have
    code="$(curl --noproxy '*' -sk -o /dev/null -w '%{http_code}' --max-time 5 "https://127.0.0.1:$port/" 2>/dev/null)"
    [ -n "$code" ] && [ "$code" != 000 ]
}
wait_healthy() {
    i=0
    while [ "$i" -lt "$WAIT" ]; do
        healthy && return 0
        sleep 1
        i=$((i + 1))
    done
    return 1
}

systemctl restart "$UNIT" >/dev/null 2>&1 || :
if ! wait_healthy; then
    if ! systemctl is-active --quiet "$UNIT"; then
        say "WARNING: cfm-edge did not come up after the restart; one more start"
        systemctl start "$UNIT" >/dev/null 2>&1 || :
    fi
    if ! wait_healthy; then
        trap - TERM INT HUP
        say "ERROR: cfm-edge does not serve after the upgrade. The DNAT STAYS OFF: the sites are served by the origin directly, without WAF/challenge. See journalctl -u cfm-edge and /var/log/cfm-edge/error.log, then: systemctl restart cfm-edge && cfm edge on${web_args:+ $web_args}$( [ "$panel_on" = 1 ] && echo ' && cfm edge panel on')"
        exit 0
    fi
fi

back_in
trap - TERM INT HUP
# Put back means read back ON: a DNAT that was on and reads anything else now
# is an edge out of the path (no WAF), which must not end in "restarted".
st="$(cfm_run edge 2>&1)"
now="$(printf '%s\n' "$st" | grep -E 'Web DNAT|Panel DNAT' | sed 's/  */ /g' | tr '\n' ';')"
lost=""
if [ "$web_on" = 1 ] && [ "$(state_of "$(printf '%s\n' "$st" | grep -m1 'Web DNAT:')" 'Web DNAT')" != 1 ]; then
    lost="cfm edge on${web_args:+ $web_args}"
fi
if [ "$panel_on" = 1 ] && [ "$(state_of "$(printf '%s\n' "$st" | grep -m1 'Panel DNAT:')" 'Panel DNAT')" != 1 ]; then
    lost="${lost:+$lost && }cfm edge panel on"
fi
if [ -n "$lost" ]; then
    say "ERROR: cfm-edge restarted, but the DNAT is not back ($now): the sites are served by the origin directly, without WAF/challenge. Run: $lost"
    exit 0
fi
say "restarted; $now"
exit 0
