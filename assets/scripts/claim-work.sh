#!/usr/bin/env bash
# claim-work.sh — claim one routed bead for this polecat session, or recover
# this session's claim after the claim command's output was lost.
#
# Usage: claim-work.sh {claim|recover}
#
#   claim    Runs `gc hook --claim --json` exactly once. A work result is
#            verified by readback before it is reported. When the hook output
#            is lost, malformed, non-zero, or reports claims_errored, the
#            helper falls back to this session's current-claim pointer
#            (`gc hook current --id-only`) and verifies that bead instead.
#   recover  Never claims. Reads only `gc hook current --id-only` and verifies
#            that bead with the same readback.
#
# The helper never searches ready work, makes a second atomic claim, releases
# or reopens a bead, or acknowledges a drain while ownership is uncertain.
#
# Environment:
#   GC_RIG         required; the rig store the bead is read back from
#                  (`gc --rig "$GC_RIG" bd show`). The scoped read is the rig
#                  membership check.
#   GC_SESSION_ID  required; must equal the bead's gc.session_id, the session
#                  back-reference the SDK stamps when it claims for a session.
#   GC_BIN         optional gc binary override (tests).
#   GC_ALIAS, BEADS_ACTOR, GC_AGENT, GC_SESSION_NAME
#                  optional; with GC_SESSION_ID they form this session's own
#                  identity set. When a hook work result names the assignee,
#                  the readback must match that exact value. When no hook
#                  result is available (recover, or claim-mode fallback), the
#                  readback assignee must be one of these identities.
#
# Readback proof: exactly one record with the requested id, status
# in_progress, gc.session_id == $GC_SESSION_ID, and the expected assignee.
#
# Hook drain reasons: no_work is a clean empty result (the helper then runs
# `gc runtime drain-ack`); claims_errored means a claim may have happened, so
# the current pointer is consulted; any other drain reason is an explicit
# refusal of this session and is rejected without consulting the pointer.
# Any work-action reason is accepted; the readback decides ownership.
#
# Stdout markers and exit codes:
#   CLAIMED_BEAD_ID=<id>            exit 0   ownership verified; work on <id>.
#   CLAIM_RECOVERED reason=<r>      (info)   printed before the readback when
#                                            the bead came from the pointer.
#   NO_ROUTED_WORK reason=no_work   exit 0   no work; drain acknowledged.
#   CLAIM_UNKNOWN reason=<r>        exit 75  ambiguous or unreadable result;
#                                            preserve the bead and session.
#   CLAIM_REJECTED reason=<r>       exit 76  hook refusal, or the readback
#                                            does not prove ownership.
#   usage error                     exit 64
# CLI diagnostics from gc go to stderr.
set -euo pipefail

readonly EXIT_USAGE=64 EXIT_UNKNOWN=75 EXIT_REJECTED=76
readonly BEAD_ID_PATTERN='^[A-Za-z0-9][A-Za-z0-9._-]*$'
readonly READBACK_ATTEMPTS=3

MODE="${1:-}"
[[ "$MODE" == claim || "$MODE" == recover ]] || {
  echo "usage: claim-work.sh {claim|recover}" >&2
  exit "$EXIT_USAGE"
}

unknown() {
  printf 'CLAIM_UNKNOWN reason=%s\n' "$1"
  exit "$EXIT_UNKNOWN"
}

rejected() {
  printf 'CLAIM_REJECTED reason=%s\n' "$1"
  exit "$EXIT_REJECTED"
}

GC_BIN="${GC_BIN:-gc}"
GC_RIG="${GC_RIG:-}"
GC_SESSION_ID="${GC_SESSION_ID:-}"
[[ -n "$GC_RIG" ]] || rejected missing_rig
[[ -n "$GC_SESSION_ID" ]] || rejected missing_session_id

SESSION_IDENTITIES=()
for identity in "${GC_ALIAS:-}" "$GC_SESSION_ID" "${BEADS_ACTOR:-}" "${GC_AGENT:-}" "${GC_SESSION_NAME:-}"; do
  if [[ -n "$identity" ]]; then SESSION_IDENTITIES+=("$identity"); fi
done

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gasvillage-hook-claim.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

# report_diagnostics LABEL FILE copies a captured gc stderr file to stderr.
report_diagnostics() {
  if [[ -s "$2" ]]; then
    printf '%s diagnostics:\n' "$1" >&2
    cat "$2" >&2
  fi
}

# current_bead_id prints this session's current-claim bead id, or returns 1.
current_bead_id() {
  local output_file="$TMP_DIR/current.out" error_file="$TMP_DIR/current.err" bead_id
  if ! "$GC_BIN" hook current --id-only >"$output_file" 2>"$error_file"; then
    report_diagnostics 'gc hook current' "$error_file"
    return 1
  fi
  bead_id="$(sed -e 's/[[:space:]]*$//' "$output_file")"
  if [[ ! "$bead_id" =~ $BEAD_ID_PATTERN ]]; then
    printf 'gc hook current returned an invalid bead id\n' >&2
    return 1
  fi
  printf '%s' "$bead_id"
}

# is_session_identity VALUE succeeds when VALUE is one of this session's ids.
is_session_identity() {
  local identity
  for identity in "${SESSION_IDENTITIES[@]}"; do
    [[ "$1" == "$identity" ]] && return 0
  done
  return 1
}

# verify_bead ID [EXACT_ASSIGNEE] reads ID back from the rig store and prints
# CLAIMED_BEAD_ID only when the record proves this session owns it.
verify_bead() {
  local bead_id="$1" exact_assignee="${2:-}" attempt read_ok=0 status assignee session_id
  local show_file="$TMP_DIR/show.json" error_file="$TMP_DIR/show.err"
  for ((attempt = 1; attempt <= READBACK_ATTEMPTS; attempt++)); do
    if "$GC_BIN" --rig "$GC_RIG" bd show "$bead_id" --json >"$show_file" 2>"$error_file" \
      && jq -e . "$show_file" >/dev/null 2>&1; then
      read_ok=1
      break
    fi
    if ((attempt < READBACK_ATTEMPTS)); then sleep 1; fi
  done
  if [[ "$read_ok" != 1 ]]; then
    report_diagnostics 'gc bd show' "$error_file"
    unknown readback_unavailable
  fi

  jq -e --arg id "$bead_id" 'type == "array" and length == 1 and .[0].id == $id' \
    "$show_file" >/dev/null 2>&1 || rejected bead_identity_mismatch
  status="$(jq -r '.[0].status // empty' "$show_file")"
  assignee="$(jq -r '.[0].assignee // empty' "$show_file")"
  session_id="$(jq -r '.[0].metadata["gc.session_id"] // empty' "$show_file")"

  [[ "$status" == in_progress ]] || rejected stale_status
  [[ "$session_id" == "$GC_SESSION_ID" ]] || rejected stale_session
  if [[ -n "$exact_assignee" ]]; then
    [[ "$assignee" == "$exact_assignee" ]] || rejected foreign_assignee
  else
    is_session_identity "$assignee" || rejected foreign_assignee
  fi

  printf 'CLAIMED_BEAD_ID=%s\n' "$bead_id"
}

if [[ "$MODE" == recover ]]; then
  WORK_ID="$(current_bead_id)" || unknown no_current_assignment
  printf 'CLAIM_RECOVERED reason=current_pointer\n'
  verify_bead "$WORK_ID"
  exit 0
fi

HOOK_OUT="$TMP_DIR/hook.json"
HOOK_ERR="$TMP_DIR/hook.err"
if "$GC_BIN" hook --claim --json >"$HOOK_OUT" 2>"$HOOK_ERR"; then
  HOOK_CODE=0
else
  HOOK_CODE=$?
fi

hook_result_is() {
  jq -e "type == \"object\" and .schema_version == \"1\" and .ok == true and .command == \"hook\" and ($1)" \
    "$HOOK_OUT" >/dev/null 2>&1
}

if hook_result_is '.action == "drain" and .reason == "no_work"'; then
  "$GC_BIN" runtime drain-ack || unknown drain_ack_failed
  printf 'NO_ROUTED_WORK reason=no_work\n'
  exit 0
fi

if hook_result_is '.action == "drain" and (.reason | type == "string") and .reason != "claims_errored"'; then
  report_diagnostics 'gc hook' "$HOOK_ERR"
  rejected "$(jq -r '.reason' "$HOOK_OUT")"
fi

if [[ "$HOOK_CODE" -eq 0 ]] && hook_result_is '
  .action == "work"
  and (.reason | type == "string")
  and (.bead_id | type == "string" and length > 0)
  and (.assignee | type == "string" and length > 0)'; then
  WORK_ID="$(jq -r '.bead_id' "$HOOK_OUT")"
  HOOK_ASSIGNEE="$(jq -r '.assignee' "$HOOK_OUT")"
  [[ "$WORK_ID" =~ $BEAD_ID_PATTERN ]] || rejected invalid_bead_id
  verify_bead "$WORK_ID" "$HOOK_ASSIGNEE"
  exit 0
fi

if [[ "$HOOK_CODE" -eq 124 ]]; then
  RECOVERY_REASON=hook_timeout
elif [[ "$HOOK_CODE" -ne 0 ]]; then
  RECOVERY_REASON=hook_failed
elif [[ ! -s "$HOOK_OUT" ]]; then
  RECOVERY_REASON=empty_result
elif hook_result_is '.action == "drain" and .reason == "claims_errored"'; then
  RECOVERY_REASON=claim_error
else
  RECOVERY_REASON=malformed_result
fi
report_diagnostics 'gc hook' "$HOOK_ERR"
WORK_ID="$(current_bead_id)" || unknown "${RECOVERY_REASON}_no_current_assignment"
printf 'CLAIM_RECOVERED reason=%s\n' "$RECOVERY_REASON"
verify_bead "$WORK_ID"
