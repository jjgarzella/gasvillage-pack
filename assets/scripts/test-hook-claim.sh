#!/usr/bin/env bash
# Disposable fake-CLI checks for claim result recovery. Never contacts a live city.
set -euo pipefail
export LC_ALL=C

# Detach from any live city before anything else runs. The tests export a
# fake GC_SESSION_ID for the helper; a process carrying a GC_SESSION_ID with no
# session bead, attributed to a city through an inherited GC_CITY_PATH or
# GC_CITY, is a process-table orphan to that city's supervisor, which SIGTERMs
# it mid-test (gcs-h493). Scrubbing every GC_* and BEADS_* variable removes
# that attribution and any route to a live store. GC_CONTRACT_BIN is read first
# because it is this suite's own input.
CONTRACT_BIN_OVERRIDE="${GC_CONTRACT_BIN:-}"
while IFS= read -r var; do
  case "$var" in GC_* | BEADS_*) unset "$var" ;; esac
done < <(compgen -e)

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/claim-work.sh"
PROMPT_TEMPLATE="$SCRIPT_DIR/../../agents/polecat/prompt.template.md"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export MOCK_STATE="$TMP/bead.json" MOCK_CURRENT="$TMP/current" \
  MOCK_LOG="$TMP/gc.log" MOCK_HOOK_PID="$TMP/hook.pid" MOCK_SHOW_COUNT="$TMP/show.count"
MOCK_GC="$TMP/gc"
ORIGINAL_PATH="$PATH"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "expected '$2', got '$1'"; }
assert_has() { grep -Fq -- "$2" "$1" || fail "'$2' not found in $1"; }
assert_lacks() { ! grep -Fq -- "$2" "$1" || fail "unexpected '$2' in $1"; }
assert_output_has() { assert_has "$TMP/stdout" "$1"; }
assert_output_lacks() { assert_lacks "$TMP/stdout" "$1"; }
assert_stderr_has() { assert_has "$TMP/stderr" "$1"; }
assert_calls() { assert_eq "$(grep -c "^$1\$" "$MOCK_LOG" || true)" "$2"; }

readonly MARKER_LINE='^(CLAIMED_BEAD_ID=[A-Za-z0-9._-]+|(CLAIM_RECOVERED|SESSION_DRAINED|CLAIM_UNKNOWN|CLAIM_REJECTED) reason=[a-z][a-z_]*)$'
readonly MARKER_PREFIX='(CLAIMED_BEAD_ID|CLAIM_RECOVERED|SESSION_DRAINED|CLAIM_UNKNOWN|CLAIM_REJECTED)'
readonly TERMINAL_MARKER='^(CLAIMED_BEAD_ID=|SESSION_DRAINED |CLAIM_UNKNOWN |CLAIM_REJECTED )'

# The mock's "no current claim" text comes from the helper, and the contract
# pin below checks that the installed gc still emits it.
NO_CURRENT_CLAIM_DIAGNOSTIC="$(sed -n "s/^readonly NO_CURRENT_CLAIM_DIAGNOSTIC='\(.*\)'\$/\1/p" "$HELPER")"
[[ -n "$NO_CURRENT_CLAIM_DIAGNOSTIC" ]] || fail "helper does not define NO_CURRENT_CLAIM_DIAGNOSTIC"
export NO_CURRENT_CLAIM_DIAGNOSTIC

# assert_stream_contract checks the helper's stdout/stderr contract for the
# last run: stdout holds only marker lines, stderr holds no marker, and every
# non-usage exit prints exactly one terminal marker.
assert_stream_contract() {
  local line terminal expected=1
  while IFS= read -r line; do
    [[ "$line" =~ $MARKER_LINE ]] || fail "non-marker line on stdout: $line"
  done <"$TMP/stdout"
  ! grep -Eq "$MARKER_PREFIX" "$TMP/stderr" || fail "marker written to stderr: $(cat "$TMP/stderr")"
  terminal="$(grep -Ec "$TERMINAL_MARKER" "$TMP/stdout" || true)"
  [[ "$RC" != 64 ]] || expected=0
  [[ "$terminal" == "$expected" ]] || fail "expected $expected terminal marker(s), got $terminal: $(cat "$TMP/stdout")"
}

# run CMD... captures stdout and stderr separately in $TMP/stdout and
# $TMP/stderr, the exit status in RC, and checks the stream contract.
run() {
  set +e
  "$@" >"$TMP/stdout" 2>"$TMP/stderr"
  RC=$?
  set -e
  assert_stream_contract
}

# The mock records the claim under MOCK_ASSIGNEE, independently of the
# helper's identity variables, the way the SDK picks its own claim identity.
cat >"$MOCK_GC" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
# Every helper process must stay unattributable to a live city (see the scrub
# at the top of the suite); fail loudly instead of being reaped.
if [[ -n "${GC_CITY_PATH:-}${GC_CITY:-}" ]]; then
  echo "mock gc: inherited live city identity; the suite must scrub it" >&2
  exit 99
fi
rig=""
if [[ "${1:-}" == --rig ]]; then rig="$2"; shift 2; fi
printf '%s %s\n' "$rig" "$*" >>"$MOCK_LOG"

# record_claim stamps the claim; MOCK_SKIP_POINTER=1 models a claim whose
# current-claim stamp failed (the SDK does not fail the claim for that).
record_claim() {
  jq --arg owner "${MOCK_ASSIGNEE:-session-a}" --arg session "${GC_SESSION_ID:-}" \
    '.[0].status="in_progress"
     | .[0].assignee=$owner
     | .[0].metadata["gc.session_id"]=$session' \
    "$MOCK_STATE" >"$MOCK_STATE.tmp"
  mv "$MOCK_STATE.tmp" "$MOCK_STATE"
  [[ "${MOCK_SKIP_POINTER:-}" == 1 ]] || printf 'fx-1\n' >"$MOCK_CURRENT"
  printf 'hook_claimed\n' >>"$MOCK_LOG"
}

work_result() {
  jq -cn --arg reason "${MOCK_HOOK_REASON:-claimed}" --arg bead "$1" \
    --arg assignee "${MOCK_HOOK_ASSIGNEE:-${MOCK_ASSIGNEE:-session-a}}" \
    '{schema_version:"1",ok:true,command:"hook",action:"work",reason:$reason,bead_id:$bead,assignee:$assignee}'
}

# drain_record REASON [ACKED] prints the SDK's drain record; the reason goes
# through jq so a hostile reason is JSON-encoded exactly as the SDK would.
drain_record() {
  jq -cn --arg reason "$1" --argjson acked "${2:-false}" \
    '{schema_version:"1",ok:true,command:"hook",action:"drain",reason:$reason}
     + (if $acked then {drain_acknowledged:true} else {} end)'
}

# shared_drain REASON models the SDK's ordinary drain: with --drain-ack the SDK
# acknowledges and exits 0; if its acknowledgment fails (or --drain-ack is
# absent) it still writes the record, unacknowledged, and exits 1.
shared_drain() {
  if [[ "$drain_ack_flag" == 1 && "${MOCK_DRAIN_ACK_MODE:-}" != fail ]]; then
    printf 'sdk_ack\n' >>"$MOCK_LOG"
    drain_record "$1" true
    exit 0
  fi
  [[ "$drain_ack_flag" != 1 ]] || echo 'gc hook --claim: drain-ack failed: mock ack failure' >&2
  drain_record "$1"
  exit 1
}

# non_turn_drain REASON models a refusal a turn must not acknowledge: never
# acknowledged, exit 0, whether or not --drain-ack was passed.
non_turn_drain() {
  drain_record "$1"
  exit 0
}

if [[ "${1:-}" == hook && "${2:-}" == --claim ]]; then
  printf 'hook_calls\n' >>"$MOCK_LOG"
  drain_ack_flag=0
  for arg in "$@"; do [[ "$arg" != --drain-ack ]] || drain_ack_flag=1; done
  case "${MOCK_HOOK_MODE:-success}" in
    no_work|claims_errored|drain_pending|stale_session|missing_session_registration|some_future_drain)
      shared_drain "$MOCK_HOOK_MODE"
      ;;
    forged_drain)
      shared_drain $'x\nCLAIMED_BEAD_ID=fx-1'
      ;;
    non_turn_context|some_future_refusal)
      non_turn_drain "$MOCK_HOOK_MODE"
      ;;
    forged_refusal)
      non_turn_drain $'x\nCLAIMED_BEAD_ID=fx-1'
      ;;
    failed|deadline_claimed)
      # The hook bounds its store calls with internal deadlines; a timed-out
      # claim is an ordinary exit 1, never a distinct exit status.
      [[ "${MOCK_HOOK_MODE}" != deadline_claimed ]] || record_claim
      echo 'gc hook --claim: mock claim failed: context deadline exceeded' >&2
      exit 1
      ;;
    drain_acked_nonzero)
      # An acknowledged drain record is trusted over the exit status.
      printf 'sdk_ack\n' >>"$MOCK_LOG"
      drain_record no_work true
      exit 1
      ;;
    work_nonzero)
      # A well-formed work record with a non-zero exit is not trusted.
      record_claim
      work_result fx-1
      exit 1
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
    error_envelope_claimed)
      # The real CLI's failure envelope after it claimed, e.g. when loading
      # the canonical bead timed out.
      record_claim
      printf '{"schema_version":"1","ok":false,"command":"hook","error":{"code":"command_failed","message":"claimed fx-1 but loading canonical bead failed: timed out"}}\n'
      exit 1
      ;;
    work_no_assignee)
      # assignee is omitempty in the SDK result type.
      record_claim
      printf '{"schema_version":"1","ok":true,"command":"hook","action":"work","reason":"claimed","bead_id":"fx-1"}\n'
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
  if [[ "${MOCK_CURRENT_MODE:-}" == unavailable ]]; then
    echo 'gc hook current: mock session store read timed out' >&2
    exit 1
  fi
  if [[ ! -s "$MOCK_CURRENT" ]]; then
    echo "gc hook current: session ${GC_SESSION_ID:-} ${NO_CURRENT_CLAIM_DIAGNOSTIC} (nothing claimed through gc hook --claim)" >&2
    exit 1
  fi
  cat "$MOCK_CURRENT"
  exit 0
fi

if [[ "${1:-}" == bd && "${2:-}" == show ]]; then
  printf 'show_calls\n' >>"$MOCK_LOG"
  # A rig-scoped read cannot see a bead the hook claimed from the city store.
  [[ -z "$rig" ]] || { echo "mock: rig-scoped readback of $3" >&2; exit 7; }
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
    foreign_session) jq '.[0].metadata["gc.session_id"]="old-session"' "$MOCK_STATE" ;;
    closed) jq '.[0].status="closed"' "$MOCK_STATE" ;;
    stale_status) jq '.[0].status="open"' "$MOCK_STATE" ;;
    wrong_id) jq '.[0].id="fx-2"' "$MOCK_STATE" ;;
    two_records) jq '. + .' "$MOCK_STATE" ;;
    object) jq '.[0]' "$MOCK_STATE" ;;
    *) exit 8 ;;
  esac
  exit 0
fi

if [[ "${1:-}" == runtime && "${2:-}" == drain-ack ]]; then
  printf 'drain_ack %s\n' "${3:-}" >>"$MOCK_LOG"
  [[ "${MOCK_DRAIN_ACK_MODE:-}" != fail ]] || { echo 'mock drain ack failed' >&2; exit 1; }
  echo 'mock: drain acknowledged'
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
    MOCK_ASSIGNEE MOCK_SHOW_MODE MOCK_SHOW_FAILURES MOCK_READBACK MOCK_DRAIN_ACK_MODE \
    MOCK_SKIP_POINTER MOCK_CURRENT_MODE
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
assert_stderr_has 'usage: claim-work.sh {claim|recover}'

reset_state
run "$HELPER" bogus
assert_eq "$RC" 64
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
assert_output_lacks 'CLAIM_RECOVERED'
assert_calls hook_calls 1
assert_calls ' hook --claim --drain-ack --json' 1
assert_calls show_calls 1
assert_lacks "$MOCK_LOG" 'current_calls'
assert_calls ' bd show fx-1 --json' 1
assert_no_mutation

# The readback is id-routed, never rig-scoped, so GC_RIG is not an input: the
# hook may have claimed the bead from the city store.
reset_state
run env -u GC_RIG "$HELPER" claim
assert_eq "$RC" 0
assert_output_has 'CLAIMED_BEAD_ID=fx-1'
assert_calls ' bd show fx-1 --json' 1

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

# --- hook drains: the SDK acknowledges; the helper never consults the pointer --

# Every drain the SDK acknowledges is reported as drained, including
# claims_errored (nothing was claimed) and reasons the SDK adds later. The
# helper passes --drain-ack and never runs gc runtime drain-ack itself.
for reason in no_work claims_errored drain_pending stale_session missing_session_registration some_future_drain; do
  reset_state
  export MOCK_HOOK_MODE="$reason"
  set_current_claimed
  run "$HELPER" claim
  assert_eq "$RC" 0
  assert_output_has "SESSION_DRAINED reason=$reason"
  assert_output_lacks 'CLAIMED_BEAD_ID'
  assert_output_lacks 'CLAIM_RECOVERED'
  assert_calls ' hook --claim --drain-ack --json' 1
  assert_calls hook_calls 1
  assert_calls sdk_ack 1
  assert_lacks "$MOCK_LOG" 'current_calls'
  assert_lacks "$MOCK_LOG" 'show_calls'
  assert_no_mutation
done

# The SDK's acknowledgment failed: it still writes the drain record and exits 1.
# Nothing was claimed, so the pointer is not consulted, and nothing is acked.
for reason in no_work claims_errored drain_pending; do
  reset_state
  export MOCK_HOOK_MODE="$reason" MOCK_DRAIN_ACK_MODE=fail
  set_current_claimed
  run "$HELPER" claim
  assert_eq "$RC" 75
  assert_output_has 'CLAIM_UNKNOWN reason=drain_ack_failed'
  assert_output_lacks 'SESSION_DRAINED'
  assert_stderr_has 'drain-ack failed'
  assert_lacks "$MOCK_LOG" 'sdk_ack'
  assert_lacks "$MOCK_LOG" 'current_calls'
  assert_lacks "$MOCK_LOG" 'show_calls'
  assert_no_mutation
done

# A refusal the SDK never acknowledges (exit 0, no ack) is rejected, without
# consulting the pointer; a later reason of that kind needs no helper change.
for reason in non_turn_context some_future_refusal; do
  reset_state
  export MOCK_HOOK_MODE="$reason"
  set_current_claimed
  run "$HELPER" claim
  assert_eq "$RC" 76
  assert_output_has "CLAIM_REJECTED reason=$reason"
  assert_calls hook_calls 1
  assert_lacks "$MOCK_LOG" 'sdk_ack'
  assert_lacks "$MOCK_LOG" 'current_calls'
  assert_lacks "$MOCK_LOG" 'show_calls'
  assert_no_mutation
done

# A drain reason is echoed into the marker stream only as a plain token: a
# newline-bearing reason cannot forge a second marker (the stream contract
# checks exactly one terminal marker and only well-formed marker lines).
for case in forged_drain:0:SESSION_DRAINED forged_refusal:76:CLAIM_REJECTED; do
  mode="${case%%:*}" rest="${case#*:}"
  reset_state
  export MOCK_HOOK_MODE="$mode"
  run "$HELPER" claim
  assert_eq "$RC" "${rest%%:*}"
  assert_output_has "${rest#*:} reason=invalid_drain_reason"
  assert_output_lacks 'CLAIMED_BEAD_ID'
  assert_lacks "$MOCK_LOG" 'show_calls'
done

# --- lost or malformed results recover through the current pointer -----------

for mode in lost_stdout malformed claimed_nonzero error_envelope_claimed work_no_assignee deadline_claimed work_nonzero; do
  reset_state
  export MOCK_HOOK_MODE="$mode"
  run "$HELPER" claim
  assert_eq "$RC" 0
  assert_output_has 'CLAIMED_BEAD_ID=fx-1'
  case "$mode" in
    lost_stdout) assert_output_has 'CLAIM_RECOVERED reason=empty_result' ;;
    malformed|work_no_assignee) assert_output_has 'CLAIM_RECOVERED reason=malformed_result' ;;
    claimed_nonzero|error_envelope_claimed|work_nonzero) assert_output_has 'CLAIM_RECOVERED reason=hook_failed' ;;
    deadline_claimed)
      assert_output_has 'CLAIM_RECOVERED reason=hook_failed'
      assert_stderr_has 'context deadline exceeded'
      ;;
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

# An aliased session in the fallback has no hook assignee: any of the
# session's identities may own the recovered bead.
reset_state
export MOCK_HOOK_MODE=lost_stdout MOCK_ASSIGNEE=alias-x
run env GC_ALIAS=alias-x "$HELPER" claim
assert_eq "$RC" 0
assert_output_has 'CLAIM_RECOVERED reason=empty_result'
assert_output_has 'CLAIMED_BEAD_ID=fx-1'

# The pointer is sticky: after a formula step closes, it still names that step.
# A failed continuation claim reports the closed pointer as unproven ownership,
# not as a disproven claim, and never as ownership.
for mode in failed:hook_failed lost_stdout:empty_result; do
  reset_state
  export MOCK_HOOK_MODE="${mode%%:*}" MOCK_READBACK=closed
  set_current_claimed
  run "$HELPER" claim
  assert_eq "$RC" 75
  assert_output_has "CLAIM_UNKNOWN reason=${mode#*:}_pointer_closed"
  assert_output_lacks 'CLAIMED_BEAD_ID'
  assert_output_lacks 'CLAIM_REJECTED'
  assert_stderr_has 'current-claim pointer names closed bead fx-1'
  assert_no_mutation
done

# A pointer bead that is neither in_progress nor closed disproves ownership.
reset_state
export MOCK_HOOK_MODE=failed MOCK_READBACK=stale_status
set_current_claimed
run "$HELPER" claim
assert_eq "$RC" 76
assert_output_has 'CLAIM_REJECTED reason=stale_status'
assert_no_mutation

# A work result without an assignee whose pointer stamp failed is unknown.
reset_state
export MOCK_HOOK_MODE=work_no_assignee MOCK_SKIP_POINTER=1
run "$HELPER" claim
assert_eq "$RC" 75
assert_output_has 'CLAIM_UNKNOWN reason=malformed_result_no_current_assignment'
assert_no_mutation

# A failed pointer lookup is not "nothing claimed".
reset_state
export MOCK_HOOK_MODE=deadline_claimed MOCK_CURRENT_MODE=unavailable
run "$HELPER" claim
assert_eq "$RC" 75
assert_output_has 'CLAIM_UNKNOWN reason=hook_failed_current_unavailable'
assert_stderr_has 'mock session store read timed out'
assert_no_mutation

# Failed hooks with no pointer are unknown, and both CLI errors are reported.
reset_state
export MOCK_HOOK_MODE=failed
run "$HELPER" claim
assert_eq "$RC" 75
assert_output_has 'CLAIM_UNKNOWN reason=hook_failed_no_current_assignment'
assert_stderr_has 'context deadline exceeded'
assert_stderr_has 'gc hook current diagnostics:'
assert_stderr_has "$NO_CURRENT_CLAIM_DIAGNOSTIC"
assert_calls hook_calls 1
assert_calls current_calls 1
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

# A work record from a non-zero hook is ignored even when it names a bead: with
# no pointer stamp the claim stays unproven.
reset_state
export MOCK_HOOK_MODE=work_nonzero MOCK_SKIP_POINTER=1
run "$HELPER" claim
assert_eq "$RC" 75
assert_output_has 'CLAIM_UNKNOWN reason=hook_failed_no_current_assignment'
assert_lacks "$MOCK_LOG" 'show_calls'
assert_no_mutation

# A malformed pointer in the claim-mode fallback is unknown, never read back.
reset_state
export MOCK_HOOK_MODE=lost_stdout MOCK_SKIP_POINTER=1
printf '../x\n' >"$MOCK_CURRENT"
run "$HELPER" claim
assert_eq "$RC" 75
assert_output_has 'CLAIM_UNKNOWN reason=empty_result_invalid_current_pointer'
assert_lacks "$MOCK_LOG" 'show_calls'
assert_no_mutation

# An acknowledged drain record wins over a non-zero exit status.
reset_state
export MOCK_HOOK_MODE=drain_acked_nonzero
set_current_claimed
run "$HELPER" claim
assert_eq "$RC" 0
assert_output_has 'SESSION_DRAINED reason=no_work'
assert_lacks "$MOCK_LOG" 'current_calls'
assert_lacks "$MOCK_LOG" 'show_calls'
assert_no_mutation

# A missing jq is named before any gc call, in both modes, instead of being
# misread as a malformed hook result or an unreadable readback.
mkdir -p "$TMP/nojq-bin"
for tool in bash env mktemp rm sed grep cat sleep; do
  ln -sf "$(command -v "$tool")" "$TMP/nojq-bin/$tool"
done
for mode in claim recover; do
  reset_state
  set_current_claimed
  run env PATH="$TMP/nojq-bin" "$HELPER" "$mode"
  assert_eq "$RC" 75
  assert_output_has 'CLAIM_UNKNOWN reason=jq_unavailable'
  assert_stderr_has 'jq not found'
  assert_lacks "$MOCK_LOG" 'hook_calls'
  assert_lacks "$MOCK_LOG" 'current_calls'
  assert_lacks "$MOCK_LOG" 'show_calls'
done

# --- readback ------------------------------------------------------------------

reset_state
export MOCK_HOOK_MODE=success MOCK_SHOW_MODE=fail
run "$HELPER" claim
assert_eq "$RC" 75
assert_output_has 'CLAIM_UNKNOWN reason=readback_unavailable'
assert_stderr_has 'gc bd show diagnostics:'
assert_stderr_has 'mock read timeout'
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
expect_rejected foreign_session foreign_session_id
expect_rejected stale_status stale_status
# A closed bead the hook itself named is disproven; only a pointer is sticky.
expect_rejected closed stale_status
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

# Recovery failures never claim, mutate, or drain. Only the SDK's "no current
# claim" answer (no_current_assignment) and a pointer to this session's closed
# claim (pointer_closed) mean the session holds nothing; the prompt routes only
# those two to a fresh claim.
reset_state
run "$HELPER" recover
assert_eq "$RC" 75
assert_output_has 'CLAIM_UNKNOWN reason=no_current_assignment'
assert_stderr_has "$NO_CURRENT_CLAIM_DIAGNOSTIC"
assert_lacks "$MOCK_LOG" 'hook_calls'
assert_lacks "$MOCK_LOG" 'show_calls'
assert_no_mutation

reset_state
set_current_claimed
export MOCK_CURRENT_MODE=unavailable
run "$HELPER" recover
assert_eq "$RC" 75
assert_output_has 'CLAIM_UNKNOWN reason=current_unavailable'
assert_stderr_has 'mock session store read timed out'
assert_lacks "$MOCK_LOG" 'hook_calls'
assert_lacks "$MOCK_LOG" 'show_calls'
assert_no_mutation

for pointer in '../x' 'a b' ' '; do
  reset_state
  printf '%s\n' "$pointer" >"$MOCK_CURRENT"
  run "$HELPER" recover
  assert_eq "$RC" 75
  assert_output_has 'CLAIM_UNKNOWN reason=invalid_current_pointer'
  assert_stderr_has 'gc hook current returned an invalid bead id'
  assert_lacks "$MOCK_LOG" 'hook_calls'
  assert_lacks "$MOCK_LOG" 'show_calls'
  assert_no_mutation
done

reset_state
set_current_claimed
export MOCK_READBACK=closed
run "$HELPER" recover
assert_eq "$RC" 75
assert_output_has 'CLAIM_UNKNOWN reason=pointer_closed'
assert_output_lacks 'CLAIMED_BEAD_ID'
assert_lacks "$MOCK_LOG" 'hook_calls'
assert_no_mutation

reset_state
set_current_claimed
export MOCK_SHOW_MODE=fail
run "$HELPER" recover
assert_eq "$RC" 75
assert_output_has 'CLAIM_RECOVERED reason=current_pointer'
assert_output_has 'CLAIM_UNKNOWN reason=readback_unavailable'
assert_calls show_calls 3
assert_lacks "$MOCK_LOG" 'hook_calls'
assert_no_mutation

for readback in foreign_owner:foreign_assignee foreign_session:foreign_session_id stale_status:stale_status; do
  reset_state
  set_current_claimed
  export MOCK_READBACK="${readback%%:*}"
  run "$HELPER" recover
  assert_eq "$RC" 76
  assert_output_has "CLAIM_REJECTED reason=${readback#*:}"
  assert_lacks "$MOCK_LOG" 'hook_calls'
  assert_no_mutation
done

# --- SDK contract pin ------------------------------------------------------------

# The helper depends on SDK behavior that the fake CLI above can only repeat:
# the `gc hook --drain-ack` flag, the drain_acknowledged result field, and the
# "no current claim" diagnostic of `gc hook current`. Check the gc that polecats
# actually run, so an SDK change fails here instead of stalling the pool.
# Override the binary with GC_CONTRACT_BIN.
REAL_GC="${CONTRACT_BIN_OVERRIDE:-$(command -v gc || true)}"
[[ -n "$REAL_GC" && -f "$REAL_GC" ]] || fail 'no installed gc to pin the SDK contract; set GC_CONTRACT_BIN'
# The flag is pinned on the hook command's own help: the bare text "drain-ack"
# also names `gc runtime drain-ack` and would match without the flag.
hook_help="$(cd "$TMP" && "$REAL_GC" hook --help 2>&1)" || fail "installed gc ($REAL_GC) hook --help failed: $hook_help"
grep -Eq -- '(^|[[:space:]])--drain-ack([[:space:]]|$)' <<<"$hook_help" \
  || fail "installed gc ($REAL_GC) gc hook no longer accepts --drain-ack"
for contract_text in "$NO_CURRENT_CLAIM_DIAGNOSTIC" 'drain_acknowledged'; do
  LC_ALL=C grep -aFq -- "$contract_text" "$REAL_GC" \
    || fail "installed gc ($REAL_GC) no longer contains SDK contract text: $contract_text"
done

# --- reason vocabulary: the helper header is the single source -----------------

# Every reason=<token> named by the prompt, README, or rollout doc must be one
# the helper header documents, so prose cannot drift from the helper.
HELPER_HEADER="$(sed -n '/^set -euo pipefail$/q;p' "$HELPER")"
for doc in "$PROMPT_TEMPLATE" "$SCRIPT_DIR/../../README.md" "$SCRIPT_DIR/../../docs/claim-recovery-rollout.md"; do
  [[ -f "$doc" ]] || fail "missing doc: $doc"
  while IFS= read -r token; do
    grep -Eq "(^|[^a-z_])${token}([^a-z_]|\$)" <<<"$HELPER_HEADER" \
      || fail "$doc names reason=$token, which the claim-work.sh header does not document"
  done < <(grep -Eo 'reason=[a-z][a-z_]*' "$doc" | sed 's/^reason=//' | sort -u)
done
# The prompt states the agent's re-claim exception; the helper header must too.
for token in no_current_assignment pointer_closed; do
  assert_has "$PROMPT_TEMPLATE" "reason=$token"
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

# Each command runs in a fresh shell, so every fenced block that uses $PACK_DIR
# must invoke the decode partial before its first use.
pack_dir_blocks=0
in_block=0
block_has_partial=0
block_uses_pack_dir=0
line_no=0
while IFS= read -r line; do
  line_no=$((line_no + 1))
  if [[ "$line" == '```'* ]]; then
    if ((in_block)); then
      ((block_uses_pack_dir == 0)) || pack_dir_blocks=$((pack_dir_blocks + 1))
      in_block=0
    else
      in_block=1 block_has_partial=0 block_uses_pack_dir=0
    fi
    continue
  fi
  ((in_block)) || continue
  if [[ "$line" == *'{{ template "polecat-pack-dir" . }}'* ]]; then
    block_has_partial=1
  elif [[ "$line" == *'$PACK_DIR'* ]]; then
    ((block_has_partial)) || fail "prompt line $line_no uses \$PACK_DIR before the polecat-pack-dir partial: $line"
    block_uses_pack_dir=1
  fi
done <"$PROMPT_TEMPLATE"
((in_block == 0)) || fail 'prompt template has an unterminated code fence'
assert_eq "$pack_dir_blocks" "$(grep -cF '{{ template "polecat-pack-dir" . }}' "$PROMPT_TEMPLATE")"
((pack_dir_blocks >= 4)) || fail "expected at least 4 \$PACK_DIR blocks, found $pack_dir_blocks"

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
