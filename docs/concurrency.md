# Tangerine Concurrency Guide

**Version:** 0.1.0  
**Last Updated:** March 2026

Complete guide to concurrent and asynchronous programming in Tangerine.

---

## Table of Contents

1. [Overview](#overview)
2. [Threading (`std/thread`)](#threading)
3. [Synchronization Primitives (`std/sync`)](#synchronization-primitives)
4. [Async/Await (`std/async`)](#asyncawait)
5. [Structured Concurrency](#structured-concurrency)
6. [Channels](#channels)
7. [Async Streams](#async-streams)
8. [Thread Pools](#thread-pools)
9. [Atomics](#atomics)
10. [Resilience Patterns](#resilience-patterns)
11. [Send and Sync](#send-and-sync)
12. [Best Practices](#best-practices)

---

## Overview

Tangerine provides two concurrency models:

| Model | Module | Use Case |
|-------|--------|----------|
| **OS Threads** | `std/thread` | CPU-bound parallelism, blocking operations |
| **Async Tasks** | `std/async` | I/O-bound concurrency, high connection count |

Both models leverage the ownership system to prevent data races at compile time.

---

## Threading

### Spawning Threads

```tangerine
use std::thread

let handle = thread::spawn(|| {
  println("hello from thread")
  42
})

let result = handle.join()  # waits, returns Result[Int, ThreadError]
```

### Thread Builder

```tangerine
let handle = thread::ThreadBuilder::new()
  .name("worker-1")
  .stack_size(2 * 1024 * 1024)  # 2 MB stack
  .spawn(|| heavy_computation())
```

### Scoped Threads

Scoped threads can borrow from the parent stack — they are guaranteed to join before the scope exits:

```tangerine
let data = vec![1, 2, 3, 4, 5]
let mut results = Vec::new()

thread::scope(|s| {
  for chunk in data.chunks(2) do
    s.spawn(|| {
      chunk.iter().sum()  # borrows chunk from parent
    })
  end
  # All spawned threads join here automatically
})
```

### Thread Parking

```tangerine
let t = thread::current()
thread::spawn(move || {
  # ... prepare data ...
  t.unpark()  # wake the parked thread
})
thread::park()  # sleep until unparked
```

---

## Synchronization Primitives

### Mutex

```tangerine
use std::sync::Mutex

let counter = Arc::new(Mutex::new(0))

for _ in 0..10 do
  let counter = counter.clone()
  thread::spawn(move || {
    let mut guard = counter.lock()
    *guard = *guard + 1
    # guard auto-unlocks via Drop
  })
end
```

### RwLock

Allows multiple readers or one writer:

```tangerine
use std::sync::RwLock

let config = Arc::new(RwLock::new(load_config()))

# Multiple readers
let guard = config.read()
println(guard.port.to_string())

# Exclusive writer
let mut guard = config.write()
guard.port = 8080
```

### Condvar (Condition Variable)

```tangerine
use std::sync::{Mutex, Condvar}

let pair = Arc::new((Mutex::new(false), Condvar::new()))

# Waiting thread
let (lock, cvar) = &*pair
let mut ready = lock.lock()
while !*ready do
  ready = cvar.wait(ready)
end

# Signaling thread
let (lock, cvar) = &*pair
let mut ready = lock.lock()
*ready = true
cvar.notify_one()
```

### Barrier

Synchronize multiple threads at a rendezvous point:

```tangerine
let barrier = Arc::new(Barrier::new(4))

for i in 0..4 do
  let b = barrier.clone()
  thread::spawn(move || {
    phase_1(i)
    b.wait()       # all 4 threads meet here
    phase_2(i)
  })
end
```

### Semaphore

Limit concurrent access to a resource:

```tangerine
use std::sync::Semaphore

let sem = Arc::new(Semaphore::new(3))  # max 3 concurrent

for i in 0..10 do
  let sem = sem.clone()
  thread::spawn(move || {
    let permit = sem.acquire()  # blocks if 3 already held
    do_work(i)
    # permit dropped, slot released
  })
end
```

### Once

Run initialization exactly once:

```tangerine
let init = Once::new()
let mut config: Option[Config] = Option::None

init.call_once(|| {
  config = Option::Some(load_config())
})
```

### CancellationToken

```tangerine
let token = CancellationToken::new()
let child_token = token.child_token()

thread::spawn(move || {
  while !child_token.is_cancelled() do
    do_work()
  end
})

# Later...
token.cancel()  # signals all child tokens too
```

---

## Async/Await

### Fundamentals

```tangerine
use std::async

async def fetch_data(url: &str) -> Result[String, HttpError]
  let response = http_get(url).await?
  let body = response.text().await?
  Result::Ok(body)
end

# Run an async function
async::run(async {
  let data = fetch_data("https://api.example.com/data").await?
  println(data)
})
```

### Future Trait

```tangerine
trait Future
  type Output
  def poll(self: &mut Self, cx: &mut Context) -> Poll[Self::Output]
end

enum Poll[T]
  Ready(T)
  Pending
end
```

### Executor

Tangerine's built-in executor uses epoll/kqueue for I/O:

```tangerine
let executor = Executor::new()
executor.spawn(async { task_1().await })
executor.spawn(async { task_2().await })
executor.run()  # runs until all tasks complete
```

### Timeouts and Sleep

```tangerine
use std::async::{sleep, timeout}

# Sleep
sleep(Duration::from_millis(100)).await

# Timeout
match timeout(Duration::from_secs(5), fetch_data(url)).await
when Result::Ok(data) then process(data)
when Result::Err(_) then println("timed out!")
end
```

### Select (Racing Futures)

```tangerine
use std::async::select

match select(fetch_a(), fetch_b()).await
when Either::Left(a) then println("a finished first: " + a)
when Either::Right(b) then println("b finished first: " + b)
end
```

---

## Structured Concurrency

Tangerine implements the nursery/task-scope pattern to prevent orphaned tasks:

```tangerine
use std::async::TaskScope

async def process_batch(urls: &[String]) -> Result[Vec[String], HttpError]
  TaskScope::scoped(ScopeErrorStrategy::CancelAll, async |scope| {
    let mut handles = Vec::new()
    for url in urls do
      handles.push(scope.spawn(async { fetch_data(url).await }))
    end
    
    let mut results = Vec::new()
    for h in handles do
      results.push(h.await?)
    end
    Result::Ok(results)
  }).await
end
```

### Error Strategies

| Strategy | Behavior on Error |
|----------|------------------|
| `CancelAll` | Cancel all sibling tasks immediately |
| `CollectErrors` | Let all tasks run, collect all errors |
| `IgnoreErrors` | Ignore individual task failures |

---

## Channels

### Synchronous Channels (`std/thread`)

```tangerine
use std::thread::Channel

let (tx, rx) = Channel::new()
thread::spawn(move || {
  tx.send(42)
})
let value = rx.recv()  # blocks until message available
```

### Async Channels (`std/async`)

```tangerine
use std::async::channel

let (tx, rx) = channel(100)  # buffer size 100

async::spawn(async move {
  tx.send("hello").await
})

let msg = rx.recv().await
```

---

## Async Streams

Process sequences of async values:

```tangerine
use std::async::AsyncIterator

let stream = channel_stream(rx)
  .map(|item| item * 2)
  .filter(|item| *item > 10)
  .take(5)

let results = collect_stream(stream).await
```

---

## Thread Pools

### Fixed-Size Pool

```tangerine
use std::thread::ThreadPool

let pool = ThreadPool::new(4)  # 4 worker threads

for i in 0..100 do
  pool.execute(move || {
    process_item(i)
  })
end

pool.shutdown()  # waits for all jobs to complete
```

### With Return Values

```tangerine
let handle = pool.submit(|| expensive_computation())
# ... do other work ...
let result = handle.join()
```

---

## Atomics

Lock-free operations for simple shared state:

```tangerine
use std::thread::{AtomicInt, AtomicBool, Ordering}

let counter = Arc::new(AtomicInt::new(0))
let running = Arc::new(AtomicBool::new(true))

# Atomic increment
counter.fetch_add(1, Ordering::SeqCst)

# Compare-and-swap
let old = counter.compare_and_swap(5, 10, Ordering::SeqCst)

# Load/store
running.store(false, Ordering::Release)
let is_running = running.load(Ordering::Acquire)
```

### Ordering Levels

| Ordering | Guarantee |
|----------|-----------|
| `Relaxed` | No ordering guarantee (fastest) |
| `Acquire` | Reads after this see writes from the `Release` side |
| `Release` | Writes before this are visible to `Acquire` readers |
| `AcqRel` | Both acquire and release |
| `SeqCst` | Total sequential ordering (safest, slowest) |

---

## Resilience Patterns

### Retry with Backoff

```tangerine
use std::async::retry

let config = RetryConfig {
  max_retries: 3,
  initial_delay: Duration::from_millis(100),
  max_delay: Duration::from_secs(5),
  multiplier: 2.0,
  jitter: true,
}

let result = retry(config, || async { fetch_data(url).await }).await
```

### Circuit Breaker

Prevent cascading failures:

```tangerine
use std::async::CircuitBreaker

let breaker = CircuitBreaker::new(
  5,                          # failure threshold
  Duration::from_secs(30),    # recovery timeout
)

if breaker.allow_request() then
  match call_service().await
  when Result::Ok(v) then
    breaker.record_success()
    v
  when Result::Err(e) then
    breaker.record_failure()
    return Result::Err(e)
  end
else
  return Result::Err(CircuitBreakerError::CircuitOpen)
end
```

### Async Semaphore

```tangerine
use std::async::AsyncSemaphore

let sem = AsyncSemaphore::new(10)  # max 10 concurrent

async def rate_limited_fetch(url: &str) -> Result[String, Error]
  let permit = sem.acquire().await
  let result = fetch(url).await
  # permit dropped, slot released
  result
end
```

---

## Send and Sync

Tangerine uses `Send` and `Sync` marker traits to ensure thread safety:

| Trait | Meaning |
|-------|---------|
| `Send` | Value can be transferred to another thread |
| `Sync` | Value can be shared between threads via `&T` |

```tangerine
# This works because Vec[Int] is Send
thread::spawn(move || {
  let data = vec![1, 2, 3]  # moved into thread
  process(data)
})

# This would fail — Rc is not Send
let rc = Rc::new(42)
thread::spawn(move || {
  println(rc.to_string())
  # ERROR: Rc[Int] does not implement Send
})

# Use Arc instead for thread-safe sharing
let arc = Arc::new(42)
thread::spawn(move || {
  println(arc.to_string())  # OK: Arc is Send + Sync
})
```

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

1. **Prefer message passing** over shared state — use channels
2. **Keep critical sections small** — hold locks briefly
3. **Use scoped threads** when borrowing from parent — avoids cloning
4. **Use structured concurrency** in async code — prevents orphaned tasks
5. **Always handle cancellation** — check `CancellationToken` in long loops
6. **Avoid mixing blocking and async** — use `spawn_blocking()` for blocking ops in async context
7. **Use `Arc<Mutex<T>>`** sparingly — consider lock-free alternatives for hot paths
