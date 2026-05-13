# Gas Village

A lightweight Gas City pack for newcomers and token-budget-conscious work.

## What it is

Where **Gas Town** optimizes for parallel-agent velocity, **Gas Village**
optimizes for approachability and a low token floor. Three roles, one
always-on agent.

## Roles

| Role      | Scope | Lifecycle               | What it's for |
|-----------|-------|-------------------------|---------------|
| `mayor`   | city  | always-on, sleeps 30m   | Coordinator. Plans, dispatches, manages rigs. |
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

# Add a crew member by declaring an [[agent]] entry inline:
# [[agent]]
# name = "alice"
# dir = "my-project"
# prompt_template = "packs/gasvillage/assets/prompts/crew.template.md"
# pre_start = ["packs/gasvillage/assets/scripts/worktree-setup.sh /path/to/my-project /path/to/city/.gc/worktrees/my-project/alice alice --sync"]
# idle_timeout = "4h"
```

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
- **Mayor sleeps** after 30m idle; wakes on user prompt or mail.
- **Polecats** are pure on-demand (`min=0`).
- **Crew** is user-driven, so token use tracks human activity — naturally
  bounded.

## Graduating

When you outgrow Gas Village, layer in additional packs:

- **`maintenance`** — dog pool, formula-driven housekeeping (compaction,
  orphan-sweep, wisp-compact).
- **`dolt`** — Dolt health and cleanup (often auto-included via the
  Gas City builtins).
- **`gastown`** — the full multi-agent stack: deacon, boot, witness,
  refinery, convoys.
