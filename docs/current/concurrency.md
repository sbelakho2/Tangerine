# Tangerine Concurrency Guide

**Version:** 0.2.0
**Last Updated:** 2026-08

Complete guide to concurrent and asynchronous programming in Tangerine,
written against the **access/resource model** (the current dialect). The
March-2026 edition taught the removed borrow syntax (`&T` parameters,
`&self` receivers, `Send`/`Sync` marker traits); this edition teaches the
model the compiler actually implements.

---

## Table of Contents

1. [The Access/Resource Model](#the-accessresource-model)
2. [Transferable and Shareable](#transferable-and-shareable)
3. [Threads (`std/thread`)](#threads)
4. [Shared State: `Arc`](#shared-state-arc)
5. [Locks: `Mutex` and `RwLock`](#locks-mutex-and-rwlock)
6. [Condition Variables, `Once`, and Barriers](#condition-variables-once-and-barriers)
7. [Atomics](#atomics)
8. [Channels](#channels)
9. [The Async Model (`std/async`)](#the-async-model)
10. [Structured Concurrency](#structured-concurrency)
11. [Cancellation](#cancellation)
12. [Async Synchronization](#async-synchronization)
13. [The Executor](#the-executor)
14. [Thread Pools (`std/exec`)](#thread-pools)
15. [Best Practices](#best-practices)

---

## The Access/Resource Model

Tangerine provides two concurrency models:

| Model | Module | Use Case |
|-------|--------|----------|
| **OS Threads** | `std/thread` | CPU-bound parallelism, blocking operations |
| **Async Tasks** | `std/async` | I/O-bound concurrency, high connection count |

Both models are built on the ownership/access system. There are **no
first-class reference types**: `&T` / `&mut T` in a type position is the
E106 hard error, and the legacy parameter spellings (`mut x:`, `&x:`,
`&mut x:`, `move x:`, `own x:`, `x: &T`, `&self`, ...) are the E100 hard
error. Access to a value is expressed with **parameter conventions**:

| Convention | Meaning | Caller keeps |
|------------|---------|--------------|
| `x: T` (the default `let`) | read-only access | ownership |
| `inout x: T` | exclusive mutation | ownership |
| `sink x: T` | the by-value transfer | nothing (consumed) |
| `set x: T` | initialize dead storage | ownership (must be exactly Live on exit) |

At a call site, `&place` / `&mut place` are **access markers** — they
select the callee-side convention (`&x` passes a place to an `inout` or
`let` parameter, `&mut x` to an `inout` or `sink` parameter). They are
only valid as call arguments; anywhere else is a compile error.

Concurrency builds on this model:

- **Thread-crossing moves** use `sink` (the closure capture is *moved*
  into the thread).
- **Shared state** lives in a heap allocation owned by `Arc` — the
  refcounted allocation is the one shared-ownership shape.
- **Locks** protect the shared value; the guards hold their own `Arc`
  clone of the lock state (the heap-stable guard design — see
  [Locks](#locks-mutex-and-rwlock)).
- **Message passing** moves values through channels; the channel state
  itself is `Arc`-owned.

---

## Transferable and Shareable

The compiler derives two thread-safety properties for every type,
expressed as the marker traits `Transferable` and `Shareable`
(`std/core.tg`):

| Property | Meaning |
|----------|---------|
| `Transferable` | a value of the type may be **moved** to another thread (a `sink` transfer across the boundary) |
| `Shareable` | a value of the type may be **shared** with other threads (the address is reachable from more than one thread at once) |

The primitive types, `String`, the atomics, the shared-state types
(`Mutex`, `RwLock`, `Condvar`, `Once`, `Barrier`), and the async
synchronizers (`AsyncMutex`, `AsyncSemaphore`, the channels) carry the
impls; the closure/thread boundary resolves them through the trait
solver. The legacy `Send`/`Sync` marker names from the removed dialect
are not part of the current grammar — the docs and examples in this
guide use the access/resource vocabulary.

A value that is **not** `Transferable` cannot be `sink`-captured into a
spawned thread closure; a value that is not `Shareable` cannot be shared
through an `Arc` across threads. The compiler checks both at the spawn
boundary, so a data race is a compile error, not a runtime crash.

---

## Threads

### Spawning Threads

`std::thread::spawn` takes the closure by value (the capture is `sink` —
moved into the thread) and returns a `JoinHandle`:

```tangerine
use std::thread::{spawn, JoinHandle}

let mut handle = spawn(|| {
  println("hello from thread")
  42
})

let result = handle.join()  # Result[Int, String]: Ok(42) when the thread ran
```

The closure captures are **moved** into the thread. To use a value from
the enclosing scope, clone it before the spawn (the canonical pattern is
an `Arc` clone — see [Shared State: Arc](#shared-state-arc)):

```tangerine
use std::thread::spawn
use std::sync::Arc

let shared = Arc::new(0)
let mut worker = spawn(move || {
  let mine = shared.clone()  # the capture is the cloned Arc
  println(mine.to_string())
})

let _ = worker.join()
```

### Thread Builder

Named threads with an explicit stack size use `thread_builder()`:

```tangerine
use std::thread::thread_builder

let mut handle = thread_builder()
  .name("worker-1".to_string())
  .stack_size(2 * 1024 * 1024)  # 2 MB stack
  .spawn(|| heavy_computation())
  .unwrap()  # Result[JoinHandle[T], String]
```

`thread_builder().spawn(...)` returns `Result[JoinHandle[T], String]` —
the failure path (pthread_create failure, injected as EAGAIN by the
fault-injection hook) is a `Result::Err`, and the captured resources of
the never-started closure are dropped exactly once.

### Scoped Threads

`std::thread::scoped` joins every spawned thread before it returns, so
the parent's stack data is safe to observe for the scope's lifetime:

```tangerine
use std::thread::scoped

scoped(|s| {
  s.spawn(|| println("worker 1"))
  s.spawn(|| println("worker 2"))
})
# every scoped thread has joined here
```

### Sleeping and Yielding

```tangerine
use std::thread::{thread_sleep_ms, yield_now}

thread_sleep_ms(100)  # block the current thread for 100 ms
yield_now()           # yield the current time slice
```

### Parking

A thread can park itself and be woken by another thread:

```tangerine
use std::thread::{park, spawn}

let mut t = spawn(|| {
  park()  # sleeps until unparked by another thread
  println("woken")
})

let _ = t.join()
```

`unpark(t: Thread)` wakes a parked thread; `Thread::current()` gives the
running thread's handle.

---

## Shared State: `Arc`

`Arc` (`std::sync`) is the one shared-ownership shape: the value lives in
a **heap allocation** whose refcount is an atomic in the control block.
Every clone is a refcount increment; the last release runs the value's
drop glue (`drop_in_place`) before freeing the storage.

```tangerine
use std::sync::Arc

let shared = Arc::new(vec![1, 2, 3])
let a = shared.clone()
let b = shared.clone()

println(a.strong_count().to_string())  # 3 (shared + a + b)
```

The `Arc` surface is ownership-honest:

- `Arc::deref(self)` returns `Ptr[T]` — the read-only view of the
  shared value (there is no first-class reference; the pointer view is
  the explicit, unsafe-free way to read).
- `Arc::get_mut(inout self)` returns `Option[PtrMut[T]]` — `Some`
  **exactly while the strong count is one**: unique-only mutable
  access.
- `Arc::try_unwrap(sink self)` is sink-consuming — the caller's `Arc`
  is consumed on both outcomes; the success path moves the value out
  and frees the block.

The heap-stable guard design: every handle that must outlive a stack
frame (locks, channels, futures) holds its **own `Arc` clone** of the
shared state, never a raw pointer into a caller-owned object. A
`Mutex`, channel endpoint, or executor can be dropped or moved while a
guard/future/handle lives, and the shared state stays alive.

---

## Locks: `Mutex` and `RwLock`

### Mutex

`Mutex[T]` guards a value with a spin-atomic lock. `Mutex::lock` clones
the `Arc` into the guard, so the guard keeps the lock state alive; the
guard's `Drop` releases the lock with an atomic store. Guards are
created on `Arc` clones shared across threads:

```tangerine
use std::sync::{Arc, Mutex}
use std::thread::spawn

let counter = Arc::new(Mutex::new(0))
let mut handles = Vec::new()

for _ in 0..10 do
  let c = counter.clone()
  let mut h = spawn(move || {
    let mut guard = c.lock()
    *guard = *guard + 1  # the guard's Ptr deref; dropped at scope end
    0
  })
  handles.push(h)
end

for mut h in handles do
  let _ = h.join()
end

let final_value = *counter.lock()
println(final_value.to_string())  # 10 — no lost updates
```

The guard value access is the explicit pointer view (`*guard` /
`guard.get()` for reads, `guard.get_mut()` for the mutable write under
the lock). The lock protocol, not the refcount, provides uniqueness
while a guard lives — the guard's `Arc` clone is never refcount-unique
(the `Mutex` itself holds a second clone).

`Mutex::try_lock` returns `Option[MutexGuard[T]]` — `None` when the lock
is held:

```tangerine
match counter.clone().try_lock()
when Option::Some(guard) then println("acquired")
when Option::None then println("busy")
end
```

### RwLock

`RwLock[T]` allows multiple readers or one writer:

```tangerine
use std::sync::{Arc, RwLock}

let config = Arc::new(RwLock::new(8080))

# multiple readers may hold read guards concurrently
let read_guard = config.clone().read()
let port = *read_guard

# the writer is exclusive — the write guard takes the writer flag
let mut write_guard = config.clone().write()
let w = write_guard.get_mut()
*w = 9090
```

---

## Condition Variables, `Once`, and Barriers

### Condvar

`Condvar::wait` consumes the `MutexGuard`, releases the lock, and
re-locks through the `Arc` the guard kept alive — the returned guard is
the re-acquired lock. The predicate is re-checked after **every** wake
(the lost-wakeup-safe pattern):

```tangerine
use std::sync::{Arc, Mutex, Condvar}
use std::thread::spawn

let ready = Arc::new(Mutex::new(false))
let cond = Arc::new(Condvar::new())

let r = ready.clone()
let c = cond.clone()
spawn(move || {
  let mut guard = r.lock()
  *guard = true
  c.notify_one()  # wake one waiter
})

let mut guard = ready.lock()
while !*guard do
  guard = cond.wait(guard)  # the re-acquired guard
end
println("ready")
```

`notify_one` wakes exactly one registered waiter (the oldest, FIFO);
`notify_all` detaches the whole current cohort — waiters registering
after a notify belong to the next cohort, so no lost wakeups.

### Once

`Once` runs an initializer exactly once across all threads. The state
machine is a single atomic compare-and-swap (`UNINITIALIZED -> RUNNING
-> COMPLETE`): exactly one caller wins the CAS and runs `f`; the others
spin while `RUNNING` and no-op on `COMPLETE`. `call_once` on a complete
`Once` never re-runs the initializer.

```tangerine
use std::sync::Once

let init = Once::new()

init.call_once(|| {
  println("initializing exactly once")
})
init.call_once(|| {
  println("never printed")
})
```

### Barrier

`Barrier` synchronizes a fixed count of threads at a rendezvous point.
The shared `Arc` gives every spawned thread a clone:

```tangerine
use std::thread::{barrier_new, spawn}
use std::sync::Arc

let barrier = Arc::new(barrier_new(4))  # 4 threads rendezvous

for i in 0..4 do
  let b = barrier.clone()
  spawn(move || {
    phase_1(i)
    let _ = b.wait()  # blocks until all 4 arrive
    phase_2(i)
  })
end
```

`Barrier::wait` returns `true` exactly once per rendezvous (the
serial-thread caller), so one designated thread can run a
post-phase cleanup:

```tangerine
if barrier.wait() then
  println("all phases complete")
end
```

---

## Atomics

The atomics are the one lock-free primitive family. Every operation
routes through the `__intrinsic_atomic_*` compiler authority (inline
LDAR/STLR/LSE on AArch64, LOCKed xchg/xadd/cmpxchg on x86-64); a fence
never substitutes for atomicity.

`std::sync` provides the sized types (`AtomicBool`, `AtomicU32`,
`AtomicU64`, `AtomicPtr[T]`) with the load/store/swap/CAS surface, and
`std::thread` re-exports `AtomicInt`/`AtomicBool` with the `Ordering`
enum (`Relaxed`, `Acquire`, `Release`, `AcqRel`, `SeqCst`):

```tangerine
use std::sync::{Arc, AtomicU32}
use std::thread::spawn

let counter = Arc::new(AtomicU32::new(0))
let c = counter.clone()
spawn(move || {
  let mut c2 = c
  c2.fetch_add(1)
})

let n = counter.load()
println(n.to_string())
```

Compare-and-swap is the building block for lock-free protocols:

```tangerine
use std::sync::AtomicU32

let mut slot = AtomicU32::new(5)
let old = slot.compare_and_swap(5, 10)
println(old.to_string())  # 5 — the CAS hit, the slot now holds 10
```

Ordering levels, weakest to strongest:

| Ordering | Guarantee |
|----------|-----------|
| `Relaxed` | atomicity only — no ordering |
| `Acquire` | subsequent reads see the writes released by the peer |
| `Release` | prior writes are visible to the peer's `Acquire` read |
| `AcqRel` | both — for read-modify-write operations |
| `SeqCst` | total sequential order (the emitters' default discipline) |

The `SeqCst` store on x86-64 is the xchg-based store (TSO makes the
plain-MOV store release for the weaker orderings); on AArch64 it is the
STLR of the LDAR/STLR pair.

---

## Channels

### Synchronous Channels (`std/thread`)

`std::thread::channel()` is the MPSC (multi-producer, single-consumer)
channel with a **two-sided ownership protocol**: `Sender` and `Receiver`
hold `Arc[ChannelInner[T]]`; the sender count and the explicit
receiver-alive state live in the shared inner. Dropping the **last
sender** closes the receive side (queued values drain first, then
`recv` reports the close); dropping the **last receiver** wakes every
blocked bounded sender and makes future sends fail with the value
returned — nothing is lost, nothing is double-owned.

```tangerine
use std::thread::{channel, spawn}

let (tx, rx) = channel()

spawn(move || {
  let _ = tx.send(42)  # Result[Unit, Int]; Err(42) when the receive side is gone
})

match rx.recv()  # Result[Int, Unit]
when Result::Ok(v) then println(v.to_string())
when Result::Err(_) then println("channel closed")
end
```

Bounded channels (`channel_bounded(capacity)`) park a `send` on the
full queue; the parked send re-checks the close/receiver-alive
predicates after every wake:

```tangerine
use std::thread::channel_bounded

let (tx, rx) = channel_bounded(2)  # at most 2 queued values
```

### Async Channels (`std/async`)

The async channel is the buffered MPSC with wakers: `send` and `recv`
are **futures** — they return `Pending` (with the waker registered) when
the buffer is full/empty and complete when space/a value is available:

```tangerine
use std::async::channel

std::async::block_on(async {
  let (tx, rx) = channel(100)  # buffer size 100

  let handle = std::async::spawn(async {
    let _ = tx.send("hello".to_string()).await
  })

  let msg = rx.recv().await  # Option[String]
  match msg
  when Option::Some(m) then println(m)
  when Option::None then println("channel closed")
  end
  let _ = handle.await
})
```

The channel's shared state lives in the `Arc`-owned allocation; the
`SendFuture`/`RecvFuture` each hold their own clone, so the inner stays
alive even if an endpoint is dropped or moved while a future is in
flight. `Sender::close()` closes the channel and wakes every blocked
receiver.

---

## The Async Model

### Fundamentals

`std/async` implements cooperative async/await on a single-threaded
executor. An async function is declared with `async def` and awaited
with `.await`; `std::async::block_on` runs a future to completion:

```tangerine
use std::async

async def fetch_data(url: String) -> Result[String, String]
  let response = http_get(url).await?
  let body = response.text().await?
  Result::Ok(body)
end

let data = std::async::block_on(async {
  let d = fetch_data("https://api.example.com/data".to_string()).await?
  println(d)
  d
})
```

The `Future` trait is the poll contract — a future returns
`Poll::Ready(value)` or `Poll::Pending` (with the waker registered):

```tangerine
trait Future
  type Output
  def poll(inout self, inout cx: Context) -> Poll[Self::Output]
end

enum Poll[T]
  Ready(T)
  Pending
end
```

### The Executor

`Executor::new()` creates the single-threaded cooperative executor; the
whole scheduler state (tasks, ready queue, timer heap, the I/O reactor,
the deterministic-mode state) lives in an `Arc`-owned heap allocation,
and wakers/handles hold their own clone — a task can outlive the
stack-local executor that spawned it.

```tangerine
use std::async::Executor

let mut exec = Executor::new().unwrap()
exec.spawn(async { task_1().await })
exec.spawn(async { task_2().await })
exec.run()  # drives the tasks to completion
```

`std::async::spawn` registers a `()`-output future on the **global**
executor (established by `block_on`) and returns a `JoinHandle[()]`:

```tangerine
use std::async

std::async::block_on(async {
  let handle = std::async::spawn(async {
    std::async::sleep_millis(10).await
    println("task done")
  })
  let result = handle.await  # Result[(), String]
})
```

### Timers and Timeouts

```tangerine
use std::async::{sleep_millis, timeout}
use std::time::Duration

std::async::block_on(async {
  sleep_millis(100).await  # cooperative sleep — the executor advances other tasks

  let result = timeout(Duration::from_secs(5), fetch_data(url)).await
  match result
  when Result::Ok(data) then println(data)
  when Result::Err(_) then println("timed out!")
  end
})
```

The deterministic executor mode drives a **virtual clock**: in the
deterministic run the wall clock never moves, and a sleep completes when
the executor advances virtual time.

### Racing and Joining Futures

```tangerine
use std::async::{select, join}

std::async::block_on(async {
  match select(fetch_a(), fetch_b()).await
  when Either::Left(a) then println("a finished first: " + a)
  when Either::Right(b) then println("b finished first: " + b)
  end

  let (a, b) = join(fetch_a(), fetch_b()).await  # waits for both
})
```

---

## Structured Concurrency

`std::async::scoped` runs a body with a `TaskScope`: every child task
reaches a terminal state (complete or cancelled) **before** the scope
exits. `scope.spawn` returns a typed `ScopedTaskHandle`; `join_all` is
an async join that awaits each child, so the executor's cooperative
scheduling advances the children between the join's polls.

```tangerine
use std::async

let result = std::async::block_on(std::async::scoped(|scope| {
  scope.spawn(async {
    std::async::sleep_millis(5).await
    println("child 1")
  })
  scope.spawn(async {
    std::async::sleep_millis(2).await
    println("child 2")
  })
}))
```

Error strategies:

| Strategy | Behavior on the first child failure |
|----------|-------------------------------------|
| `CancelAll` (default) | cancel the remaining children; the scope fails |
| `CollectErrors` | let every child run; aggregate all errors |
| `IgnoreErrors` | wait for every child; suppress the child errors |

```tangerine
scope.with_error_strategy(std::async::ScopeErrorStrategy::CollectErrors)
```

---

## Cancellation

`CancellationToken` forms a parent→descendant tree: `cancel()` sets the
atomic flag (idempotent) and propagates to every registered descendant.
A child registered during the parent's cancellation always observes the
cancelled state — no lost cancellation. `TaskScope` uses the token to
cancel its remaining children.

```tangerine
use std::async::cancellation_token_new

let token = cancellation_token_new()
let child_token = token.child()

std::async::block_on(async {
  let handle = std::async::spawn(async {
    while !child_token.is_cancelled() do
      std::async::sleep_millis(1).await
    end
    println("cancelled cleanly")
  })
  token.cancel()  # signals the child tokens too
  let _ = handle.await
})
```

---

## Async Synchronization

### AsyncMutex

`AsyncMutex` is the async-side mutex: `lock()` returns a `LockFuture`
whose polls never block the executor — a contended poll enqueues its
waker once and returns `Pending`; the guard's `Drop` releases the lock
with an atomic store and wakes the **oldest** waiter (FIFO). The lock
state lives in the `Arc`-owned allocation.

```tangerine
use std::async::async_mutex_new

let mutex = async_mutex_new(0)
let mut exec = std::async::executor_new()

exec.spawn(async {
  let mut guard = mutex.lock().await
  *guard = *guard + 1
})
exec.spawn(async {
  let mut guard = mutex.lock().await
  *guard = *guard + 1
})
exec.run()  # both tasks complete; each guard's Drop releases the lock
```

### AsyncSemaphore

`AsyncSemaphore` limits concurrent access to a resource; `acquire()`
returns a future that completes with a `SemaphorePermit`, and dropping
the permit releases the slot and wakes the oldest waiter:

```tangerine
use std::async::AsyncSemaphore

let sem = AsyncSemaphore::new(10)  # max 10 concurrent

async def rate_limited_fetch(url: String) -> Result[String, String]
  let _permit = sem.acquire().await
  let result = fetch(url).await
  result  # the permit drops here — the slot is released
end
```

### Retry

```tangerine
use std::async::retry

let config = retry_config_default()

let result = retry(config, || async {
  fetch(url).await
}).await
```

---

## The Executor

### Deterministic Mode

The executor's `set_deterministic` mode drives the seeded RNG and the
virtual clock, so a run is reproducible: sleeps complete when the
executor advances virtual time, and the task schedule is seeded. The
clock suite (`executor_clock_test.tg`) and the conservation suite
(`exec_conservation_test.tg`) pin the scheduler invariants — a task
ledger records every submit/queued/running/completed/cancelled/failed
transition and every task reaches a terminal state exactly once.

### The Reactor

The executor carries an I/O reactor (kqueue on macOS, epoll via the
shim on Linux) that drives `TcpStream` readiness. `wait_readable` /
`wait_writable` return readiness futures; `read_async` / `write_async`
move the stream and buffer into the future (`sink` arguments), so the
buffer is owned by the in-flight I/O:

```tangerine
use std::async::{wait_readable}

std::async::block_on(async {
  let ready = wait_readable(stream).await  # the reactor token fires on readiness
})
```

The reactor's readiness tokens have the pinned semantics: the
second-poll-stays-pending / ready-consume / EAGAIN-re-register behavior
on the kqueue-backed reactor (`reactor_readiness_test.tg`).

---

## Thread Pools

`std/exec` provides the work-stealing thread pool. `Executor::new` /
`Executor::new_default` start the worker threads; `submit` enqueues a
closure and returns a task id; `submit_with_result` returns a
`JoinHandle` for the result; `shutdown` drains the queues before the
workers exit.

```tangerine
use std::exec::Executor
use std::exec::TaskPriority

let pool = Executor::new(4).unwrap()  # 4 worker threads

let id = pool.submit(|| {
  println("job")
}, TaskPriority::Normal)

pool.shutdown()  # waits for the queues to drain
```

The executor's conservation accounting (`Executor::conservation_ok`)
verifies that every submitted task reached a terminal state — the
exec-conservation suite asserts the ledger invariants.

---

## Best Practices

### Choosing Between Threads and Async

| Use Threads when... | Use Async when... |
|--------------------|-------------------|
| CPU-bound work (computation) | I/O-bound work (network, disk) |
| Few concurrent tasks | Many concurrent tasks (thousands) |
| Blocking APIs unavoidable | Cooperative scheduling acceptable |
| Simplicity preferred | Maximum throughput needed |

### General Guidelines

1. **Prefer message passing over shared state** — move values through
   channels; the ownership protocol closes the receive side on the last
   sender drop and rejects sends after the last receiver drop.
2. **Keep critical sections small** — hold locks briefly; the guard's
   `Drop` releases the lock, so scope the guard tightly.
3. **Clone the `Arc`, not the data** — every thread-bound closure
   captures its own clone; the last clone's release runs the drop glue
   exactly once.
4. **Use structured concurrency in async code** — `scoped` guarantees
   every child reaches a terminal state before the scope exits; a
   spawned task that outlives its creator is an orphaned task.
5. **Check cancellation in long loops** — poll
   `CancellationToken::is_cancelled` and exit cooperatively.
6. **Never block the executor** — use threads (or the thread pool) for
   blocking work; a blocking call inside an async task stalls every
   task on the single-threaded executor.
7. **The heap-stable guard design is the pattern** — any handle that
   can outlive its creator (guards, endpoints, futures, handles) holds
   its own `Arc` clone of the shared state; no handle holds a raw
   pointer into a caller-owned object.

---

*This document is doctest-checked (a canonical member of the
docs/current set): every fenced example is current-grammar — no legacy
parameter spellings, no first-class reference forms, no `Send`/`Sync`
markers — enforced by `scripts/check_doctests.sh`.*
