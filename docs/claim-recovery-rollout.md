# Claim result recovery: operator rollout and rollback

This change updates the polecat prompt and its claim helper; no bead migration
is required. Syncing the pack leaves existing bead records untouched. New
sessions use the normal atomic claim flow with `--drain-ack`, so every hook
drain that claimed nothing (`no_work`, `claims_errored`, `drain_pending`,
`stale_session`, `missing_session_registration`) is acknowledged by the SDK
itself, exactly as for any other `--drain-ack` caller. Review and merge the pack change through
the repository's normal human gate before deploying it.

## Behavior change: preserve and report instead of release

The previous prompt released the claim back to the pool (status `open`, empty
assignee) only when its readback stayed unreadable after retries, and on an
assignee or status mismatch it reported `CLAIM_REJECTED` and drain-acked
without releasing. So preserve-and-report replaces a release only for an
unreadable readback; for a mismatch it replaces drain-ack-and-leave. The new
helper never releases, reopens, or drains while ownership is uncertain. On `CLAIM_UNKNOWN` (exit 75) or `CLAIM_REJECTED`
(exit 76) the polecat leaves the bead untouched, mails the full helper output to
the coordinator (`gasvillage.mayor` at claim time), and stops without
acknowledging a drain.

A bead can therefore stay `in_progress` and assigned to a stopped polecat
session after an unreadable readback. The coordinator's report mail names the
session, rig, and helper output. Inspect the bead with
`gc bd show <id>` (id-routed to the rig or city store), confirm the session is
no longer working it, and then release or reassign the bead through the city's
normal coordinator flow. The pack never does this automatically.

## Rollout

1. After approval, update the city's Gas Village pack source to the reviewed
   commit using that city's normal pack sync or materialization procedure.
   Confirm the polecat prompt and `assets/scripts/claim-work.sh` come from the
   same revision.
2. Let the normal pool create new polecat sessions from the updated pack.
   Existing sessions keep the prompt they started with; updating pack files
   does not reload a running session.
3. If an existing session reports that a claim command yielded, keep polling
   that exact execution handle until the original process exits. Do not start
   another claim while it may still be running.
4. If the process exited but its result was lost, recover read-only in that
   same session with the synced helper:

   ```bash
   bash <pack-dir>/assets/scripts/claim-work.sh recover
   ```

   It reads only `gc hook current --id-only`, reads the bead back with
   id-routed `gc bd show <id> --json`, and prints `CLAIMED_BEAD_ID=<id>` only
   when it proves this session owns the bead (the ownership fields and
   identity inputs are listed in the helper header). On `CLAIM_UNKNOWN` or
   `CLAIM_REJECTED`, leave the bead and session unchanged and follow the
   report-and-stop handling above, except for the header's decision rule:
   `recover` answering `CLAIM_UNKNOWN reason=no_current_assignment` or
   `CLAIM_UNKNOWN reason=pointer_closed` means the SDK has said the session
   holds no open claim, so one normal `claim` run is allowed.
5. Do not issue a second `gc hook --claim`, search `bd ready`, clear an
   assignee, reopen a bead, or acknowledge a drain while the claim result is
   unknown. The current-session pointer is the only recovery source. The
   re-claim in step 4 is not a second claim on an unknown result: it follows
   the SDK's positive answer that this session has no open claim.

### Why a read-only pointer instead of re-running the hook

`gc hook --claim` does adopt work already assigned to the session, so
re-running it looks like an idempotent recovery. It is not safe while a result
is unknown. The original process may still be running, so a second call races
it. Adoption also depends on its assignment query seeing the earlier claim;
if that query misses it (for example, a claim that is not yet visible, or one
recorded under an identity the query does not match), the call claims a second
routed bead for the same session. Reading the current-claim
pointer never claims, so a lost result costs at most a report to the
coordinator, never a duplicate claim. The helper reads only that pointer; the
pointer's "no current claim" answer currently comes from SDK diagnostic text,
pinned by `assets/scripts/test-hook-claim.sh` against the installed `gc`.

## Rollback

If review or rollout finds a defect, revert the pack change and sync the
previous reviewed pack revision. New sessions then use the previous prompt.
Running sessions do not reload either revision, so handle any uncertain claim
with the read-only `recover` check above while the helper is still present, or
by reading the same fields from `gc bd show <id> --json`
(`.[0].status`, `.[0].assignee`, and `.[0].metadata["gc.session_id"]`; the
metadata key is the literal dotted string). Preserve valid in-progress claims;
do not bulk unroute, reopen, or drain beads as part of rollback.
