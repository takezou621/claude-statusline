#!/bin/bash
# claude-statusline — a fast, dependency-light status line for Claude Code.
# https://github.com/takezou621/claude-statusline
#
# Protocol: Claude Code pipes one JSON object on stdin
# (model.display_name, workspace.current_dir, workspace.project_dir).
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
ws = d.get("workspace") if isinstance(d.get("workspace"), dict) else {}
md = d.get("model") if isinstance(d.get("model"), dict) else {}
fields = [
    md.get("display_name") or "",
    ws.get("current_dir") or d.get("cwd") or "",
    ws.get("project_dir") or "",
]
sys.stdout.write("\x1f".join(fields))
' 2>/dev/null || true)"
  if [ -n "$parsed" ]; then
    # Unit Separator (\x1f) as IFS: a NON-whitespace delimiter, so empty
    # fields are preserved and never shift when model/project_dir is absent
    # (a tab would collapse leading empty fields and shift everything).
    IFS=$'\x1f' read -r model cur_dir proj_dir <<< "$parsed"
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
