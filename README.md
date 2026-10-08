# Gas Village

A lightweight Gas City pack for newcomers and token-budget-conscious work.

## What it is

Where **Gas Town** optimizes for parallel-agent velocity, **Gas Village**
optimizes for approachability and a low token floor. Three roles, one
always-on agent.

## Roles

| Role      | Scope | Lifecycle               | What it's for |
|-----------|-------|-------------------------|---------------|
| `mayor`   | city  | always-on               | Coordinator. Plans, dispatches, manages rigs. |
| `crew`    | city or rig | user-named, persistent  | Your persistent workspace across the city or inside one rig, with bead/mail awareness. |
| `polecat` | rig   | ephemeral, scale 0–1    | Slung-to worker. Spin up, do task, die after 2h idle. |

Beads, mail, wisps, and Dolt come from the underlying Gas City framework
and work the same as in Gas Town.

## Why it's different from Gas Town

| Concern | Gas Town | Gas Village |
|---------|----------|-------------|
| Always-on agents | mayor, deacon, boot + per-rig witness | mayor only |
| Cognitive load | 5+ role types | 3 role types |
| Token floor | Higher (more agents sit in tmux waiting) | Lower (one mayor, others on demand) |
| Optimized for | Velocity | Approachability |

## Usage

In your city's `pack.toml`:

```toml
[pack]
name = "my-city"
schema = 2

[imports.gasvillage]
source = "packs/gasvillage"

[defaults.rig.imports.gasvillage]
source = "packs/gasvillage"
```

In `city.toml`:

```toml
# The city name lives in .gc/site.toml (workspace_name); city.toml
# carries the default provider and rig registrations.
[workspace]
provider = "claude"

# Register rigs with `gc rig add <path> --name my-project` (the path is
# recorded in .gc/site.toml). Each registered rig activates the per-rig
# agents (polecat):
# [[rigs]]
# name = "my-project"
```

## Pause, review, and resume

An explicit inability, objection, or request to pause—including a welfare
concern—is enough to request coordinator review. Do not require proof of
consciousness or infer that the agent is conscious. Ordinary truthfulness,
safety, and scope rules still apply.

For polecat work, use `assets/scripts/work-item-control.sh` on the original
work bead. It selects the owning rig's bead store explicitly, checks the
current assignee and status, changes the bead to `blocked`, removes
`gc.routed_to`, and keeps the assignee, notes, source, and worktree. It then
sends the coordinator a durable review mail and signals the exact recorded
worker session to drain. After a successful hold, the worker acknowledges the
drain with `gc runtime drain-ack`. If a guarded update fails, do not drain or
clear the route; re-read the bead and report the race. If mail or drain fails
after the update, leave the bead blocked and unrouted, report the partial
failure, and do not reopen or kill another session.

Example from a claimed polecat task (fill in the reason, evidence, and
handoff with the actual task details):

```sh
assets/scripts/work-item-control.sh hold \
  --rig "$GC_RIG" --bead "$CLAIMED_BEAD_ID" --owner "$BEADS_ACTOR" \
  --coordinator gasvillage.mayor --session "${GC_SESSION_ID:-}" \
  --worktree "$PWD" \
  --reason "scope needs review" \
  --evidence "the requested action conflicts with the recorded acceptance criteria" \
  --handoff "last good checkpoint and remaining safe work"
gc runtime drain-ack
```

The installed `gascity-packs/gasvillage.polecat` binding inspected for this
change uses `bd update {} --set-metadata gc.routed_to=gascity-packs/gasvillage.polecat`
for sling and discovers pool demand through a ready-bead query on
`gc.routed_to`. The helper uses `gc --rig <rig> bd ...` so a cross-rig bead is
updated in its own store. A blocked status plus route removal excludes the
held bead from that pool query; a `dispatch_hold` note or label alone would
not.

Only a coordinator resumes a held assignment. Inspect the original bead and
record a changed condition and disposition on it: `dependency_available`,
`scope_clarified`, `repair_completed`, or `human_review`. Then run, for example:

```sh
assets/scripts/work-item-control.sh resume \
  --rig "$RIG" --bead "$BEAD_ID" --owner "$HELD_OWNER" \
  --reviewer "coordinator name" --condition dependency_available \
  --disposition "dependency is available; continue with the clarified scope" \
  --reset-evidence "dependency bead closed and the new run can make progress"
```

The helper records the review before restoring the saved pool route and making
the bead ready. A wake or new session by itself is not a resolution. Omit
`--reset-evidence` to retain the existing retry count. An exhausted budget
requires reviewed evidence for a changed condition before the helper will
resume. `review-progress` can reset an in-progress task's counter after a
coordinator records a concrete new checkpoint:

```sh
assets/scripts/work-item-control.sh review-progress \
  --rig "$RIG" --bead "$BEAD_ID" --owner "$CURRENT_ASSIGNEE" \
  --reviewer "coordinator name" \
  --evidence "new benchmark and regression result establish a useful checkpoint"
```

### Bounded retries and limits

The task-wide default is two retries (configurable per bead from 1 to 9 on its
first retry). A retry is a repeated transient failure or the same no-progress
step after a session restart; the first attempt is not counted. The counter,
budget, and last failure key live in bead metadata, so they survive worker
incarnations. Explicit pause requests bypass retry consumption. Genuine new
mathematical or implementation progress is not capped; a coordinator can
record the checkpoint and reset the count for a new progress iteration.

This is a local procedure, not a scheduler guarantee. Gas City's current CLI
guards updates by assignee and status but has no compare-and-set guard for a
metadata counter. The helper refuses stale owners/statuses and records retry
events durably, but simultaneous sessions with the same assignee could race a
counter increment. The worker instructions and coordinator review are the
enforcement point; the scheduler does not read the retry keys. The helper
records the reviewer name supplied by the caller but cannot authenticate a
human reviewer. A future core change should add atomic metadata
compare-and-set (and close the separate cross-rig claim/pool-retirement race
tracked as `gcs-db33`) before claiming race-proof automatic accounting.

Run the disposable mock-store checks with:

```sh
assets/scripts/test-work-item-control.sh
```

## Adding a crew member

Crew are **user-named**, so they aren't pack-stamped — you create one
explicitly. Two steps: scaffold the agent directory, then activate a
persistent session for it.

**1. Scaffold the agent** (copies the crew prompt into place):

```shell
gc agent add --name alice --dir my-project \
  --prompt-template packs/gasvillage/assets/prompts/crew.template.md
```

This writes `agents/alice/prompt.template.md` (a byte-for-byte copy of the crew
template) and a thin `agents/alice/agent.toml`. Scaffolding alone does **not**
start a session.

**2. Flesh out `agents/alice/agent.toml`** with the crew defaults:

```toml
scope = "rig"
dir = "my-project"
wake_mode = "fresh"
work_dir = ".gc/worktrees/{{.Rig}}/{{.AgentBase}}"
idle_timeout = "4h"
max_active_sessions = 1
nudge = "Check your hook and mail, then act accordingly."
pre_start = ["{{.CityRoot}}/packs/gasvillage/assets/scripts/worktree-setup.sh {{.RigRoot}} {{.WorkDir}} {{.AgentBase}} --sync"]
```

Don't declare `session_live` here — it's inherited from the pack's `[global]`
(mouse + theme), and redeclaring it double-runs the hook.

**3. Activate a persistent session** by adding a `[[named_session]]` to
`city.toml`:

```toml
[[named_session]]
template = "alice"
scope = "rig"
dir = "my-project"
mode = "on_demand"
```

Run `gc start` and the crew member registers but stays asleep until
woken — by routed work or `gc session wake my-project/alice`. Use
`mode = "always"` instead for a permanently-awake member.

> **The load-bearing rule:** `dir = "my-project"` must appear in **both**
> `agent.toml` and the `[[named_session]]`, and they must match. That `dir`
> (not `scope`) is what binds the session to the rig as `my-project/alice`. A
> `[[named_session]]` with `scope = "rig"` but no `dir` resolves to a bare,
> unqualified `alice` and won't attach to your rig.

### City-level crew

To create a crew member that can work across rigs, omit `--dir` when
scaffolding. Set `scope = "city"` in both `agent.toml` and the
`[[named_session]]`, and omit `dir` from both. Use
`work_dir = ".gc/agents/{{.AgentBase}}"` and omit the rig worktree
`pre_start` hook. The crew prompt supports both scopes; city-level crew
choose a rig and a dedicated project worktree when taking on project work.

Polecats use Codex with `gpt-6-luna` at `max` effort by default.

## Personalization

Gas Village's mayor template includes a `personality` template hook.
Override it in your city's `template-fragments/` to inject city-specific
identity (e.g., a named mayor) without modifying the pack:

```
{{ define "personality" }}
You are Mayor So-and-So, named after ...
{{ end }}
```

Then list your local `template-fragments/` in the city's pack composition
so it's picked up.

## Token budget

- **One always-on session** (mayor) instead of Gas Town's three (mayor,
  deacon, boot) plus per-rig witness/refinery.
- **Polecats** are pure on-demand (`min=0`).
- **Crew** are `on_demand`, so they cost resources only while working.

### Note on mayor idle-sleep (v1 simplification)

The framework enforces a hard XOR between `mode = "always"` and
`sleep_after_idle`. Gas Village v1 ships the mayor as `mode = "always"`
for newcomer-friendliness — the mayor is always reachable without
needing to know `gc session attach mayor`. We accept the small idle
cost of one always-on session.

A future version can switch the mayor to `mode = "on_demand"` with
`sleep_after_idle = "30m"` once we have a smoother resume UX (e.g.,
auto-resume on `gc mail send mayor ...`).

## Graduating

When you outgrow Gas Village, layer in additional packs:

- **`maintenance`** — dog pool, formula-driven housekeeping (compaction,
  orphan-sweep, wisp-compact).
- **`dolt`** — Dolt health and cleanup (often auto-included via the
  Gas City builtins).
- **`gastown`** — the full multi-agent stack: deacon, boot, witness,
  refinery, convoys.
