#!/usr/bin/env bash
# Disposable fake-CLI checks for claim result recovery. Never contacts a live city.
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/claim-work.sh"
PROMPT_TEMPLATE="$SCRIPT_DIR/../../agents/polecat/prompt.template.md"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export MOCK_STATE="$TMP/bead.json" MOCK_CURRENT="$TMP/current" \
  MOCK_LOG="$TMP/gc.log" MOCK_HOOK_PID="$TMP/hook.pid" MOCK_SHOW_COUNT="$TMP/show.count"
MOCK_GC="$TMP/gc"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "expected '$2', got '$1'"; }
assert_has() { grep -Fq -- "$2" "$1" || fail "'$2' not found in $1"; }
assert_lacks() { ! grep -Fq -- "$2" "$1" || fail "unexpected '$2' in $1"; }
assert_output_has() { assert_has <(printf '%s\n' "$OUTPUT") "$1"; }
assert_calls() { assert_eq "$(grep -c "^$1\$" "$MOCK_LOG" || true)" "$2"; }

# run CMD... captures combined output in OUTPUT and the exit status in RC.
run() {
  set +e
  OUTPUT="$("$@" 2>&1)"
  RC=$?
  set -e
}

# The mock records the claim under MOCK_ASSIGNEE, independently of the
# helper's identity variables, the way the SDK picks its own claim identity.
cat >"$MOCK_GC" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
rig=""
if [[ "${1:-}" == --rig ]]; then rig="$2"; shift 2; fi
printf '%s %s\n' "$rig" "$*" >>"$MOCK_LOG"

record_claim() {
  jq --arg owner "${MOCK_ASSIGNEE:-session-a}" --arg session "${GC_SESSION_ID:-}" \
    '.[0].status="in_progress"
     | .[0].assignee=$owner
     | .[0].metadata["gc.session_id"]=$session' \
    "$MOCK_STATE" >"$MOCK_STATE.tmp"
  mv "$MOCK_STATE.tmp" "$MOCK_STATE"
  printf 'fx-1\n' >"$MOCK_CURRENT"
  printf 'hook_claimed\n' >>"$MOCK_LOG"
}

work_result() {
  jq -cn --arg reason "${MOCK_HOOK_REASON:-claimed}" --arg bead "$1" \
    --arg assignee "${MOCK_HOOK_ASSIGNEE:-${MOCK_ASSIGNEE:-session-a}}" \
    '{schema_version:"1",ok:true,command:"hook",action:"work",reason:$reason,bead_id:$bead,assignee:$assignee}'
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
    invalid_id)
      work_result "${MOCK_HOOK_BEAD_ID:-../x}"
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
  work_result fx-1
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
  count=$(( $(cat "$MOCK_SHOW_COUNT" 2>/dev/null || echo 0) + 1 ))
  printf '%s\n' "$count" >"$MOCK_SHOW_COUNT"
  case "${MOCK_SHOW_MODE:-}" in
    fail) echo 'mock read timeout' >&2; exit 124 ;;
    fail_valid_json) cat "$MOCK_STATE"; exit 1 ;;
    flaky) ((count > ${MOCK_SHOW_FAILURES:-1})) || { echo 'mock transient read failure' >&2; exit 124; } ;;
  esac
  bead="$3"
  [[ "$bead" == fx-1 ]] || exit 7
  case "${MOCK_READBACK:-normal}" in
    normal) cat "$MOCK_STATE" ;;
    foreign_owner) jq '.[0].assignee="other-worker"' "$MOCK_STATE" ;;
    stale_session) jq '.[0].metadata["gc.session_id"]="old-session"' "$MOCK_STATE" ;;
    stale_status) jq '.[0].status="closed"' "$MOCK_STATE" ;;
    wrong_id) jq '.[0].id="fx-2"' "$MOCK_STATE" ;;
    two_records) jq '. + .' "$MOCK_STATE" ;;
    object) jq '.[0]' "$MOCK_STATE" ;;
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

# A pool session with no alias: the SDK records its claims under GC_SESSION_ID.
export GC_BIN="$MOCK_GC" GC_RIG=research GC_SESSION_ID=session-a
unset GC_ALIAS BEADS_ACTOR GC_AGENT GC_SESSION_NAME

reset_state() {
  jq -n '[{id:"fx-1",status:"open",assignee:"",metadata:{}}]' >"$MOCK_STATE"
  : >"$MOCK_LOG"
  : >"$MOCK_CURRENT"
  rm -f "$MOCK_HOOK_PID" "$MOCK_SHOW_COUNT"
  unset MOCK_HOOK_MODE MOCK_HOOK_DELAY MOCK_HOOK_REASON MOCK_HOOK_ASSIGNEE MOCK_HOOK_BEAD_ID \
    MOCK_ASSIGNEE MOCK_SHOW_MODE MOCK_SHOW_FAILURES MOCK_READBACK MOCK_DRAIN_ACK_MODE
}

# set_current_claimed [ASSIGNEE] stamps a verified claim and this session's pointer.
set_current_claimed() {
  jq --arg owner "${1:-session-a}" '.[0].status="in_progress"
      | .[0].assignee=$owner
      | .[0].metadata={"gc.session_id":"session-a"}' \
    "$MOCK_STATE" >"$MOCK_STATE.tmp"
  mv "$MOCK_STATE.tmp" "$MOCK_STATE"
  printf 'fx-1\n' >"$MOCK_CURRENT"
}

assert_no_mutation() {
  assert_lacks "$MOCK_LOG" 'bd update'
  assert_lacks "$MOCK_LOG" 'bd ready'
  assert_lacks "$MOCK_LOG" 'bd list'
  assert_lacks "$MOCK_LOG" 'drain_ack'
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
  local mode="$1" reason="$2"
  reset_state
  export MOCK_HOOK_MODE=success MOCK_READBACK="$mode"
  run "$HELPER" claim
  assert_eq "$RC" 76
  assert_output_has "CLAIM_REJECTED reason=$reason"
  assert_calls hook_calls 1
  assert_no_mutation
}

[[ -x "$HELPER" ]] || fail "missing executable helper: $HELPER"

# --- usage and preflight -----------------------------------------------------

reset_state
run "$HELPER"
assert_eq "$RC" 64
assert_output_has 'usage: claim-work.sh {claim|recover}'

reset_state
run env -u GC_RIG "$HELPER" claim
assert_eq "$RC" 76
assert_output_has 'CLAIM_REJECTED reason=missing_rig'
assert_lacks "$MOCK_LOG" 'hook_calls'

reset_state
run env -u GC_SESSION_ID "$HELPER" claim
assert_eq "$RC" 76
assert_output_has 'CLAIM_REJECTED reason=missing_session_id'
assert_lacks "$MOCK_LOG" 'hook_calls'

# --- direct claims -----------------------------------------------------------

# Only GC_SESSION_ID is set and the bead carries no workflow-root provenance
# (a plain routed bead): the hook's own assignee and gc.session_id prove it.
reset_state
run "$HELPER" claim
assert_eq "$RC" 0
assert_output_has 'CLAIMED_BEAD_ID=fx-1'
assert_lacks <(printf '%s\n' "$OUTPUT") 'CLAIM_RECOVERED'
assert_calls hook_calls 1
assert_calls show_calls 1
assert_lacks "$MOCK_LOG" 'current_calls'
assert_has "$MOCK_LOG" 'research bd show fx-1 --json'
assert_no_mutation

# Any work reason is accepted, including reasons the SDK may add later.
for reason in existing_assignment ready_assignment some_future_reason; do
  reset_state
  export MOCK_HOOK_REASON="$reason"
  run "$HELPER" claim
  assert_eq "$RC" 0
  assert_output_has 'CLAIMED_BEAD_ID=fx-1'
  assert_lacks "$MOCK_LOG" 'current_calls'
done

# An aliased session: the hook records the alias and the readback matches it.
reset_state
export MOCK_ASSIGNEE=alias-x
run env GC_ALIAS=alias-x "$HELPER" claim
assert_eq "$RC" 0
assert_output_has 'CLAIMED_BEAD_ID=fx-1'

# The readback must match the assignee the hook reported, not merely any
# identity of this session.
reset_state
export MOCK_ASSIGNEE=session-a MOCK_HOOK_ASSIGNEE=alias-x
run env GC_ALIAS=alias-x "$HELPER" claim
assert_eq "$RC" 76
assert_output_has 'CLAIM_REJECTED reason=foreign_assignee'
assert_no_mutation

# The hook's bead id is validated before it reaches gc bd show.
for bad_id in '../x' 'a b' '-x'; do
  reset_state
  export MOCK_HOOK_MODE=invalid_id MOCK_HOOK_BEAD_ID="$bad_id"
  run "$HELPER" claim
  assert_eq "$RC" 76
  assert_output_has 'CLAIM_REJECTED reason=invalid_bead_id'
  assert_lacks "$MOCK_LOG" 'show_calls'
  assert_lacks "$MOCK_LOG" 'current_calls'
  assert_no_mutation
done

# --- empty results -----------------------------------------------------------

for mode in no_work no_work_nonzero; do
  reset_state
  export MOCK_HOOK_MODE="$mode"
  run "$HELPER" claim
  assert_eq "$RC" 0
  assert_output_has 'NO_ROUTED_WORK reason=no_work'
  assert_calls hook_calls 1
  assert_lacks "$MOCK_LOG" 'current_calls'
  assert_lacks "$MOCK_LOG" 'show_calls'
  assert_has "$MOCK_LOG" 'drain_ack'
done

reset_state
export MOCK_HOOK_MODE=no_work MOCK_DRAIN_ACK_MODE=fail
run "$HELPER" claim
assert_eq "$RC" 75
assert_output_has 'CLAIM_UNKNOWN reason=drain_ack_failed'
assert_calls hook_calls 1
assert_has "$MOCK_LOG" 'drain_ack'
assert_lacks "$MOCK_LOG" 'current_calls'
assert_lacks "$MOCK_LOG" 'show_calls'

# --- lost or malformed results recover through the current pointer -----------

for mode in lost_stdout malformed claimed_nonzero; do
  reset_state
  export MOCK_HOOK_MODE="$mode"
  run "$HELPER" claim
  assert_eq "$RC" 0
  assert_output_has 'CLAIMED_BEAD_ID=fx-1'
  case "$mode" in
    lost_stdout) assert_output_has 'CLAIM_RECOVERED reason=empty_result' ;;
    malformed) assert_output_has 'CLAIM_RECOVERED reason=malformed_result' ;;
    claimed_nonzero) assert_output_has 'CLAIM_RECOVERED reason=hook_failed' ;;
  esac
  assert_calls hook_calls 1
  assert_calls current_calls 1
  assert_calls show_calls 1
  assert_no_mutation
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
run "$HELPER" recover
assert_eq "$RC" 0
assert_output_has 'CLAIMED_BEAD_ID=fx-1'
assert_calls hook_calls 1
assert_calls current_calls 1
assert_calls show_calls 2

# Failed hooks with no pointer are unknown, and both CLI errors are reported.
reset_state
export MOCK_HOOK_MODE=timeout
run "$HELPER" claim
assert_eq "$RC" 75
assert_output_has 'CLAIM_UNKNOWN reason=hook_timeout_no_current_assignment'
assert_output_has 'mock hook timed out'
assert_output_has 'gc hook current diagnostics:'
assert_output_has 'no current bead'
assert_calls hook_calls 1
assert_calls current_calls 1
assert_no_mutation

reset_state
export MOCK_HOOK_MODE=claims_errored
run "$HELPER" claim
assert_eq "$RC" 75
assert_output_has 'CLAIM_UNKNOWN reason=claim_error_no_current_assignment'
assert_no_mutation

for mode in malformed_no_claim empty_no_claim; do
  reset_state
  export MOCK_HOOK_MODE="$mode"
  run "$HELPER" claim
  assert_eq "$RC" 75
  if [[ "$mode" == malformed_no_claim ]]; then
    assert_output_has 'CLAIM_UNKNOWN reason=malformed_result_no_current_assignment'
  else
    assert_output_has 'CLAIM_UNKNOWN reason=empty_result_no_current_assignment'
  fi
  assert_calls hook_calls 1
  assert_calls current_calls 1
  assert_no_mutation
done

# --- explicit hook refusals never consult an older pointer --------------------

for reason in stale_session non_turn_context drain_pending missing_session_registration stale_session_nonzero; do
  reset_state
  export MOCK_HOOK_MODE="$reason"
  set_current_claimed
  run "$HELPER" claim
  assert_eq "$RC" 76
  assert_output_has "CLAIM_REJECTED reason=${reason%_nonzero}"
  assert_calls hook_calls 1
  assert_lacks "$MOCK_LOG" 'current_calls'
  assert_lacks "$MOCK_LOG" 'show_calls'
  assert_no_mutation
done

# --- readback ------------------------------------------------------------------

reset_state
export MOCK_HOOK_MODE=success MOCK_SHOW_MODE=fail
run "$HELPER" claim
assert_eq "$RC" 75
assert_output_has 'CLAIM_UNKNOWN reason=readback_unavailable'
assert_output_has 'gc bd show diagnostics:'
assert_output_has 'mock read timeout'
assert_calls hook_calls 1
assert_calls show_calls 3
assert_lacks "$MOCK_LOG" 'current_calls'
assert_no_mutation

reset_state
export MOCK_HOOK_MODE=success MOCK_SHOW_MODE=fail_valid_json
run "$HELPER" claim
assert_eq "$RC" 75
assert_output_has 'CLAIM_UNKNOWN reason=readback_unavailable'
assert_calls hook_calls 1
assert_calls show_calls 3
assert_lacks "$MOCK_LOG" 'current_calls'
assert_no_mutation

# Transient readback failures recover within the retry budget.
for failures in 1 2; do
  reset_state
  export MOCK_HOOK_MODE=success MOCK_SHOW_MODE=flaky MOCK_SHOW_FAILURES="$failures"
  run "$HELPER" claim
  assert_eq "$RC" 0
  assert_output_has 'CLAIMED_BEAD_ID=fx-1'
  assert_calls show_calls "$((failures + 1))"
  assert_no_mutation
done

expect_rejected foreign_owner foreign_assignee
expect_rejected stale_session stale_session
expect_rejected stale_status stale_status
expect_rejected wrong_id bead_identity_mismatch
expect_rejected two_records bead_identity_mismatch
expect_rejected object bead_identity_mismatch

# --- recover mode ----------------------------------------------------------------

reset_state
set_current_claimed
run "$HELPER" recover
assert_eq "$RC" 0
assert_output_has 'CLAIM_RECOVERED reason=current_pointer'
assert_output_has 'CLAIMED_BEAD_ID=fx-1'
assert_lacks "$MOCK_LOG" 'hook_calls'
assert_no_mutation

# Recovery has no hook result, so any of this session's identities may own it.
for var in GC_ALIAS BEADS_ACTOR GC_AGENT GC_SESSION_NAME; do
  reset_state
  set_current_claimed "ident-$var"
  run env "$var=ident-$var" "$HELPER" recover
  assert_eq "$RC" 0
  assert_output_has 'CLAIMED_BEAD_ID=fx-1'
  assert_lacks "$MOCK_LOG" 'hook_calls'
done

# Recovery failures never claim, mutate, or drain.
reset_state
run "$HELPER" recover
assert_eq "$RC" 75
assert_output_has 'CLAIM_UNKNOWN reason=no_current_assignment'
assert_output_has 'no current bead'
assert_lacks "$MOCK_LOG" 'hook_calls'
assert_lacks "$MOCK_LOG" 'show_calls'
assert_no_mutation

for pointer in '../x' 'a b' ' '; do
  reset_state
  printf '%s\n' "$pointer" >"$MOCK_CURRENT"
  run "$HELPER" recover
  assert_eq "$RC" 75
  assert_output_has 'CLAIM_UNKNOWN reason=no_current_assignment'
  assert_output_has 'gc hook current returned an invalid bead id'
  assert_lacks "$MOCK_LOG" 'hook_calls'
  assert_lacks "$MOCK_LOG" 'show_calls'
  assert_no_mutation
done

for readback in foreign_owner:foreign_assignee stale_session:stale_session stale_status:stale_status; do
  reset_state
  set_current_claimed
  export MOCK_READBACK="${readback%%:*}"
  run "$HELPER" recover
  assert_eq "$RC" 76
  assert_output_has "CLAIM_REJECTED reason=${readback#*:}"
  assert_lacks "$MOCK_LOG" 'hook_calls'
  assert_no_mutation
done

# --- prompt template: pack path decode ---------------------------------------------

# Every pack script call site in the polecat prompt goes through $PACK_DIR, and
# ConfigDir is interpolated only as hex.
[[ -f "$PROMPT_TEMPLATE" ]] || fail "missing prompt template: $PROMPT_TEMPLATE"
while IFS= read -r line; do
  [[ "$line" == *'$PACK_DIR/assets/scripts/'* ]] || fail "pack script call site bypasses \$PACK_DIR: $line"
done < <(grep -F 'assets/scripts/' "$PROMPT_TEMPLATE")
while IFS= read -r line; do
  [[ "$line" == *'{{ printf "%x" .ConfigDir }}'* ]] || fail "raw ConfigDir interpolation: $line"
done < <(grep -F '.ConfigDir' "$PROMPT_TEMPLATE")

# Render the decode line with a hostile path, as Go's printf "%x" would, and run it.
decode_line="$(grep -F 'printf -v PACK_DIR' "$PROMPT_TEMPLATE")"
[[ -n "$decode_line" ]] || fail 'prompt template has no PACK_DIR decode line'
hostile_dir=$'/tmp/pack dir/it\'s $(touch "'"$TMP"'/injected") `x` \\x41 \xc3\xbc'
hostile_hex="$(printf '%s' "$hostile_dir" | od -An -v -tx1 | tr -d ' \n')"
placeholder='{{ printf "%x" .ConfigDir }}'
rendered_line="${decode_line/"$placeholder"/$hostile_hex}"
[[ "$rendered_line" != "$decode_line" ]] || fail 'decode line lacks the hex ConfigDir placeholder'
printf '%s\nprintf "%%s" "$PACK_DIR"\n' "$rendered_line" >"$TMP/decode.sh"
assert_eq "$(bash "$TMP/decode.sh")" "$hostile_dir"
[[ ! -e "$TMP/injected" ]] || fail 'decoded ConfigDir was executed as shell'

echo 'PASS: hook claim recovery mock-CLI checks'
