# claude-statusline

A fast, dependency-light status line for [Claude Code](https://docs.claude.com/en/docs/claude-code/overview).

Shows **git branch | repo name | model | context usage | quota** on one compact, colorized line — and nothing you don't need.

```
 fix/issue-404-apply-fallback |  cloudlegal-word-addin |  Fable 5.1 |  コンテキスト 8% |  5h クォータ 23% → 17:00
```

The two percentages measure different things and are labeled as such: `コンテキスト` (context) is how full this session's context window is; the `5h`/`7d`/`spend`/`glm`-labeled クォータ (quota) is how much of the account's rate-limit/billing window is consumed. The segment labels render in Japanese, and each segment carries a monochrome Nerd Font icon (branch U+E0A0, repo U+F07B, model U+F544, context U+F080, quota U+F252) drawn in the segment's color — these are private-use glyphs, so a Nerd Font / powerline-patched terminal font is required; delete the icons in the `parts` lines for a plainer line.

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
| context usage | default < 50%, yellow ≥ 50%, red ≥ 80% | `コンテキスト <pct>%` — `context_window.used_percentage`, rounded to an integer. Also red whenever `exceeds_200k_tokens` is set. Hidden when absent (e.g. before the first API response). |
| quota reset | same thresholds as context usage | The rate-limit window with the earliest `resets_at` among `rate_limits.five_hour` / `seven_day` / `spend_limit`: `<label> クォータ <pct>% → <local reset time>`. Labels: `5h`, `7d`, `spend`. Reset time is `HH:MM` today, `MM/DD HH:MM` otherwise. Present for Claude.ai Pro/Max subscribers or behind a Claude apps gateway, after the first API response; hidden otherwise. Falls back to the [GLM quota](#glm-zai-quota) when routing through a glm endpoint. |

## GLM (Z.AI) quota

When Claude Code sends no `rate_limits` (no Claude.ai subscription in play) **and** the session routes through a glm endpoint, the script fetches the GLM Coding Plan quota instead and shows it as the same segment with the label `glm`:

```
 fix/issue-404-apply-fallback |  cloudlegal-word-addin |  glm-5.3[1m] |  コンテキスト 21% |  glm クォータ 42% → 15:54
```

- **Detection** (any of): the session's model name starts with `glm` (case-insensitive); `ANTHROPIC_BASE_URL` points at `z.ai` / `bigmodel.cn` **or at a local address** (a routing proxy); or `CLAUDE_STATUSLINE_GLM_HOST` is set.
- **Host resolution**: `CLAUDE_STATUSLINE_GLM_HOST` if set; otherwise the origin of `ANTHROPIC_BASE_URL` when it points at z.ai / bigmodel.cn **or at a local address** (`127.*`, `localhost`, `[::1]` — treated as a routing proxy expected to forward `/api/monitor/...` and inject auth); otherwise `https://api.z.ai`.
- **Token**: `CLAUDE_STATUSLINE_GLM_TOKEN` first (dedicated, so it never interferes with `ANTHROPIC_AUTH_TOKEN` / subscription OAuth on other routes), then `ANTHROPIC_AUTH_TOKEN`, then `ANTHROPIC_API_KEY` — sent raw in the `Authorization` header per Z.AI's monitor API. With no token the request is sent unauthenticated, which works when a local routing proxy injects auth. Nothing is sent anywhere except the resolved quota host.
- **Fast + polite**: `GET /api/monitor/usage/quota/limit` with a 3s timeout, cached to `${TMPDIR:-/tmp}/claude-statusline-glm.json` for 2 minutes — renders stay local; the API is hit at most once per TTL. Requires `curl`.
- **Timezone**: reset times (Claude windows and GLM alike) always render in the OS-configured timezone — the script clears any inherited `TZ` env var and lets Python fall back to `/etc/localtime`, so the display never drifts when Claude Code is launched from a terminal or launcher that sets `TZ`.
- **Graceful**: network failure, malformed response, or missing env simply hides the segment.

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
