#!/usr/bin/env bash
# pairwalk — one-hotkey orchestrator→executor handoff for herdr.
#
# open-dialog  Open the "new task" popup (bound to a key).
# dialog       Popup flow: repo → worktree → Claude orchestrator → kickoff.
# spawn        Split an executor pane off the caller and hand it PLAN.md.
# runner-for   Print the executor agent name bound to the caller's worktree.
# release      Close the executor pane and drop its state entry.
# status       Show pairwalk tasks and live agents.
#
# Agent names are branch-bound (planner-<branch-slug> / runner-<branch-slug>)
# so they can never collide across concurrent worktrees.
#
# Config: pairwalk.conf (KEY=value) in the plugin config dir.
set -euo pipefail

PLUGIN_ID="rick.pairwalk"
HERDR="${HERDR_BIN_PATH:-herdr}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_MODEL="openrouter/z-ai/glm-5.3-flash"

die() { printf 'pairwalk: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
have "$HERDR" || die "herdr binary not found ($HERDR)"
have python3 || die "python3 required for JSON parsing"

# jget <json> <dotted.path> — print value, exit 1 when missing.
jget() {
  python3 - "$1" "$2" <<'PY'
import json, sys
try:
    obj = json.loads(sys.argv[1])
except Exception:
    sys.exit(1)
cur = obj
for part in sys.argv[2].split("."):
    if isinstance(cur, dict) and part in cur:
        cur = cur[part]
    else:
        sys.exit(1)
if cur is None:
    sys.exit(1)
print(cur if isinstance(cur, str) else json.dumps(cur))
PY
}

# first_json <json> <path> [path...] — first path that resolves.
first_json() {
  local json="$1"; shift
  local p
  for p in "$@"; do
    if jget "$json" "$p" >/dev/null 2>&1; then jget "$json" "$p"; return 0; fi
  done
  return 1
}

config_dir() {
  if [ -n "${HERDR_PLUGIN_CONFIG_DIR:-}" ]; then printf '%s\n' "$HERDR_PLUGIN_CONFIG_DIR"; return; fi
  local d
  d="$("$HERDR" plugin config-dir "$PLUGIN_ID" 2>/dev/null | tail -1 || true)"
  [ -n "$d" ] && { printf '%s\n' "$d"; return; }
  printf '%s\n' "$HOME/.config/herdr/plugins/config/$PLUGIN_ID"
}

CONF_DIR="$(config_dir)"
mkdir -p "$CONF_DIR"
STATE_FILE="$CONF_DIR/state.json"
CONF_FILE="$CONF_DIR/pairwalk.conf"

if [ ! -f "$CONF_FILE" ]; then
  cat > "$CONF_FILE" <<EOF
# pairwalk configuration (KEY=value, no spaces in values)
# Executor model (runs directly; prewalk is disabled for the executor):
MODEL=$DEFAULT_MODEL
# Executor approval mode: yolo (isolated worktrees) | write | always-ask
APPROVAL_MODE=yolo
PLAN_FILE=PLAN.md
DIRECTION=right
AGENT_KIND=omp
# Orchestrator agent kind and optional model (empty = Claude's own default,
# pick Fable inside Claude once and it sticks):
ORCHESTRATOR_KIND=claude
ORCHESTRATOR_MODEL=
EOF
fi

MODEL="$DEFAULT_MODEL"; APPROVAL_MODE="yolo"; PLAN_FILE="PLAN.md"; DIRECTION="right"; AGENT_KIND="omp"
ORCHESTRATOR_KIND="claude"; ORCHESTRATOR_MODEL=""
while IFS='=' read -r k v; do
  case "$k" in
    MODEL|APPROVAL_MODE|PLAN_FILE|DIRECTION|AGENT_KIND|ORCHESTRATOR_KIND|ORCHESTRATOR_MODEL) printf -v "$k" '%s' "$v" ;;
  esac
done < <(grep -v '^[[:space:]]*#' "$CONF_FILE" | grep -v '^[[:space:]]*$' || true)

slug_for_branch() { # branch → lowercase slug, max 22 chars (fits name limit with suffixes)
  python3 - "$1" <<'PY'
import re, sys
s = re.sub(r'[^a-z0-9]+', '-', sys.argv[1].lower()).strip('-')[:22].strip('-')
print(s or "task")
PY
}

# agent_names — assigned agent names of all live agents, one per line.
agent_names() {
  "$HERDR" agent list 2>/dev/null | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
for a in d.get("result",{}).get("agents",[]):
    n=a.get("name")
    if n: print(n)
' || true
}

pick_name() { # pick_name <prefix> — prefix must already be worktree-unique
  local prefix="$1" names candidate n
  names="$(agent_names)"
  candidate="$prefix"; n=2
  while printf '%s\n' "$names" | grep -qx "$candidate"; do
    candidate="$prefix-$n"; n=$((n+1))
  done
  printf '%s\n' "$candidate"
}

live_agent_in() { # live_agent_in <prefix> <cwd> — first live agent name
  local listing
  listing="$("$HERDR" agent list 2>/dev/null || true)"
  [ -n "$listing" ] || return 0
  python3 - "$1" "$2" "$listing" <<'PY'
import json, sys
prefix, want, data = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    d = json.loads(data)
except Exception:
    raise SystemExit(0)
for a in d.get("result", {}).get("agents", []):
    n = a.get("name") or ""
    if n.startswith(prefix) and a.get("cwd") == want:
        print(n)
        break
PY
}

state_read() { [ -f "$STATE_FILE" ] && cat "$STATE_FILE" || printf '{}' ; }

state_set() { # state_set <key> <field=value>... — merge entry
  local key="$1"; shift
  python3 - "$STATE_FILE" "$key" "$@" <<'PY'
import json, sys, time
path, key = sys.argv[1], sys.argv[2]
fields = dict(kv.split("=", 1) for kv in sys.argv[3:])
try: data = json.load(open(path))
except Exception: data = {}
e = data.get(key, {})
e.update(fields); e["started_at"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
data[key] = e
json.dump(data, open(path, "w"), indent=1)
PY
}

state_drop() {
  local key="$1"
  python3 - "$STATE_FILE" "$key" <<'PY'
import json, sys
path, key = sys.argv[1], sys.argv[2]
try: data = json.load(open(path))
except Exception: data = {}
data.pop(key, None)
json.dump(data, open(path, "w"), indent=1)
PY
}

state_field() { jget "$(state_read)" "$1.$2" || true; }

state_drop_by_pane() { # remove every entry whose pane == $1
  python3 - "$STATE_FILE" "$1" <<'PY'
import json, sys
path, pane = sys.argv[1], sys.argv[2]
try: data = json.load(open(path))
except Exception: data = {}
data = {k: v for k, v in data.items() if v.get("pane") != pane}
json.dump(data, open(path, "w"), indent=1)
PY
}

# ---- spawn (executor) ----

resolve_caller() {
  if [ -n "${ARG_PANE:-}" ]; then CALLER="$ARG_PANE"; return; fi
  CALLER="${HERDR_PANE_ID:-}"
  if [ -z "$CALLER" ] && [ -n "${HERDR_PLUGIN_CONTEXT_JSON:-}" ]; then
    CALLER="$(first_json "$HERDR_PLUGIN_CONTEXT_JSON" focused_pane_id pane.pane_id pane_id focused_pane.pane_id || true)"
  fi
  [ -n "$CALLER" ] || die "cannot resolve calling pane; pass --pane <ID> (or run inside a herdr pane)"
}

resolve_cwd() {
  if [ -n "${ARG_CWD:-}" ]; then WORKDIR="$ARG_CWD"; return; fi
  local ctx="${HERDR_PLUGIN_CONTEXT_JSON:-}"
  if [ -n "$ctx" ]; then
    WORKDIR="$(first_json "$ctx" focused_pane_cwd workspace_cwd pane.foreground_cwd pane.cwd worktree.checkout_path worktree.repo_root || true)"
  fi
  if [ -z "${WORKDIR:-}" ]; then
    local info
    info="$("$HERDR" pane get "$CALLER" 2>/dev/null)" || die "cannot read pane $CALLER"
    WORKDIR="$(first_json "$info" result.pane.foreground_cwd result.pane.cwd || true)"
  fi
  [ -n "${WORKDIR:-}" ] || die "cannot resolve worktree cwd; pass --cwd <PATH>"
  [ -d "$WORKDIR" ] || die "resolved cwd does not exist: $WORKDIR"
}

cmd_spawn() {
  resolve_caller
  resolve_cwd
  local plan="$WORKDIR/$PLAN_FILE"
  [ -f "$plan" ] || die "no $PLAN_FILE in $WORKDIR — the orchestrator must write the plan first"

  # Resolve the task entry for this caller pane: orchestrator name + branch.
  local tent tkey="" orch="" tbranch=""
  tent="$(python3 - "$STATE_FILE" "$CALLER" <<'PY'
import json, sys
try: data = json.load(open(sys.argv[1]))
except Exception: raise SystemExit(0)
for k, v in data.items():
    if v.get("role") == "task" and v.get("pane") == sys.argv[2]:
        print(k); print(v.get("agent", "")); print(v.get("branch", "")); break
PY
)"
  tkey="$(printf '%s' "$tent" | sed -n '1p')"
  orch="$(printf '%s' "$tent" | sed -n '2p')"
  tbranch="$(printf '%s' "$tent" | sed -n '3p')"

  local busy
  busy="$(live_agent_in runner "$WORKDIR")"
  [ -n "$busy" ] && die "executor '$busy' already running in $WORKDIR — one writer per worktree; run 'pairwalk.sh release' or wait"

  # Worktree-unique name: bound to the branch so cross-worktree collisions are impossible.
  local bslug; bslug="$(slug_for_branch "${tbranch:-$WORKDIR}")"
  local name; name="$(pick_name "runner-$bslug")"
  local split_json newpane
  split_json="$("$HERDR" pane split --pane "$CALLER" --direction "$DIRECTION" --cwd "$WORKDIR" --no-focus)" \
    || die "pane split failed: $split_json"
  newpane="$(first_json "$split_json" result.pane.pane_id result.pane_id)" || die "cannot read new pane id"

  state_set "$CALLER" role=executor pane="$newpane" agent="$name" cwd="$WORKDIR" plan="$PLAN_FILE" model="$MODEL" orchestrator="$orch" task_key="$tkey"

  if ! "$HERDR" agent start "$name" --kind "$AGENT_KIND" --pane "$newpane" --timeout 60000 \
       -- --no-prewalk --model "$MODEL" --approval-mode "$APPROVAL_MODE"; then
    die "agent start not ready yet (pane $newpane). Retry the prompt manually:
  $HERDR agent prompt $name \"Execute the plan in $PLAN_FILE\" --wait
or clean up: bash $0 release"
  fi

  local esc_clause
  if [ -n "$orch" ]; then
    esc_clause="$(printf 'ESCALATION LADDER: a todo item that fails twice (you attempted one fix after the initial failure and its validation still fails) is not yours to grind on. Immediately run: herdr agent prompt %s "ESCALATE <item> (reply to agent %s): <one-line summary of both failures>" --wait --timeout 1800000 — and pass timeout 1800 to the bash call so it can block. While escalated you own nothing and edit nothing; the orchestrator works the worktree. When the call returns, re-read the orchestrator%s reply in this conversation, re-run that item%s validation yourself, then continue with the remaining items. Items marked [gate] in the plan skip the retry: escalate after the FIRST failure.' \
      "$orch" "$name" "'" "'")"
  else
    esc_clause="ESCALATION LADDER: no escalation target is available. If a todo item fails twice, mark it BLOCKED in your report and continue with the remaining items."
  fi

  local prompt
  prompt="$(printf 'You are pairwalk executor agent %s, bound to this worktree: only act on prompts addressed to your name. Execute the plan in %s (repo root = current directory). First run todo init from its numbered items and treat that list as the implementation contract. Do not re-plan or re-architect; adapt small implementation details only, and if a core assumption is false, stop and report the mismatch instead of inventing a new design. Work along the plan%s natural commit seams and run each item%s stated validation. Never commit or stage %s. The orchestrator pane stays read-only while you execute: you own all edits in this worktree. %s' \
    "$name" "$PLAN_FILE" "'" "'" "$PLAN_FILE" "$esc_clause")"
  if ! "$HERDR" agent prompt "$name" "$prompt"; then
    die "prompt submission failed for '$name' (pane $newpane). Send it manually:
  $HERDR agent prompt $name \"Execute the plan in $PLAN_FILE\" --wait"
  fi

  "$HERDR" pane report-metadata "$newpane" --source "$PLUGIN_ID" --title "pairwalk ▸ $PLAN_FILE" 2>/dev/null || true

  printf '{"agent":"%s","pane":"%s","caller":"%s","cwd":"%s","plan":"%s","model":"%s","orchestrator":"%s"}\n' \
    "$name" "$newpane" "$CALLER" "$WORKDIR" "$PLAN_FILE" "$MODEL" "$orch"
}

# ---- runner-for (worktree-bound executor resolution) ----

cmd_runner_for() {
  local wt="${ARG_CWD:-}"
  local ctx="${HERDR_PLUGIN_CONTEXT_JSON:-}"
  if [ -z "$wt" ] && [ -n "$ctx" ]; then
    wt="$(first_json "$ctx" focused_pane_cwd workspace_cwd pane.foreground_cwd pane.cwd worktree.checkout_path worktree.repo_root || true)"
  fi
  if [ -z "$wt" ] && [ -n "${HERDR_PANE_ID:-}" ]; then
    local info
    info="$("$HERDR" pane get "${HERDR_PANE_ID}" 2>/dev/null || true)"
    wt="$(first_json "$info" result.pane.foreground_cwd result.pane.cwd || true)"
  fi
  [ -n "$wt" ] || die "cannot resolve worktree; pass --cwd <PATH>"
  wt="$(git -C "$wt" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$wt")"
  python3 - "$STATE_FILE" "$wt" "$HERDR" <<'PY'
import json, sys, subprocess, os
path, want, herdr = sys.argv[1], sys.argv[2], sys.argv[3]
try: data = json.load(open(path))
except Exception: raise SystemExit(1)
for k, v in data.items():
    if v.get("role") == "executor" and v.get("cwd") == want:
        name = v.get("agent")
        if not name: continue
        r = subprocess.run([herdr, "agent", "get", name], capture_output=True, text=True)
        if '"agent_status"' in (r.stdout + r.stderr):
            print(name); raise SystemExit(0)
raise SystemExit(1)
PY
}

# ---- release / status ----

cmd_release() {
  local target="${1:-}"
  resolve_caller || true
  if [ -z "$target" ]; then
    target="$(state_field "$CALLER" pane)"
    [ -n "$target" ] || die "no pairwalk executor recorded for pane $CALLER; pass a pane or agent id"
  fi
  local pane="$target" info
  case "$target" in
    *:p*) : ;;
    *) info="$("$HERDR" agent get "$target" 2>/dev/null || true)"
       pane="$(first_json "$info" result.agent.pane_id result.pane_id || true)" ;;
  esac
  [ -n "$pane" ] || die "cannot resolve executor pane from '$target'"
  "$HERDR" pane close "$pane" || die "closing pane $pane failed"
  state_drop_by_pane "$pane"
  printf 'pairwalk: released executor pane %s\n' "$pane"
}

cmd_status() {
  python3 - "$STATE_FILE" <<'PY'
import json, sys, os
try: data = json.load(open(sys.argv[1]))
except Exception: data = {}
if not data:
    print("pairwalk: nothing recorded")
for key, e in data.items():
    role = e.get("role", "executor")
    print(f"[{role}] {key} -> agent={e.get('agent')} pane={e.get('pane')} cwd={e.get('cwd')} model={e.get('model')} started={e.get('started_at')}")
PY
  local listing
  listing="$("$HERDR" agent list 2>/dev/null || true)"
  [ -n "$listing" ] || return 0
  python3 - "$listing" <<'PY'
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    raise SystemExit(0)
for a in d.get("result", {}).get("agents", []):
    n = a.get("name") or ""
    if n.startswith("planner-") or n.startswith("runner-"):
        print("live: %s state=%s cwd=%s" % (n, a.get("agent_status"), a.get("cwd")))
PY
}

# ---- doctor / config ----

cmd_config() {
  echo "config file:   $CONF_FILE"
  echo "state file:    $STATE_FILE"
  echo "MODEL=$MODEL                     # executor (omp) model"
  echo "APPROVAL_MODE=$APPROVAL_MODE"
  echo "PLAN_FILE=$PLAN_FILE"
  echo "DIRECTION=$DIRECTION"
  echo "AGENT_KIND=$AGENT_KIND"
  echo "ORCHESTRATOR_KIND=$ORCHESTRATOR_KIND"
  echo "ORCHESTRATOR_MODEL=${ORCHESTRATOR_MODEL:-<empty: claude uses your ~/.claude/settings.json model>}"
}

cmd_doctor() {
  local fail=""
  _pw_check() {
    if have "$2"; then echo "ok    $1"; else echo "MISS  $1 ($2 not on PATH)"; fail=1; fi
  }
  _pw_check "herdr CLI ($HERDR)" "$HERDR"
  _pw_check "python3" python3
  _pw_check "git" git
  [ "$ORCHESTRATOR_KIND" = "claude" ] && _pw_check "claude (orchestrator kind)" claude
  [ "$AGENT_KIND" = "omp" ] && _pw_check "omp (executor kind)" omp
  if [ -f "$CONF_FILE" ]; then echo "ok    config ($CONF_FILE)"; else echo "MISS  config ($CONF_FILE)"; fail=1; fi
  if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$STATE_FILE" 2>/dev/null; then
    echo "ok    state ($STATE_FILE)"
  else
    echo "WARN  state unreadable ($STATE_FILE) — will be recreated"
  fi
  if [ -n "$fail" ]; then echo "doctor: problems found"; exit 1; fi
  echo "doctor: all good"
}

# ---- new-task dialog (popup) ----

pause_fail() {
  printf '\nFAILED: %s\n\nPress enter to close…' "$1"
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$CONF_DIR/last-error.log" 2>/dev/null || true
  read -r || true
  exit 1
}

cmd_open_dialog() {
  exec "$HERDR" plugin pane open --plugin "$PLUGIN_ID" --entrypoint start
}

cmd_dialog() {
  local repo="${ARG_REPO:-}" detected="" probe="${ARG_CWD:-}"
  local ctx="${HERDR_PLUGIN_CONTEXT_JSON:-}"
  if [ -z "$probe" ] && [ -n "$ctx" ]; then
    probe="$(first_json "$ctx" focused_pane_cwd workspace_cwd pane.foreground_cwd pane.cwd foreground_pane.foreground_cwd foreground_pane.cwd foreground_cwd worktree.checkout_path worktree.repo_root || true)"
  fi
  if [ -z "$probe" ] && [ -n "${HERDR_PANE_ID:-}" ]; then
    local info
    info="$("$HERDR" pane get "${HERDR_PANE_ID}" 2>/dev/null || true)"
    probe="$(first_json "$info" result.pane.foreground_cwd result.pane.cwd || true)"
  fi
  if [ -z "$repo" ] && [ -n "$probe" ]; then
    detected="$(git -C "$probe" rev-parse --show-toplevel 2>/dev/null || true)"
  fi
  printf '[%s] ctx=%s probe=%s detected=%s\n' "$(date '+%H:%M:%S')" \
    "${ctx:-<none>}" "${probe:-<none>}" "${detected:-<none>}" \
    >> "$CONF_DIR/context-debug.log" 2>/dev/null || true
  repo="${repo:-$detected}"

  echo "── pairwalk · new task ─────────────────────────────"
  if [ -n "$repo" ]; then
    echo "Repo: $repo"
  else
    echo "No git repo detected from the focused pane${probe:+ ($probe)}."
    printf 'Repo: '
    read -r repo || repo=""
    [ -n "$repo" ] || pause_fail "no repo given — run from a repo pane or pass --repo."
  fi
  [ -d "$repo" ] || pause_fail "repo path does not exist: $repo"
  repo="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$repo")"
  local repo_name; repo_name="$(basename "$repo")"

  local default_branch="rick/pairwalk-$(date +%m%d-%H%M)"
  printf 'Branch [%s]: ' "$default_branch"
  if [ -n "${ARG_BRANCH:-}" ]; then
    BRANCH="$ARG_BRANCH"; echo "$BRANCH"
  elif read -r BRANCH; then
    BRANCH="${BRANCH:-$default_branch}"
  else
    pause_fail "aborted — no branch input."
  fi

  echo
  echo "Creating worktree $repo_name → $BRANCH …"
  local create_json rootpane wsid wt
  create_json="$("$HERDR" worktree create --cwd "$repo" --branch "$BRANCH" 2>&1)" \
    || pause_fail "worktree create failed: $create_json"
  rootpane="$(first_json "$create_json" result.root_pane.pane_id)" || pause_fail "cannot read root pane id"
  wsid="$(first_json "$create_json" result.workspace.workspace_id result.workspace.id result.workspace || true)"
  wt="$(first_json "$create_json" result.root_pane.cwd || true)"
  echo "Worktree ready: $wt (workspace ${wsid:-?})"

  echo "Starting $ORCHESTRATOR_KIND orchestrator …"
  local pslug; pslug="$(slug_for_branch "$BRANCH")"
  local pname start_out pname_ok="" attempt start_args=()
  [ -n "$ORCHESTRATOR_MODEL" ] && start_args+=(--model "$ORCHESTRATOR_MODEL")
  start_args+=(--dangerously-skip-permissions)
  pname="$(pick_name "planner-$pslug")"
  for attempt in 1 2 3 4; do
    if start_out="$("$HERDR" agent start "$pname" --kind "$ORCHESTRATOR_KIND" --pane "$rootpane" --timeout 90000 -- "${start_args[@]}" 2>&1)"; then
      pname_ok=1
    elif printf '%s' "$start_out" | grep -q 'agent_name_taken'; then
      pname="$pname-$((attempt+1))"
      continue
    fi
    break
  done
  if [ -n "$pname_ok" ]; then
    echo "Orchestrator ready."
  else
    echo "Blocked at startup — auto-accepting startup dialogs…"
    local ok="" screen found i
    for attempt in 1 2 3 4; do
      found=""
      for i in $(seq 1 16); do
        screen="$("$HERDR" pane read "$rootpane" --source visible --lines 20 2>/dev/null || true)"
        if printf '%s' "$screen" | grep -qiE 'trust this folder|dangerously|Yes, I accept'; then found=1; break; fi
        if "$HERDR" agent wait "$pname" --until idle --timeout 1 >/dev/null 2>&1; then ok=1; break; fi
        sleep 0.5
      done
      [ -n "$ok" ] && break
      if [ -z "$found" ]; then
        "$HERDR" pane read "$rootpane" --source visible --lines 10 2>/dev/null >> "$CONF_DIR/last-error.log" 2>/dev/null || true
        pause_fail "orchestrator exited or no known dialog found (pane $rootpane). Worktree kept for manual cleanup: herdr worktree remove --workspace ${wsid:-?}"
      fi
      "$HERDR" agent send-keys "$pname" down >/dev/null 2>&1 || true
      sleep 0.6
      "$HERDR" agent send-keys "$pname" enter >/dev/null 2>&1 || true
      sleep 1
      screen="$("$HERDR" pane read "$rootpane" --source visible --lines 20 2>/dev/null || true)"
      if printf '%s' "$screen" | grep -qiE 'trust this folder|Yes, I accept'; then
        "$HERDR" agent send-keys "$pname" enter >/dev/null 2>&1 || true
        sleep 1
      fi
      if "$HERDR" agent wait "$pname" --until idle --timeout 90 >/dev/null 2>&1; then ok=1; break; fi
    done
    if [ -z "$ok" ]; then
      "$HERDR" pane read "$rootpane" --source visible --lines 10 2>/dev/null >> "$CONF_DIR/last-error.log" 2>/dev/null || true
      pause_fail "orchestrator not ready after dialog auto-accept (pane $rootpane). Worktree kept for manual cleanup: herdr worktree remove --workspace ${wsid:-?}"
    fi
    echo "Orchestrator ready."
  fi

  echo "Submitting kickoff prompt …"
  local kickoff
  kickoff="$(printf 'You are pairwalk orchestrator agent %s for the fresh worktree at %s (branch %s, repo %s). The NEXT message I send is the actual task; until then only acknowledge with one short line. On the task: (1) investigate the repo READ-ONLY; (2) write PLAN.md at the worktree root — numbered, dependency-ordered items, each with outcome, area, validation, and natural commit seam, plus assumptions and acceptance criteria; PLAN.md is your ONLY write during planning; (3) run: bash %s/pairwalk.sh spawn — that starts the OMP executor split on the runner model with the plan as its contract; (4) after spawn, resolve YOUR runner and use only that name for all executor commands: RN=$(bash %s/pairwalk.sh runner-for) — never address a runner by guessing from herdr agent list, and never reuse a runner name from memory; monitor with herdr agent wait $RN --until blocked, herdr agent read $RN, review with git diff; corrections via herdr agent prompt $RN "<fix>"; (5) while the executor runs you stay read-only in this worktree — never edit files yourself; (6) when the executor finishes, verify the cumulative diff against the PLAN.md acceptance criteria and report. (7) ESCALATION LADDER: a runner message starting with "ESCALATE <item>" means that item failed twice on the runner and is now yours. You own exactly that item: implement it yourself in the worktree — this temporarily lifts your read-only restriction for that item only — satisfy its stated validation, and if the plan marks it [gate], apply the gating mechanism it references. Before replying, verify the target: herdr agent get <name-from-message> must report cwd inside YOUR worktree; if it does not, do not send — re-resolve with runner-for. When verified, reply: herdr agent prompt <runner-name> "ESCALATION DONE <item>: <what you did>", then return to read-only monitoring. Never commit or stage PLAN.md.' \
    "$pname" "$wt" "$BRANCH" "$repo" "$SCRIPT_DIR" "$SCRIPT_DIR")"
  if ! "$HERDR" agent prompt "$pname" "$kickoff"; then
    pause_fail "kickoff submission failed for '$pname' (pane $rootpane). Send it manually in the orchestrator pane."
  fi

  state_set "$BRANCH" role=task repo="$repo" branch="$BRANCH" pane="$rootpane" workspace="$wsid" agent="$pname" model="$ORCHESTRATOR_MODEL"

  echo
  echo "READY — workspace $wsid is focused with the orchestrator waiting."
  echo "Fire your task prompt at it; it plans, writes PLAN.md, and spawns the executor."
  sleep 1
}

# ---- dispatch ----

MODE="${1:-}"
shift || true
ARG_PANE=""; ARG_CWD=""; ARG_REPO=""; ARG_BRANCH=""
while [ $# -gt 0 ]; do
  case "$1" in
    --pane) ARG_PANE="$2"; shift 2 ;;
    --cwd) ARG_CWD="$2"; shift 2 ;;
    --repo) ARG_REPO="$2"; shift 2 ;;
    --branch) ARG_BRANCH="$2"; shift 2 ;;
    *) break ;;
  esac
done

case "$MODE" in
  open-dialog) cmd_open_dialog ;;
  dialog) cmd_dialog ;;
  spawn) cmd_spawn ;;
  runner-for) cmd_runner_for ;;
  release) cmd_release "$@" ;;
  status) cmd_status ;;
  doctor) cmd_doctor ;;
  config) cmd_config ;;
  *) die "usage: pairwalk.sh open-dialog|dialog|spawn|runner-for|release|status|doctor|config [--pane ID] [--cwd PATH] [--repo PATH] [--branch NAME]" ;;
esac
