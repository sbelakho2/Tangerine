/*
 * Tangerine std::async — native epoll shim library (epoll_shims.c)
 *
 * The Linux x86-64 `struct epoll_event` is a PACKED struct: { uint32_t
 * events @ 0, uint64_t data @ 4 } — size 12, alignment 4. A Tangerine
 * struct with the natural { u32; u64 } field layout would be padded to
 * 16 bytes with the data at offset 8 — a mismatch with the kernel ABI
 * (the kernel would read the events word from the wrong offset). This
 * shim keeps the REAL libc struct inside the .c file: the Tangerine side
 * passes its native representation (tg_epoll_event_layout — { u32
 * events, u32 _pad, u64 data } at offsets { 0, 4, 8 } — 16 bytes, the
 * deterministic layout the std::async EpollEvent struct mirrors
 * field-for-field with its explicit _pad field), and every conversion to
 * and from the kernel's packed epoll_event happens HERE, at the C
 * boundary. The std::async epoll calls route through these entry points.
 *
 * Exports (the std::async externs):
 *   tg_epoll_create1(flags: i32) -> i32
 *   tg_epoll_ctl(epfd: i32, op: i32, fd: i32, event: Ptr[tg_epoll_event_layout]) -> i32
 *   tg_epoll_wait(epfd: i32, events: PtrMut[tg_epoll_event_layout], maxevents: i32, timeout: i32) -> i32
 *   tg_errno_is_eagain() -> i32
 *
 * On non-Linux targets (macOS/BSD — no epoll in the kernel) the three
 * epoll entry points compile to ENOSYS stubs: the exports still exist so
 * the Mach-O symbol gate and the flat-namespace preload contract hold on
 * every CI platform, and the std::async reactor never calls them there
 * (USE_EPOLL is false off-Linux — the reactor uses kqueue).
 *
 * Build (CI, .github/workflows/ci.yml stdlib-integration job):
 *   cc -fPIC -shared native/epoll_shims.c -o build/libtg_epoll_shims.dylib
 */

#include <errno.h>
#include <stdlib.h>
#include <string.h>

#ifdef __linux__
#include <sys/epoll.h>
#endif

/* The Tangerine-native epoll event layout — mirrors std/async.tg's
 * EpollEvent field-for-field ({ u32 events, u32 _pad, u64 data } — the
 * explicit _pad makes the 16-byte layout deterministic on both sides). */
typedef struct tg_epoll_event_layout {
  uint32_t events;
  uint32_t _pad;
  uint64_t data;
} tg_epoll_event_layout;

#ifdef __linux__

/* tg_epoll_create1(flags: i32) -> i32 */
int tg_epoll_create1(int flags) {
  return epoll_create1(flags);
}

/* tg_epoll_ctl(epfd, op, fd, event) -> i32
 * The Tangerine-native event layout is converted to the kernel's PACKED
 * epoll_event here: the u64 data is copied into the packed struct's
 * data.u64 at the kernel's offset (4), not the padded offset (8). A NULL
 * event (EPOLL_CTL_DEL) is forwarded as-is — epoll_ctl ignores the
 * event argument for DEL. */
int tg_epoll_ctl(int epfd, int op, int fd, const tg_epoll_event_layout *event) {
  if (event == NULL) {
    return epoll_ctl(epfd, op, fd, NULL);
  }
  struct epoll_event ev;
  memset(&ev, 0, sizeof(ev));
  ev.events = event->events;
  ev.data.u64 = event->data;
  return epoll_ctl(epfd, op, fd, &ev);
}

/* tg_epoll_wait(epfd, events, maxevents, timeout) -> i32
 * Waits on a REAL packed struct epoll_event array, then converts every
 * returned event into the Tangerine-native layout (events word, zero
 * padding, data word). */
int tg_epoll_wait(int epfd, tg_epoll_event_layout *events, int maxevents, int timeout) {
  if (events == NULL || maxevents <= 0) {
    errno = EINVAL;
    return -1;
  }
  struct epoll_event *buf = (struct epoll_event *)malloc((size_t)maxevents * sizeof(struct epoll_event));
  if (buf == NULL) {
    return -1;
  }
  int n = epoll_wait(epfd, buf, maxevents, timeout);
  for (int i = 0; i < n; i++) {
    events[i].events = buf[i].events;
    events[i]._pad = 0;
    events[i].data = buf[i].data.u64;
  }
  free(buf);
  return n;
}

#else /* !__linux__ — macOS/BSD stubs: no epoll in the kernel. The exports
         exist for the symbol gate and the preload contract; the
         std::async reactor never calls them (USE_EPOLL is false). */

int tg_epoll_create1(int flags) {
  (void)flags;
  errno = ENOSYS;
  return -1;
}

int tg_epoll_ctl(int epfd, int op, int fd, const tg_epoll_event_layout *event) {
  (void)epfd; (void)op; (void)fd; (void)event;
  errno = ENOSYS;
  return -1;
}

int tg_epoll_wait(int epfd, tg_epoll_event_layout *events, int maxevents, int timeout) {
  (void)epfd; (void)events; (void)maxevents; (void)timeout;
  errno = ENOSYS;
  return -1;
}

#endif

/* tg_errno_is_eagain() -> i32
 * Whether the calling thread's errno is EAGAIN/EWOULDBLOCK (the same
 * value on Linux and macOS) — the stale-readiness probe the async I/O
 * futures use to decide the EAGAIN re-register path after a failed
 * operation. The shim reads the REAL thread-local errno. */
int tg_errno_is_eagain(void) {
  return errno == EAGAIN || errno == EWOULDBLOCK;
}
