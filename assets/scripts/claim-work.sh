#!/usr/bin/env bash
# claim-work.sh — claim one routed bead for this polecat session, or recover
# this session's claim after the claim command's output was lost.
#
# Usage: claim-work.sh {claim|recover}
#
#   claim    Runs `gc hook --claim --drain-ack --json` exactly once. A work
#            result is verified by readback before it is reported. A drain
#            result is reported from the SDK's own acknowledgment. When the
#            hook output is lost, malformed, or a non-zero exit without a drain
#            record, the helper falls back to this session's current-claim
#            pointer (`gc hook current --id-only`) and verifies that bead.
#   recover  Never claims. Reads only `gc hook current --id-only` and verifies
#            that bead with the same readback.
#
# The helper never searches ready work, makes a second atomic claim, releases
# or reopens a bead, or runs `gc runtime drain-ack` itself.
#
# Environment:
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
# Drains are the SDK's decision. `--drain-ack` makes the hook acknowledge every
# drain it is allowed to acknowledge (it claimed nothing) and report that in
# .drain_acknowledged; it never acknowledges a refusal that a turn must not
# acknowledge, such as non_turn_context. The helper branches only on the drain
# record's acknowledgment and the hook's exit status, never on a list of drain
# reasons, so a reason the SDK adds later needs no change here. The SDK's drain
# contract is cmd/gc/cmd_hook_claim.go writeHookClaimDrain (acknowledged: exit
# 0; acknowledgment failed: exit 1 with the record still written) and
# writeHookClaimNonTurnDrain (never acknowledged, exit 0).
#
# Readback: `gc bd show <id> --json`, deliberately not rig-scoped. The hook
# federates its claim across the rig store and the city store and its result
# does not name the store, so the SDK's id routing picks the store that owns
# the bead. Ownership proof: exactly one record with the requested id, status
# in_progress, gc.session_id == $GC_SESSION_ID, and the expected assignee.
#
# Current-claim pointer: `gc hook current` exits 1 both when the session has
# claimed nothing and when the lookup itself fails. The SDK distinguishes them
# only in its stderr text (cmd/gc/cmd_hook_current.go doHookCurrent), so the
# helper matches NO_CURRENT_CLAIM_DIAGNOSTIC; test-hook-claim.sh fails when the
# installed gc no longer contains that text. The pointer is the bead this
# session most recently claimed and is not cleared when that bead closes.
#
# Stdout carries only these markers, exactly one terminal marker per run:
#   CLAIMED_BEAD_ID=<id>            exit 0   ownership verified; work on <id>.
#   CLAIM_RECOVERED reason=<r>      (info)   printed before the readback when
#                                            the bead came from the pointer.
#   SESSION_DRAINED reason=<r>      exit 0   the hook drained without claiming
#                                            and the SDK acknowledged the drain.
#   CLAIM_UNKNOWN reason=<r>        exit 75  ownership is unproven; preserve the
#                                            bead and session.
#   CLAIM_REJECTED reason=<r>       exit 76  hook refusal, or the readback
#                                            disproves ownership.
#   usage error                     exit 64  (no marker)
# Diagnostics, including gc output, go to stderr.
#
# Reasons (every <r> matches ^[a-z][a-z_]*$):
#   SESSION_DRAINED  the SDK drain reason as reported (no_work, claims_errored,
#                    drain_pending, stale_session, missing_session_registration,
#                    or any later one), or invalid_drain_reason.
#   CLAIM_RECOVERED  current_pointer (recover mode); hook_timeout, hook_failed,
#                    empty_result, malformed_result (claim-mode fallback).
#   CLAIM_UNKNOWN    readback_unavailable  the readback could not be read.
#                    drain_ack_failed      a drain the SDK failed to acknowledge.
#                    Pointer failures, alone in recover mode and as
#                    <fallback>_<failure> in claim mode (for example
#                    hook_failed_no_current_assignment):
#                      no_current_assignment  the SDK reported no current claim.
#                      pointer_closed         the pointer names a closed bead,
#                                             the session's finished claim.
#                      current_unavailable    the pointer lookup failed.
#                      invalid_current_pointer  not a well-formed bead id.
#   CLAIM_REJECTED   missing_session_id    GC_SESSION_ID is unset.
#                    invalid_bead_id       the hook's bead id is malformed.
#                    bead_identity_mismatch  the readback is not that one bead.
#                    stale_status          the bead is not in_progress.
#                    foreign_session_id    gc.session_id names another session.
#                    foreign_assignee      the assignee is not the expected one.
#                    A drain the SDK did not acknowledge but exited 0 for
#                    (non_turn_context, or any later such refusal), reported
#                    with the SDK reason or invalid_drain_reason.
set -euo pipefail

readonly EXIT_USAGE=64 EXIT_UNKNOWN=75 EXIT_REJECTED=76
readonly BEAD_ID_PATTERN='^[A-Za-z0-9][A-Za-z0-9._-]*$'
readonly REASON_PATTERN='^[a-z][a-z_]*$'
readonly NO_CURRENT_CLAIM_DIAGNOSTIC='has no current claim'
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
GC_SESSION_ID="${GC_SESSION_ID:-}"
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

# read_current_pointer sets CURRENT_ID to this session's current-claim bead id.
# On failure it sets POINTER_FAILURE (see the header) and returns 1.
read_current_pointer() {
  local output_file="$TMP_DIR/current.out" error_file="$TMP_DIR/current.err"
  CURRENT_ID=""
  POINTER_FAILURE=""
  if ! "$GC_BIN" hook current --id-only >"$output_file" 2>"$error_file"; then
    report_diagnostics 'gc hook current' "$error_file"
    if grep -Fq "$NO_CURRENT_CLAIM_DIAGNOSTIC" "$error_file"; then
      POINTER_FAILURE=no_current_assignment
    else
      POINTER_FAILURE=current_unavailable
    fi
    return 1
  fi
  CURRENT_ID="$(sed -e 's/[[:space:]]*$//' "$output_file")"
  if [[ ! "$CURRENT_ID" =~ $BEAD_ID_PATTERN ]]; then
    printf 'gc hook current returned an invalid bead id\n' >&2
    POINTER_FAILURE=invalid_current_pointer
    return 1
  fi
}

# is_session_identity VALUE succeeds when VALUE is one of this session's ids.
is_session_identity() {
  local identity
  for identity in "${SESSION_IDENTITIES[@]}"; do
    [[ "$1" == "$identity" ]] && return 0
  done
  return 1
}

# verify_bead ID [EXACT_ASSIGNEE [CLOSED_REASON]] reads ID back from its owning
# store and prints CLAIMED_BEAD_ID only when the record proves this session owns
# it. With CLOSED_REASON (pointer-derived ids), a closed bead is this session's
# finished claim, not a disproven one: it reports CLAIM_UNKNOWN CLOSED_REASON.
verify_bead() {
  local bead_id="$1" exact_assignee="${2:-}" closed_reason="${3:-}"
  local attempt read_ok=0 status assignee session_id
  local show_file="$TMP_DIR/show.json" error_file="$TMP_DIR/show.err"
  for ((attempt = 1; attempt <= READBACK_ATTEMPTS; attempt++)); do
    if "$GC_BIN" bd show "$bead_id" --json >"$show_file" 2>"$error_file" \
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

  if [[ -n "$closed_reason" && "$status" == closed ]]; then
    printf 'current-claim pointer names closed bead %s\n' "$bead_id" >&2
    unknown "$closed_reason"
  fi
  [[ "$status" == in_progress ]] || rejected stale_status
  [[ "$session_id" == "$GC_SESSION_ID" ]] || rejected foreign_session_id
  if [[ -n "$exact_assignee" ]]; then
    [[ "$assignee" == "$exact_assignee" ]] || rejected foreign_assignee
  else
    is_session_identity "$assignee" || rejected foreign_assignee
  fi

  printf 'CLAIMED_BEAD_ID=%s\n' "$bead_id"
}

if [[ "$MODE" == recover ]]; then
  read_current_pointer || unknown "$POINTER_FAILURE"
  printf 'CLAIM_RECOVERED reason=current_pointer\n'
  verify_bead "$CURRENT_ID" "" pointer_closed
  exit 0
fi

HOOK_OUT="$TMP_DIR/hook.json"
HOOK_ERR="$TMP_DIR/hook.err"
if "$GC_BIN" hook --claim --drain-ack --json >"$HOOK_OUT" 2>"$HOOK_ERR"; then
  HOOK_CODE=0
else
  HOOK_CODE=$?
fi

hook_result_is() {
  jq -e "type == \"object\" and .schema_version == \"1\" and .ok == true and .command == \"hook\" and ($1)" \
    "$HOOK_OUT" >/dev/null 2>&1
}

# A drain record means the hook claimed nothing, whatever its exit status. The
# reason is SDK text echoed into the marker stream, so it is printed only when
# it is a single plain token.
if hook_result_is '.action == "drain"'; then
  report_diagnostics 'gc hook' "$HOOK_ERR"
  DRAIN_REASON="$(jq -r --arg pattern "$REASON_PATTERN" \
    'if (.reason | type == "string") and (.reason | test($pattern)) then .reason else "invalid_drain_reason" end' \
    "$HOOK_OUT")"
  if hook_result_is '.drain_acknowledged == true'; then
    printf 'SESSION_DRAINED reason=%s\n' "$DRAIN_REASON"
    exit 0
  fi
  [[ "$HOOK_CODE" -eq 0 ]] || unknown drain_ack_failed
  rejected "$DRAIN_REASON"
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
else
  RECOVERY_REASON=malformed_result
fi
report_diagnostics 'gc hook' "$HOOK_ERR"
read_current_pointer || unknown "${RECOVERY_REASON}_${POINTER_FAILURE}"
printf 'CLAIM_RECOVERED reason=%s\n' "$RECOVERY_REASON"
verify_bead "$CURRENT_ID" "" "${RECOVERY_REASON}_pointer_closed"
