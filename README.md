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
| `crew`    | rig   | user-named, persistent  | Your hands-on workspace inside a rig. Like a vanilla Claude Code session, with bead/mail awareness. |
| `polecat` | rig   | ephemeral, scale 0–5    | Slung-to worker. Spin up, do task, die after 2h idle. |

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
[workspace]
name = "my-city"
provider = "claude"

# Register rigs to activate per-rig agents (polecat):
# [[rigs]]
# name = "my-project"
# path = "/path/to/my-project"
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
mode = "always"
```

Run `gc start` and the crew member comes up as a stable session
`my-project/alice`.

> **The load-bearing rule:** `dir = "my-project"` must appear in **both**
> `agent.toml` and the `[[named_session]]`, and they must match. That `dir`
> (not `scope`) is what binds the session to the rig as `my-project/alice`. A
> `[[named_session]]` with `scope = "rig"` but no `dir` resolves to a bare,
> unqualified `alice` and won't attach to your rig.

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
- **Crew** is user-driven, so token use tracks human activity — naturally
  bounded.

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
