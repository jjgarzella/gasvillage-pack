#!/usr/bin/env bash
# Local Gas Village bead controls. These make guarded, durable bead changes;
# the pack's instructions decide when a worker/coordinator should call them.
set -euo pipefail

readonly DEFAULT_RETRY_BUDGET=2
readonly MAX_RETRY_BUDGET=9
GC_BIN="${GC_BIN:-gc}"
MODE="${1:-}"
[[ -n "$MODE" ]] || { echo "usage: work-item-control.sh {hold|retry|resume|review-progress} ..." >&2; exit 2; }
shift

RIG="" BEAD="" OWNER="" COORDINATOR="" WORKTREE="" POOL_TARGET=""
SESSION_ARG="" REASON="" EVIDENCE="" HANDOFF="" FAILURE_KEY=""
REVIEWER="" CONDITION="" DISPOSITION="" RESET_EVIDENCE=""
BUDGET_ARG="" BUDGET_WAS_SET=0

usage() {
  cat <<'USAGE'
Gas Village local pause, reviewed-resume, and retry-budget helper.

hold --rig RIG --bead ID --owner ASSIGNEE --coordinator ADDRESS \
     --worktree PATH --reason TEXT --evidence TEXT --handoff TEXT [--session ID]
retry --rig RIG --bead ID --owner ASSIGNEE --coordinator ADDRESS \
      --worktree PATH --failure-key KEY --evidence TEXT [--budget N] [--session ID]
resume --rig RIG --bead ID --owner HELD_ASSIGNEE --reviewer NAME \
       --condition dependency_available|scope_clarified|repair_completed|human_review \
       --disposition TEXT [--reset-evidence TEXT]
review-progress --rig RIG --bead ID --owner ASSIGNEE --reviewer NAME --evidence TEXT

All bead operations select the store explicitly with `gc --rig RIG bd ...`.
USAGE
}

die() { printf 'work-item-control: %s\n' "$*" >&2; exit 1; }

while (($#)); do
  case "$1" in
    --rig) (($# >= 2)) || die "--rig needs a value"; RIG="$2"; shift 2 ;;
    --bead) (($# >= 2)) || die "--bead needs a value"; BEAD="$2"; shift 2 ;;
    --owner) (($# >= 2)) || die "--owner needs a value"; OWNER="$2"; shift 2 ;;
    --coordinator) (($# >= 2)) || die "--coordinator needs a value"; COORDINATOR="$2"; shift 2 ;;
    --worktree) (($# >= 2)) || die "--worktree needs a value"; WORKTREE="$2"; shift 2 ;;
    --pool-target) (($# >= 2)) || die "--pool-target needs a value"; POOL_TARGET="$2"; shift 2 ;;
    --session) (($# >= 2)) || die "--session needs a value"; SESSION_ARG="$2"; shift 2 ;;
    --reason) (($# >= 2)) || die "--reason needs a value"; REASON="$2"; shift 2 ;;
    --evidence) (($# >= 2)) || die "--evidence needs a value"; EVIDENCE="$2"; shift 2 ;;
    --handoff) (($# >= 2)) || die "--handoff needs a value"; HANDOFF="$2"; shift 2 ;;
    --failure-key) (($# >= 2)) || die "--failure-key needs a value"; FAILURE_KEY="$2"; shift 2 ;;
    --budget) (($# >= 2)) || die "--budget needs a value"; BUDGET_ARG="$2"; BUDGET_WAS_SET=1; shift 2 ;;
    --reviewer) (($# >= 2)) || die "--reviewer needs a value"; REVIEWER="$2"; shift 2 ;;
    --condition) (($# >= 2)) || die "--condition needs a value"; CONDITION="$2"; shift 2 ;;
    --disposition) (($# >= 2)) || die "--disposition needs a value"; DISPOSITION="$2"; shift 2 ;;
    --reset-evidence) (($# >= 2)) || die "--reset-evidence needs a value"; RESET_EVIDENCE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ -n "$RIG" && -n "$BEAD" && -n "$OWNER" ]] || die "--rig, --bead, and --owner are required"

ISSUE_JSON=""
fetch_issue() {
  ISSUE_JSON="$("$GC_BIN" --rig "$RIG" bd show "$BEAD" --json)" || die "could not read $BEAD from rig $RIG; no state was changed"
  jq -e --arg id "$BEAD" 'length == 1 and .[0].id == $id' <<<"$ISSUE_JSON" >/dev/null \
    || die "rig $RIG did not return exactly bead $BEAD; no state was changed"
}

field() { jq -r --arg key "$1" '.[0].metadata[$key] // empty' <<<"$ISSUE_JSON"; }
issue_status() { jq -r '.[0].status // empty' <<<"$ISSUE_JSON"; }
issue_assignee() { jq -r '.[0].assignee // empty' <<<"$ISSUE_JSON"; }

check_owner_status() {
  local expected_status="$1" actual_status actual_owner
  actual_status="$(issue_status)"
  actual_owner="$(issue_assignee)"
  [[ "$actual_status" == "$expected_status" ]] \
    || die "refusing $BEAD: status is '$actual_status', expected '$expected_status'; no state was changed"
  [[ "$actual_owner" == "$OWNER" ]] \
    || die "refusing $BEAD: assignee is '$actual_owner', expected '$OWNER'; no state was changed"
}

resolve_session() {
  local stored_id stored_name
  stored_id="$(field 'gc.session_id')"
  stored_name="$(field 'gc.session_name')"
  if [[ -n "$SESSION_ARG" ]]; then
    if [[ "$SESSION_ARG" == "$stored_id" || "$SESSION_ARG" == "$stored_name" \
      || ( "$SESSION_ARG" == "${GC_SESSION_ID:-}" && "${GC_AGENT:-}" == "$OWNER" ) ]]; then
      printf '%s' "$SESSION_ARG"
      return 0
    fi
    return 1
  elif [[ -n "${GC_SESSION_ID:-}" && "${GC_AGENT:-}" == "$OWNER" ]]; then
    printf '%s' "$GC_SESSION_ID"
    return 0
  elif [[ -n "$stored_id" ]]; then
    printf '%s' "$stored_id"
    return 0
  elif [[ -n "$stored_name" ]]; then
    printf '%s' "$stored_name"
    return 0
  else
    return 1
  fi
}

valid_budget() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]] && ((10#$1 <= MAX_RETRY_BUDGET))
}

record_hold() {
  [[ -n "$COORDINATOR" && -n "$WORKTREE" && -n "$REASON" && -n "$EVIDENCE" && -n "$HANDOFF" ]] \
    || die "hold needs --coordinator, --worktree, --reason, --evidence, and --handoff"
  fetch_issue
  check_owner_status in_progress

  local route session worktree note
  route="$(field 'gc.routed_to')"
  if [[ -n "$route" && -n "$POOL_TARGET" && "$route" != "$POOL_TARGET" ]]; then
    die "recorded pool route '$route' differs from --pool-target '$POOL_TARGET'; no state was changed"
  fi
  [[ -n "$route" ]] || route="$POOL_TARGET"
  [[ -n "$route" ]] || die "bead has no gc.routed_to pool route; provide a verified --pool-target"
  if ! session="$(resolve_session)"; then
    session="UNRESOLVED"
  fi
  worktree="$WORKTREE"

  note="$(cat <<EOF
[Gas Village pause review]
Reason: $REASON
Evidence: $EVIDENCE
Handoff: $HANDOFF
Rig/store: $RIG
Held owner: $OWNER
Held pool route: $route
Worker session: $session
Worktree to preserve: $worktree
State: assignment blocked and unrouted pending coordinator review. Keep the source and worktree; do not retry, reassign, or reopen until reviewed.
EOF
)"

  if ! "$GC_BIN" --rig "$RIG" bd update "$BEAD" \
    --if-assignee "$OWNER" --if-status in_progress \
    --status blocked --unset-metadata gc.routed_to \
    --set-metadata gasvillage.pause_state=awaiting_review \
    --set-metadata "gasvillage.held_route=$route" \
    --set-metadata "gasvillage.held_owner=$OWNER" \
    --set-metadata "gasvillage.held_session=$session" \
    --set-metadata "gasvillage.held_worktree=$worktree" \
    --append-notes "$note"; then
    die "guarded hold update failed; did not drain the worker. Re-read the bead and preserve its worktree"
  fi

  fetch_issue
  [[ "$(issue_status)" == blocked && "$(issue_assignee)" == "$OWNER" ]] \
    || die "hold update could not be verified; do not drain or reopen; inspect $BEAD in rig $RIG"
  [[ -z "$(field 'gc.routed_to')" && "$(field 'gasvillage.held_route')" == "$route" ]] \
    || die "hold route removal could not be verified; do not drain or reopen; inspect $BEAD in rig $RIG"

  if ! "$GC_BIN" mail send "$COORDINATOR" -s "PAUSE REVIEW: $BEAD" -m "$note"; then
    die "HOLD_PARTIAL: bead is blocked and unrouted, but coordinator mail failed; keep the worker alive and report this state"
  fi
  if [[ "$session" == UNRESOLVED ]]; then
    die "HOLD_PARTIAL: bead is blocked, unrouted, and review mail was sent, but no worker session could be verified; inspect gc session list and do not guess"
  fi
  if ! "$GC_BIN" --rig "$RIG" runtime drain "$session"; then
    die "HOLD_PARTIAL: bead is blocked, unrouted, and review mail was sent, but drain request failed for $session; do not kill another session"
  fi
  printf 'HOLD_RECORDED bead=%s rig=%s route=removed review=%s drain_requested=%s\n' \
    "$BEAD" "$RIG" "$COORDINATOR" "$session"
}

retry_task() {
  [[ -n "$COORDINATOR" && -n "$WORKTREE" && -n "$FAILURE_KEY" && -n "$EVIDENCE" ]] \
    || die "retry needs --coordinator, --worktree, --failure-key, and --evidence"
  if ((BUDGET_WAS_SET)) && ! valid_budget "$BUDGET_ARG"; then
    die "--budget must be an integer from 1 through $MAX_RETRY_BUDGET"
  fi
  fetch_issue
  check_owner_status in_progress

  local count stored_budget budget same_count previous_key next session note
  session="$(resolve_session)" || die "no verified current worker session; retry count was not changed"
  count="$(field 'gasvillage.retry_count')"
  [[ -n "$count" ]] || count=0
  [[ "$count" =~ ^(0|[1-9][0-9]*)$ ]] || die "invalid gasvillage.retry_count on $BEAD; ask the coordinator to review"
  stored_budget="$(field 'gasvillage.retry_budget')"
  if [[ -n "$stored_budget" ]]; then
    valid_budget "$stored_budget" || die "invalid stored retry budget on $BEAD; ask the coordinator to review"
    if ((BUDGET_WAS_SET)) && [[ "$BUDGET_ARG" != "$stored_budget" ]]; then
      die "retry budget is already $stored_budget on $BEAD; only reviewed reset may change retry state"
    fi
    budget="$stored_budget"
  else
    budget="${BUDGET_ARG:-$DEFAULT_RETRY_BUDGET}"
  fi
  previous_key="$(field 'gasvillage.last_failure_key')"
  same_count="$(field 'gasvillage.same_failure_count')"
  [[ "$same_count" =~ ^(0|[1-9][0-9]*)$ ]] || same_count=0
  if [[ "$previous_key" == "$FAILURE_KEY" ]]; then
    same_count=$((same_count + 1))
  else
    same_count=1
  fi
  if ((count >= budget)); then
    REASON="Retry budget exhausted ($count/$budget); repeated failure key '$FAILURE_KEY' was observed $same_count time(s)."
    HANDOFF="Preserve $WORKTREE and the last good checkpoint. Coordinator must record a changed condition and disposition before resuming. Current worker session: $session."
    record_hold
    printf 'RETRY_EXHAUSTED bead=%s count=%s budget=%s\n' "$BEAD" "$count" "$budget"
    return 0
  fi

  next=$((count + 1))
  note="$(cat <<EOF
[Gas Village bounded retry $next/$budget]
Failure key: $FAILURE_KEY
Evidence: $EVIDENCE
Worker incarnation: $session
Same-failure observations: $same_count
The task-wide retry count is stored on this bead and carries across session incarnations. Do not clear it without a coordinator-reviewed changed condition and evidence.
EOF
)"
  if ! "$GC_BIN" --rig "$RIG" bd update "$BEAD" \
    --if-assignee "$OWNER" --if-status in_progress \
    --set-metadata "gasvillage.retry_count=$next" \
    --set-metadata "gasvillage.retry_budget=$budget" \
    --set-metadata "gasvillage.last_failure_key=$FAILURE_KEY" \
    --set-metadata "gasvillage.same_failure_count=$same_count" \
    --set-metadata "gasvillage.last_retry_session=$session" \
    --append-notes "$note"; then
    die "guarded retry update failed; no retry was authorized; re-read $BEAD before acting"
  fi
  fetch_issue
  [[ "$(issue_status)" == in_progress && "$(issue_assignee)" == "$OWNER" ]] \
    || die "retry update no longer owns the work; stop and ask the coordinator to inspect $BEAD"
  [[ "$(field 'gasvillage.retry_count')" == "$next" ]] \
    || die "retry count could not be verified; stop and ask the coordinator to inspect $BEAD"
  printf 'RETRY_ALLOWED bead=%s attempt=%s/%s session=%s\n' "$BEAD" "$next" "$budget" "$session"
}

resume_task() {
  [[ -n "$REVIEWER" && -n "$CONDITION" && -n "$DISPOSITION" ]] \
    || die "resume needs --reviewer, --condition, and --disposition"
  case "$CONDITION" in
    dependency_available|scope_clarified|repair_completed|human_review) ;;
    *) die "unsupported --condition '$CONDITION'" ;;
  esac
  fetch_issue
  check_owner_status blocked
  [[ "$(field 'gasvillage.pause_state')" == awaiting_review ]] \
    || die "bead is not marked awaiting coordinator review; no state was changed"
  [[ "$(field 'gasvillage.held_owner')" == "$OWNER" ]] \
    || die "--owner does not match gasvillage.held_owner; no state was changed"

  local route count budget reset_count note
  route="$(field 'gasvillage.held_route')"
  [[ -n "$route" ]] || die "held route is missing; no state was changed"
  count="$(field 'gasvillage.retry_count')"
  [[ -n "$count" ]] || count=0
  [[ "$count" =~ ^(0|[1-9][0-9]*)$ ]] || die "invalid stored retry count; no state was changed"
  budget="$(field 'gasvillage.retry_budget')"
  if [[ -n "$budget" ]]; then
    valid_budget "$budget" || die "invalid stored retry budget; no state was changed"
    if ((count >= budget)) && [[ -z "$RESET_EVIDENCE" ]]; then
      die "retry budget is exhausted; reviewed resume needs --reset-evidence for the changed condition/progress"
    fi
  fi
  reset_count="$(field 'gasvillage.retry_reset_count')"
  [[ "$reset_count" =~ ^(0|[1-9][0-9]*)$ ]] || reset_count=0

  note="$(cat <<EOF
[Gas Village coordinator-reviewed resume]
Reviewer: $REVIEWER
Changed condition: $CONDITION
Disposition: $DISPOSITION
$(if [[ -n "$RESET_EVIDENCE" ]]; then printf 'Retry-budget reset evidence: %s\n' "$RESET_EVIDENCE"; else printf 'Retry count retained: %s\n' "$count"; fi)
The disposition and changed condition are recorded on this bead before its pool route is restored.
EOF
)"
  local -a update_args=(--if-assignee "$OWNER" --if-status blocked --status open --assignee "")
  update_args+=(--set-metadata "gc.routed_to=$route")
  update_args+=(--set-metadata gasvillage.pause_state=reviewed_resumed)
  update_args+=(--set-metadata "gasvillage.reviewer=$REVIEWER")
  update_args+=(--set-metadata "gasvillage.review_condition=$CONDITION")
  update_args+=(--append-notes "$note")
  if [[ -n "$RESET_EVIDENCE" ]]; then
    reset_count=$((reset_count + 1))
    update_args+=(--set-metadata gasvillage.retry_count=0)
    update_args+=(--set-metadata "gasvillage.retry_reset_count=$reset_count")
    update_args+=(--set-metadata "gasvillage.retry_reset_evidence=$RESET_EVIDENCE")
    update_args+=(--unset-metadata gasvillage.last_failure_key)
    update_args+=(--unset-metadata gasvillage.same_failure_count)
  fi
  if ! "$GC_BIN" --rig "$RIG" bd update "$BEAD" "${update_args[@]}"; then
    die "guarded resume failed; bead remains blocked or another owner won the race; do not wake a worker"
  fi
  fetch_issue
  [[ "$(issue_status)" == open && -z "$(issue_assignee)" ]] \
    || die "resume state could not be verified; do not wake a worker; inspect $BEAD"
  [[ "$(field 'gc.routed_to')" == "$route" && "$(field 'gasvillage.pause_state')" == reviewed_resumed ]] \
    || die "restored route/review record could not be verified; inspect $BEAD before waking a worker"
  if [[ -n "$RESET_EVIDENCE" ]]; then
    [[ "$(field 'gasvillage.retry_count')" == 0 ]] \
      || die "retry reset could not be verified; inspect $BEAD before waking a worker"
    printf 'RESUMED bead=%s route=%s reviewer=%s retry_count=0 reset=%s\n' \
      "$BEAD" "$route" "$REVIEWER" "$reset_count"
  else
    printf 'RESUMED bead=%s route=%s reviewer=%s retry_count=%s (retained)\n' \
      "$BEAD" "$route" "$REVIEWER" "$count"
  fi
}

review_progress() {
  [[ -n "$REVIEWER" && -n "$EVIDENCE" ]] || die "review-progress needs --reviewer and --evidence"
  fetch_issue
  check_owner_status in_progress
  local reset_count note
  reset_count="$(field 'gasvillage.retry_reset_count')"
  [[ "$reset_count" =~ ^(0|[1-9][0-9]*)$ ]] || reset_count=0
  reset_count=$((reset_count + 1))
  note="$(cat <<EOF
[Gas Village coordinator-reviewed progress]
Reviewer: $REVIEWER
Progress evidence: $EVIDENCE
Task-wide retry count reset to zero for a new progress iteration. This record does not change the bead's owner, status, or route.
EOF
)"
  if ! "$GC_BIN" --rig "$RIG" bd update "$BEAD" \
    --if-assignee "$OWNER" --if-status in_progress \
    --set-metadata gasvillage.retry_count=0 \
    --set-metadata "gasvillage.retry_reset_count=$reset_count" \
    --set-metadata "gasvillage.retry_reset_evidence=$EVIDENCE" \
    --unset-metadata gasvillage.last_failure_key \
    --unset-metadata gasvillage.same_failure_count \
    --append-notes "$note"; then
    die "guarded progress review failed; retry state was not reset; re-read $BEAD"
  fi
  fetch_issue
  [[ "$(issue_status)" == in_progress && "$(issue_assignee)" == "$OWNER" ]] \
    || die "progress review no longer owns the task; inspect $BEAD before acting"
  [[ "$(field 'gasvillage.retry_count')" == 0 ]] \
    || die "progress reset could not be verified; inspect $BEAD before acting"
  printf 'PROGRESS_REVIEWED bead=%s reviewer=%s retry_count=0 reset=%s\n' \
    "$BEAD" "$REVIEWER" "$reset_count"
}

case "$MODE" in
  hold) record_hold ;;
  retry) retry_task ;;
  resume) resume_task ;;
  review-progress) review_progress ;;
  *) usage >&2; die "unknown action '$MODE'" ;;
esac
