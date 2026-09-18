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
# jev-claude status: when the jev-claude Stop hook is installed
# (~/.claude/hooks/jev), the jev segment mirrors its latest verdict and
# today's verdict counts, read from the hook's own local log (no network).
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
jev_dir="${CLAUDE_STATUSLINE_JEV_DIR:-${HOME:-/nonexistent}/.claude/hooks/jev}"

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

# --- jev-claude hook status ---------------------------------------------------
# Reflect the jev-claude Stop hook (github.com/takezou621/jev-claude, installed
# at ~/.claude/hooks/jev): its latest verdict (pass / block / error) and
# today's verdict counts, read from the hook's own local log — entirely local,
# no network. The segment is hidden when jev is not installed, shows "off"
# when installed but disabled (jev-config.json enabled) or not registered in
# settings.json, and "idle" when the last real verdict is older than 15
# minutes. Entries logged by jev's own test suites (the synthetic flag, the
# jev-mj-* projects) are excluded. Parsed once and cached until none of the
# read files change, so re-renders between log writes cost one cache read.
if [ -f "$jev_dir/verify-done.mjs" ] && command -v python3 >/dev/null 2>&1; then
  jev_out="$(JEV_DIR="$jev_dir" python3 -c '
import calendar, json, os, time

jev_dir = os.environ["JEV_DIR"]
home = os.path.expanduser("~")
cfg_dir = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(home, ".claude")
cfg_path = os.path.join(jev_dir, "jev-config.json")
settings_path = os.path.join(cfg_dir, "settings.json")
# jev names its daily log in UTC (new Date().toISOString()), so pick the same
# day — otherwise the segment goes idle every evening for UTC+ zones.
log_path = os.path.join(jev_dir, "logs", "jev-" + time.strftime("%Y-%m-%d", time.gmtime()) + ".jsonl")

def emit(state, counts):
    print("\x1f".join((state, counts)))

def sig(p):
    try:
        st = os.stat(p)
        return "%d.%d" % (st.st_mtime_ns, st.st_size)
    except OSError:
        return "-"

# Cache keyed on the exact file set we read: the log is up to a few MB/day
# and the status line renders far more often than jev writes entries.
key = "|".join(p + "=" + sig(p) for p in (cfg_path, settings_path, log_path))
# Per-uid name + O_NOFOLLOW: when TMPDIR is unset this lands in the shared
# /tmp, where a symlink planted by another user must not be followed.
cache_path = os.path.join(os.environ.get("TMPDIR") or "/tmp",
                          "claude-statusline-jev-%d.json" % os.getuid())
try:
    with open(cache_path) as f:
        c = json.load(f)
    out = c.get("out")
    latest = c.get("latest")
    if c.get("key") == key and isinstance(out, list) and len(out) == 2:
        # Re-evaluate staleness on every hit: a cached pass/block/err must
        # still decay to idle once the verdict is older than 15 minutes,
        # even if the log stops changing.
        state = out[0]
        if state in ("ok", "block", "err"):
            if not isinstance(latest, (int, float)) or time.time() - latest > 900:
                state = "idle"
        emit(state, out[1])
        raise SystemExit
except SystemExit:
    raise
except Exception:
    pass

# Same semantics as the hook itself (hookDisabled): "enabled": false stops
# every hook, "enabled": {"stop": false} stops the Stop hook only.
enabled = None
try:
    with open(cfg_path) as f:
        enabled = json.load(f).get("enabled", None)
except Exception:
    pass
latest = None        # epoch of the newest real verdict, for staleness re-checks
latest_kind = None   # its verdict, so the state can be recomputed later
if enabled is False or (isinstance(enabled, dict) and enabled.get("stop") is False):
    out = ("off", "")
else:
    hooked = False
    try:
        with open(settings_path) as f:
            for entry in json.load(f).get("hooks", {}).get("Stop", []) or []:
                for h in (entry or {}).get("hooks") or []:
                    # Match this installation, not just any jev mention.
                    if jev_dir in str((h or {}).get("command", "")):
                        hooked = True
    except Exception:
        pass
    if not hooked:
        out = ("off", "")
    else:
        n_pass = n_block = n_err = 0
        try:
            with open(log_path, "rb") as f:
                for raw in f:
                    # jev writes one JSON object per line with "ts" first
                    # (JSON.stringify of {ts, ...entry}), so a line not
                    # shaped like that is a torn/corrupt write, not data.
                    if not raw.startswith(b"{\"ts\":\""):
                        continue
                    # Only the Stop hook verdicts: other labels (bash / smoke /
                    # doctor) answer different questions, and matching on raw
                    # bytes keeps the scan cheap for a multi-MB daily log.
                    if b"\"label\":\"stop\"" not in raw:
                        continue
                    # Test-suite entries: the synthetic flag (golden runners)
                    # and the fixture project names of the jev test suites.
                    if b"\"synthetic\":true" in raw:
                        continue
                    if b"\"project\":\"jev-mj" in raw or b"\"project\":\"sample-app\"" in raw or b"\"project\":\"genericproj\"" in raw:
                        continue
                    if b"\"ok\":false" in raw:
                        kind = "err"
                    elif b"\"decision\":\"pass\"" in raw:
                        kind = "pass"
                    elif b"\"decision\":\"block\"" in raw:
                        kind = "block"
                    else:
                        continue
                    if kind == "pass":
                        n_pass += 1
                    elif kind == "block":
                        n_block += 1
                    else:
                        n_err += 1
                    i = raw.find(b"\"ts\":\"")
                    if i >= 0 and len(raw) >= i + 29:
                        try:
                            ep = calendar.timegm(time.strptime(raw[i + 6:i + 29].decode(), "%Y-%m-%dT%H:%M:%S.%f"))
                            if latest is None or ep >= latest:
                                latest = ep
                                latest_kind = kind
                        except ValueError:
                            pass
        except OSError:
            pass
        if latest_kind is None or time.time() - latest > 900:
            state = "idle"
        else:
            state = latest_kind
        counts = ""
        if latest_kind is not None:
            counts = "%d/%d" % (n_pass, n_block)
            if n_err:
                counts += "/%d" % n_err
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
ICON_TICK="$(printf '\357\200\214')"    # U+F00C check mark  (jev pass count)
ICON_CROSS="$(printf '\357\200\215')"   # U+F00D cross mark  (jev block count)
ICON_ALERT="$(printf '\357\201\261')"   # U+F071 warning     (jev error count)
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
if [ -n "$jev_state" ]; then
  # Decorate the raw "pass/block(/err)" counts so their meaning is visible:
  # " 292  219  23" instead of a bare "292/219/23".
  if [ -n "$jev_counts" ]; then
    IFS=/ read -r jev_p jev_b jev_e <<< "$jev_counts"
    jev_counts="${ICON_TICK}${jev_p} ${ICON_CROSS}${jev_b}"
    if [ -n "${jev_e:-}" ]; then
      jev_counts="${jev_counts} ${ICON_ALERT}${jev_e}"
    fi
  fi
  # jev-claude Stop-hook status: "<state> <counts>". The
  # counts are today's verdicts from the hook's own log; the color follows the
  # latest verdict (yellow=blocked, red=errored), dim=off/idle.
  case "$jev_state" in
    block)    parts+=("${ICON_JEV} ${C_WARN}jev block${jev_counts:+ $jev_counts}${C_RESET}") ;;
    err)      parts+=("${ICON_JEV} ${C_CRIT}jev err${jev_counts:+ $jev_counts}${C_RESET}") ;;
    idle)     parts+=("${ICON_JEV} ${C_DIM}jev idle${jev_counts:+ $jev_counts}${C_RESET}") ;;
    off)      parts+=("${ICON_JEV} ${C_DIM}jev off${C_RESET}") ;;
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
