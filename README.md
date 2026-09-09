# pairwalk

A [herdr](https://herdr.dev) plugin that turns one hotkey into a full plan→execute pipeline:
a **worktree**, a **Fable orchestrator** (Claude Code), and a cheap **OMP executor** in a split pane —
with an escalation ladder so the expensive model only touches the hard 5%.

```
prefix+shift+w
  └─ popup: repo (auto-detected) + branch
      └─ worktree created (werksfeer hooks run)
          └─ Claude Code starts in the worktree (permissions bypassed, trust auto-accepted)
              └─ kickoff contract submitted: plan → spawn → monitor → verify
                  └─ you paste the task
                      ├─ planner investigates read-only, writes PLAN.md
                      ├─ spawns the OMP executor split (cheap model, yolo)
                      │    └─ fails a step twice? → escalates that step to the orchestrator
                      └─ verifies the diff against acceptance criteria and reports
```

## Install

Local development:

```sh
herdr plugin link /path/to/herdr-pairwalk
```

From GitHub (once this repo is pushed):

```sh
herdr plugin install <owner>/herdr-pairwalk
```

Then bind keys in `~/.config/herdr/config.toml`:

```toml
[[keys.command]]
key = "prefix+shift+w"
type = "plugin_action"
command = "rick.pairwalk.start"
description = "pairwalk: new task in worktree"

[[keys.command]]
key = "prefix+shift+p"
type = "plugin_action"
command = "rick.pairwalk.spawn"
description = "pairwalk: spawn executor for PLAN.md"

[[keys.command]]
key = "prefix+shift+r"
type = "plugin_action"
command = "rick.pairwalk.release"
description = "pairwalk: release executor pane"
```

## Commands

| Action / CLI | What it does |
|---|---|
| `start` (`prefix+shift+w`) | Popup: worktree + orchestrator + kickoff, all automatic |
| `spawn` (`prefix+shift+p`) | Split an executor pane off the caller for an existing `PLAN.md` |
| `release` (`prefix+shift+r`) | Close the executor pane, drop its state |
| `status` | Show recorded tasks/executors and live pairwalk agents |
| `doctor` | Check binaries, config, and state health |
| `config` | Print effective configuration |

Headless equivalents (usable from any agent pane): `bash pairwalk.sh dialog|spawn|runner-for|release|status|doctor|config`.

## Configuration

`pairwalk.conf` in the plugin config dir (`herdr plugin config-dir rick.pairwalk`,
default `~/.config/herdr/plugins/config/rick.pairwalk/pairwalk.conf`), created on first run:

| Key | Default | Meaning |
|---|---|---|
| `MODEL` | `openrouter/z-ai/glm-5.3-flash:low` | Executor (OMP) model — runs directly, prewalk disabled |
| `APPROVAL_MODE` | `yolo` | Executor approval mode (`write`/`always-ask` still auto-accepts startup dialogs) |
| `PLAN_FILE` | `PLAN.md` | Plan contract the orchestrator must write |
| `DIRECTION` | `right` | Executor split direction |
| `AGENT_KIND` | `omp` | Executor agent kind |
| `ORCHESTRATOR_KIND` | `claude` | Orchestrator agent kind |
| `ORCHESTRATOR_MODEL` | *(empty)* | Passed as `--model` to the orchestrator. **Empty = your own Claude default** (`~/.claude/settings.json` → e.g. `claude-fable-5-1[1m]`). Find ids via `/model` in Claude. |

Per-run overrides: `pairwalk.sh spawn --model <id>`, `dialog --repo <path> --branch <name> --cwd <path>`.

## Safety model

- **One writer per worktree.** The orchestrator is read-only while the executor runs;
  spawn refuses a second executor in the same worktree.
- **Worktree-bound agent names.** Agents are `planner-<branch-slug>` / `runner-<branch-slug>`,
  so a name can never belong to two concurrent worktrees, and every reply path verifies
  the target's cwd before sending (`runner-for`, `agent get` cwd checks).
- **`PLAN.md` is never committed** — both sides are contract-bound to ignore it in git.
- **Startup dialogs are auto-accepted** (folder trust, bypass-permissions confirm) with
  screen verification before keys are sent.

## Escalation ladder

Executor todo item fails twice → the runner escalates that one step to the orchestrator
(`ESCALATE <item> … --wait`), does nothing meanwhile; the orchestrator implements that step
itself, validates, replies `ESCALATION DONE`, returns to read-only monitoring; the runner
re-validates and continues. Items marked `[gate]` in the plan escalate after the *first*
failure. Cheap model does the volume; the expensive model handles the tail.

## Troubleshooting

- `~/.config/herdr/plugins/config/rick.pairwalk/last-error.log` — every popup failure, timestamped.
- `context-debug.log` — raw herdr context the popup received per run.
- `pairwalk.sh status` / `doctor` for state and dependency checks.
- If a Claude pane shows "Update installed · Restart to update", restart that pane when convenient.

## Uninstall

```sh
herdr plugin unlink rick.pairwalk   # or: herdr plugin uninstall rick.pairwalk
```
