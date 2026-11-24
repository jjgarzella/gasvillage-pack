# Claim result recovery: operator rollout and rollback

This change updates the polecat prompt and its claim helper; no bead migration
is required. Syncing the pack leaves existing bead records untouched. New
sessions use the normal atomic claim flow, and a clean empty result is followed
by the normal drain acknowledgment. Review and merge the pack change through
the repository's normal human gate before deploying it.

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
   same session:

   ```bash
   WORK_ID=$(gc hook current --id-only) || exit 1
   gc --rig "$GC_RIG" bd show "$WORK_ID" --json
   ```

   Continue only when the returned bead is `in_progress`, its assignee is the
   current worker, `metadata.gc.root_store_ref` is `rig:$GC_RIG`,
   `metadata.gc.session_id` equals `$GC_SESSION_ID`, and
   `metadata.gc.claimed_at` is present. If any field is missing or mismatched,
   leave the bead and session unchanged and ask the Mayor to inspect it.
5. Do not issue a second `gc hook --claim`, search `bd ready`, clear an
   assignee, reopen a bead, or acknowledge a drain while the claim result is
   unknown. The current-session pointer is the only recovery source.

## Rollback

If review or rollout finds a defect, revert the pack change and sync the
previous reviewed pack revision. New sessions then use the previous prompt.
Running sessions do not reload either revision, so handle any uncertain claim
with the read-only current-pointer check above. Preserve valid in-progress
claims; do not bulk unroute, reopen, or drain beads as part of rollback.
