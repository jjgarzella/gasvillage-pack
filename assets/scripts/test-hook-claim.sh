#!/usr/bin/env bash
# Disposable fake-CLI checks for claim result recovery. Never contacts a live city.
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/claim-work.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export MOCK_STATE="$TMP/bead.json" MOCK_CURRENT="$TMP/current" \
  MOCK_LOG="$TMP/gc.log" MOCK_HOOK_PID="$TMP/hook.pid"
MOCK_GC="$TMP/gc"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "expected '$2', got '$1'"; }
assert_has() { grep -Fq -- "$2" "$1" || fail "'$2' not found in $1"; }
assert_lacks() { ! grep -Fq -- "$2" "$1" || fail "unexpected '$2' in $1"; }

cat >"$MOCK_GC" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
rig=""
if [[ "${1:-}" == --rig ]]; then rig="$2"; shift 2; fi
printf '%s %s\n' "$rig" "$*" >>"$MOCK_LOG"

record_claim() {
  rig="${rig:-${GC_RIG:-}}"
  jq --arg owner "${BEADS_ACTOR:-worker}" --arg session "${GC_SESSION_ID:-session-a}" \
    --arg rig "$rig" --arg route "$rig/polecat" \
    '.[0].status="in_progress"
     | .[0].assignee=$owner
     | .[0].metadata["gc.routed_to"]=$route
     | .[0].metadata["gc.root_store_ref"]="rig:"+$rig
     | .[0].metadata["gc.session_id"]=$session
     | .[0].metadata["gc.claimed_at"]="2026-11-24T14:00:00Z"' \
    "$MOCK_STATE" >"$MOCK_STATE.tmp"
  mv "$MOCK_STATE.tmp" "$MOCK_STATE"
  printf 'fx-1\n' >"$MOCK_CURRENT"
  printf 'hook_claimed\n' >>"$MOCK_LOG"
}

if [[ "${1:-}" == hook && "${2:-}" == --claim ]]; then
  printf 'hook_calls\n' >>"$MOCK_LOG"
  case "${MOCK_HOOK_MODE:-success}" in
    no_work|no_work_nonzero)
      printf '{"schema_version":"1","ok":true,"command":"hook","action":"drain","reason":"no_work"}\n'
      [[ "${MOCK_HOOK_MODE}" != no_work_nonzero ]] || exit 1
      exit 0
      ;;
    timeout)
      echo 'mock hook timed out' >&2
      exit 124
      ;;
    claims_errored)
      printf '{"schema_version":"1","ok":true,"command":"hook","action":"drain","reason":"claims_errored"}\n'
      exit 0
      ;;
    stale_session|non_turn_context|drain_pending|missing_session_registration|stale_session_nonzero)
      reason="${MOCK_HOOK_MODE%_nonzero}"
      printf '{"schema_version":"1","ok":true,"command":"hook","action":"drain","reason":"%s"}\n' "$reason"
      [[ "${MOCK_HOOK_MODE}" != stale_session_nonzero ]] || exit 1
      exit 0
      ;;
    malformed_no_claim)
      printf '{broken'
      exit 0
      ;;
    empty_no_claim)
      exit 0
      ;;
    success|slow|lost_stdout|malformed|claimed_nonzero)
      record_claim
      ;;
    *) echo "unknown mock hook mode" >&2; exit 2 ;;
  esac
  if [[ "${MOCK_HOOK_MODE:-success}" == slow ]]; then
    printf '%s\n' "$$" >"$MOCK_HOOK_PID"
    sleep "${MOCK_HOOK_DELAY:-1}"
  fi
  if [[ "${MOCK_HOOK_MODE:-success}" == lost_stdout ]]; then exit 0; fi
  if [[ "${MOCK_HOOK_MODE:-success}" == malformed ]]; then printf '{broken'; exit 0; fi
  if [[ "${MOCK_HOOK_MODE:-success}" == claimed_nonzero ]]; then exit 1; fi
  printf '{"schema_version":"1","ok":true,"command":"hook","action":"work","reason":"claimed","bead_id":"fx-1","assignee":"worker","route":"%s/polecat"}\n' "$rig"
  exit 0
fi

if [[ "${1:-}" == hook && "${2:-}" == current ]]; then
  printf 'current_calls\n' >>"$MOCK_LOG"
  [[ -s "$MOCK_CURRENT" ]] || { echo 'no current bead' >&2; exit 1; }
  cat "$MOCK_CURRENT"
  exit 0
fi

if [[ "${1:-}" == bd && "${2:-}" == show ]]; then
  printf 'show_calls\n' >>"$MOCK_LOG"
  case "${MOCK_SHOW_MODE:-}" in
    fail) echo 'mock read timeout' >&2; exit 124 ;;
    fail_valid_json) cat "$MOCK_STATE"; exit 1 ;;
  esac
  bead="$3"
  [[ "$bead" == fx-1 ]] || exit 7
  case "${MOCK_READBACK:-normal}" in
    normal) cat "$MOCK_STATE" ;;
    foreign_owner) jq '.[0].assignee="other-worker"' "$MOCK_STATE" ;;
    stale_session) jq '.[0].metadata["gc.session_id"]="old-session"' "$MOCK_STATE" ;;
    wrong_rig) jq '.[0].metadata["gc.root_store_ref"]="rig:other"' "$MOCK_STATE" ;;
    stale_status) jq '.[0].status="closed"' "$MOCK_STATE" ;;
    missing_claim_timestamp) jq 'del(.[0].metadata["gc.claimed_at"])' "$MOCK_STATE" ;;
    *) exit 8 ;;
  esac
  exit 0
fi

if [[ "${1:-}" == runtime && "${2:-}" == drain-ack ]]; then
  printf 'drain_ack\n' >>"$MOCK_LOG"
  [[ "${MOCK_DRAIN_ACK_MODE:-}" != fail ]] || { echo 'mock drain ack failed' >&2; exit 1; }
  exit 0
fi

echo "unexpected mock gc command: $*" >&2
exit 9
MOCK
chmod +x "$MOCK_GC"

export GC_BIN="$MOCK_GC" GC_RIG=research BEADS_ACTOR=worker GC_AGENT=worker GC_SESSION_ID=session-a

reset_state() {
  jq -n '[{id:"fx-1",status:"open",assignee:"",metadata:{}}]' >"$MOCK_STATE"
  : >"$MOCK_LOG"
  : >"$MOCK_CURRENT"
  rm -f "$MOCK_HOOK_PID"
  unset MOCK_HOOK_MODE MOCK_HOOK_DELAY MOCK_SHOW_MODE MOCK_READBACK MOCK_DRAIN_ACK_MODE
}

set_current_claimed() {
  jq '.[0].status="in_progress"
      | .[0].assignee="worker"
      | .[0].metadata={"gc.root_store_ref":"rig:research","gc.session_id":"session-a","gc.claimed_at":"2026-11-24T14:00:00Z"}' \
    "$MOCK_STATE" >"$MOCK_STATE.tmp"
  mv "$MOCK_STATE.tmp" "$MOCK_STATE"
  printf 'fx-1\n' >"$MOCK_CURRENT"
}

wait_for_file() {
  local path="$1" attempts="$2" delay="$3" attempt
  for ((attempt = 0; attempt < attempts; attempt++)); do
    [[ -s "$path" ]] && return 0
    sleep "$delay"
  done
  return 1
}

expect_rejected() {
  local mode="$1" reason="$2" code="$3" output rc
  reset_state
  export MOCK_HOOK_MODE=success MOCK_READBACK="$mode"
  set +e
  output="$("$HELPER" claim 2>&1)"
  rc=$?
  set -e
  assert_eq "$rc" "$code"
  assert_has <(printf '%s\n' "$output") "CLAIM_REJECTED reason=$reason"
  assert_eq "$(grep -c '^hook_calls$' "$MOCK_LOG")" 1
  assert_lacks "$MOCK_LOG" 'bd update'
  assert_lacks "$MOCK_LOG" 'drain_ack'
}

[[ -x "$HELPER" ]] || fail "missing executable helper: $HELPER"

reset_state
set +e
output="$(env -u GC_RIG "$HELPER" claim 2>&1)"
rc=$?
set -e
assert_eq "$rc" 76
assert_has <(printf '%s\n' "$output") 'CLAIM_REJECTED reason=missing_rig'
assert_lacks "$MOCK_LOG" 'hook_calls'

reset_state
set +e
output="$(env -u GC_SESSION_ID "$HELPER" claim 2>&1)"
rc=$?
set -e
assert_eq "$rc" 76
assert_has <(printf '%s\n' "$output") 'CLAIM_REJECTED reason=missing_session_id'
assert_lacks "$MOCK_LOG" 'hook_calls'

reset_state
set +e
output="$(env -u BEADS_ACTOR -u GC_SESSION_NAME -u GC_AGENT "$HELPER" claim 2>&1)"
rc=$?
set -e
assert_eq "$rc" 76
assert_has <(printf '%s\n' "$output") 'CLAIM_REJECTED reason=missing_assignee_identity'
assert_lacks "$MOCK_LOG" 'hook_calls'

reset_state
output="$("$HELPER" claim)"
assert_has <(printf '%s\n' "$output") 'CLAIMED_BEAD_ID=fx-1'
assert_eq "$(grep -c '^hook_calls$' "$MOCK_LOG")" 1
assert_eq "$(grep -c '^show_calls$' "$MOCK_LOG")" 1
assert_lacks "$MOCK_LOG" 'current_calls'
assert_lacks "$MOCK_LOG" 'bd ready'
assert_lacks "$MOCK_LOG" 'bd list'
assert_lacks "$MOCK_LOG" 'bd update'

reset_state
export MOCK_HOOK_MODE=no_work
output="$("$HELPER" claim)"
assert_has <(printf '%s\n' "$output") 'NO_ROUTED_WORK reason=no_work'
assert_eq "$(grep -c '^hook_calls$' "$MOCK_LOG")" 1
assert_lacks "$MOCK_LOG" 'current_calls'
assert_lacks "$MOCK_LOG" 'show_calls'
assert_has "$MOCK_LOG" 'drain_ack'

reset_state
export MOCK_HOOK_MODE=no_work_nonzero
output="$("$HELPER" claim)"
assert_has <(printf '%s\n' "$output") 'NO_ROUTED_WORK reason=no_work'
assert_eq "$(grep -c '^hook_calls$' "$MOCK_LOG")" 1
assert_lacks "$MOCK_LOG" 'current_calls'
assert_lacks "$MOCK_LOG" 'show_calls'
assert_has "$MOCK_LOG" 'drain_ack'

reset_state
export MOCK_HOOK_MODE=no_work MOCK_DRAIN_ACK_MODE=fail
set +e
output="$("$HELPER" claim 2>&1)"
rc=$?
set -e
assert_eq "$rc" 75
assert_has <(printf '%s\n' "$output") 'CLAIM_UNKNOWN reason=drain_ack_failed'
assert_eq "$(grep -c '^hook_calls$' "$MOCK_LOG")" 1
assert_has "$MOCK_LOG" 'drain_ack'
assert_lacks "$MOCK_LOG" 'current_calls'
assert_lacks "$MOCK_LOG" 'show_calls'

for mode in lost_stdout malformed claimed_nonzero; do
  reset_state
  export MOCK_HOOK_MODE="$mode"
  output="$("$HELPER" claim)"
  assert_has <(printf '%s\n' "$output") 'CLAIMED_BEAD_ID=fx-1'
  case "$mode" in
    lost_stdout) assert_has <(printf '%s\n' "$output") 'CLAIM_RECOVERED reason=empty_result' ;;
    malformed) assert_has <(printf '%s\n' "$output") 'CLAIM_RECOVERED reason=malformed_result' ;;
    claimed_nonzero) assert_has <(printf '%s\n' "$output") 'CLAIM_RECOVERED reason=hook_failed' ;;
  esac
  assert_eq "$(grep -c '^hook_calls$' "$MOCK_LOG")" 1
  assert_eq "$(grep -c '^current_calls$' "$MOCK_LOG")" 1
  assert_eq "$(grep -c '^show_calls$' "$MOCK_LOG")" 1
  assert_lacks "$MOCK_LOG" 'bd update'
done

# A tool can yield while the original nested CLI is still running. Keep the
# exact process handle, wait for that process, then simulate its response being
# lost and recover only through the session's current-claim pointer.
reset_state
export MOCK_HOOK_MODE=slow MOCK_HOOK_DELAY=1
started="$(date +%s)"
"$HELPER" claim >"$TMP/original.out" 2>"$TMP/original.err" &
original_pid=$!
wait_for_file "$MOCK_HOOK_PID" 100 0.01 || fail 'mock hook did not publish its pid within the bounded wait'
hook_pid="$(cat "$MOCK_HOOK_PID")"
kill -0 "$original_pid" 2>/dev/null || fail 'original helper exited before the simulated tool yield'
kill -0 "$hook_pid" 2>/dev/null || fail 'nested gc process exited before the simulated tool yield'
assert_has "$MOCK_LOG" 'hook_claimed'
wait "$original_pid"
completed="$(date +%s)"
((completed - started >= 1)) || fail 'original nested command did not remain active for the measured delay'
kill -0 "$hook_pid" 2>/dev/null && fail 'nested gc process remained alive after its original handle completed'
: >"$TMP/original.out" # the outer tool lost the completed result/marker
output="$("$HELPER" recover)"
assert_has <(printf '%s\n' "$output") 'CLAIMED_BEAD_ID=fx-1'
assert_eq "$(grep -c '^hook_calls$' "$MOCK_LOG")" 1
assert_eq "$(grep -c '^current_calls$' "$MOCK_LOG")" 1
assert_eq "$(grep -c '^show_calls$' "$MOCK_LOG")" 2

reset_state
export MOCK_HOOK_MODE=timeout
set +e
output="$("$HELPER" claim 2>&1)"
rc=$?
set -e
assert_eq "$rc" 75
assert_has <(printf '%s\n' "$output") 'CLAIM_UNKNOWN reason=hook_timeout_no_current_assignment'
assert_has <(printf '%s\n' "$output") 'mock hook timed out'
assert_eq "$(grep -c '^hook_calls$' "$MOCK_LOG")" 1
assert_eq "$(grep -c '^current_calls$' "$MOCK_LOG")" 1
assert_lacks "$MOCK_LOG" 'drain_ack'

reset_state
export MOCK_HOOK_MODE=claims_errored
set +e
output="$("$HELPER" claim 2>&1)"
rc=$?
set -e
assert_eq "$rc" 75
assert_has <(printf '%s\n' "$output") 'CLAIM_UNKNOWN reason=claim_error_no_current_assignment'
assert_lacks "$MOCK_LOG" 'drain_ack'

for reason in stale_session non_turn_context drain_pending missing_session_registration; do
  reset_state
  export MOCK_HOOK_MODE="$reason"
  set_current_claimed
  set +e
  output="$("$HELPER" claim 2>&1)"
  rc=$?
  set -e
  assert_eq "$rc" 76
  assert_has <(printf '%s\n' "$output") "CLAIM_REJECTED reason=$reason"
  assert_eq "$(grep -c '^hook_calls$' "$MOCK_LOG")" 1
  assert_lacks "$MOCK_LOG" 'current_calls'
  assert_lacks "$MOCK_LOG" 'show_calls'
  assert_lacks "$MOCK_LOG" 'drain_ack'
done

reset_state
export MOCK_HOOK_MODE=stale_session_nonzero
set_current_claimed
set +e
output="$("$HELPER" claim 2>&1)"
rc=$?
set -e
assert_eq "$rc" 76
assert_has <(printf '%s\n' "$output") 'CLAIM_REJECTED reason=stale_session'
assert_eq "$(grep -c '^hook_calls$' "$MOCK_LOG")" 1
assert_lacks "$MOCK_LOG" 'current_calls'
assert_lacks "$MOCK_LOG" 'show_calls'
assert_lacks "$MOCK_LOG" 'drain_ack'

for mode in malformed_no_claim empty_no_claim; do
  reset_state
  export MOCK_HOOK_MODE="$mode"
  set +e
  output="$("$HELPER" claim 2>&1)"
  rc=$?
  set -e
  assert_eq "$rc" 75
  if [[ "$mode" == malformed_no_claim ]]; then
    assert_has <(printf '%s\n' "$output") 'CLAIM_UNKNOWN reason=malformed_result_no_current_assignment'
  else
    assert_has <(printf '%s\n' "$output") 'CLAIM_UNKNOWN reason=empty_result_no_current_assignment'
  fi
  assert_eq "$(grep -c '^hook_calls$' "$MOCK_LOG")" 1
  assert_eq "$(grep -c '^current_calls$' "$MOCK_LOG")" 1
  assert_lacks "$MOCK_LOG" 'drain_ack'
done

reset_state
export MOCK_HOOK_MODE=success MOCK_SHOW_MODE=fail
set +e
output="$("$HELPER" claim 2>&1)"
rc=$?
set -e
assert_eq "$rc" 75
assert_has <(printf '%s\n' "$output") 'CLAIM_UNKNOWN reason=readback_unavailable'
assert_eq "$(grep -c '^hook_calls$' "$MOCK_LOG")" 1
assert_eq "$(grep -c '^show_calls$' "$MOCK_LOG")" 3
assert_lacks "$MOCK_LOG" 'current_calls'
assert_lacks "$MOCK_LOG" 'bd update'
assert_lacks "$MOCK_LOG" 'drain_ack'

reset_state
export MOCK_HOOK_MODE=success MOCK_SHOW_MODE=fail_valid_json
set +e
output="$("$HELPER" claim 2>&1)"
rc=$?
set -e
assert_eq "$rc" 75
assert_has <(printf '%s\n' "$output") 'CLAIM_UNKNOWN reason=readback_unavailable'
assert_eq "$(grep -c '^hook_calls$' "$MOCK_LOG")" 1
assert_eq "$(grep -c '^show_calls$' "$MOCK_LOG")" 3
assert_lacks "$MOCK_LOG" 'current_calls'
assert_lacks "$MOCK_LOG" 'bd update'
assert_lacks "$MOCK_LOG" 'drain_ack'

expect_rejected foreign_owner foreign_assignee 76
expect_rejected stale_session stale_session 76
expect_rejected wrong_rig wrong_rig 76
expect_rejected stale_status stale_status 76
expect_rejected missing_claim_timestamp missing_claim_timestamp 76

reset_state
printf 'fx-1\n' >"$MOCK_CURRENT"
jq '.[0].status="in_progress" | .[0].assignee="worker" | .[0].metadata={"gc.root_store_ref":"rig:research","gc.session_id":"session-a","gc.claimed_at":"2026-11-24T14:00:00Z"}' \
  "$MOCK_STATE" >"$MOCK_STATE.tmp"
mv "$MOCK_STATE.tmp" "$MOCK_STATE"
output="$("$HELPER" recover)"
assert_has <(printf '%s\n' "$output") 'CLAIMED_BEAD_ID=fx-1'
assert_lacks "$MOCK_LOG" 'hook_calls'

echo 'PASS: hook claim recovery mock-CLI checks'
