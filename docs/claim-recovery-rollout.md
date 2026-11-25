# Claim result recovery: operator rollout and rollback

This change updates the polecat prompt and its claim helper; no bead migration
is required. Syncing the pack leaves existing bead records untouched. New
sessions use the normal atomic claim flow with `--drain-ack`, so every hook
drain that claimed nothing (`no_work`, `claims_errored`, `drain_pending`,
`stale_session`, `missing_session_registration`) is acknowledged by the SDK
itself, exactly as for any other `--drain-ack` caller. Review and merge the pack change through
the repository's normal human gate before deploying it.

## Behavior change: preserve and report instead of release

The previous prompt released a claim back to the pool and drain-acked when its
readback did not match. The new helper never releases, reopens, or drains while
ownership is uncertain. On `CLAIM_UNKNOWN` (exit 75) or `CLAIM_REJECTED`
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
   when the bead is `in_progress`, its `gc.session_id` equals
   `$GC_SESSION_ID`, and its assignee is one of the session's own identities
   (`GC_ALIAS`, `GC_SESSION_ID`, `BEADS_ACTOR`, `GC_AGENT`,
   `GC_SESSION_NAME`). On `CLAIM_UNKNOWN` or
   `CLAIM_REJECTED`, leave the bead and session unchanged and follow the
   report-and-stop handling above. Only `CLAIM_UNKNOWN
   reason=no_current_assignment` (the SDK reported no current claim) and
   `CLAIM_UNKNOWN reason=pointer_closed` (the session's most recent claim is
   closed) mean the session holds nothing; `current_unavailable` and
   `invalid_current_pointer` leave ownership uncertain.
5. Do not issue a second `gc hook --claim`, search `bd ready`, clear an
   assignee, reopen a bead, or acknowledge a drain while the claim result is
   unknown. The current-session pointer is the only recovery source.

## Rollback

If review or rollout finds a defect, revert the pack change and sync the
previous reviewed pack revision. New sessions then use the previous prompt.
Running sessions do not reload either revision, so handle any uncertain claim
with the read-only `recover` check above while the helper is still present, or
by reading the same fields from `gc bd show <id> --json`
(`.[0].status`, `.[0].assignee`, and `.[0].metadata["gc.session_id"]`; the
metadata key is the literal dotted string). Preserve valid in-progress claims;
do not bulk unroute, reopen, or drain beads as part of rollback.
