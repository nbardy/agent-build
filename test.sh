#!/bin/bash
# Smoke test in a private state directory. Each check names the bug it catches.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
ab="$here/agent-build"
T="$(mktemp -d "${TMPDIR:-/tmp}/agent-build-test.XXXXXX")"
export AGENT_BUILD_DIR="$T" AGENT_BUILD_MIN_FREE_PCT=0
unset AGENT_BUILD_HELD AGENT_BUILD_ENV AGENT_BUILD_GPU_PIDFILE AGENT_BUILD_GPU_ENV AGENT_BUILD_LIMITS AGENT_BUILD_MAX_WAIT
fail=0
check() { if [[ "$2" == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: got '$2', want '$3'"; fail=1; fi; }
has() { if [[ "$2" == *"$3"* ]]; then echo "ok   $1"; else echo "FAIL $1: '$2' lacks '$3'"; fail=1; fi; }

# Catches: the wrapper swallowing or rewriting the command's exit status.
"$ab" sh -c 'exit 3'; check "exit status passes through" "$?" 3
"$ab" no-such-command-xyz 2>/dev/null; check "missing command is 127" "$?" 127

# Catches: two heavy jobs running at once (no mutual exclusion).
"$ab" sh -c 'echo start-a; sleep 3; echo end-a' >"$T/log" 2>&1 &
sleep 0.7
"$ab" sh -c 'echo start-b' >>"$T/log" 2>"$T/wait.err"
wait
check "second job starts after the first ends" "$(grep -E '^(start|end)-' "$T/log" | tr '\n' ' ')" "start-a end-a start-b "
has "a waiter is told who holds the slot" "$(cat "$T/wait.err")" "waiting for the heavy slot, held by pid"

# Catches: one class waiting behind another (light, gpu and sim are independent of heavy).
"$ab" sleep 3 &
sleep 0.7
t0=$SECONDS; "$ab" --light true && "$ab" --gpu true && "$ab" --sim true
check "light, gpu and sim do not wait for heavy" "$((SECONDS - t0 < 2))" 1

# Catches: status hiding the queue. One holder (sleeping, so idle) and one waiter.
"$ab" true 2>/dev/null &
sleep 0.7
st="$("$ab" --status)"
has "status shows the holder and its limit" "$st" "heavy  held"
has "status shows the class limit" "$st" "limit 30m"
has "status says the holder is idle" "$st" "idle now"
has "status lists the queue" "$st" "queue 1: pid"
wait

# Catches: a cancelled job dying silently, and its children surviving it.
"$ab" sh -c 'sleep 60 & echo $! >"$AGENT_BUILD_DIR/grandchild"; wait' 2>"$T/cancel.err" &
job=$!
sleep 0.7
"$ab" --cancel "render loop does not compile; run it with --gpu" >/dev/null
wait "$job"; check "cancelled job exits 75" "$?" 75
has "the job's owner reads the reason" "$(cat "$T/cancel.err")" "render loop does not compile"
sleep 0.3
kill -0 "$(cat "$T/grandchild")" 2>/dev/null; check "the job's children are stopped too" "$?" 1
check "slot is free after a cancel" "$("$ab" --status | head -1 | tr -s ' ')" "heavy free"

# Catches: a build script that calls the wrapper again deadlocking on its own parent's slot.
t0=$SECONDS; out="$("$ab" "$ab" echo nested)"; check "nested call runs at once" "$out $((SECONDS - t0 < 2))" "nested 1"

# Catches: a waiting job that cannot be cancelled.
"$ab" sleep 4 &
sleep 0.5
"$ab" true 2>"$T/w.err" &
waiter=$!
sleep 0.7
"$ab" --cancel "$waiter" "not needed any more" >/dev/null
wait "$waiter"; check "cancelled waiter exits 75" "$?" 75
has "the waiter's owner reads the reason" "$(cat "$T/w.err")" "not needed any more"
wait

# Catches: a job blocking forever in the queue (the caller never gets control back).
"$ab" sleep 4 &
sleep 0.5
"$ab" --max-wait 0.02 echo should-not-run >"$T/mw.out" 2>"$T/mw.err"; code=$?
check "a bounded wait exits 69" "$code" 69
check "nothing ran after giving up" "$(cat "$T/mw.out")" ""
has "the caller is told who held the slot" "$(cat "$T/mw.err")" "gave up after"
wait

# Catches: a job holding a slot without limit, with and without a declared longer limit.
AGENT_BUILD_LIMITS=heavy=0.02 "$ab" sleep 30 2>"$T/lim.err"; check "a job past its class limit is stopped with 75" "$?" 75
has "its owner is told about the limit" "$(cat "$T/lim.err")" "its limit"
AGENT_BUILD_LIMITS=heavy=0.02 "$ab" --max-minutes 1 "full release build" sleep 2; check "a declared longer limit lets it finish" "$?" 0

# Catches: holding one shared lock while blocked on another (the GPU held by a job still waiting for a build slot).
"$ab" sleep 3 &
sleep 0.5
"$ab" --gpu --heavy true 2>/dev/null &
sleep 0.8
has "a job waiting for heavy+gpu holds neither" "$("$ab" --status)" "gpu    free"
t0=$SECONDS; "$ab" --gpu true; check "so another gpu job is not blocked by it" "$((SECONDS - t0 < 2))" 1
wait

# Catches: a waiter for several slots freezing the free ones for everyone behind it, and the
# opposite, that waiter being overtaken forever.
now() { perl -MTime::HiRes=time -e 'printf "%.1f", time'; }
"$ab" sleep 3 &
sleep 0.4
"$ab" --gpu --heavy true 2>/dev/null &
sleep 0.9
t0=$(now); "$ab" --gpu true; t1=$(now)
check "a later gpu job runs while an earlier heavy+gpu job waits on heavy" "$(perl -e "print(($t1 - $t0) < 1.0 ? 1 : 0)")" 1
wait
"$ab" sleep 3 &
sleep 0.4
AGENT_BUILD_STRICT_AFTER=0 "$ab" --gpu --heavy true 2>/dev/null &
sleep 0.9
t0=$(now); AGENT_BUILD_STRICT_AFTER=0 "$ab" --gpu true 2>/dev/null; t1=$(now)
check "once the earlier job has waited long enough, it goes first" "$(perl -e "print(($t1 - $t0) > 1.0 ? 1 : 0)")" 1
wait

# Catches: a later job overtaking an earlier one for the same slot.
"$ab" sleep 2 &
sleep 0.4
"$ab" sh -c 'echo first' >>"$T/fifo" 2>/dev/null &
sleep 0.4
"$ab" sh -c 'echo second' >>"$T/fifo" 2>/dev/null &
sleep 0.4
"$ab" sh -c 'echo third' >>"$T/fifo" 2>/dev/null &
wait
check "waiters run first in, first out" "$(tr '\n' ' ' <"$T/fifo")" "first second third "

# Catches: starting a job when memory is short.
AGENT_BUILD_MIN_FREE_PCT=100 "$ab" --max-wait 0.02 true 2>"$T/mem.err"; check "below the memory floor nothing starts" "$?" 69
has "and the caller is told it was memory" "$(cat "$T/mem.err")" "memory"

# Catches: the gpu class ignoring a PID-file GPU lock that other tools use.
export AGENT_BUILD_GPU_PIDFILE="$T/gpu.pid" AGENT_BUILD_GPU_ENV=TEST_GPU_HOLDER
"$ab" --gpu sh -c 'echo "$(cat "$AGENT_BUILD_GPU_PIDFILE") $TEST_GPU_HOLDER $PPID"' >"$T/pid.out"
read -r in_file in_env parent <"$T/pid.out"
check "the PID file names the wrapper while the job runs" "$in_file $in_env" "$parent $parent"
check "and is removed afterwards" "$([[ -e "$T/gpu.pid" ]] && echo present || echo gone)" "gone"
sh -c 'echo $$ >"$0"; exec sleep 3' "$T/gpu.pid" &
sleep 0.4
"$ab" --gpu --max-wait 0.02 true 2>/dev/null; check "a live foreign PID in the file holds the gpu slot" "$?" 69
wait
"$ab" --gpu true; check "a dead PID in the file does not" "$?" 0

[[ $fail == 0 ]] && echo "all checks passed" || echo "SOME CHECKS FAILED"
exit $fail
