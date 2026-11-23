#!/bin/bash
# Smoke test in a private state directory. Each check names the bug it catches.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
ab="$here/agent-build"
export AGENT_BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agent-build-test.XXXXXX")"
unset AGENT_BUILD_HELD AGENT_BUILD_ENV
fail=0
check() { if [[ "$2" == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: got '$2', want '$3'"; fail=1; fi; }
has() { if [[ "$2" == *"$3"* ]]; then echo "ok   $1"; else echo "FAIL $1: '$2' lacks '$3'"; fail=1; fi; }

# Catches: the wrapper swallowing or rewriting the command's exit status.
"$ab" sh -c 'exit 3'; check "exit status passes through" "$?" 3
"$ab" no-such-command-xyz 2>/dev/null; check "missing command is 127" "$?" 127

# Catches: two heavy jobs running at once (no mutual exclusion).
"$ab" sh -c 'echo start-a; sleep 3; echo end-a' >"$AGENT_BUILD_DIR/log" 2>&1 &
sleep 0.7
"$ab" sh -c 'echo start-b' >>"$AGENT_BUILD_DIR/log" 2>"$AGENT_BUILD_DIR/wait.err"
wait
check "second job starts after the first ends" "$(grep -E '^(start|end)-' "$AGENT_BUILD_DIR/log" | tr '\n' ' ')" "start-a end-a start-b "
has "a waiter is told who holds the slot" "$(cat "$AGENT_BUILD_DIR/wait.err")" "waiting for the heavy slot, held by pid"

# Catches: a light job waiting behind a heavy one (the two lanes must be independent).
"$ab" sleep 3 &
sleep 0.7
t0=$SECONDS; "$ab" --light true; check "light slot does not wait for heavy" "$((SECONDS - t0 < 2))" 1

# Catches: status hiding the queue. One holder (sleeping, so idle) and one waiter.
"$ab" true 2>/dev/null &
sleep 0.7
st="$("$ab" --status)"
has "status shows the holder" "$st" "heavy held"
has "status says the holder is idle" "$st" "idle now"
has "status lists the waiter" "$st" "waiting"
wait

# Catches: a cancelled job dying silently, and its children surviving it.
"$ab" sh -c 'sleep 60 & echo $! >"$AGENT_BUILD_DIR/grandchild"; wait' 2>"$AGENT_BUILD_DIR/cancel.err" &
job=$!
sleep 0.7
"$ab" --cancel "render loop does not compile; run it without the wrapper" >/dev/null
wait "$job"; check "cancelled job exits 75" "$?" 75
has "the job's owner reads the reason" "$(cat "$AGENT_BUILD_DIR/cancel.err")" "render loop does not compile"
sleep 0.3
kill -0 "$(cat "$AGENT_BUILD_DIR/grandchild")" 2>/dev/null; check "the job's children are stopped too" "$?" 1
check "slot is free after a cancel" "$("$ab" --status | head -1 | tr -s ' ')" "heavy free"

# Catches: a build script that calls the wrapper again deadlocking on its own parent's slot.
t0=$SECONDS; out="$("$ab" "$ab" echo nested)"; check "nested call runs at once" "$out $((SECONDS - t0 < 2))" "nested 1"

# Catches: a waiting job that cannot be cancelled.
"$ab" sleep 4 &
sleep 0.5
"$ab" true 2>"$AGENT_BUILD_DIR/w.err" &
waiter=$!
sleep 0.7
"$ab" --cancel "$waiter" "not needed any more" >/dev/null
wait "$waiter"; check "cancelled waiter exits 75" "$?" 75
has "the waiter's owner reads the reason" "$(cat "$AGENT_BUILD_DIR/w.err")" "not needed any more"
wait

[[ $fail == 0 ]] && echo "all checks passed" || echo "SOME CHECKS FAILED"
exit $fail
