# herdr-pairwalk

A [herdr](https://herdr.dev) plugin that turns one hotkey into a complete plan→execute pipeline:
a **git worktree**, a **Fable orchestrator** (Claude Code), and a cheap **OMP executor** in a split
pane — with an escalation ladder so the expensive model only touches the hard 5%.

```
prefix+shift+w
  └─ popup: repo (auto-detected) + branch
      └─ worktree created (your worktree hooks run)
          └─ Claude Code starts in the worktree (permissions bypassed, trust auto-accepted)
              └─ kickoff contract submitted: plan → spawn → monitor → verify
                  └─ you paste the task
                      ├─ planner investigates read-only, writes PLAN.md
                      ├─ spawns the OMP executor split (cheap model, yolo)
                      │    └─ a step fails twice? → escalates that step to the orchestrator
                      ├─ verifies the diff against acceptance criteria and reports DONE
                      └─ follow-up tweaks loop through the same pipeline
```

Cheap model does the volume; the expensive model plans, verifies, and handles the hard 5%.

---

## Getting started

- [herdr](https://herdr.dev) **0.7.4+** with the herdr CLI on `PATH`
- OMP (`omp` binary on `PATH`) — the executor
- [Claude Code](https://claude.com/claude-code) (`claude` binary) — the orchestrator
- `python3` and `git`

Check everything at once:

```sh
bash pairwalk.sh doctor
```

### Install

From GitHub:

```sh
herdr plugin install Kuret/herdr-pairwalk
```

Or link a local checkout while hacking on it:

```sh
herdr plugin link /path/to/herdr-pairwalk
```

The plugin registers as `rick.pairwalk` with four actions (`start`, `spawn`, `release`, `status`)
and a popup pane. Bind keys in `~/.config/herdr/config.toml`:

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

Run `herdr server reload-config` (or restart herdr) and you're set.

### Configure

Everything lives in `pairwalk.conf`, created on first run:

```sh
herdr plugin config-dir rick.pairwalk
# → ~/.config/herdr/plugins/config/rick.pairwalk/pairwalk.conf
```

| Key | Default | Meaning |
|---|---|---|
| `MODEL` | `openrouter/z-ai/glm-5.3-flash:low` | Executor (OMP) model. Any model id or OMP alias/role. Prewalk is disabled for the executor — the plan already exists. |
| `APPROVAL_MODE` | `yolo` | Executor approval mode. pairwalk is designed for isolated herdr worktrees; use `write`/`always-ask` if you want more friction. |
| `PLAN_FILE` | `PLAN.md` | The plan contract the orchestrator must write before spawning. |
| `DIRECTION` | `right` | Executor split direction (`right`/`down`). |
| `AGENT_KIND` | `omp` | Executor agent kind. |
| `ORCHESTRATOR_KIND` | `claude` | Orchestrator agent kind. |
| `ORCHESTRATOR_MODEL` | *(empty)* | Passed as `claude --model <id>` when set. **Empty = your own Claude default** (`~/.claude/settings.json`, e.g. `claude-fable-5-1[1m]`). Discover ids via `/model` inside Claude. |

Per-run overrides: `pairwalk.sh spawn --model <id>`,
`pairwalk.sh dialog --repo <path> --branch <name> --cwd <path>`.

Inspect the effective configuration anytime:

```sh
bash pairwalk.sh config
```

### First run

1. Focus any pane inside the repo you want to work on (or any pane — you can type the repo path).
2. Press `prefix+shift+w`. A popup shows the detected repo and asks only for a branch
   (enter accepts the generated `rick/pairwalk-MMDD-HHMM`).
3. Everything else is automatic (~10s): worktree created → orchestrator started →
   trust dialogs auto-accepted → kickoff contract submitted.
4. **Paste your task** into the orchestrator pane and hit enter. Done — the pipeline
   takes it from there (see [The workflow](#the-workflow)).

---

## The workflow

This is the full lifecycle of a pairwalk task, what happens automatically, and where you act.

### 1. New task — `prefix+shift+w`

You press the hotkey from any pane inside a git repo. The popup asks only for a branch.
Pairwalk then, without further input:

1. creates the worktree (`~/.herdr/worktrees/<repo>/<branch>`) — your worktree hooks run;
2. starts Claude Code there with `--dangerously-skip-permissions`, auto-accepting the
   folder-trust and bypass-permissions dialogs (screen-verified, retried if a key is eaten);
3. submits the orchestrator contract: plan → spawn → monitor → verify → follow-ups;
4. focuses the new workspace with the orchestrator waiting at an empty prompt.

### 2. Fire the task

Paste your task into the orchestrator pane. It then:

1. investigates the repo **read-only**;
2. writes `PLAN.md` at the worktree root — numbered, dependency-ordered items, each with
   outcome, area, validation, and a natural commit seam, plus assumptions and acceptance
   criteria. This file is the plan contract and the orchestrator's *only* write;
3. runs `pairwalk.sh spawn` — an executor pane splits off (OMP, cheap model, `yolo`,
   prewalk off) and receives the plan as its implementation contract;
4. resolves its own runner via `runner-for` (worktree-bound name) and monitors it.

### 3. Execution — the cheap model grinds

The executor runs `todo init` from `PLAN.md` and executes item by item:

- works along the plan's commit seams, runs each item's stated validation;
- **escalation ladder**: an item that fails twice is escalated to the orchestrator — the
  runner sends `ESCALATE <item> … --wait`, edits nothing while the orchestrator (your
  expensive model) implements exactly that step, validates it, and hands back with
  `ESCALATION DONE`. The runner re-validates and continues. Items marked `[gate]` in the
  plan skip the retry and escalate after the first failure;
- items that cannot be escalated (no orchestrator channel) are marked `BLOCKED` and the
  runner moves on.

You watch it all in the herdr sidebar (`working` / `blocked` / `done` per pane); the
orchestrator reviews diffs between seams and sends corrections to the runner.

### 4. Verification and report

When the executor finishes, the orchestrator verifies the cumulative diff against the
plan's acceptance criteria and reports `DONE`. It then **stays alive** — the session is
not a one-shot.

### 5. Follow-ups

Paste a tweak or follow-up question into the orchestrator pane. It:

1. investigates read-only;
2. amends `PLAN.md` — new numbered items under a `## Follow-ups` section (or amends
   existing ones) — still its only write;
3. hands execution back to the same runner pane (`FOLLOWUP: …`, context retained) — or
   re-spawns a fresh executor if the old one was released;
4. monitors, verifies, reports — the escalation ladder applies unchanged.

If you paste a tweak into the **runner** pane by mistake, it does not improvise: it
forwards `FOLLOWUP REQUEST: <tweak>` to the orchestrator and waits.

### 6. Finish

- `prefix+shift+r` in the orchestrator pane — closes the executor pane, drops its state.
- Push and open a PR as usual.
- `herdr worktree remove --workspace <id>` — worktree hooks clean up after themselves.

### Concurrency

Run as many pairwalk tasks as you like, in parallel: every worktree gets its own
branch-bound agents (`planner-<branch-slug>`, `runner-<branch-slug>`), so prompts can
never cross between flows. One writer per worktree is enforced — a second `spawn` in the
same worktree refuses.

### Small tasks

For self-contained work that doesn't need an orchestrator, skip the popup and just run
OMP in a worktree pane — pairwalk only structures the multi-agent flow when you ask for it.

---

## Safety model

- **One writer per worktree**, enforced at spawn time.
- **Worktree-bound agent names** — cross-worktree misdelivery is impossible; every reply
  path verifies the target's cwd before sending.
- **`PLAN.md` is never committed** — both sides are contract-bound to ignore it in git.
- **Approval defaults are deliberately loose** (`yolo`) because pairwalk runs in isolated
  herdr worktrees; tighten via `APPROVAL_MODE` if you prefer.

## Troubleshooting

- `~/.config/herdr/plugins/config/rick.pairwalk/last-error.log` — every popup failure, timestamped.
- `context-debug.log` — raw herdr context the popup received per run.
- `pairwalk.sh status` / `doctor` for state and dependency checks.
- A runner that finishes while the orchestrator waits: monitor waits use herdr's settled
  states (idle/done/blocked) — never `--until blocked` alone.

## Uninstall

```sh
herdr plugin uninstall rick.pairwalk
```