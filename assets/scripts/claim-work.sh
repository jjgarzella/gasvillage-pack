#!/usr/bin/env bash
# Claim one routed bead, or recover the current session's claim after lost output.
set -euo pipefail

MODE="${1:-}"
[[ "$MODE" == claim || "$MODE" == recover ]] || {
  echo "usage: claim-work.sh {claim|recover}" >&2
  exit 64
}

GC_BIN="${GC_BIN:-gc}"
GC_RIG="${GC_RIG:-}"
GC_SESSION_ID="${GC_SESSION_ID:-}"
EXPECTED_OWNER="${BEADS_ACTOR:-${GC_SESSION_NAME:-${GC_AGENT:-}}}"
[[ -n "$GC_RIG" ]] || { echo 'CLAIM_REJECTED reason=missing_rig'; exit 76; }
[[ -n "$GC_SESSION_ID" ]] || { echo 'CLAIM_REJECTED reason=missing_session_id'; exit 76; }
[[ -n "$EXPECTED_OWNER" ]] || { echo 'CLAIM_REJECTED reason=missing_assignee_identity'; exit 76; }

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gasvillage-hook-claim.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

unknown() {
  printf 'CLAIM_UNKNOWN reason=%s\n' "$1"
  exit 75
}

rejected() {
  printf 'CLAIM_REJECTED reason=%s\n' "$1"
  exit 76
}

report_hook_diagnostics() {
  if [ -s "$HOOK_ERR" ]; then
    printf 'gc hook diagnostics:\n' >&2
    cat "$HOOK_ERR" >&2
  fi
}

current_bead_id() {
  local output_file="$TMP_DIR/current.out" error_file="$TMP_DIR/current.err" bead_id
  if ! "$GC_BIN" hook current --id-only >"$output_file" 2>"$error_file"; then
    return 1
  fi
  bead_id="$(sed -e 's/[[:space:]]*$//' "$output_file")"
  [[ "$bead_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
  printf '%s' "$bead_id"
}

verify_current_bead() {
  local bead_id="$1" attempt show_file error_file read_ok=0 record_count found_id status assignee store_ref session_id claimed_at
  show_file="$TMP_DIR/show.json"
  error_file="$TMP_DIR/show.err"
  for attempt in 1 2 3; do
    if "$GC_BIN" --rig "$GC_RIG" bd show "$bead_id" --json >"$show_file" 2>"$error_file" \
      && jq -e --arg id "$bead_id" 'type == "array" and length == 1 and .[0].id == $id' "$show_file" >/dev/null 2>&1; then
      read_ok=1
      break
    fi
    if ((attempt < 3)); then sleep 1; fi
  done
  if [[ "$read_ok" != 1 ]]; then
    unknown readback_unavailable
  fi

  record_count="$(jq 'length' "$show_file")"
  found_id="$(jq -r '.[0].id // empty' "$show_file")"
  [[ "$record_count" == 1 && "$found_id" == "$bead_id" ]] || rejected bead_identity_mismatch
  status="$(jq -r '.[0].status // empty' "$show_file")"
  assignee="$(jq -r '.[0].assignee // empty' "$show_file")"
  store_ref="$(jq -r '.[0].metadata["gc.root_store_ref"] // empty' "$show_file")"
  session_id="$(jq -r '.[0].metadata["gc.session_id"] // empty' "$show_file")"
  claimed_at="$(jq -r '.[0].metadata["gc.claimed_at"] // empty' "$show_file")"

  [[ "$status" == in_progress ]] || rejected stale_status
  [[ "$assignee" == "$EXPECTED_OWNER" ]] || rejected foreign_assignee
  [[ "$store_ref" == "rig:$GC_RIG" ]] || rejected wrong_rig
  [[ "$session_id" == "$GC_SESSION_ID" ]] || rejected stale_session
  [[ -n "$claimed_at" ]] || rejected missing_claim_timestamp

  printf 'CLAIMED_BEAD_ID=%s\n' "$bead_id"
}

if [[ "$MODE" == recover ]]; then
  if ! WORK_ID="$(current_bead_id)"; then
    unknown no_current_assignment
  fi
  printf 'CLAIM_RECOVERED reason=current_pointer\n'
  verify_current_bead "$WORK_ID"
  exit 0
fi

HOOK_OUT="$TMP_DIR/hook.json"
HOOK_ERR="$TMP_DIR/hook.err"
if "$GC_BIN" hook --claim --json >"$HOOK_OUT" 2>"$HOOK_ERR"; then
  HOOK_CODE=0
else
  HOOK_CODE=$?
fi

if jq -e '
  type == "object"
  and .schema_version == "1"
  and .ok == true
  and .command == "hook"
  and .action == "drain"
  and .reason == "no_work"
' "$HOOK_OUT" >/dev/null 2>&1; then
  if ! "$GC_BIN" runtime drain-ack; then
    unknown drain_ack_failed
  fi
  printf 'NO_ROUTED_WORK reason=no_work\n'
  exit 0
fi

if jq -e '
  type == "object"
  and .schema_version == "1"
  and .ok == true
  and .command == "hook"
  and .action == "drain"
  and (.reason | type == "string")
  and .reason != "no_work"
  and .reason != "claims_errored"
' "$HOOK_OUT" >/dev/null 2>&1; then
  HOOK_REASON="$(jq -r '.reason' "$HOOK_OUT")"
  rejected "$HOOK_REASON"
fi

WORK_ID=""
RECOVERY_REASON=""
if [[ "$HOOK_CODE" -eq 0 ]] && jq -e '
  type == "object"
  and .schema_version == "1"
  and .ok == true
  and .command == "hook"
  and .action == "work"
  and (.reason == "claimed" or .reason == "existing_assignment" or .reason == "ready_assignment")
  and (.bead_id | type == "string" and length > 0)
  and (.assignee | type == "string" and length > 0)
' "$HOOK_OUT" >/dev/null 2>&1; then
  WORK_ID="$(jq -r '.bead_id' "$HOOK_OUT")"
else
  if [[ "$HOOK_CODE" -eq 124 ]]; then
    RECOVERY_REASON=hook_timeout
  elif [[ "$HOOK_CODE" -ne 0 ]]; then
    RECOVERY_REASON=hook_failed
  elif [[ ! -s "$HOOK_OUT" ]]; then
    RECOVERY_REASON=empty_result
  elif jq -e 'type == "object" and .action == "drain" and .reason == "claims_errored"' "$HOOK_OUT" >/dev/null 2>&1; then
    RECOVERY_REASON=claim_error
  else
    RECOVERY_REASON=malformed_result
  fi
  report_hook_diagnostics
  if ! WORK_ID="$(current_bead_id)"; then
    unknown "${RECOVERY_REASON}_no_current_assignment"
  fi
fi

[[ "$WORK_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || rejected invalid_bead_id
if [[ -n "$RECOVERY_REASON" ]]; then
  printf 'CLAIM_RECOVERED reason=%s\n' "$RECOVERY_REASON"
fi
verify_current_bead "$WORK_ID"
