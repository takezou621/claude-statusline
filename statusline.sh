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
  case "$model" in glm*) glm_active=1 ;; esac
  if [ "$glm_active" = "0" ]; then
    case "${ANTHROPIC_BASE_URL:-}" in
      *z.ai*|*bigmodel.cn*) glm_active=1 ;;
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
# Each segment carries a leading icon (powerline-style). Icons sit outside the
# color codes — terminals pick their own emoji presentation, and ANSI-wrapping
# them can render as tofu on some fonts. Delete an icon for a plainer line.
if [ -n "$branch" ]; then
  parts+=("🌿 ${C_BRANCH}${branch}${C_RESET}")
fi
if [ -n "$repo_name" ]; then
  parts+=("📁 ${C_REPO}${repo_name}${C_RESET}")
fi
if [ -n "$model" ]; then
  parts+=("🤖 ${C_MODEL}${model}${C_RESET}")
fi
if [ -n "$ctx_pct" ]; then
  # Color-code context usage: default < 50%, yellow >= 50%, red >= 80%
  # (red also when exceeds_200k_tokens is set, regardless of the percentage).
  # Labeled "コンテキスト" (context) so it is not confused with the quota usage
  # percentage.
  ctx_color=""
  if [ "$exceeds" = "1" ] || [ "$ctx_pct" -ge 80 ] 2>/dev/null; then
    ctx_color="$C_CRIT"
  elif [ "$ctx_pct" -ge 50 ] 2>/dev/null; then
    ctx_color="$C_WARN"
  fi
  parts+=("📊 ${ctx_color}コンテキスト ${ctx_pct}%${C_RESET}")
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
  q_text="⏳ ${q_label:+$q_label }${q_pct:+クォータ ${q_pct}%}${q_reset:+ → $q_reset}"
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
