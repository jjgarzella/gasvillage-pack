#!/usr/bin/env bash
# Disposable mock-store checks for work-item-control.sh. Never contacts a live city.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/work-item-control.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export MOCK_STATE="$TMP/bead.json" MOCK_LOG="$TMP/calls.log" MOCK_RACE_MARK="$TMP/raced"
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
printf 'rig=%s %s\n' "$rig" "$*" >>"$MOCK_LOG"

if [[ "${1:-}" == bd && "${2:-}" == show ]]; then
  shift 2
  [[ "$1" == "$(jq -r '.[0].id' "$MOCK_STATE")" ]] || exit 7
  cat "$MOCK_STATE"
  exit 0
fi

if [[ "${1:-}" == bd && "${2:-}" == update ]]; then
  shift 2
  bead="$1"; shift
  [[ "$bead" == "$(jq -r '.[0].id' "$MOCK_STATE")" ]] || exit 7
  if [[ "${MOCK_FAIL:-}" == update ]]; then echo 'mock update failure' >&2; exit 1; fi
  if [[ "${MOCK_RACE:-}" == owner && ! -e "$MOCK_RACE_MARK" ]]; then
    jq '.[0].assignee = "other-worker"' "$MOCK_STATE" >"$MOCK_STATE.tmp"
    mv "$MOCK_STATE.tmp" "$MOCK_STATE"
    : >"$MOCK_RACE_MARK"
  fi
  if [[ "${MOCK_RACE:-}" == status && ! -e "$MOCK_RACE_MARK" ]]; then
    jq '.[0].status = "blocked"' "$MOCK_STATE" >"$MOCK_STATE.tmp"
    mv "$MOCK_STATE.tmp" "$MOCK_STATE"
    : >"$MOCK_RACE_MARK"
  fi
  if [[ "${MOCK_RACE:-}" == owner || "${MOCK_RACE:-}" == status ]]; then
    current_assignee="$(jq -r '.[0].assignee // empty' "$MOCK_STATE")"
    current_status="$(jq -r '.[0].status // empty' "$MOCK_STATE")"
  else
    current_assignee="$(jq -r '.[0].assignee // empty' "$MOCK_STATE")"
    current_status="$(jq -r '.[0].status // empty' "$MOCK_STATE")"
  fi
  if_assignee=""; if_status=""; status=""; assignee="__KEEP__"; append_notes=""
  set_meta=(); unset_meta=()
  while (($#)); do
    case "$1" in
      --if-assignee) if_assignee="$2"; shift 2 ;;
      --if-status) if_status="$2"; shift 2 ;;
      --status) status="$2"; shift 2 ;;
      --assignee) assignee="$2"; shift 2 ;;
      --set-metadata) set_meta+=("$2"); shift 2 ;;
      --unset-metadata) unset_meta+=("$2"); shift 2 ;;
      --append-notes) append_notes="$2"; shift 2 ;;
      *) echo "unsupported mock update arg: $1" >&2; exit 8 ;;
    esac
  done
  [[ -z "$if_assignee" || "$current_assignee" == "$if_assignee" ]] || exit 13
  [[ -z "$if_status" || "$current_status" == "$if_status" ]] || exit 13
  temp="$MOCK_STATE.tmp"
  cp "$MOCK_STATE" "$temp"
  if [[ -n "$status" ]]; then jq --arg v "$status" '.[0].status=$v' "$temp" >"$temp.next"; mv "$temp.next" "$temp"; fi
  if [[ "$assignee" != __KEEP__ ]]; then jq --arg v "$assignee" '.[0].assignee=$v' "$temp" >"$temp.next"; mv "$temp.next" "$temp"; fi
  for pair in "${set_meta[@]}"; do
    key="${pair%%=*}"; value="${pair#*=}"
    jq --arg k "$key" --arg v "$value" '.[0].metadata[$k]=$v' "$temp" >"$temp.next"; mv "$temp.next" "$temp"
  done
  for key in "${unset_meta[@]}"; do
    jq --arg k "$key" 'del(.[0].metadata[$k])' "$temp" >"$temp.next"; mv "$temp.next" "$temp"
  done
  if [[ -n "$append_notes" ]]; then
    jq --arg v "$append_notes" '.[0].notes = (if ((.[0].notes // "") == "") then $v else .[0].notes + "\n\n" + $v end)' "$temp" >"$temp.next"; mv "$temp.next" "$temp"
  fi
  mv "$temp" "$MOCK_STATE"
  echo 'mock update succeeded'
  exit 0
fi

if [[ "${1:-}" == mail && "${2:-}" == send ]]; then
  [[ "${MOCK_FAIL:-}" == mail ]] && { echo 'mock mail failure' >&2; exit 1; }
  exit 0
fi
if [[ "${1:-}" == runtime && "${2:-}" == drain ]]; then
  [[ "${MOCK_FAIL:-}" == drain ]] && { echo 'mock drain failure' >&2; exit 1; }
  exit 0
fi
echo "unsupported mock gc command: $*" >&2
exit 9
MOCK
chmod +x "$MOCK_GC"
export GC_BIN="$MOCK_GC"

reset_state() {
  local status="${1:-in_progress}" assignee="${2:-worker}" count="${3:-}" budget="${4:-}"
  jq -n --arg status "$status" --arg owner "$assignee" --arg count "$count" --arg budget "$budget" \
    '[{id:"fx-1",status:$status,assignee:$owner,notes:"existing checkpoint",metadata:{"gc.routed_to":"research/gasvillage.polecat","gc.session_id":"live-session","gc.session_name":"polecat-session","work_dir":"/work/source"}} | if $count != "" then .metadata["gasvillage.retry_count"]=$count else . end | if $budget != "" then .metadata["gasvillage.retry_budget"]=$budget else . end]' \
    >"$MOCK_STATE"
  : >"$MOCK_LOG"
  rm -f "$MOCK_RACE_MARK"
  unset MOCK_FAIL MOCK_RACE
}

run_hold() {
  "$HELPER" hold --rig research --bead fx-1 --owner worker \
    --coordinator gasvillage.mayor --session live-session --worktree /work/source \
    --reason 'cannot proceed safely' --evidence 'observed blocker' --handoff 'last good checkpoint is c0ffee'
}

reset_state
run_hold >/dev/null
assert_eq "$(jq -r '.[0].status' "$MOCK_STATE")" blocked
assert_eq "$(jq -r '.[0].assignee' "$MOCK_STATE")" worker
assert_eq "$(jq -r '.[0].metadata["gc.routed_to"] // empty' "$MOCK_STATE")" ''
assert_eq "$(jq -r '.[0].metadata["gasvillage.held_route"]' "$MOCK_STATE")" research/gasvillage.polecat
assert_eq "$(jq -r '.[0].metadata["gasvillage.held_session"]' "$MOCK_STATE")" live-session
assert_has "$MOCK_STATE" 'last good checkpoint is c0ffee'
assert_has "$MOCK_STATE" '/work/source'
assert_has "$MOCK_STATE" 'existing checkpoint'
assert_has "$MOCK_LOG" 'rig=research bd show fx-1 --json'
assert_has "$MOCK_LOG" 'rig=research bd update fx-1'
assert_has "$MOCK_LOG" 'mail send gasvillage.mayor'
assert_has "$MOCK_LOG" 'runtime drain live-session'
if jq -e '.[0].status == "open" and .[0].assignee == "" and .[0].metadata["gc.routed_to"] != null' "$MOCK_STATE" >/dev/null; then
  fail 'held task still matches the routed ready-work shape'
fi

reset_state in_progress other-worker
: >"$MOCK_LOG"
if run_hold >/dev/null 2>&1; then fail 'wrong owner was allowed to hold the bead'; fi
assert_lacks "$MOCK_LOG" 'bd update fx-1'
assert_lacks "$MOCK_LOG" 'mail send'
assert_lacks "$MOCK_LOG" 'runtime drain'

reset_state
export MOCK_RACE=owner
if run_hold >/dev/null 2>&1; then fail 'stale-owner race passed its update guard'; fi
assert_eq "$(jq -r '.[0].assignee' "$MOCK_STATE")" other-worker
assert_eq "$(jq -r '.[0].metadata["gc.routed_to"]' "$MOCK_STATE")" research/gasvillage.polecat
assert_lacks "$MOCK_LOG" 'mail send'
assert_lacks "$MOCK_LOG" 'runtime drain'

reset_state
export MOCK_RACE=status
if run_hold >/dev/null 2>&1; then fail 'stale-status race passed its update guard'; fi
assert_eq "$(jq -r '.[0].status' "$MOCK_STATE")" blocked
assert_eq "$(jq -r '.[0].assignee' "$MOCK_STATE")" worker
assert_eq "$(jq -r '.[0].metadata["gc.routed_to"]' "$MOCK_STATE")" research/gasvillage.polecat
assert_lacks "$MOCK_LOG" 'mail send'
assert_lacks "$MOCK_LOG" 'runtime drain'

reset_state
export MOCK_FAIL=update
if run_hold >/dev/null 2>&1; then fail 'failed bead update reported success'; fi
assert_eq "$(jq -r '.[0].status' "$MOCK_STATE")" in_progress
assert_lacks "$MOCK_LOG" 'mail send'
assert_lacks "$MOCK_LOG" 'runtime drain'

reset_state
export MOCK_FAIL=mail
if run_hold >/dev/null 2>&1; then fail 'mail failure reported a complete hold'; fi
assert_eq "$(jq -r '.[0].status' "$MOCK_STATE")" blocked
assert_eq "$(jq -r '.[0].metadata["gc.routed_to"] // empty' "$MOCK_STATE")" ''
assert_lacks "$MOCK_LOG" 'runtime drain'

reset_state
export MOCK_FAIL=drain
if run_hold >/dev/null 2>&1; then fail 'drain failure reported a complete hold'; fi
assert_eq "$(jq -r '.[0].status' "$MOCK_STATE")" blocked
assert_eq "$(jq -r '.[0].metadata["gc.routed_to"] // empty' "$MOCK_STATE")" ''
assert_has "$MOCK_LOG" 'mail send gasvillage.mayor'

reset_state
jq '.[0].metadata |= del(."gc.session_id", ."gc.session_name")' "$MOCK_STATE" >"$MOCK_STATE.tmp"
mv "$MOCK_STATE.tmp" "$MOCK_STATE"
if run_hold >/dev/null 2>&1; then fail 'unverified session was reported as drained'; fi
assert_eq "$(jq -r '.[0].status' "$MOCK_STATE")" blocked
assert_eq "$(jq -r '.[0].metadata["gc.routed_to"] // empty' "$MOCK_STATE")" ''
assert_eq "$(jq -r '.[0].metadata["gasvillage.held_session"]' "$MOCK_STATE")" UNRESOLVED
assert_has "$MOCK_LOG" 'mail send gasvillage.mayor'
assert_lacks "$MOCK_LOG" 'runtime drain'

reset_state in_progress worker 0 2
for incarnation in 1 2; do
  GC_SESSION_ID="incarnation-$incarnation" GC_AGENT=worker "$HELPER" retry \
    --rig research --bead fx-1 --owner worker --coordinator gasvillage.mayor \
    --worktree /work/source --session "incarnation-$incarnation" \
    --failure-key same-preflight --evidence 'same measured failure' >/dev/null
  assert_eq "$(jq -r '.[0].metadata["gasvillage.retry_count"]' "$MOCK_STATE")" "$incarnation"
done
assert_has "$MOCK_STATE" 'Worker incarnation: incarnation-1'
assert_has "$MOCK_STATE" 'Worker incarnation: incarnation-2'
GC_SESSION_ID=incarnation-3 GC_AGENT=worker "$HELPER" retry \
  --rig research --bead fx-1 --owner worker --coordinator gasvillage.mayor \
  --worktree /work/source --session incarnation-3 \
  --failure-key same-preflight --evidence 'still no progress' >/dev/null
assert_eq "$(jq -r '.[0].status' "$MOCK_STATE")" blocked
assert_eq "$(jq -r '.[0].metadata["gasvillage.retry_count"]' "$MOCK_STATE")" 2
assert_eq "$(jq -r '.[0].metadata["gc.routed_to"] // empty' "$MOCK_STATE")" ''

if "$HELPER" resume --rig research --bead fx-1 --owner worker \
  --reviewer coordinator --condition dependency_available --disposition 'dependency is ready' \
  >/dev/null 2>&1; then fail 'exhausted budget resumed without reset evidence'; fi
assert_eq "$(jq -r '.[0].status' "$MOCK_STATE")" blocked

"$HELPER" resume --rig research --bead fx-1 --owner worker \
  --reviewer coordinator --condition dependency_available \
  --disposition 'retry after dependency became available' \
  --reset-evidence 'dependency bead closed; a new run can make progress' >/dev/null
assert_eq "$(jq -r '.[0].status' "$MOCK_STATE")" open
assert_eq "$(jq -r '.[0].assignee' "$MOCK_STATE")" ''
assert_eq "$(jq -r '.[0].metadata["gc.routed_to"]' "$MOCK_STATE")" research/gasvillage.polecat
assert_eq "$(jq -r '.[0].metadata["gasvillage.retry_count"]' "$MOCK_STATE")" 0
assert_has "$MOCK_STATE" 'dependency became available'
assert_lacks "$MOCK_LOG" 'session wake'

# Simulate the routed pool's later claim, in a different incarnation.
jq '.[0].status="in_progress" | .[0].assignee="worker" | .[0].metadata["gc.session_id"]="incarnation-4"' \
  "$MOCK_STATE" >"$MOCK_STATE.tmp"
mv "$MOCK_STATE.tmp" "$MOCK_STATE"
GC_SESSION_ID=incarnation-4 GC_AGENT=worker "$HELPER" retry \
  --rig research --bead fx-1 --owner worker --coordinator gasvillage.mayor \
  --worktree /work/source --session incarnation-4 \
  --failure-key changed-condition --evidence 'new iteration checkpoint' >/dev/null
assert_eq "$(jq -r '.[0].metadata["gasvillage.retry_count"]' "$MOCK_STATE")" 1
"$HELPER" review-progress --rig research --bead fx-1 --owner worker \
  --reviewer coordinator --evidence 'review accepted a concrete new checkpoint' >/dev/null
assert_eq "$(jq -r '.[0].metadata["gasvillage.retry_count"]' "$MOCK_STATE")" 0
assert_has "$MOCK_STATE" 'review accepted a concrete new checkpoint'

reset_state in_progress worker 1 2
run_hold >/dev/null
assert_eq "$(jq -r '.[0].metadata["gasvillage.retry_count"]' "$MOCK_STATE")" 1

echo 'PASS: work-item-control mock-store checks'
