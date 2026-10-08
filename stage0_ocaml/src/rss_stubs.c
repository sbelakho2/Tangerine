/* rss_stubs.c — native resident-set-size measurement for the seed VM.

   The OCaml layer (vm.ml, current_rss_bytes) measures RSS in three
   tiers:

     1. Linux: /proc/self/status "VmRSS: N kB" (the OCaml path).
     2. macOS: tg_current_rss_bytes below — Mach task_info
        (MACH_TASK_BASIC_INFO.resident_size, bytes).  This is what lets
        the final authorization gate run natively on macOS.
     3. everywhere else: unavailable (0), and a requested ceiling is a
        hard configuration error in the VM, never a silent no-op.

   tg_current_rss_bytes is the raw C entry point (0 on success, nonzero
   on failure); tg_current_rss_bytes_ml is the OCaml-facing wrapper
   returning the measurement as a nativeint (>= 0 bytes, -1
   unavailable) so vm.ml needs no out-parameter plumbing.

   This file stays dependency-free: the only includes are the OCaml
   runtime headers (mlvalues/memory for the wrapper; alloc.h declares
   caml_copy_nativeint) and, on Apple platforms only, <mach/mach.h>.
   The non-Apple branch of tg_current_rss_bytes compiles to a constant
   "unavailable" and never references Mach. */

#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/alloc.h>

#ifdef __APPLE__
#include <mach/mach.h>
#endif

/* Raw measurement: writes the current process RSS in bytes to *out and
   returns 0, or returns nonzero when the host cannot measure (the
   non-Apple build, or a failing task_info call). */
int tg_current_rss_bytes(long long *out) {
#ifdef __APPLE__
  mach_task_basic_info_data_t info;
  mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
  kern_return_t kr = task_info(mach_task_self(), MACH_TASK_BASIC_INFO,
                               (task_info_t)&info, &count);
  if (kr != KERN_SUCCESS) {
    return (int)kr;
  }
  *out = (long long)info.resident_size;
  return 0;
#else
  (void)out;
  return 1;
#endif
}

/* OCaml-facing wrapper (external tg_rss_bytes : unit -> nativeint in
   vm.ml): > 0 = bytes, 0 = measured zero, -1 = unavailable. */
CAMLprim value tg_current_rss_bytes_ml(value unit) {
  CAMLparam1(unit);
  long long rss = 0;
  if (tg_current_rss_bytes(&rss) == 0) {
    CAMLreturn(caml_copy_nativeint((intnat)rss));
  }
  CAMLreturn(caml_copy_nativeint((intnat)-1));
}
