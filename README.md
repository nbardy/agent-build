# agent-build

One heavy build at a time per machine, for machines where several coding agents (or people) work
at once. Put it in front of any command that should not run beside another like it:

```sh
agent-build cargo build --release
agent-build make -j8 test
```

The second caller waits its turn instead of doubling the load. Unlike a bare lock, the queue is
visible and a job can be stopped with a reason that reaches whoever started it.

## Why

Several agents compiling at once can make every build many times slower than running them in
turn. A plain lock fixes that and creates a new problem: a job that holds the lock for a long
time, perhaps without compiling anything, silently blocks everyone, and the only remedy is to
kill it without telling its owner why. This tool keeps the lock and adds what was missing.

## Use

| Command | What it does |
|---|---|
| `agent-build COMMAND [ARG ...]` | Wait for the heavy slot, run the command, release the slot. Exit status is the command's. |
| `agent-build --light COMMAND [ARG ...]` | Use the light slot: one small job at low priority that runs beside the heavy one, so a ten-second check never waits behind a long build. |
| `agent-build --status` | Who holds each slot, for how long, whether it is using any CPU right now, and who is waiting. |
| `agent-build --cancel REASON` | Stop the job holding the heavy slot. |
| `agent-build --cancel PID REASON` | Stop a specific job, running or waiting (PIDs are in `--status`). |

A waiting job says who it is waiting for, and how to look or intervene:

```
agent-build: waiting for the heavy slot, held by pid 4821 for 34m12s, idle now (python in /work/render).
agent-build: see the queue with `agent-build --status`; stop the holder with `agent-build --cancel 'why'`.
```

```
$ agent-build --status
heavy held 34m12s by pid 4821, idle now: python in /work/render
      waiting 30m05s: pid 5170: cargo in /work/sim
light free
```

A cancelled job stops its whole process tree, prints the reason on its own stderr and exits
with status 75, so the agent or person who started it learns why:

```
$ agent-build --cancel "render loop compiles nothing; run it without agent-build"
agent-build: stopped pid 4821; it reported your reason to its caller.
```

```
agent-build: this job was cancelled. Reason given: render loop compiles nothing; run it without agent-build (cancelled from /work/sim)
```

## Install

It is one file with no dependencies beyond Python 3.8+ and `ps`. Works on macOS and Linux.

```sh
curl -fsSL https://raw.githubusercontent.com/nbardy/agent-build/main/agent-build -o ~/.local/bin/agent-build
chmod +x ~/.local/bin/agent-build
```

Then tell your agents, in whatever instructions file they read: *run builds and test suites
through `agent-build`; do not wrap long simulations, renders or training runs in it.*

## How it works

- A slot is `flock(2)` on a file, held by the wrapper process while the command runs as its
  child. The kernel releases it when the wrapper exits for any reason, so there are no stale
  locks to clean up.
- The lock's file descriptor is not passed to the command, so a daemon the build leaves behind
  (a compiler cache server, for example) cannot keep the slot.
- The command runs in its own process group. A cancel sends SIGTERM to the group and SIGKILL
  after ten seconds.
- "idle now" means the holder's whole process tree used no measurable CPU over one second.
  It is a hint that a job may be holding the slot without building; nothing is stopped
  automatically.
- A command started under a slot that calls `agent-build` again runs at once (it already holds
  the slot), so build scripts can use it freely.
- Waiters are served in the order the kernel wakes them, which is not strictly first come,
  first served.

## Settings

| Variable | Meaning |
|---|---|
| `AGENT_BUILD=off` | Run commands directly, with no locking (a machine of your own). |
| `AGENT_BUILD_DIR` | Where the lock and job files live. Default: `~/Library/Caches/agent-build` on macOS, `$XDG_CACHE_HOME/agent-build` or `~/.cache/agent-build` elsewhere. |
| `AGENT_BUILD_ENV` | Name of the variable that marks "already inside a slot" for nested calls. Default `AGENT_BUILD_HELD`. |
| `CARGO_BUILD_JOBS` | Left alone on the heavy slot; defaults to 4 on the light slot if unset. |

`AGENT_BUILD_DIR` and `AGENT_BUILD_ENV` exist so the tool can share lock files with an existing
`flock`-based gate: any script that locks `slot.0` or `slot.light` in the same directory, writes
`holder=PID owner=PID since=EPOCH label=TEXT` to `slot.N.info` and exports `PID:N` in the
named variable excludes against it both ways. A job that holds a slot through such a script can
be cancelled, but it cannot be given the reason.

## Limits

- If the wrapper itself is killed with SIGKILL, the slot is released but its command keeps
  running unlocked.
- The idle check is instantaneous. A build waiting on a network download looks idle.
- One user per queue: a job can only be cancelled by a user allowed to signal it.

## Test

```sh
./test.sh
```

Runs in a private temporary directory and checks mutual exclusion, the independent light slot,
status output, cancel of a running job (reason delivered, children stopped) and of a waiting
job, and nested calls.
