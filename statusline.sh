#!/bin/bash
# claude-statusline — a fast, dependency-light status line for Claude Code.
# https://github.com/takezou621/claude-statusline
#
# Protocol: Claude Code pipes one JSON object on stdin
# (model, workspace, context_window, rate_limits — see README for the fields used).
# Fast path: python3 for JSON + local git (--no-optional-locks).
# GLM (Z.AI) quota: when the session routes through a glm endpoint
# (ANTHROPIC_BASE_URL contains z.ai / bigmodel.cn) Claude Code sends no
# rate_limits, so the script fetches GET <host>/api/monitor/usage/quota/limit
# with ANTHROPIC_AUTH_TOKEN (raw, no Bearer) — cached for 2 minutes, 3s
# timeout, so renders stay fast and the API is hit at most once per TTL.
# jev status: when the jev-mcp judgment log is present (~/.jev/logs,
# github.com/takezou621/jev-mcp), the jev segment mirrors today's real
# judgments and the latest one's action, read from the log (no network).
# Degrades gracefully: missing git/python3/network/malformed input still
# prints a usable line.
#
# Requirements: bash, python3, git (optional), curl (only for the GLM quota).
# License: MIT (see LICENSE).

set -euo pipefail

# Render times in the OS-configured timezone: drop any TZ inherited from the
# parent process (launchers/IDE terminals sometimes export TZ), so Python's
# localtime falls back to /etc/localtime (the macOS System Settings region).
unset TZ

input="$(cat)"

model=""
cur_dir=""
proj_dir=""
ctx_pct=""
q_label=""
q_pct=""
q_reset=""
exceeds=""
jev_state=""
jev_counts=""
jev_log_dir="${CLAUDE_STATUSLINE_JEV_DIR:-${HOME:-/nonexistent}/.jev/logs}"

# --- Parse stdin JSON (python3; stock macOS has no jq) ----------------------
if command -v python3 >/dev/null 2>&1; then
  parsed="$(printf '%s' "$input" | python3 -c '
import json, sys, time
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
if not isinstance(d, dict):
    d = {}
def sub(key):
    v = d.get(key)
    return v if isinstance(v, dict) else {}
ws = sub("workspace")
md = sub("model")
cw = sub("context_window")
pct = cw.get("used_percentage")
pct_s = str(int(pct)) if isinstance(pct, (int, float)) else ""

def fmt_reset(ts):
    t = time.localtime(ts)
    same_day = time.strftime("%Y%m%d", t) == time.strftime("%Y%m%d")
    return time.strftime("%H:%M", t) if same_day else time.strftime("%m/%d %H:%M", t)

# Quota: pick the present rate-limit window with the earliest resets_at
# (five_hour / seven_day / spend_limit may each be independently absent).
rl = sub("rate_limits")
best = None
for lbl, key in (("5h", "five_hour"), ("7d", "seven_day"), ("spend", "spend_limit")):
    w = rl.get(key)
    if not isinstance(w, dict):
        continue
    v = w.get("used_percentage")
    v_s = str(int(v)) if isinstance(v, (int, float)) else ""
    r = w.get("resets_at")
    r_s = fmt_reset(r) if isinstance(r, (int, float)) else ""
    if not v_s and not r_s:
        continue
    sortkey = r if isinstance(r, (int, float)) else float("inf")
    if best is None or sortkey < best[0]:
        best = (sortkey, lbl, v_s, r_s)
q_label, q_pct, q_reset = (best[1], best[2], best[3]) if best else ("", "", "")

fields = [
    md.get("display_name") or "",
    ws.get("current_dir") or d.get("cwd") or "",
    ws.get("project_dir") or "",
    pct_s,
    q_label,
    q_pct,
    q_reset,
    "1" if d.get("exceeds_200k_tokens") else "",
]
sys.stdout.write("\x1f".join(fields))
' 2>/dev/null || true)"
  if [ -n "$parsed" ]; then
    # Unit Separator (\x1f) as IFS: a NON-whitespace delimiter, so empty
    # fields are preserved and never shift when a segment is absent
    # (a tab would collapse leading empty fields and shift everything).
    IFS=$'\x1f' read -r model cur_dir proj_dir ctx_pct q_label q_pct q_reset exceeds <<< "$parsed"
  fi
fi

# --- GLM (Z.AI / Zhipu) quota fallback --------------------------------------
# Active when Claude Code sends no rate_limits AND the session uses a glm
# model (model name starts with "glm") or routes through a glm endpoint.
if [ -z "$q_label" ]; then
  glm_active=0
  # Case-insensitive model match: display names vary ("glm-5.3-flash" from a
  # remapped ID, "GLM-5.3" from a modelPicker label) and case is sensitive.
  case "$(printf '%s' "$model" | tr '[:upper:]' '[:lower:]')" in glm*) glm_active=1 ;; esac
  if [ "$glm_active" = "0" ]; then
    case "${ANTHROPIC_BASE_URL:-}" in
      *z.ai*|*bigmodel.cn*) glm_active=1 ;;
      # A local BASE_URL is a routing proxy (same rule as host resolution
      # below): arm the fallback so GLM-routed sessions keep the quota
      # segment even when the display name does not start with "glm".
      # Harmless for non-GLM proxies — the monitor fetch just fails and
      # the segment stays hidden.
      http://127.*|http://localhost*|http://\[::1\]*) glm_active=1 ;;
    esac
  fi
  [ -n "${CLAUDE_STATUSLINE_GLM_HOST:-}" ] && glm_active=1
  if [ "$glm_active" = "1" ]; then
    glm_host="${CLAUDE_STATUSLINE_GLM_HOST:-}"
    if [ -z "$glm_host" ] && [ -n "${ANTHROPIC_BASE_URL:-}" ]; then
      # Origin (scheme://host) of ANTHROPIC_BASE_URL: a z.ai/bigmodel host is
      # used directly; a local address is treated as a routing proxy that
      # forwards to the monitor API and injects auth itself.
      glm_host="$(BASE_URL="$ANTHROPIC_BASE_URL" python3 -c "
import os
from urllib.parse import urlparse
u = urlparse(os.environ.get('BASE_URL', ''))
print(u.scheme + '://' + u.netloc if u.netloc else '')
" 2>/dev/null || true)"
      case "$glm_host" in
        *z.ai*|*bigmodel.cn*) : ;;
        http://127.*|http://localhost*|http://\[::1\]*) : ;;
        *) glm_host="https://api.z.ai" ;;
      esac
    fi
    [ -z "$glm_host" ] && glm_host="https://api.z.ai"
    # Dedicated token var first: setting ANTHROPIC_AUTH_TOKEN globally can
    # override subscription OAuth for non-glm routes, so prefer the local one.
    glm_token="${CLAUDE_STATUSLINE_GLM_TOKEN:-${ANTHROPIC_AUTH_TOKEN:-${ANTHROPIC_API_KEY:-}}}"
    glm_cache="${TMPDIR:-/tmp}/claude-statusline-glm.json"
    glm_fresh=0
    if [ -s "$glm_cache" ]; then
      glm_age=$(( $(date +%s) - $(python3 -c "import json;print(int(json.load(open('$glm_cache')).get('fetched_at',0)))" 2>/dev/null || echo 0) ))
      [ "$glm_age" -lt 120 ] 2>/dev/null && glm_fresh=1
    fi
    if [ "$glm_fresh" = "0" ] && command -v curl >/dev/null 2>&1; then
      if [ -n "$glm_token" ]; then
        # With a local token: authenticate directly against the quota host.
        curl -s -m 3 \
          -H "Authorization: $glm_token" \
          -H "Accept-Language: en-US,en" \
          "$glm_host/api/monitor/usage/quota/limit" 2>/dev/null
      else
        # No local token (e.g. a routing proxy holds it): try unauthenticated —
        # a local proxy that injects auth will still answer.
        curl -s -m 3 \
          -H "Accept-Language: en-US,en" \
          "$glm_host/api/monitor/usage/quota/limit" 2>/dev/null
      fi | python3 -c '
import json, sys, time
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
data = d.get("data") if isinstance(d.get("data"), dict) else d
limits = data.get("limits") if isinstance(data, dict) else None
best = None
for it in limits or []:
    if not isinstance(it, dict):
        continue
    r = it.get("nextResetTime")   # epoch milliseconds
    p = it.get("percentage")
    if not isinstance(r, (int, float)) or not isinstance(p, (int, float)):
        continue
    if best is None or r < best[0]:
        best = (r, p)
if best is None:
    sys.exit(1)
print(json.dumps({"fetched_at": int(time.time()), "reset_ms": best[0], "pct": int(best[1])}))
' > "$glm_cache.tmp" 2>/dev/null && mv -f "$glm_cache.tmp" "$glm_cache" || rm -f "$glm_cache.tmp"
    fi
    # Read the cache (fresh or stale-but-usable) into the quota fields.
    if [ -s "$glm_cache" ]; then
      glm_out="$(python3 -c "
import json, time
try:
    c = json.load(open('$glm_cache'))
    t = c['reset_ms'] / 1000.0
    if t > time.time() - 86400 * 30:
        lt = time.localtime(t)
        same = time.strftime('%Y%m%d', lt) == time.strftime('%Y%m%d')
        rs = time.strftime('%H:%M', lt) if same else time.strftime('%m/%d %H:%M', lt)
        print(c['pct'], rs, sep='\x1f')
except Exception:
    pass
" 2>/dev/null || true)"
      if [ -n "$glm_out" ]; then
        IFS=$'\x1f' read -r q_pct q_reset <<< "$glm_out"
        q_label="glm"
      fi
    fi
  fi
fi

# --- jev judgment-log status ---------------------------------------------------
# Reflect the jev-mcp judgment log (~/.jev/logs, github.com/takezou621/jev-mcp):
# today's real-judgment counts (pass / block / escalate, plus failed judgments
# as a separate slot) and the latest judgment's action as the segment state —
# entirely local, no network. The segment is hidden when the log directory
# does not exist (jev-mcp not in use yet) and goes "idle" when the latest real
# judgment is older than 15 minutes — yesterday's file is scanned too, so a
# judgment written just before midnight still reads as fresh at 00:05 (and an
# MCP server started with TZ set lands its lines in a file named by a day
# this process computes differently around midnight). Entries logged by jev's
# own test suites and smoke runs (model values containing "stub": stub,
# stub-N, test-stub, dev-stub) are excluded. The log itself is sensitive
# (0600) and carries the judge's probabilities: the scan matches only line
# shapes, actions and timestamps — the probabilities and evidence paths are
# never parsed or displayed. Parsed once and cached until the log files
# change, so re-renders between log writes cost one cache read.
if [ -d "$jev_log_dir" ] && command -v python3 >/dev/null 2>&1; then
  jev_out="$(JEV_LOG_DIR="$jev_log_dir" python3 -c '
import calendar, json, os, time

log_dir = os.environ["JEV_LOG_DIR"]
# jev-mcp names its daily file by the LOCAL day (log.ts: new Date() minus the
# UTC offset), unlike jev-claude which logged in UTC — pick the same day or
# the segment shows an empty day every evening for UTC+ zones.
def day(n):
    return time.strftime("%Y-%m-%d", time.localtime(time.time() - n * 86400))
today_path = os.path.join(log_dir, "jev-" + day(0) + ".jsonl")
paths = [(today_path, True), (os.path.join(log_dir, "jev-" + day(1) + ".jsonl"), False)]

def emit(state, counts):
    print("\x1f".join((state, counts)))

def sig(p):
    try:
        st = os.stat(p)
        return "%d.%d" % (st.st_mtime_ns, st.st_size)
    except OSError:
        return "-"

# Cache keyed on the exact files we read: the log is up to a few MB/day and
# the status line renders far more often than jev writes entries.
key = "|".join(p + "=" + sig(p) for p, _ in paths)
# Per-uid name + O_NOFOLLOW: when TMPDIR is unset this lands in the shared
# /tmp, where a symlink planted by another user must not be followed — on
# the read side either, or a planted cache could paint the segment.
cache_path = os.path.join(os.environ.get("TMPDIR") or "/tmp",
                          "claude-statusline-jev-%d.json" % os.getuid())
try:
    fd = os.open(cache_path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd) as f:
        c = json.load(f)
    out = c.get("out")
    latest = c.get("latest")
    if (c.get("key") == key and isinstance(out, list) and len(out) == 2
            and out[0] in ("pass", "warn", "block", "escalate", "idle")):
        # Re-evaluate staleness on every hit: a cached active state must
        # still decay to idle once the judgment is older than 15 minutes,
        # even if the log stops changing.
        state = out[0]
        if state != "idle" and (
                not isinstance(latest, (int, float)) or time.time() - latest > 900):
            state = "idle"
        emit(state, out[1])
        raise SystemExit
except SystemExit:
    raise
except Exception:
    pass

latest = None        # epoch of the newest real judgment, for staleness re-checks
latest_action = None # its action, so the state can be recomputed later
n_pass = n_block = n_escalate = n_failed = 0
for path, is_today in paths:
    try:
        with open(path, "rb") as f:
            for raw in f:
                # jev-mcp writes one JSON object per line starting {"at": " —
                # a line not shaped like that is not data. A line with no
                # trailing newline is a torn write still in flight; skipping
                # it undercounts for one render and heals on the next.
                if not raw.startswith(b"{\"at\":\"") or not raw.endswith(b"\n"):
                    continue
                # Failed judgments (the judge threw; fail-open applies) are
                # their own slot, regardless of the action the caller fell
                # back to. Failed records carry no model value, so this check
                # must precede the stub-model filter.
                if b"\"status\":\"failed\"" in raw:
                    if is_today:
                        n_failed += 1
                    continue
                # Real judgments only: the test suites and smoke runs log stub
                # model values (stub / stub-N / test-stub / dev-stub), so any
                # model containing "stub" never counts — match the extracted
                # value, not a prefix of the raw line. A judged record with no
                # model value is not a real judgment either.
                i = raw.find(b"\"model\":\"")
                if i < 0:
                    continue
                j = raw.find(b"\"", i + 9)
                if j < 0 or b"stub" in raw[i + 9:j]:
                    continue
                for act in ("pass", "warn", "block", "escalate"):
                    if ("\"action\":\"%s\"" % act).encode() in raw:
                        break
                else:
                    continue
                # warn is a pass carrying a note — same count slot as pass.
                if is_today:
                    if act in ("pass", "warn"):
                        n_pass += 1
                    elif act == "block":
                        n_block += 1
                    else:
                        n_escalate += 1
                i = raw.find(b"\"at\":\"")
                if i >= 0 and len(raw) >= i + 29:
                    try:
                        # The at field is UTC (the file name is the local day).
                        ep = calendar.timegm(time.strptime(raw[i + 6:i + 29].decode(), "%Y-%m-%dT%H:%M:%S.%f"))
                        if latest is None or ep >= latest:
                            latest = ep
                            latest_action = act
                    except ValueError:
                        pass
    except OSError:
        pass
if latest_action is None or time.time() - latest > 900:
    state = "idle"
else:
    state = latest_action
counts = ""
if latest_action is not None or n_failed:
    # A day of nothing but failed judgments must still show its !N — jev
    # fails open, so that count is the only visible trace of a judge outage.
    counts = "%d/%d/%d" % (n_pass, n_block, n_escalate)
    if n_failed:
        counts += "/%d" % n_failed
out = (state, counts)

try:
    fd = os.open(cache_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump({"key": key, "out": out, "latest": latest}, f)
except Exception:
    pass
emit(*out)
' 2>/dev/null || true)"
  if [ -n "$jev_out" ]; then
    IFS=$'\x1f' read -r jev_state jev_counts <<< "$jev_out"
  fi
fi

# --- Sleep state (macOS) ----------------------------------------------------
# Whether the machine will idle-sleep or is being kept awake. Kept-awake states,
# in priority order: a running caffeinate process (any flags, via pgrep -x);
# sleep-prevention assertions held by any process (pmset -g assertions — e.g.
# coreaudiod while audio is captured); the power-manager setting itself disabled
# (pmset -g, every "sleep N" line 0). Otherwise plain "sleep on". pmset/pgrep
# are macOS-only — elsewhere the segment stays hidden. The python probe runs at
# most once per 15s TTL: the line renders per token, so every other render just
# reads the cache file here (one id + one date fork, no interpreter), and a few
# seconds of stale awake/asleep label is harmless.
sleep_state=""
sleep_cache="${TMPDIR:-/tmp}/claude-statusline-sleep-$(id -u).txt"
if [ -s "$sleep_cache" ]; then
  if IFS='|' read -r sleep_ts sleep_state < "$sleep_cache" && [ -n "$sleep_state" ]; then
    [ "$(( $(date +%s) - sleep_ts ))" -ge 15 ] && sleep_state=""
  fi
fi
if [ -z "$sleep_state" ] && command -v python3 >/dev/null 2>&1 \
   && command -v pgrep >/dev/null 2>&1 && command -v pmset >/dev/null 2>&1; then
  sleep_state="$(python3 -c '
import os, re, subprocess, time

now = int(time.time())
cache = os.path.join(os.environ.get("TMPDIR") or "/tmp",
                     "claude-statusline-sleep-%d.txt" % os.getuid())
caffeinate = False
try:
    caffeinate = subprocess.run(
        ["pgrep", "-x", "caffeinate"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    ).returncode == 0
except OSError:
    pass
try:
    a = subprocess.run(
        ["pmset", "-g", "assertions"],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        text=True, timeout=3,
    ).stdout
except Exception:
    a = ""
# System-sleep prevention only: a display-sleep assertion alone keeps the
# screen on while the system still idle-sleeps, so it reads "sleep on".
prevented = bool(re.search(r"^\s*Prevent(?:UserIdle)?SystemSleep\s+1\b", a, re.M))
try:
    g = subprocess.run(
        ["pmset", "-g"],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        text=True, timeout=3,
    ).stdout
except Exception:
    g = ""
sleeps = [int(m) for m in re.findall(r"^\s*sleep\s+(\d+)\b", g, re.M)]
if caffeinate:
    state = "caffeinate"
elif prevented:
    state = "no-sleep"
elif sleeps and all(s == 0 for s in sleeps):
    state = "sleep off"
else:
    state = "sleep on"
try:
    fd = os.open(cache, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write("%d|%s" % (now, state))
except Exception:
    pass
print(state)
' 2>/dev/null || true)"
fi

# --- Degrade gracefully if JSON/python parsing yielded nothing --------------
if [ -z "$cur_dir" ] || [ ! -d "$cur_dir" ]; then
  cur_dir="$PWD"
fi

# --- Git: branch (or short SHA when detached) + repo/project name -----------
branch=""
repo_name=""
if git_top="$(git --no-optional-locks -C "$cur_dir" rev-parse --show-toplevel 2>/dev/null)"; then
  repo_name="$(basename "$git_top")"
  branch="$(git --no-optional-locks -C "$cur_dir" branch --show-current 2>/dev/null || true)"
  if [ -z "$branch" ]; then
    # Detached HEAD (or equivalent): show the short SHA instead.
    branch="$(git --no-optional-locks -C "$cur_dir" rev-parse --short HEAD 2>/dev/null || true)"
  fi
else
  # Not inside a git worktree: fall back to the directory basename.
  repo_name="$(basename "$cur_dir")"
fi

# --- Render one compact, colored line ---------------------------------------
C_RESET=$'\033[0m'
C_DIM=$'\033[2m'
C_BRANCH=$'\033[36m'   # muted cyan for the branch
C_REPO=$'\033[32m'     # green for the repo/project name
C_MODEL=$'\033[35m'    # magenta for the model
C_WARN=$'\033[33m'     # yellow: context >= 50%, or quota >= 50%
C_CRIT=$'\033[31m'     # red: context >= 80%, quota >= 80% or over 100%
sep="${C_DIM} | ${C_RESET}"

parts=()
# Nerd Font icons (powerline-style: monochrome glyphs that take the segment's
# ANSI color). Built with printf octal escapes instead of literal characters
# so the glyph bytes survive any editor or encoding — these are private-use
# codepoints. Requires a Nerd Font / powerline-patched terminal font; without
# one they render as tofu. Drop the "${ICON_*} " prefix for a plainer line.
ICON_BRANCH="$(printf '\356\202\240')"  # U+E0A0 branch
ICON_REPO="$(printf '\357\201\273')"    # U+F07B folder
ICON_MODEL="$(printf '\357\225\204')"   # U+F544 robot
ICON_CTX="$(printf '\357\200\200')"     # U+F080 bar chart
ICON_QUOTA="$(printf '\357\211\222')"   # U+F252 hourglass
ICON_JEV="$(printf '\357\204\262')"     # U+F132 shield
ICON_SLEEP="$(printf '\357\206\206')"   # U+F186 moon
ICON_TICK="$(printf '\357\200\214')"    # U+F00C check mark  (jev pass count)
ICON_CROSS="$(printf '\357\200\215')"   # U+F00D cross mark  (jev block count)
ICON_ALERT="$(printf '\357\201\261')"   # U+F071 warning     (jev escalate count)
# Each segment carries a leading Nerd Font icon (powerline-style: monochrome
# glyphs colored by the segment's ANSI color, never emoji). They sit outside
# the color codes and require a Nerd Font / powerline-patched terminal font —
# without one they render as tofu. Delete an icon for a plainer line.
if [ -n "$branch" ]; then
  parts+=("${ICON_BRANCH} ${C_BRANCH}${branch}${C_RESET}")
fi
if [ -n "$repo_name" ]; then
  parts+=("${ICON_REPO} ${C_REPO}${repo_name}${C_RESET}")
fi
if [ -n "$model" ]; then
  parts+=("${ICON_MODEL} ${C_MODEL}${model}${C_RESET}")
fi
if [ -n "$ctx_pct" ]; then
  # Color-code context usage: default < 50%, yellow >= 50%, red >= 80%
  # (red also when exceeds_200k_tokens is set, regardless of the percentage).
  # Labeled "ctx" so it is not confused with the quota usage percentage.
  ctx_color=""
  if [ "$exceeds" = "1" ] || [ "$ctx_pct" -ge 80 ] 2>/dev/null; then
    ctx_color="$C_CRIT"
  elif [ "$ctx_pct" -ge 50 ] 2>/dev/null; then
    ctx_color="$C_WARN"
  fi
  parts+=("${ICON_CTX} ${ctx_color}ctx ${ctx_pct}%${C_RESET}")
fi
if [ -n "$sleep_state" ]; then
  # Sleep state: what keeps the machine awake, or that idle sleep is on.
  # Yellow for any kept-awake state (a long job may assume the machine stays
  # up); dim for the plain sleep-on background state.
  case "$sleep_state" in
    caffeinate)  parts+=("${ICON_SLEEP} ${C_WARN}caffeinate${C_RESET}") ;;
    no-sleep)    parts+=("${ICON_SLEEP} ${C_WARN}no-sleep${C_RESET}") ;;
    "sleep off") parts+=("${ICON_SLEEP} ${C_WARN}sleep off${C_RESET}") ;;
    *)           parts+=("${ICON_SLEEP} ${C_DIM}sleep on${C_RESET}") ;;
  esac
fi
if [ -n "$jev_state" ]; then
  # Decorate the raw "pass/block/escalate(/failed)" counts so their meaning is
  # visible: " 292  219  23 !1" instead of a bare "292/219/23/1". The failed
  # count appears only when the day has failed judgments (fail-open traces).
  if [ -n "$jev_counts" ]; then
    IFS=/ read -r jev_p jev_b jev_w jev_e <<< "$jev_counts"
    jev_counts="${ICON_TICK}${jev_p} ${ICON_CROSS}${jev_b} ${ICON_ALERT}${jev_w}"
    if [ -n "${jev_e:-}" ]; then
      jev_counts="${jev_counts} ${C_CRIT}!${jev_e}${C_RESET}"
    fi
  fi
  # jev judgment-log status: "<state> <counts>". The counts are today's real
  # judgments from ~/.jev/logs; the color follows the latest judgment's action
  # (red=block, yellow=escalate/warn), dim=idle.
  case "$jev_state" in
    block)    parts+=("${ICON_JEV} ${C_CRIT}jev block${jev_counts:+ $jev_counts}${C_RESET}") ;;
    escalate) parts+=("${ICON_JEV} ${C_WARN}jev escalate${jev_counts:+ $jev_counts}${C_RESET}") ;;
    warn)     parts+=("${ICON_JEV} ${C_WARN}jev warn${jev_counts:+ $jev_counts}${C_RESET}") ;;
    idle)     parts+=("${ICON_JEV} ${C_DIM}jev idle${jev_counts:+ $jev_counts}${C_RESET}") ;;
    *)        parts+=("${ICON_JEV} jev ok${jev_counts:+ $jev_counts}") ;;
  esac
fi
if [ -n "$q_pct" ] || [ -n "$q_reset" ]; then
  # Quota window: "<label> <pct>% -> <reset time>" (label/pct/reset each
  # optional). Same color thresholds as context; over 100% is red too.
  q_color=""
  if [ "$q_pct" -ge 80 ] 2>/dev/null; then
    q_color="$C_CRIT"
  elif [ "$q_pct" -ge 50 ] 2>/dev/null; then
    q_color="$C_WARN"
  fi
  q_text="${ICON_QUOTA} ${q_label:+$q_label }${q_pct:+quota ${q_pct}%}${q_reset:+ → $q_reset}"
  parts+=("${q_color}${q_text}${C_RESET}")
fi

if [ "${#parts[@]}" -eq 0 ]; then
  # Never print an empty status line.
  printf '%s\n' "$(basename "$cur_dir")"
  exit 0
fi

out=""
for i in "${!parts[@]}"; do
  if [ "$i" -eq 0 ]; then
    out="${parts[$i]}"
  else
    out="${out}${sep}${parts[$i]}"
  fi
done
printf '%s\n' "$out"
