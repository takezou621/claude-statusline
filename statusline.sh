#!/bin/bash
# claude-statusline — a fast, dependency-light status line for Claude Code.
# https://github.com/takezou621/claude-statusline
#
# Protocol: Claude Code pipes one JSON object on stdin
# (model, workspace, cost, context_window — see README for the fields used).
# Fast path only: python3 for JSON + local git calls with --no-optional-locks.
# No network, no docker/aws, no heavy subprocesses. Degrades gracefully:
# missing git/python3 or malformed input still prints a usable line.
#
# Requirements: bash, python3, git (optional — works without a repo too).
# License: MIT (see LICENSE).

set -euo pipefail

input="$(cat)"

model=""
cur_dir=""
proj_dir=""
ctx_pct=""
cost_usd=""
exceeds=""

# --- Parse stdin JSON (python3; stock macOS has no jq) ----------------------
if command -v python3 >/dev/null 2>&1; then
  parsed="$(printf '%s' "$input" | python3 -c '
import json, sys
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
co = sub("cost")
pct = cw.get("used_percentage")
pct_s = str(int(pct)) if isinstance(pct, (int, float)) else ""
cost = co.get("total_cost_usd")
cost_s = f"{cost:.2f}" if isinstance(cost, (int, float)) else ""
fields = [
    md.get("display_name") or "",
    ws.get("current_dir") or d.get("cwd") or "",
    ws.get("project_dir") or "",
    pct_s,
    cost_s,
    "1" if d.get("exceeds_200k_tokens") else "",
]
sys.stdout.write("\x1f".join(fields))
' 2>/dev/null || true)"
  if [ -n "$parsed" ]; then
    # Unit Separator (\x1f) as IFS: a NON-whitespace delimiter, so empty
    # fields are preserved and never shift when a segment is absent
    # (a tab would collapse leading empty fields and shift everything).
    IFS=$'\x1f' read -r model cur_dir proj_dir ctx_pct cost_usd exceeds <<< "$parsed"
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
C_WARN=$'\033[33m'     # yellow: context >= 50%, or the cost segment
C_CRIT=$'\033[31m'     # red: context >= 80% or exceeds_200k_tokens
sep="${C_DIM} | ${C_RESET}"

parts=()
if [ -n "$branch" ]; then
  parts+=("${C_BRANCH}${branch}${C_RESET}")
fi
if [ -n "$repo_name" ]; then
  parts+=("${C_REPO}${repo_name}${C_RESET}")
fi
if [ -n "$model" ]; then
  parts+=("${C_MODEL}${model}${C_RESET}")
fi
if [ -n "$ctx_pct" ]; then
  # Color-code context usage: default < 50%, yellow >= 50%, red >= 80%
  # (red also when exceeds_200k_tokens is set, regardless of the percentage).
  ctx_color=""
  if [ "$exceeds" = "1" ] || [ "$ctx_pct" -ge 80 ] 2>/dev/null; then
    ctx_color="$C_CRIT"
  elif [ "$ctx_pct" -ge 50 ] 2>/dev/null; then
    ctx_color="$C_WARN"
  fi
  parts+=("${ctx_color}${ctx_pct}%${C_RESET}")
fi
if [ -n "$cost_usd" ]; then
  parts+=("${C_WARN}\$${cost_usd}${C_RESET}")
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
