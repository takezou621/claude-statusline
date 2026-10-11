#!/bin/bash
# claude-sleep-toggle — flip the sleep prevention shown by the status line's
# sleep segment (github.com/takezou621/claude-statusline, same repo).
# One call starts a persistent `caffeinate -dis`, the next stops every
# caffeinate process, then clears the status line's 15s cache so the next
# render shows the change immediately. Prints the state before and after.
#
# Out of scope, on purpose: other processes' sleep assertions (the no-sleep
# state — coreaudiod, sharingd, a running call) belong to their owning apps
# and are reported, not touched; the system sleep setting itself (sleep off
# / sleep on) needs sudo — change it with `sudo pmset -a sleep <minutes>`.
#
# Requirements: bash, pgrep. License: MIT (see LICENSE).

set -euo pipefail

# Mirror statusline.sh's state probe: any caffeinate process wins; other
# processes' PreventSystemSleep/PreventUserIdleSystemSleep detail rows count
# except powerd's always-present "Prevent sleep while display is on" one;
# every "sleep N" line of pmset -g being 0 reads sleep off.
sleep_state() {
  if pgrep -x caffeinate >/dev/null 2>&1; then
    echo "caffeinate"; return
  fi
  if command -v pmset >/dev/null 2>&1; then
    local asserts vals
    asserts="$(pmset -g assertions 2>/dev/null || true)"
    if grep -E "^[[:space:]]+pid [^(]+\([^)]+\):.*Prevent(UserIdle)?SystemSleep" <<< "$asserts" \
        | grep -v "display is on" | grep -q .; then
      echo "no-sleep"; return
    fi
    vals="$(pmset -g 2>/dev/null \
      | grep -E "^[[:space:]]*sleep[[:space:]]+[0-9]+" \
      | sed -E "s/^[[:space:]]*sleep[[:space:]]+//; s/[^0-9].*$//" || true)"
    if [ -n "$vals" ] && ! printf '%s\n' "$vals" | grep -qv "^0$"; then
      echo "sleep off"; return
    fi
  fi
  echo "sleep on"
}

caffeinate_alive() { pgrep -x caffeinate >/dev/null 2>&1; }

cache="${TMPDIR:-/tmp}/claude-statusline-sleep-${UID}.txt"
before="$(sleep_state)"

# Optional argument: "on"/"caffeinate" forces the prevention on, "off" forces
# it off (both idempotent), "status" only reports. No argument toggles.
mode="toggle"
case "${1:-}" in
  "")              mode="toggle" ;;
  on|caffeinate)   mode="on" ;;
  off)             mode="off" ;;
  status)          mode="status" ;;
  *) echo "usage: sleep-toggle.sh [on|caffeinate|off|status]" >&2; exit 2 ;;
esac

if [ "$mode" = "status" ]; then
  echo "status line state: $before"
  exit 0
fi
if [ "$mode" = "on" ] && caffeinate_alive; then
  echo "sleep prevention: already ON (caffeinate -dis running, pid $(pgrep -x caffeinate 2>/dev/null | head -1))"
  echo "status line state: $before"
  exit 0
fi
if [ "$mode" = "off" ] && ! caffeinate_alive; then
  echo "sleep prevention: already OFF (no caffeinate running)"
  echo "status line state: $before"
  exit 0
fi

if caffeinate_alive; then
  # Intentionally every caffeinate: the toggle flips the caffeinate-based
  # prevention as a whole, and any command-line caffeinate is a user-side
  # prevention — a stale one left behind would make the next "ON" call
  # read as a no-op.
  n_killed="$(pgrep -x caffeinate 2>/dev/null | wc -l | tr -d ' ')"
  pkill -x caffeinate 2>/dev/null || true
  wanted="off"
else
  nohup caffeinate -dis >/dev/null 2>&1 &
  wanted="on"
fi

# The status line caches the state for 15s. Drop the cache twice: now, and
# again after the settle wait — a probe already in flight when the toggle
# ran would otherwise write its pre-toggle result back over the cleared
# cache and the next render would stay stale.
rm -f "$cache" 2>/dev/null || true

# A beat for the assertions to move (caffeinate registers or coreaudiod
# releases them) before verifying and re-reporting.
sleep 1
rm -f "$cache" 2>/dev/null || true
after="$(sleep_state)"

# Report the action only after verifying it took effect: a pkill that
# failed (e.g. a caffeinate owned by another user) and a caffeinate that
# died on startup must not print a confident OFF/ON.
if [ "$wanted" = "off" ]; then
  if caffeinate_alive; then
    action="OFF FAILED (a caffeinate process is still running)"
  else
    action="OFF (${n_killed} caffeinate process(es) stopped)"
  fi
else
  if caffeinate_alive; then
    action="ON (caffeinate -dis running, pid $(pgrep -x caffeinate 2>/dev/null | head -1))"
  else
    action="ON FAILED (caffeinate did not stay up)"
  fi
fi

echo "sleep prevention: $action"
echo "status line state: $before -> $after"
