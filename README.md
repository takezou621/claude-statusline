# claude-statusline

A fast, dependency-light status line for [Claude Code](https://docs.claude.com/en/docs/claude-code/overview).

Shows **git branch | repo name | model | context usage | quota reset** on one compact, colorized line — and nothing you don't need.

```
fix/issue-404-apply-fallback | cloudlegal-word-addin | Fable 5.1 | 8% | 5h 23% → 17:00
```

- **Fast by design** — one `python3` call for JSON parsing and local-only `git` calls (`--no-optional-locks`). No network, no docker/aws, no heavy subprocesses.
- **Graceful degradation** — no git repo, detached HEAD, missing `python3`, or malformed input never breaks the line. Usage segments appear only when the data is present.
- **No dependencies beyond the basics** — `bash`, `python3`, `git`. Works on macOS, Linux, and WSL.
- **Monorepo friendly** — nested repos are detected from the actual git worktree, so the repo name is always the repo you are in, not the folder you launched from.

## What it shows

| Segment | Color | Behavior |
|---|---|---|
| git branch | cyan | Current branch; falls back to the short SHA on detached HEAD. Hidden outside a git repo. |
| repo name | green | Basename of the git worktree root; directory basename when not in a repo. |
| model | magenta | `model.display_name` from the statusline JSON. |
| context usage | default < 50%, yellow ≥ 50%, red ≥ 80% | `context_window.used_percentage`, rounded to an integer. Also red whenever `exceeds_200k_tokens` is set. Hidden when absent (e.g. before the first API response). |
| quota reset | same thresholds as context usage | The rate-limit window with the earliest `resets_at` among `rate_limits.five_hour` / `seven_day` / `spend_limit`: `<label> <pct>% → <local reset time>`. Labels: `5h`, `7d`, `spend`. Reset time is `HH:MM` today, `MM/DD HH:MM` otherwise. Present for Claude.ai Pro/Max subscribers or behind a Claude apps gateway, after the first API response; hidden otherwise. |

## Install

```bash
curl -fsSL -o ~/.claude/statusline.sh \
  https://raw.githubusercontent.com/takezou621/claude-statusline/main/statusline.sh
chmod +x ~/.claude/statusline.sh
```

Then add to `~/.claude/settings.json` (merge into existing keys — don't replace the whole file):

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash $HOME/.claude/statusline.sh"
  }
}
```

Start a new Claude Code session and the status line appears at the bottom.

## How it works

Claude Code pipes a JSON object to the configured command on stdin:

```json
{
  "model": { "display_name": "Fable 5.1" },
  "workspace": { "current_dir": "/you/your-repo", "project_dir": "/you" }
}
```

The script parses it with `python3` (stock macOS has no `jq`), resolves the git
worktree and branch locally, and prints one ANSI-colored line. Every step is
guarded: if anything fails it still prints a usable line and exits 0.

## Customize

All the logic is in one ~90-line bash file. Common tweaks:

- **Colors** — edit the `C_BRANCH` / `C_REPO` / `C_MODEL` ANSI codes near the bottom.
- **Extra segments** (time, exit status, etc.) — append to the `parts` array.
- **Separator** — change `sep`.

## License

[MIT](./LICENSE)
