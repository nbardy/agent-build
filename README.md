# agent-build

Shared slots for heavy work on one machine, for machines where several coding agents (or people)
work at once. Put it in front of anything heavy and say what the job needs:

```sh
agent-build cargo build --release              # a full build or test suite
agent-build --light cargo check -p parser      # a small check; runs beside a full build
agent-build --gpu python render_batch.py       # the GPU
agent-build --sim ./balance_batch --minutes 45 # one long CPU job, beside builds
agent-build --gpu --heavy ./gpu_timing.sh      # a quiet GPU and no build running
```

A job waits its turn instead of doubling the load. Unlike a bare lock, the queue is visible, no
job waits or holds a slot without bound, and a job can be stopped with a reason that reaches
whoever started it.

## Why

Several agents compiling, rendering or simulating at once can make every job many times slower
than running them in turn. A plain lock fixes that and creates new failures, each of which this
tool exists to remove:

| Failure with a plain lock | What agent-build does |
|---|---|
| A job that compiles nothing holds the build lock for an hour | Classes: declare `--gpu` or `--sim` and it does not take the build slot. Every class has a hold limit |
| An agent blocks in the queue forever and never gets control back | The wait is bounded: after 10 minutes the command exits 69 and says who held the slot |
| A job holds the GPU while it waits for a build slot | A job gets all of its slots or none: on any miss it releases everything and retries |
| Nobody can see the queue | `--status` shows holders, their age, whether they are using CPU, the waiters and memory |
| The only remedy is `kill`, and the owner never learns why | `--cancel REASON` stops the job's whole process tree and prints the reason on its stderr |

## Use

```
agent-build [CLASS ...] [OPTION ...] COMMAND [ARG ...]
```

| Class | Slot | For | Hold limit |
|---|---|---|---:|
| (none) or `--heavy` | heavy | A full build or test suite. One per machine | 30 min |
| `--light` | light | One small job, at low priority (`CARGO_BUILD_JOBS` defaults to 4), beside the heavy one | 10 min |
| `--gpu` | gpu | Renders, GPU benchmarks, training | 60 min |
| `--sim` | sim | One long CPU job, such as a simulation batch, beside builds | 120 min |

Classes combine. The job gets every slot it names, or waits holding none.

| Option | Meaning |
|---|---|
| `--max-wait MIN` | Give up after MIN minutes in the queue (default 10). Exit 69; nothing was run. |
| `--max-minutes N REASON` | Hold the slots up to N minutes instead of the class limit. The reason shows in `--status`. |
| `--mem GB` | Memory the job will use. It starts only when that still leaves the free-memory floor. |

| Command | Meaning |
|---|---|
| `agent-build --status` | Every slot's holder, age, busy or idle, and limit; the queue in order; available memory. |
| `agent-build --cancel REASON` | Stop the job holding the heavy slot. |
| `agent-build --cancel PID REASON` | Stop any job, running or waiting (PIDs are in `--status`). |

Exit status is the command's own, except:

| Status | Meaning | What the caller should do |
|---:|---|---|
| 69 | Gave up waiting. Nothing ran. The message names what was in the way | Do other work and retry, or pass `--max-wait` |
| 75 | The job was cancelled (the reason is printed) or ran past its hold limit | Read the reason. For a long job, declare it with `--max-minutes N REASON` |

```
$ agent-build --status
heavy  held 4m10s by pid 4821, busy now, limit 30m: cargo in /work/app
light  free
gpu    held 51m02s by pid 5170, idle now, limit 90m: nightly render set: python in /work/render
sim    free
queue 1: pid 6012, waiting 2m31s for heavy+gpu: gpu_timing.sh in /work/app
memory 31% available (jobs start above 10%)
```

A waiting job says what it is waiting for and when it will give up:

```
agent-build: waiting for the heavy slot, held by pid 4821 for 4m10s, busy now (cargo in /work/app).
agent-build: it gives up after 10 minutes (--max-wait MIN). See the queue with `agent-build --status`.
```

A cancelled job reports to its own caller:

```
$ agent-build --cancel 5170 "idle for 20 minutes while holding the GPU"
agent-build: stopped pid 5170; it reported your reason to its caller.
```
```
agent-build: this job was cancelled. Reason given: idle for 20 minutes while holding the GPU (cancelled from /work/app)
```

## Guidance for agents

Put something like this in the instructions file your agents read:

> Run anything heavy through `agent-build`, with the class it needs: builds and test suites
> (no flag), small single-package checks (`--light`), GPU work (`--gpu`), long CPU simulations
> (`--sim`). Wrap the work, not the thinking: if you loop render, think, render, wrap each render
> batch, so a slot is never held while you decide what to do next. If a command exits 69, the
> queue was busy: do something else and retry. If it exits 75, read the reason.

## Install

One file, no dependencies beyond Python 3.8+ and `ps`. macOS and Linux.

```sh
curl -fsSL https://raw.githubusercontent.com/nbardy/agent-build/main/agent-build -o ~/.local/bin/agent-build
chmod +x ~/.local/bin/agent-build
```

## How it works

- **Slots.** A slot is `flock(2)` on a file, held by the wrapper while the command runs as its
  child. The kernel releases it when the wrapper exits for any reason, so there are no stale
  locks. The lock's descriptor is not passed to the command, so a daemon the job leaves behind
  (a compiler cache server, say) cannot keep a slot.
- **All or nothing.** A job tries its slots in a fixed order without blocking. If any is taken
  it releases the ones it got and tries again shortly. It never holds one shared lock while
  waiting for another.
- **Order.** Jobs are numbered as they arrive. A later job never takes the slot an earlier
  waiter is blocked on, so each slot is first in, first out. An earlier waiter that needs
  several slots leaves its other slots open to later jobs for its first two minutes
  (`AGENT_BUILD_STRICT_AFTER`, seconds); after that it reserves all of them, so it cannot be
  starved and free slots are not frozen behind it either.
- **Memory.** Nothing starts while available memory (after the job's `--mem`, and the `--mem`
  of jobs started in the last minute) is under the floor. Available means free plus reclaimable
  pages on macOS and `MemAvailable` on Linux.
- **Limits.** The wrapper stops its own job when the hold limit passes: SIGTERM to the job's
  process group, SIGKILL ten seconds later. A cancel works the same way.
- **Idle.** "idle now" means the holder's whole process tree used no measurable CPU for one
  second. It is a hint; nothing is stopped for being idle.
- **Nesting.** A command started under a slot that calls `agent-build` again for the same slot
  runs at once.

## Settings

| Variable | Meaning | Default |
|---|---|---|
| `AGENT_BUILD=off` | Run commands directly, with no slots (a machine of your own) | on |
| `AGENT_BUILD_DIR` | Where lock and job files live | `~/Library/Caches/agent-build` (macOS), `~/.cache/agent-build` |
| `AGENT_BUILD_MAX_WAIT` | Default for `--max-wait`, minutes | 10 |
| `AGENT_BUILD_LIMITS` | Hold limits in minutes, for example `heavy=45,gpu=90` | heavy 30, light 10, gpu 60, sim 120 |
| `AGENT_BUILD_MIN_FREE_PCT` | Free-memory floor, percent of total; 0 turns it off | 10 |
| `AGENT_BUILD_STRICT_AFTER` | Seconds a multi-slot waiter leaves its unblocked slots open to later jobs | 120 |

### Sharing locks with existing scripts

If the machine already has lock scripts, agent-build can take the same locks, so old and new
callers exclude each other in both directions.

| Variable | For |
|---|---|
| `AGENT_BUILD_DIR` | A `flock` gate that locks `slot.0` (heavy), `slot.light` or `slot.sim` in a directory and writes `holder=PID owner=PID since=EPOCH label=TEXT` to `slot.N.info` |
| `AGENT_BUILD_ENV` | The variable that gate exports as `PID:N` to mark "already inside", so nested calls pass straight through either way |
| `AGENT_BUILD_GPU_PIDFILE` | A GPU lock that is a file holding the owner's PID, replaced under `flock` of `FILE.guard`. The `--gpu` slot then uses that file |
| `AGENT_BUILD_GPU_ENV` | The variable that GPU lock reads for nesting; it is set to the wrapper's PID |

A job that holds a slot through such a script shows in `--status` and can be cancelled, but it
cannot be given the reason, and its hold limit is flagged, not enforced.

## Limits of the tool

- A legitimately long job that does not declare `--max-minutes` is stopped at its class limit
  and that run is lost. This is deliberate: a slot held too long costs everyone else.
- If the wrapper itself is killed with SIGKILL, its slots are released but its command keeps
  running unlocked.
- Waiters poll, so a script outside this tool that re-takes a lock within milliseconds of
  releasing it can starve them. The bounded wait turns that into exit 69, not a hang.
- The idle check is instantaneous: a build waiting on a download looks idle.
- One user per queue: a job can only be cancelled by a user allowed to signal it.

## Test

```sh
./test.sh
```

Runs in a private temporary directory: mutual exclusion, independent classes, all-or-nothing
acquisition, first in first out, bounded wait, hold limits, the memory floor, status, cancel of
running and waiting jobs, nested calls and the PID-file GPU lock.
