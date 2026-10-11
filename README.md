# claude-statusline

A fast, dependency-light status line for [Claude Code](https://docs.claude.com/en/docs/claude-code/overview).

Shows **git branch | repo name | model | context usage | sleep | jev | quota** on one compact, colorized line — and nothing you don't need.

```
 fix/issue-404-apply-fallback |  cloudlegal-word-addin |  Fable 5.1 |  ctx 8% |  caffeinate |  jev ok 12 1 0 |  5h quota 23% → 17:00
```

The two percentages measure different things and are labeled as such: `ctx` is how full this session's context window is; the `5h`/`7d`/`spend`/`glm`-labeled quota is how much of the account's rate-limit/billing window is consumed. Each segment carries a monochrome Nerd Font icon (branch U+E0A0, repo U+F07B, model U+F544, context U+F080, sleep U+F186, jev U+F132, quota U+F252) drawn in the segment's color - the jev judgment counts carry their own glyphs (U+F00C pass, U+F00D block, U+F071 escalate) — these are private-use glyphs, so a Nerd Font / powerline-patched terminal font is required; delete the icons in the `parts` lines for a plainer line.

- **Fast by design** — one `python3` call for JSON parsing and local-only `git` calls (`--no-optional-locks`). No network, no docker/aws, no heavy subprocesses. (With the [jev](#jev-status) judgment log in place, one more short `python3` call reads its status — cached, so it costs the same interpreter startup either way. The [sleep](#sleep-status) probe likewise runs at most once per 15 s — every other render reads its cache in plain bash, no interpreter.)
- **Graceful degradation** — no git repo, detached HEAD, missing `python3`, or malformed input never breaks the line. Usage segments appear only when the data is present.
- **No dependencies beyond the basics** — `bash`, `python3`, `git`. Works on macOS, Linux, and WSL.
- **Monorepo friendly** — nested repos are detected from the actual git worktree, so the repo name is always the repo you are in, not the folder you launched from.

## What it shows

| Segment | Color | Behavior |
|---|---|---|
| git branch | cyan | Current branch; falls back to the short SHA on detached HEAD. Hidden outside a git repo. |
| repo name | green | Basename of the git worktree root; directory basename when not in a repo. |
| model | magenta | `model.display_name` from the statusline JSON. |
| context usage | default < 50%, yellow ≥ 50%, red ≥ 80% | `ctx <pct>%` — `context_window.used_percentage`, rounded to an integer. Also red whenever `exceeds_200k_tokens` is set. Hidden when absent (e.g. before the first API response). |
| sleep status | yellow when kept awake, dim otherwise | `caffeinate` / `no-sleep` / `sleep off` / `sleep on` — whether the machine will idle-sleep or is being kept awake, and by what. macOS only; hidden elsewhere. See [sleep status](#sleep-status). |
| quota reset | same thresholds as context usage | The rate-limit window with the earliest `resets_at` among `rate_limits.five_hour` / `seven_day` / `spend_limit`: `<label> quota <pct>% → <local reset time>`. Labels: `5h`, `7d`, `spend`. Reset time is `HH:MM` today, `MM/DD HH:MM` otherwise. Present for Claude.ai Pro/Max subscribers or behind a Claude apps gateway, after the first API response; hidden otherwise. Falls back to the [GLM quota](#glm-zai-quota) when routing through a glm endpoint. |
| jev status | red when the latest judgment is block, yellow when escalate/warn, dim when idle |  `jev <state> <pass> <block> <escalate> [!<failed>]` - mirrors the [jev-mcp](https://github.com/takezou621/jev-mcp) judgment log: today's real-judgment counts and the latest judgment's action, read from the log (no network). Hidden when the log directory does not exist; see [jev status](#jev-status). |

## GLM (Z.AI) quota

When Claude Code sends no `rate_limits` (no Claude.ai subscription in play) **and** the session routes through a glm endpoint, the script fetches the GLM Coding Plan quota instead and shows it as the same segment with the label `glm`:

```
 fix/issue-404-apply-fallback |  cloudlegal-word-addin |  glm-5.3[1m] |  ctx 21% |  glm quota 42% → 15:54
```

- **Detection** (any of): the session's model name starts with `glm` (case-insensitive); `ANTHROPIC_BASE_URL` points at `z.ai` / `bigmodel.cn` **or at a local address** (a routing proxy); or `CLAUDE_STATUSLINE_GLM_HOST` is set.
- **Host resolution**: `CLAUDE_STATUSLINE_GLM_HOST` if set; otherwise the origin of `ANTHROPIC_BASE_URL` when it points at z.ai / bigmodel.cn **or at a local address** (`127.*`, `localhost`, `[::1]` — treated as a routing proxy expected to forward `/api/monitor/...` and inject auth); otherwise `https://api.z.ai`.
- **Token**: `CLAUDE_STATUSLINE_GLM_TOKEN` first (dedicated, so it never interferes with `ANTHROPIC_AUTH_TOKEN` / subscription OAuth on other routes), then `ANTHROPIC_AUTH_TOKEN`, then `ANTHROPIC_API_KEY` — sent raw in the `Authorization` header per Z.AI's monitor API. With no token the request is sent unauthenticated, which works when a local routing proxy injects auth. Nothing is sent anywhere except the resolved quota host.
- **Fast + polite**: `GET /api/monitor/usage/quota/limit` with a 3s timeout, cached to `${TMPDIR:-/tmp}/claude-statusline-glm.json` for 2 minutes — renders stay local; the API is hit at most once per TTL. Requires `curl`.
- **Timezone**: reset times (Claude windows and GLM alike) always render in the OS-configured timezone — the script clears any inherited `TZ` env var and lets Python fall back to `/etc/localtime`, so the display never drifts when Claude Code is launched from a terminal or launcher that sets `TZ`.
- **Graceful**: network failure, malformed response, or missing env simply hides the segment.

## jev status

When the [jev-mcp](https://github.com/takezou621/jev-mcp) judgment log exists at `~/.jev/logs`, the status line mirrors what jev is doing:

```
 jev ok 12 1 0 |  jev block 12 1 0 |  jev escalate 12 1 2 |  jev warn 12 1 0 |  jev idle 12 1 0 |  jev escalate 4 0 4 !1
```

- **Format**: ` jev <state> <pass> <block> <escalate> [!<failed>]` - today's real-judgment counts from the log (`~/.jev/logs/jev-YYYY-MM-DD.jsonl`, local day, as jev-mcp names it) plus the latest judgment's action as the state. `warn` (a pass carrying a note) is counted in the pass slot. The `!` count appears only when the day has failed judgments - jev fails open, so this is the only visible trace of a judge outage. The color follows the latest judgment's action: default = pass, yellow = warn / escalate, red = block, dim = `idle`.
- **States**: `ok` (latest judgment passed), `warn` (passed with a note), `escalate` (passed but routed to a human - check the review queue), `block` (the change was blocked), `idle` (no real judgment in the last 15 minutes).
- **Real judgments only**: entries from jev's own test suites and smoke runs log stub model values (`stub` / `test-stub` / `dev-stub` / `stub-N`) and never count. The log itself is sensitive (`0600`) and carries the judge's probabilities - the scan matches only line shapes, actions and timestamps; the probabilities and evidence paths are never parsed or displayed.
- **Entirely local**: reads the log file - no network, no `node` process, no `curl`.
- **Cached**: parsed once and cached to `${TMPDIR:-/tmp}/claude-statusline-jev-<uid>.json` (per-user file, created `0600` with `O_NOFOLLOW`), keyed on the log path, mtime and size - re-renders between log writes cost one cache read, and the entry goes stale to `idle` when no judgment lands for 15 minutes.
- **Path override**: set `CLAUDE_STATUSLINE_JEV_DIR` if the log lives elsewhere. The segment disappears entirely when the log directory does not exist (jev-mcp not in use yet).

## Sleep status

macOS only. The segment reports whether the machine will idle-sleep or is being kept awake, and by what:

| State | Meaning |
|---|---|
| `caffeinate` | A `caffeinate` process is running (any flags). |
| `no-sleep` | Another process holds a sleep-prevention assertion (`pmset -g assertions`: `PreventSystemSleep` or `PreventUserIdleSystemSleep`) — e.g. `coreaudiod` while audio is captured. |
| `sleep off` | The power-manager setting disables sleep entirely (every `sleep N` line in `pmset -g` is `0`). |
| `sleep on` | No prevention — the system will idle-sleep normally. |

- **Kept-awake states render in yellow** — a long-running job may assume the machine stays up; plain `sleep on` renders dim, background-information style.
- **Priority**: `caffeinate` beats `no-sleep` beats `sleep off`; only when none holds does the segment read `sleep on`. A display-sleep-only assertion keeps the screen, not the system, awake, so it still reads `sleep on` — and so does powerd's ever-present "Prevent sleep while display is on" assertion, which just reflects that the display is on (ordinary active use), so it is ignored.
- **Cached**: at most one probe per 15 s — every other render reads the small cache file (`${TMPDIR:-/tmp}/claude-statusline-sleep-<uid>.txt`, created `0600` with `O_NOFOLLOW`) in plain bash, with no interpreter start.
- **Graceful**: hidden entirely where `pmset`/`pgrep` are unavailable (Linux, WSL, containers).

## Sleep toggle

The companion script `sleep-toggle.sh` flips the caffeinate-based prevention on and off and clears the status line's 15 s cache, so the very next render already shows the flipped state:

```bash
curl -fsSL -o ~/.claude/sleep-toggle.sh \
  https://raw.githubusercontent.com/takezou621/claude-statusline/main/sleep-toggle.sh
chmod +x ~/.claude/sleep-toggle.sh
bash ~/.claude/sleep-toggle.sh    # prints "sleep prevention: ON/OFF" + state before -> after
```

- **What it toggles**: only the caffeinate process — one call starts a persistent `caffeinate -dis`, the next stops every caffeinate. Other processes' `no-sleep` assertions (`coreaudiod`, Handoff, a running call) are reported in the resulting state but never touched, and the system `sleep off`/`sleep on` setting is out of scope (`sudo pmset -a sleep <minutes>` changes it).
- **From inside Claude Code**: save `~/.claude/commands/sleep-toggle.md` to get a `/sleep-toggle` slash command:

  ```markdown
  ---
  description: Toggle sleep prevention (the status line's sleep segment)
  allowed-tools: Bash(bash ~/.claude/sleep-toggle.sh)
  ---
  !bash ~/.claude/sleep-toggle.sh
  ```

- **As a plain shortcut**: `alias sleep-toggle='bash ~/.claude/sleep-toggle.sh'` in your shell rc, or bind that command to a key in your terminal of choice — the script prints the before/after state in one line.

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
