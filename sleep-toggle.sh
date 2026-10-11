#!/bin/bash
# claude-sleep-toggle — flip the sleep prevention shown by the status line's
# sleep segment (github.com/takezou621/claude-statusline, same repo).
# One call starts a persistent `caffeinate -dis`, the next stops every
# caffeinate process, then clears the status line's 15s cache so the next
# render shows the change immediately. Prints the state before and after.
#
#   sleep-toggle.sh              toggle on <-> off
#   sleep-toggle.sh on           force on ("caffeinate" is an alias)
#   sleep-toggle.sh off          force off (idempotent)
#   sleep-toggle.sh status       report the current state only
#
# Out of scope, on purpose: other processes' sleep assertions (the no-sleep
# state — coreaudiod, sharingd, a running call) belong to their owning apps
# and are reported, not touched; the system sleep setting itself (sleep off
# / sleep on) needs sudo — change it with `sudo pmset -a sleep <minutes>`.
#
# Requirements: bash, pgrep, ps. License: MIT (see LICENSE).

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

# The pid of a caffeinate this toggle could have started (persistent -dis):
# a time-limited `caffeinate -i -t 300` or a display-only one started
# elsewhere must not read as "already ON" — it would expire out from under
# the user while the status line still shows caffeinate.
ours_pid() {
  local p cmd
  while read -r p; do
    cmd="$(ps -o command= -p "$p" 2>/dev/null || true)"
    case "$cmd" in
      "caffeinate -dis"|*" caffeinate -dis") echo "$p"; return 0 ;;
    esac
  done < <(pgrep -x caffeinate 2>/dev/null)
  return 1
}

usage() {
  echo "usage: sleep-toggle.sh [on|caffeinate|off|status]" >&2
  exit 2
}

help() {
  cat <<'EOF'
usage: sleep-toggle.sh [on|caffeinate|off|status]

  (none)   toggle the caffeinate-based sleep prevention on <-> off
  on       force prevention on ("caffeinate" is an alias, idempotent)
  off      force prevention off (idempotent)
  status   report the current state only
EOF
  exit 0
}

if [ $# -eq 0 ]; then
  mode="toggle"
elif [ $# -eq 1 ]; then
  case "$1" in
    on|caffeinate) mode="on" ;;
    off)           mode="off" ;;
    status)        mode="status" ;;
    -h|--help)     help ;;
    *)             usage ;;
  esac
else
  usage
fi

cache="${TMPDIR:-/tmp}/claude-statusline-sleep-${UID}.txt"
before="$(sleep_state)"

if [ "$mode" = "status" ]; then
  echo "status line state: $before"
  exit 0
fi

# Decide the action from the requested mode, not from a second aliveness
# check: a caffeinate appearing or vanishing between the two checks must not
# make a forced "on" kill or a forced "off" start the opposite of what was
# asked. Only the modeless toggle derives its direction from the live state.
case "$mode" in
  on)
    if ours_pid >/dev/null; then
      echo "sleep prevention: already ON (caffeinate -dis running, pid $(ours_pid))"
      echo "status line state: $before"
      exit 0
    fi
    action="start" ;;
  off)
    if ! caffeinate_alive; then
      echo "sleep prevention: already OFF (no caffeinate running)"
      echo "status line state: $before"
      exit 0
    fi
    action="stop" ;;
  *)
    if caffeinate_alive; then action="stop"; else action="start"; fi ;;
esac

if [ "$action" = "stop" ]; then
  # Intentionally every caffeinate: the toggle flips the caffeinate-based
  # prevention as a whole, and any command-line caffeinate is a user-side
  # prevention — a stale one left behind would make the next "on" call
  # read as a no-op. The count is guarded: if the last caffeinate exits
  # right here, pgrep's non-zero exit must not abort the script (pipefail).
  n_killed="0"
  if pgrep -x caffeinate >/dev/null 2>&1; then
    n_killed="$(pgrep -x caffeinate 2>/dev/null | wc -l | tr -d ' ')"
  fi
  pkill -x caffeinate 2>/dev/null || true
else
  nohup caffeinate -dis >/dev/null 2>&1 &
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

# Report the action only after verifying it took effect, and exit non-zero
# when the requested state was not reached so callers can tell.
failed=0
if [ "$action" = "stop" ]; then
  if caffeinate_alive; then
    failed=1
    action="OFF FAILED (a caffeinate process is still running, pid $(pgrep -x caffeinate 2>/dev/null | head -1))"
  else
    action="OFF (${n_killed} caffeinate process(es) stopped)"
  fi
else
  if ours_pid >/dev/null; then
    action="ON (caffeinate -dis running, pid $(ours_pid))"
  else
    failed=1
    action="ON FAILED (caffeinate did not stay up)"
  fi
fi

echo "sleep prevention: $action"
echo "status line state: $before -> $after"
if [ "$failed" = "1" ]; then
  exit 1
fi
exit 0
