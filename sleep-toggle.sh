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

cache="${TMPDIR:-/tmp}/claude-statusline-sleep-${UID}.txt"
before="$(sleep_state)"

if pgrep -x caffeinate >/dev/null 2>&1; then
  pkill -x caffeinate 2>/dev/null || true
  action="OFF (caffeinate stopped)"
else
  nohup caffeinate -dis >/dev/null 2>&1 &
  action="ON (caffeinate -dis, pid $!)"
fi

# The status line caches the state for 15s — drop it so the very next render
# already shows the flipped state.
rm -f "$cache" 2>/dev/null || true

# A beat for caffeinate to register its assertions before re-reporting.
sleep 1
after="$(sleep_state)"

echo "sleep prevention: $action"
echo "status line state: $before -> $after"
