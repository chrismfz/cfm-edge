#!/bin/sh
# cfm-edge-upgrade-restart.sh — after an rpm upgrade, restart a RUNNING
# cfm-edge so the new binary and unit apply, without refusing connections.
#
# Installed as /usr/lib/cfm-edge/upgrade-restart.sh; the spec's %posttrans
# runs it on every install/upgrade. It never fails the transaction (exit 0
# always) and never starts an edge that was not running.
#
# Why not %systemd_postun_with_restart: a plain restart of an edge in the
# path (CFM's web/panel DNAT on) closes its ports at once and drains for up
# to TimeoutStopSec; every new connection meanwhile is refused (virgo,
# 2026-11-20: 30 s). With the DNAT off the edge gets no traffic, so the
# restart costs nothing. So:
#
#   cfm-edge not running             -> nothing
#   /etc/cfm-edge/no-upgrade-restart -> nothing (the operator restarts it)
#   new binary refuses the config    -> nothing: the old edge keeps serving
#   DNAT off                         -> restart
#   DNAT on                          -> cfm edge off, restart, check, cfm edge on
#   restart failed                   -> one more start; still down: the DNAT
#                                       STAYS off (the origin serves, no WAF),
#                                       loud warning
#   cfm without `cfm edge` (old cfm) -> nothing, warning (no blind restart)
#
# Everything it does goes to stdout (shown by yum) and to the journal
# (logger -t cfm-edge-upgrade).
# Appended, not prepended: a minimal scriptlet PATH still finds them, and a
# caller's PATH (the test's stubs) wins.
PATH="${PATH:+$PATH:}/usr/sbin:/usr/bin:/sbin:/bin"
BIN="${CFM_EDGE_BIN:-/usr/sbin/cfm-edge}"
OPTOUT="${CFM_EDGE_OPTOUT:-/etc/cfm-edge/no-upgrade-restart}"
UNIT=cfm-edge.service

say() {
    echo "cfm-edge upgrade: $*"
    logger -t cfm-edge-upgrade -- "$*" 2>/dev/null || :
}

systemctl is-active --quiet "$UNIT" 2>/dev/null || exit 0

if [ -e "$OPTOUT" ]; then
    say "$OPTOUT exists: not restarting; restart cfm-edge yourself (cfm edge off first if it is in the path)"
    exit 0
fi

if ! "$BIN" -t -q >/dev/null 2>&1; then
    say "WARNING: the new cfm-edge refuses the live config (cfm-edge -t); NOT restarting, the running edge keeps serving. Fix the config, then restart it out of the path."
    "$BIN" -t 2>&1 | tail -5 | sed 's/^/  /'
    exit 0
fi

systemctl daemon-reload 2>/dev/null || :

# Is this edge in the path? Only CFM knows (cfm edge, cfm >= 2026.11.20).
web_on=0
panel_on=0
if command -v cfm >/dev/null 2>&1 && st="$(cfm edge 2>/dev/null)" && printf '%s\n' "$st" | grep -q 'Web DNAT:'; then
    printf '%s\n' "$st" | grep -q 'Web DNAT: *ON' && web_on=1
    printf '%s\n' "$st" | grep -q 'Panel DNAT: *ON' && panel_on=1
else
    say "WARNING: cannot read the DNAT state (no \`cfm edge\`: cfm missing or older than 2026.11.20); NOT restarting. Restart cfm-edge out of the path yourself (cfm dnat off, restart, cfm dnat on)."
    exit 0
fi

healthy() {
    systemctl is-active --quiet "$UNIT" || return 1
    ss -ltnp 2>/dev/null | grep -E ':9043\b' | grep -q cfm-edge || return 1
    code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 https://127.0.0.1:9043/ 2>/dev/null)"
    [ -n "$code" ] && [ "$code" != 000 ]
}

if [ "$web_on" = 0 ] && [ "$panel_on" = 0 ]; then
    say "DNAT is off (the edge is not in the path): restarting cfm-edge"
    systemctl restart "$UNIT" || say "WARNING: systemctl restart cfm-edge failed (DNAT is off: the origin serves)"
    exit 0
fi

say "the edge is in the path (web DNAT $web_on, panel DNAT $panel_on): taking it out, restarting, putting it back"
[ "$web_on" = 1 ] && { cfm edge off >/dev/null 2>&1 || :; }
[ "$panel_on" = 1 ] && { cfm edge panel off >/dev/null 2>&1 || :; }
st="$(cfm edge 2>/dev/null)"
if printf '%s\n' "$st" | grep -qE 'Web DNAT: *ON|Panel DNAT: *ON'; then
    # Never restart an edge that still takes traffic.
    [ "$web_on" = 1 ] && { cfm edge on >/dev/null 2>&1 || :; }
    [ "$panel_on" = 1 ] && { cfm edge panel on >/dev/null 2>&1 || :; }
    say "WARNING: the DNAT did not turn off; NOT restarting (put back as it was). Restart cfm-edge out of the path yourself."
    exit 0
fi

systemctl restart "$UNIT" >/dev/null 2>&1 || :
sleep 2
if ! healthy; then
    say "WARNING: cfm-edge is not healthy after the restart; one more start"
    systemctl start "$UNIT" >/dev/null 2>&1 || :
    sleep 3
fi
if ! healthy; then
    say "ERROR: cfm-edge does not serve after the upgrade. The DNAT STAYS OFF: the sites are served by the origin directly, without WAF/challenge. See: journalctl -u cfm-edge; /var/log/cfm-edge/error.log. Then: systemctl restart cfm-edge && cfm edge on$( [ "$panel_on" = 1 ] && echo ' && cfm edge panel on')"
    exit 0
fi

[ "$web_on" = 1 ] && { cfm edge on >/dev/null 2>&1 || say "WARNING: cfm edge on failed; run it by hand"; }
[ "$panel_on" = 1 ] && { cfm edge panel on >/dev/null 2>&1 || say "WARNING: cfm edge panel on failed; run it by hand"; }
say "restarted; the edge is back in the path ($(cfm edge 2>/dev/null | grep -E 'Web DNAT|Panel DNAT' | sed 's/  */ /g' | tr '\n' ';'))"
exit 0
