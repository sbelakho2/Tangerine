/*  Tangerine Runtime Library — Implementation
 *  Provides String, Vec, Map, Set, Option, Result, Box, I/O, and
 *  all standard library primitives needed by the self-hosting compiler.
 */

#include "tg_runtime.h"
#include <ctype.h>
#include <math.h>
#include <errno.h>
#include <unistd.h>
#include <sys/stat.h>
#include <signal.h>
#ifdef __linux__
#include <sys/random.h>
#endif
#ifdef __APPLE__
#include <execinfo.h>
#elif defined(__linux__)
#include <execinfo.h>
#endif

/* ── Segfault handler ──────────────────────────────────────────────── */
static void tg_segfault_handler(int sig) {
    fprintf(stderr, "\nSEGFAULT (signal %d) backtrace:\n", sig);
#if defined(__APPLE__) || defined(__linux__)
    void* array[64];
    int size = backtrace(array, 64);
    backtrace_symbols_fd(array, size, STDERR_FILENO);
#endif
    _exit(139);
}

/* ── Global state ──────────────────────────────────────────────────── */

int    g_argc = 0;
char** g_argv = NULL;

/* Hash salt to prevent HashDoS attacks (randomized at startup). */
static uint64_t g_hash_salt = 0;

static void tg_init_hash_salt(void) {
#if defined(__APPLE__) || defined(__FreeBSD__) || defined(__OpenBSD__)
    arc4random_buf(&g_hash_salt, sizeof(g_hash_salt));
#elif defined(__linux__)
    /* getentropy is available since glibc 2.25 / Linux 3.17 */
    if (getentropy(&g_hash_salt, sizeof(g_hash_salt)) != 0) {
        /* Fallback: read from /dev/urandom */
        FILE* f = fopen("/dev/urandom", "rb");
        if (f) {
            (void)fread(&g_hash_salt, sizeof(g_hash_salt), 1, f);
            fclose(f);
        }
    }
#else
    /* Fallback for other POSIX systems */
    FILE* f = fopen("/dev/urandom", "rb");
    if (f) {
        (void)fread(&g_hash_salt, sizeof(g_hash_salt), 1, f);
        fclose(f);
    }
#endif
}

void tg_init(int argc, char** argv) {
    g_argc = argc;
    g_argv = argv;
    tg_init_hash_salt();
    signal(SIGSEGV, tg_segfault_handler);
    signal(SIGBUS, tg_segfault_handler);
}

/* ── Panic / assert ────────────────────────────────────────────────── */

TgVal tg_debug_val(TgVal v) {
    fprintf(stderr, "[TG_DEBUG] val=%lld (0x%llx)", (long long)v, (unsigned long long)v);
    if (v == 0) {
        fprintf(stderr, " [NIL]\n");
    } else {
        void* ptr = (void*)(intptr_t)v;
        int64_t* words = (int64_t*)ptr;
        fprintf(stderr, " ptr=%p tag=%lld f0=%lld f1=%lld\n", ptr, words[0], words[1], words[2]);
    }
    return TG_NIL;
}

void tg_panic(const char* msg) {
    fprintf(stderr, "PANIC: %s\n", msg);
#if defined(__APPLE__) || defined(__linux__)
    void* callstack[128];
    int frames = backtrace(callstack, 128);
    backtrace_symbols_fd(callstack, frames, 2);
#endif
    abort();
}

void tg_assert(TgVal cond, const char* msg) {
    if (!cond) tg_panic(msg);
}

/* ── Memory allocation ─────────────────────────────────────────────── */

static _Atomic size_t tg_alloc_total_bytes  = 0;
static _Atomic size_t tg_free_total_bytes   = 0;
static _Atomic size_t tg_alloc_peak_bytes   = 0;
static _Atomic size_t tg_alloc_live_bytes   = 0;
static _Atomic size_t tg_alloc_count_total  = 0;
static _Atomic size_t tg_free_count_total   = 0;

size_t tg_debug_alloc_total(void) { return tg_alloc_total_bytes; }
size_t tg_debug_free_total(void)  { return tg_free_total_bytes; }
size_t tg_debug_alloc_peak(void)  { return tg_alloc_peak_bytes; }
size_t tg_debug_alloc_count(void) { return tg_alloc_count_total; }
size_t tg_debug_free_count(void)  { return tg_free_count_total; }

static void track_alloc(size_t size) {
    tg_alloc_total_bytes += size;
    tg_alloc_count_total++;
    size_t live = (tg_alloc_live_bytes += size);
    /* Relaxed peak update — races are harmless for a debug counter */
    if (live > tg_alloc_peak_bytes) {
        tg_alloc_peak_bytes = live;
    }
}

void* tg_alloc(size_t size) {
    void* p = calloc(1, size);
    if (!p && size > 0) tg_panic("out of memory");
    track_alloc(size);
    return p;
}

void* tg_realloc(void* ptr, size_t size) {
    void* p = realloc(ptr, size);
    if (!p && size > 0) tg_panic("out of memory");
    return p;
}

void tg_free(void* ptr) {
    if (ptr) { tg_free_count_total++; }
    free(ptr);
}

/* ── String ────────────────────────────────────────────────────────── */

static TgString* str_ptr(TgVal s) { return (TgString*)tg_as_ptr(s); }

static void str_grow(TgString* s, int64_t needed) {
    if (needed < 0) return;
    if (s->len + needed <= s->cap) return;
    /* Guard against integer overflow */
    if (s->len > INT64_MAX / 2 || needed > INT64_MAX - s->len)
        tg_panic("string capacity overflow");
    int64_t new_cap = s->cap * 2;
    if (new_cap < s->len + needed) new_cap = s->len + needed;
    if (new_cap < 16) new_cap = 16;
    s->data = (char*)tg_realloc(s->data, (size_t)new_cap + 1);
    s->cap = new_cap;
}

TgVal tg_str_new(void) {
    TgString* s = (TgString*)tg_alloc(sizeof(TgString));
    s->data = (char*)tg_alloc(16);
    s->data[0] = '\0';
    s->len = 0;
    s->cap = 15;
    return tg_from_ptr(s);
}

TgVal tg_str_from_cstr(const char* cs) {
    if (!cs) return tg_str_new();
    TgString* s = (TgString*)tg_alloc(sizeof(TgString));
    int64_t len = (int64_t)strlen(cs);
    int64_t cap = len < 15 ? 15 : len;
    s->data = (char*)tg_alloc(cap + 1);
    memcpy(s->data, cs, len);
    s->data[len] = '\0';
    s->len = len;
    s->cap = cap;
    return tg_from_ptr(s);
}

TgVal tg_str_from_len(const char* cs, int64_t len) {
    TgString* s = (TgString*)tg_alloc(sizeof(TgString));
    int64_t cap = len < 15 ? 15 : len;
    s->data = (char*)tg_alloc(cap + 1);
    if (cs && len > 0) memcpy(s->data, cs, len);
    s->data[len] = '\0';
    s->len = len;
    s->cap = cap;
    return tg_from_ptr(s);
}

TgVal tg_str_clone(TgVal sv) {
    TgString* s = str_ptr(sv);
    if (!s) return tg_str_new();
    return tg_str_from_len(s->data, s->len);
}

void tg_str_free(TgVal sv) {
    TgString* s = str_ptr(sv);
    if (s) { tg_free(s->data); tg_free(s); }
}

int64_t tg_str_len(TgVal sv) {
    TgString* s = str_ptr(sv);
    return s ? s->len : 0;
}

TgVal tg_str_is_empty(TgVal sv) {
    return tg_str_len(sv) == 0 ? TG_TRUE : TG_FALSE;
}

TgVal tg_str_push_char(TgVal sv, TgVal ch) {
    TgString* s = str_ptr(sv);
    if (!s) return TG_NIL;
    char c = (char)(ch & 0xFF);
    str_grow(s, 1);
    s->data[s->len++] = c;
    s->data[s->len] = '\0';
    return TG_NIL;
}

TgVal tg_str_push_str(TgVal sv, TgVal other_v) {
    TgString* s = str_ptr(sv);
    TgString* o = str_ptr(other_v);
    if (!s || !o || o->len == 0) return TG_NIL;
    str_grow(s, o->len);
    memcpy(s->data + s->len, o->data, o->len);
    s->len += o->len;
    s->data[s->len] = '\0';
    return TG_NIL;
}

TgVal tg_str_concat(TgVal a, TgVal b) {
    TgString* sa = str_ptr(a);
    TgString* sb = str_ptr(b);
    int64_t la = sa ? sa->len : 0;
    int64_t lb = sb ? sb->len : 0;
    TgString* r = (TgString*)tg_alloc(sizeof(TgString));
    int64_t cap = la + lb;
    if (cap < 15) cap = 15;
    r->data = (char*)tg_alloc(cap + 1);
    if (la > 0) memcpy(r->data, sa->data, la);
    if (lb > 0) memcpy(r->data + la, sb->data, lb);
    r->len = la + lb;
    r->cap = cap;
    r->data[r->len] = '\0';
    return tg_from_ptr(r);
}

TgVal tg_str_concat_cstr(TgVal a, const char* b) {
    TgVal bs = tg_str_from_cstr(b);
    return tg_str_concat(a, bs);
}

TgVal tg_str_contains(TgVal sv, TgVal sub_v) {
    TgString* s = str_ptr(sv);
    TgString* sub = str_ptr(sub_v);
    if (!s || !sub) return TG_FALSE;
    if (sub->len == 0) return TG_TRUE;
    return strstr(s->data, sub->data) != NULL ? TG_TRUE : TG_FALSE;
}

TgVal tg_str_starts_with(TgVal sv, TgVal prefix_v) {
    TgString* s = str_ptr(sv);
    TgString* p = str_ptr(prefix_v);
    if (!s || !p) return TG_FALSE;
    if (p->len > s->len) return TG_FALSE;
    return memcmp(s->data, p->data, p->len) == 0 ? TG_TRUE : TG_FALSE;
}

TgVal tg_str_ends_with(TgVal sv, TgVal suffix_v) {
    TgString* s = str_ptr(sv);
    TgString* x = str_ptr(suffix_v);
    if (!s || !x) return TG_FALSE;
    if (x->len > s->len) return TG_FALSE;
    return memcmp(s->data + s->len - x->len, x->data, x->len) == 0 ? TG_TRUE : TG_FALSE;
}

TgVal tg_str_find(TgVal sv, TgVal sub_v) {
    TgString* s = str_ptr(sv);
    TgString* sub = str_ptr(sub_v);
    if (!s || !sub) return tg_option_none();
    char* found = strstr(s->data, sub->data);
    if (!found) return tg_option_none();
    return tg_option_some((TgVal)(found - s->data));
}

TgVal tg_str_slice(TgVal sv, TgVal start, TgVal end) {
    TgString* s = str_ptr(sv);
    if (!s) return tg_str_new();
    int64_t st = start < 0 ? 0 : start;
    int64_t en = end > s->len ? s->len : end;
    if (st >= en) return tg_str_new();
    return tg_str_from_len(s->data + st, en - st);
}

TgVal tg_str_char_at(TgVal sv, TgVal idx) {
    TgString* s = str_ptr(sv);
    if (!s || idx < 0 || idx >= s->len) return TG_NIL;
    return (TgVal)(unsigned char)s->data[idx];
}

TgVal tg_str_to_lowercase(TgVal sv) {
    TgString* s = str_ptr(sv);
    if (!s) return tg_str_new();
    TgVal r = tg_str_from_len(s->data, s->len);
    TgString* rs = str_ptr(r);
    for (int64_t i = 0; i < rs->len; i++)
        rs->data[i] = (char)tolower((unsigned char)rs->data[i]);
    return r;
}

TgVal tg_str_to_uppercase(TgVal sv) {
    TgString* s = str_ptr(sv);
    if (!s) return tg_str_new();
    TgVal r = tg_str_from_len(s->data, s->len);
    TgString* rs = str_ptr(r);
    for (int64_t i = 0; i < rs->len; i++)
        rs->data[i] = (char)toupper((unsigned char)rs->data[i]);
    return r;
}

TgVal tg_str_trim(TgVal sv) {
    TgString* s = str_ptr(sv);
    if (!s || s->len == 0) return tg_str_new();
    int64_t start = 0, end = s->len;
    while (start < end && isspace((unsigned char)s->data[start])) start++;
    while (end > start && isspace((unsigned char)s->data[end - 1])) end--;
    return tg_str_from_len(s->data + start, end - start);
}

TgVal tg_str_replace(TgVal sv, TgVal from_v, TgVal to_v) {
    TgString* s = str_ptr(sv);
    TgString* from = str_ptr(from_v);
    TgString* to = str_ptr(to_v);
    if (!s || !from || from->len == 0) return tg_str_clone(sv);
    TgVal result = tg_str_new();
    TgString* r = str_ptr(result);
    int64_t i = 0;
    while (i < s->len) {
        if (i + from->len <= s->len && memcmp(s->data + i, from->data, from->len) == 0) {
            if (to && to->len > 0) {
                str_grow(r, to->len);
                memcpy(r->data + r->len, to->data, to->len);
                r->len += to->len;
            }
            i += from->len;
        } else {
            str_grow(r, 1);
            r->data[r->len++] = s->data[i++];
        }
    }
    r->data[r->len] = '\0';
    return result;
}

TgVal tg_str_split(TgVal sv, TgVal delim_v) {
    TgString* s = str_ptr(sv);
    TgString* d = str_ptr(delim_v);
    TgVal result = tg_vec_new();
    if (!s || s->len == 0) return result;
    if (!d || d->len == 0) {
        tg_vec_push(result, tg_str_clone(sv));
        return result;
    }
    int64_t start = 0;
    for (int64_t i = 0; i <= s->len - d->len; i++) {
        if (memcmp(s->data + i, d->data, d->len) == 0) {
            tg_vec_push(result, tg_str_from_len(s->data + start, i - start));
            start = i + d->len;
            i = start - 1;
        }
    }
    tg_vec_push(result, tg_str_from_len(s->data + start, s->len - start));
    return result;
}

TgVal tg_str_lines(TgVal sv) {
    return tg_str_split(sv, tg_str_from_cstr("\n"));
}

TgVal tg_str_eq(TgVal a, TgVal b) {
    TgString* sa = str_ptr(a);
    TgString* sb = str_ptr(b);
    if (sa == sb) return TG_TRUE;
    if (!sa || !sb) return TG_FALSE;
    if (sa->len != sb->len) return TG_FALSE;
    return memcmp(sa->data, sb->data, sa->len) == 0 ? TG_TRUE : TG_FALSE;
}

TgVal tg_str_neq(TgVal a, TgVal b) {
    return tg_str_eq(a, b) ? TG_FALSE : TG_TRUE;
}

/* Deep equality for tagged enum values: compare tag then fields recursively */
TgVal tg_val_eq(TgVal a, TgVal b) {
    if (a == b) return TG_TRUE;
    if (!a || !b) return TG_FALSE;
    /* Both are non-zero → treat as heap-allocated tagged enum structs.
       Layout: [tag, nfields, f0, f1, ...] */
    int64_t* ap = (int64_t*)(void*)a;
    int64_t* bp = (int64_t*)(void*)b;
    if (ap[0] != bp[0]) return TG_FALSE; /* different tags */
    /* Read the field count stored at position 1 */
    int nf = (int)ap[1];
    if (nf < 0 || nf > 64) nf = 0; /* safety clamp */
    /* Compare payload fields starting at position 2 */
    for (int i = 2; i < 2 + nf; i++) {
        if (ap[i] != bp[i]) {
            /* Fields differ — try string comparison if both look like valid string ptrs */
            if ((uint64_t)ap[i] < 0x10000 || (uint64_t)bp[i] < 0x10000) {
                return TG_FALSE;
            }
            TgString* sa = (TgString*)(void*)ap[i];
            TgString* sb = (TgString*)(void*)bp[i];
            if (sa && sb && sa->len >= 0 && sa->len < 10000000 &&
                sb->len >= 0 && sb->len < 10000000 &&
                sa->len == sb->len && sa->data && sb->data &&
                memcmp(sa->data, sb->data, sa->len) == 0) {
                continue; /* string fields match */
            }
            return TG_FALSE;
        }
    }
    return TG_TRUE;
}

TgVal tg_val_neq(TgVal a, TgVal b) {
    return tg_val_eq(a, b) ? TG_FALSE : TG_TRUE;
}

TgVal tg_str_cmp(TgVal a, TgVal b) {
    TgString* sa = str_ptr(a);
    TgString* sb = str_ptr(b);
    if (!sa && !sb) return 0;
    if (!sa) return -1;
    if (!sb) return 1;
    int64_t min_len = sa->len < sb->len ? sa->len : sb->len;
    int c = memcmp(sa->data, sb->data, min_len);
    if (c != 0) return c < 0 ? -1 : 1;
    if (sa->len < sb->len) return -1;
    if (sa->len > sb->len) return 1;
    return 0;
}

int64_t tg_str_hash(TgVal sv) {
    TgString* s = str_ptr(sv);
    if (!s) return 0;
    /* Salted FNV-1a — salt prevents HashDoS */
    uint64_t h = 14695981039346656037ULL ^ g_hash_salt;
    for (int64_t i = 0; i < s->len; i++) {
        h ^= (unsigned char)s->data[i];
        h *= 1099511628211ULL;
    }
    return (int64_t)h;
}

TgVal tg_str_to_int(TgVal sv) {
    TgString* s = str_ptr(sv);
    if (!s) return 0;
    return (TgVal)strtoll(s->data, NULL, 10);
}

TgVal tg_str_parse_float(TgVal sv) {
    TgString* s = str_ptr(sv);
    if (!s) return tg_from_double(0.0);
    return tg_from_double(strtod(s->data, NULL));
}

TgVal tg_int_to_string(TgVal i) {
    char buf[32];
    snprintf(buf, sizeof(buf), "%lld", (long long)i);
    return tg_str_from_cstr(buf);
}

TgVal tg_uint_to_string(TgVal u) {
    char buf[32];
    snprintf(buf, sizeof(buf), "%llu", (unsigned long long)(uint64_t)u);
    return tg_str_from_cstr(buf);
}

TgVal tg_float_to_string(TgVal f) {
    char buf[64];
    snprintf(buf, sizeof(buf), "%g", tg_to_double(f));
    return tg_str_from_cstr(buf);
}

TgVal tg_bool_to_string(TgVal b) {
    return tg_str_from_cstr(b ? "true" : "false");
}

TgVal tg_char_to_string(TgVal c) {
    char buf[8] = {0};
    buf[0] = (char)(c & 0xFF);
    return tg_str_from_cstr(buf);
}

const char* tg_str_cstr(TgVal sv) {
    TgString* s = str_ptr(sv);
    return s ? s->data : "";
}

TgVal tg_str_bytes(TgVal sv) {
    TgString* s = str_ptr(sv);
    TgVal v = tg_vec_new();
    if (s) {
        for (int64_t i = 0; i < s->len; i++)
            tg_vec_push(v, (TgVal)(unsigned char)s->data[i]);
    }
    return v;
}

TgVal tg_str_chars(TgVal sv) {
    return tg_str_bytes(sv);  /* simplified: byte == char for ASCII */
}

/* ── Vec ───────────────────────────────────────────────────────────── */

static TgVec* vec_ptr(TgVal v) { return (TgVec*)tg_as_ptr(v); }

static void vec_grow(TgVec* v, int64_t extra) {
    if (extra < 0) return;
    if (v->len + extra <= v->cap) return;
    /* Guard against integer overflow */
    if (v->len > INT64_MAX / 2 || extra > INT64_MAX - v->len)
        tg_panic("vec capacity overflow");
    int64_t new_cap = v->cap * 2;
    if (new_cap < v->len + extra) new_cap = v->len + extra;
    if (new_cap < 8) new_cap = 8;
    if ((uint64_t)new_cap > SIZE_MAX / sizeof(TgVal))
        tg_panic("vec allocation size overflow");
    v->data = (TgVal*)tg_realloc(v->data, (size_t)new_cap * sizeof(TgVal));
    v->cap = new_cap;
}

TgVal tg_vec_new(void) {
    TgVec* v = (TgVec*)tg_alloc(sizeof(TgVec));
    v->data = NULL;
    v->len = 0;
    v->cap = 0;
    return tg_from_ptr(v);
}

TgVal tg_vec_with_capacity(int64_t cap) {
    TgVec* v = (TgVec*)tg_alloc(sizeof(TgVec));
    v->data = (TgVal*)tg_alloc(cap * sizeof(TgVal));
    v->len = 0;
    v->cap = cap;
    return tg_from_ptr(v);
}

TgVal tg_vec_from_array(TgVal* arr, int64_t len) {
    TgVal v = tg_vec_with_capacity(len);
    TgVec* vp = vec_ptr(v);
    if (arr && len > 0) memcpy(vp->data, arr, len * sizeof(TgVal));
    vp->len = len;
    return v;
}

TgVal tg_vec_clone(TgVal vv) {
    TgVec* v = vec_ptr(vv);
    if (!v) return tg_vec_new();
    TgVal r = tg_vec_with_capacity(v->len);
    TgVec* rp = vec_ptr(r);
    if (v->len > 0) memcpy(rp->data, v->data, v->len * sizeof(TgVal));
    rp->len = v->len;
    return r;
}

void tg_vec_free(TgVal vv) {
    TgVec* v = vec_ptr(vv);
    if (v) { tg_free(v->data); tg_free(v); }
}

int64_t tg_vec_len(TgVal vv) {
    TgVec* v = vec_ptr(vv);
    return v ? v->len : 0;
}

TgVal tg_vec_is_empty(TgVal vv) {
    return tg_vec_len(vv) == 0 ? TG_TRUE : TG_FALSE;
}

TgVal tg_vec_get(TgVal vv, TgVal idx) {
    TgVec* v = vec_ptr(vv);
    if (!v || idx < 0 || idx >= v->len) return TG_NIL;
    return v->data[idx];
}

TgVal tg_vec_set(TgVal vv, TgVal idx, TgVal val) {
    TgVec* v = vec_ptr(vv);
    if (!v || idx < 0 || idx >= v->len) return TG_NIL;
    v->data[idx] = val;
    return TG_NIL;
}

TgVal tg_vec_last(TgVal vv) {
    TgVec* v = vec_ptr(vv);
    if (!v || v->len == 0) return tg_option_none();
    return tg_option_some(v->data[v->len - 1]);
}

TgVal tg_vec_push(TgVal vv, TgVal item) {
    TgVec* v = vec_ptr(vv);
    if (!v) return TG_NIL;
    vec_grow(v, 1);
    v->data[v->len++] = item;
    return TG_NIL;
}

TgVal tg_vec_pop(TgVal vv) {
    TgVec* v = vec_ptr(vv);
    if (!v || v->len == 0) return tg_option_none();
    return tg_option_some(v->data[--v->len]);
}

TgVal tg_vec_insert(TgVal vv, TgVal idx, TgVal item) {
    TgVec* v = vec_ptr(vv);
    if (!v || idx < 0 || idx > v->len) return TG_NIL;
    vec_grow(v, 1);
    memmove(&v->data[idx + 1], &v->data[idx], (v->len - idx) * sizeof(TgVal));
    v->data[idx] = item;
    v->len++;
    return TG_NIL;
}

TgVal tg_vec_remove(TgVal vv, TgVal idx) {
    TgVec* v = vec_ptr(vv);
    if (!v || idx < 0 || idx >= v->len) return TG_NIL;
    TgVal removed = v->data[idx];
    memmove(&v->data[idx], &v->data[idx + 1], (v->len - idx - 1) * sizeof(TgVal));
    v->len--;
    return removed;
}

TgVal tg_vec_clear(TgVal vv) {
    TgVec* v = vec_ptr(vv);
    if (v) v->len = 0;
    return TG_NIL;
}

TgVal tg_vec_truncate(TgVal vv, TgVal new_len) {
    TgVec* v = vec_ptr(vv);
    if (v && new_len < v->len) v->len = new_len;
    return TG_NIL;
}

TgVal tg_vec_reverse(TgVal vv) {
    TgVec* v = vec_ptr(vv);
    if (!v || v->len < 2) return TG_NIL;
    for (int64_t i = 0, j = v->len - 1; i < j; i++, j--) {
        TgVal tmp = v->data[i];
        v->data[i] = v->data[j];
        v->data[j] = tmp;
    }
    return TG_NIL;
}

TgVal tg_vec_extend(TgVal vv, TgVal other_v) {
    TgVec* v = vec_ptr(vv);
    TgVec* o = vec_ptr(other_v);
    if (!v || !o || o->len == 0) return TG_NIL;
    vec_grow(v, o->len);
    memcpy(v->data + v->len, o->data, o->len * sizeof(TgVal));
    v->len += o->len;
    return TG_NIL;
}

TgVal tg_vec_extend_from_slice(TgVal vv, TgVal other_v) {
    tg_vec_extend(vv, other_v);
    return TG_NIL;
}

TgVal tg_vec_contains(TgVal vv, TgVal item) {
    TgVec* v = vec_ptr(vv);
    if (!v) return TG_FALSE;
    for (int64_t i = 0; i < v->len; i++)
        if (v->data[i] == item) return TG_TRUE;
    return TG_FALSE;
}

/* Sorting: simple qsort wrapper */
static int sort_cmp_default(const void* a, const void* b) {
    TgVal va = *(const TgVal*)a;
    TgVal vb = *(const TgVal*)b;
    if (va < vb) return -1;
    if (va > vb) return 1;
    return 0;
}

TgVal tg_vec_sort(TgVal vv) {
    TgVec* v = vec_ptr(vv);
    if (v && v->len > 1)
        qsort(v->data, v->len, sizeof(TgVal), sort_cmp_default);
    return TG_NIL;
}

static TgVal g_sort_closure = 0;
static int sort_cmp_closure(const void* a, const void* b) {
    TgVal va = *(const TgVal*)a;
    TgVal vb = *(const TgVal*)b;
    return (int)tg_closure_call2(g_sort_closure, va, vb);
}

TgVal tg_vec_sort_by(TgVal vv, TgVal cmp_fn) {
    TgVec* v = vec_ptr(vv);
    if (!v || v->len <= 1) return TG_NIL;
    g_sort_closure = cmp_fn;
    qsort(v->data, v->len, sizeof(TgVal), sort_cmp_closure);
    g_sort_closure = 0;
    return TG_NIL;
}

TgVal tg_vec_map(TgVal vv, TgVal fn) {
    TgVec* v = vec_ptr(vv);
    TgVal result = tg_vec_new();
    if (!v) return result;
    for (int64_t i = 0; i < v->len; i++)
        tg_vec_push(result, tg_closure_call1(fn, v->data[i]));
    return result;
}

TgVal tg_vec_filter(TgVal vv, TgVal fn) {
    TgVec* v = vec_ptr(vv);
    TgVal result = tg_vec_new();
    if (!v) return result;
    for (int64_t i = 0; i < v->len; i++) {
        if (tg_closure_call1(fn, v->data[i]))
            tg_vec_push(result, v->data[i]);
    }
    return result;
}

TgVal tg_vec_filter_map(TgVal vv, TgVal fn) {
    TgVec* v = vec_ptr(vv);
    TgVal result = tg_vec_new();
    if (!v) return result;
    for (int64_t i = 0; i < v->len; i++) {
        TgVal opt = tg_closure_call1(fn, v->data[i]);
        if (tg_option_is_some(opt))
            tg_vec_push(result, tg_option_unwrap(opt));
    }
    return result;
}

TgVal tg_vec_any(TgVal vv, TgVal fn) {
    TgVec* v = vec_ptr(vv);
    if (!v) return TG_FALSE;
    for (int64_t i = 0; i < v->len; i++)
        if (tg_closure_call1(fn, v->data[i])) return TG_TRUE;
    return TG_FALSE;
}

TgVal tg_vec_all(TgVal vv, TgVal fn) {
    TgVec* v = vec_ptr(vv);
    if (!v) return TG_TRUE;
    for (int64_t i = 0; i < v->len; i++)
        if (!tg_closure_call1(fn, v->data[i])) return TG_FALSE;
    return TG_TRUE;
}

TgVal tg_vec_find(TgVal vv, TgVal fn) {
    TgVec* v = vec_ptr(vv);
    if (!v) return tg_option_none();
    for (int64_t i = 0; i < v->len; i++)
        if (tg_closure_call1(fn, v->data[i]))
            return tg_option_some(v->data[i]);
    return tg_option_none();
}

TgVal tg_vec_enumerate(TgVal vv) {
    TgVec* v = vec_ptr(vv);
    TgVal result = tg_vec_new();
    if (!v) return result;
    for (int64_t i = 0; i < v->len; i++)
        tg_vec_push(result, tg_tuple_new2(i, v->data[i]));
    return result;
}

TgVal tg_vec_for_each(TgVal vv, TgVal fn) {
    TgVec* v = vec_ptr(vv);
    if (!v) return TG_NIL;
    for (int64_t i = 0; i < v->len; i++)
        tg_closure_call1(fn, v->data[i]);
    return TG_NIL;
}

TgVal tg_vec_iter(TgVal vv) { return vv; } /* identity: iterating a vec = the vec itself */

TgVal tg_vec_join(TgVal vv, TgVal sep) {
    TgVec* v = vec_ptr(vv);
    if (!v || v->len == 0) return tg_str_new();
    TgVal result = tg_str_clone(v->data[0]);
    for (int64_t i = 1; i < v->len; i++) {
        result = tg_str_concat(result, sep);
        result = tg_str_concat(result, v->data[i]);
    }
    return result;
}

TgVal tg_vec_collect(TgVal vv) { return vv; } /* identity for bootstrap */

/* ── Map ───────────────────────────────────────────────────────────── */

static TgMap* map_ptr(TgVal m) { return (TgMap*)tg_as_ptr(m); }

static int64_t map_hash_key(TgMap* m, TgVal key) {
    if (m->key_is_string) {
        return tg_str_hash(key);
    }
    /* Integer hash: murmurhash-like */
    uint64_t h = (uint64_t)key;
    h ^= h >> 33;
    h *= 0xff51afd7ed558ccdULL;
    h ^= h >> 33;
    h *= 0xc4ceb9fe1a85ec53ULL;
    h ^= h >> 33;
    return (int64_t)h;
}

static int map_keys_eq(TgMap* m, TgVal a, TgVal b) {
    if (m->key_is_string) return tg_str_eq(a, b) != 0;
    return a == b;
}

static TgMap* map_alloc(int key_is_string) {
    TgMap* m = (TgMap*)tg_alloc(sizeof(TgMap));
    m->capacity = 16;
    m->buckets = (TgMapEntry*)tg_alloc(m->capacity * sizeof(TgMapEntry));
    m->len = 0;
    m->key_is_string = key_is_string;
    return m;
}

static void map_rehash(TgMap* m) {
    int64_t old_cap = m->capacity;
    TgMapEntry* old = m->buckets;
    m->capacity = old_cap * 2;
    m->buckets = (TgMapEntry*)tg_alloc(m->capacity * sizeof(TgMapEntry));
    m->len = 0;
    for (int64_t i = 0; i < old_cap; i++) {
        if (old[i].state == 1) {
            /* Re-insert */
            int64_t h = old[i].hash;
            int64_t idx = ((uint64_t)h) % m->capacity;
            while (m->buckets[idx].state == 1) {
                idx = (idx + 1) % m->capacity;
            }
            m->buckets[idx] = old[i];
            m->len++;
        }
    }
    tg_free(old);
}

TgVal tg_map_new(void) {
    return tg_from_ptr(map_alloc(0));
}

TgVal tg_map_new_string_keys(void) {
    return tg_from_ptr(map_alloc(1));
}

TgVal tg_map_clone(TgVal mv) {
    TgMap* m = map_ptr(mv);
    if (!m) return tg_map_new();
    TgMap* r = (TgMap*)tg_alloc(sizeof(TgMap));
    r->capacity = m->capacity;
    r->buckets = (TgMapEntry*)tg_alloc(r->capacity * sizeof(TgMapEntry));
    memcpy(r->buckets, m->buckets, m->capacity * sizeof(TgMapEntry));
    r->len = m->len;
    r->key_is_string = m->key_is_string;
    return tg_from_ptr(r);
}

void tg_map_free(TgVal mv) {
    TgMap* m = map_ptr(mv);
    if (m) { tg_free(m->buckets); tg_free(m); }
}

int64_t tg_map_len(TgVal mv) {
    TgMap* m = map_ptr(mv);
    return m ? m->len : 0;
}

TgVal tg_map_is_empty(TgVal mv) {
    return tg_map_len(mv) == 0 ? TG_TRUE : TG_FALSE;
}

TgVal tg_map_insert(TgVal mv, TgVal key, TgVal value) {
    TgMap* m = map_ptr(mv);
    if (!m) return TG_NIL;
    if (m->len * 4 >= m->capacity * 3) map_rehash(m);

    int64_t h = map_hash_key(m, key);
    int64_t idx = ((uint64_t)h) % m->capacity;
    int64_t first_tombstone = -1;
    while (1) {
        if (m->buckets[idx].state == 0) {
            int64_t ins = first_tombstone >= 0 ? first_tombstone : idx;
            m->buckets[ins].key = key;
            m->buckets[ins].value = value;
            m->buckets[ins].hash = h;
            m->buckets[ins].state = 1;
            m->len++;
            return TG_NIL;
        }
        if (m->buckets[idx].state == 2 && first_tombstone < 0) {
            first_tombstone = idx;
        }
        if (m->buckets[idx].state == 1 && m->buckets[idx].hash == h &&
            map_keys_eq(m, m->buckets[idx].key, key)) {
            m->buckets[idx].value = value;
            return TG_NIL;
        }
        idx = (idx + 1) % m->capacity;
    }
}

TgVal tg_map_get(TgVal mv, TgVal key) {
    TgMap* m = map_ptr(mv);
    if (!m || m->len == 0) return tg_option_none();
    int64_t h = map_hash_key(m, key);
    int64_t idx = ((uint64_t)h) % m->capacity;
    while (1) {
        if (m->buckets[idx].state == 0) return tg_option_none();
        if (m->buckets[idx].state == 1 && m->buckets[idx].hash == h &&
            map_keys_eq(m, m->buckets[idx].key, key))
            return tg_option_some(m->buckets[idx].value);
        idx = (idx + 1) % m->capacity;
    }
}

TgVal tg_map_get_mut(TgVal mv, TgVal key) {
    return tg_map_get(mv, key);
}

TgVal tg_map_contains_key(TgVal mv, TgVal key) {
    return tg_option_is_some(tg_map_get(mv, key));
}

TgVal tg_map_remove(TgVal mv, TgVal key) {
    TgMap* m = map_ptr(mv);
    if (!m || m->len == 0) return tg_option_none();
    int64_t h = map_hash_key(m, key);
    int64_t idx = ((uint64_t)h) % m->capacity;
    while (1) {
        if (m->buckets[idx].state == 0) return tg_option_none();
        if (m->buckets[idx].state == 1 && m->buckets[idx].hash == h &&
            map_keys_eq(m, m->buckets[idx].key, key)) {
            TgVal val = m->buckets[idx].value;
            m->buckets[idx].state = 2;
            m->len--;
            return tg_option_some(val);
        }
        idx = (idx + 1) % m->capacity;
    }
}

TgVal tg_map_entries(TgVal mv) {
    TgMap* m = map_ptr(mv);
    TgVal result = tg_vec_new();
    if (!m) return result;
    for (int64_t i = 0; i < m->capacity; i++) {
        if (m->buckets[i].state == 1) {
            tg_vec_push(result, tg_tuple_new2(m->buckets[i].key, m->buckets[i].value));
        }
    }
    return result;
}

TgVal tg_map_keys(TgVal mv) {
    TgMap* m = map_ptr(mv);
    TgVal result = tg_vec_new();
    if (!m) return result;
    for (int64_t i = 0; i < m->capacity; i++) {
        if (m->buckets[i].state == 1)
            tg_vec_push(result, m->buckets[i].key);
    }
    return result;
}

TgVal tg_map_values(TgVal mv) {
    TgMap* m = map_ptr(mv);
    TgVal result = tg_vec_new();
    if (!m) return result;
    for (int64_t i = 0; i < m->capacity; i++) {
        if (m->buckets[i].state == 1)
            tg_vec_push(result, m->buckets[i].value);
    }
    return result;
}

/* ── Set ───────────────────────────────────────────────────────────── */

TgVal tg_set_new(void) { return tg_map_new(); }
TgVal tg_set_new_string_keys(void) { return tg_map_new_string_keys(); }
TgVal tg_set_clone(TgVal s) { return tg_map_clone(s); }
void  tg_set_free(TgVal s) { tg_map_free(s); }
int64_t tg_set_len(TgVal s) { return tg_map_len(s); }
TgVal tg_set_is_empty(TgVal s) { return tg_map_is_empty(s); }

TgVal tg_set_insert(TgVal s, TgVal key) {
    TgVal prev = tg_map_contains_key(s, key);
    tg_map_insert(s, key, TG_TRUE);
    return prev ? TG_FALSE : TG_TRUE;
}

TgVal tg_set_remove(TgVal s, TgVal key) {
    return tg_option_is_some(tg_map_remove(s, key));
}

TgVal tg_set_contains(TgVal s, TgVal key) {
    return tg_map_contains_key(s, key);
}

TgVal tg_set_to_vec(TgVal s) { return tg_map_keys(s); }
TgVal tg_set_into_vec(TgVal s) { return tg_map_keys(s); }

/* ── Option ────────────────────────────────────────────────────────── */

TgVal tg_option_some(TgVal val) {
    TgOption* o = (TgOption*)tg_alloc(sizeof(TgOption));
    o->_tag = 0;  /* Some */
    o->_nfields = 1;
    o->value = val;
    return tg_from_ptr(o);
}

TgVal tg_option_none(void) {
    TgOption* o = (TgOption*)tg_alloc(sizeof(TgOption));
    o->_tag = 1;  /* None */
    o->_nfields = 0;
    o->value = TG_NIL;
    return tg_from_ptr(o);
}

TgVal tg_option_is_some(TgVal opt) {
    TgOption* o = (TgOption*)tg_as_ptr(opt);
    return (o && o->_tag == 0) ? TG_TRUE : TG_FALSE;
}

TgVal tg_option_is_none(TgVal opt) {
    return tg_option_is_some(opt) ? TG_FALSE : TG_TRUE;
}

TgVal tg_option_unwrap(TgVal opt) {
    TgOption* o = (TgOption*)tg_as_ptr(opt);
    if (!o || o->_tag != 0) tg_panic("unwrap on None");
    return o->value;
}

TgVal tg_option_unwrap_or(TgVal opt, TgVal default_val) {
    TgOption* o = (TgOption*)tg_as_ptr(opt);
    if (!o || o->_tag != 0) return default_val;
    return o->value;
}

TgVal tg_option_map(TgVal opt, TgVal fn) {
    TgOption* o = (TgOption*)tg_as_ptr(opt);
    if (!o || o->_tag != 0) return tg_option_none();
    return tg_option_some(tg_closure_call1(fn, o->value));
}

/* ── Result ────────────────────────────────────────────────────────── */

TgVal tg_result_ok(TgVal val) {
    TgResult* r = (TgResult*)tg_alloc(sizeof(TgResult));
    r->_tag = 0;  /* Ok */
    r->_nfields = 1;
    r->value = val;
    return tg_from_ptr(r);
}

TgVal tg_result_err(TgVal err) {
    TgResult* r = (TgResult*)tg_alloc(sizeof(TgResult));
    r->_tag = 1;  /* Err */
    r->_nfields = 1;
    r->value = err;
    return tg_from_ptr(r);
}

TgVal tg_result_is_ok(TgVal res) {
    TgResult* r = (TgResult*)tg_as_ptr(res);
    return (r && r->_tag == 0) ? TG_TRUE : TG_FALSE;
}

TgVal tg_result_is_err(TgVal res) {
    return tg_result_is_ok(res) ? TG_FALSE : TG_TRUE;
}

TgVal tg_result_unwrap(TgVal res) {
    TgResult* r = (TgResult*)tg_as_ptr(res);
    if (!r || r->_tag != 0) tg_panic("unwrap on Err");
    return r->value;
}

TgVal tg_result_unwrap_err(TgVal res) {
    TgResult* r = (TgResult*)tg_as_ptr(res);
    if (!r || r->_tag == 0) tg_panic("unwrap_err on Ok");
    return r->value;
}

TgVal tg_result_map_err(TgVal res, TgVal fn) {
    TgResult* r = (TgResult*)tg_as_ptr(res);
    if (!r || r->_tag == 0) return res;
    return tg_result_err(tg_closure_call1(fn, r->value));
}

/* ── Box ───────────────────────────────────────────────────────────── */

TgVal tg_box_new(TgVal val) {
    TgVal* p = (TgVal*)tg_alloc(sizeof(TgVal));
    *p = val;
    return tg_from_ptr(p);
}

TgVal tg_box_deref(TgVal bx) {
    TgVal* p = (TgVal*)tg_as_ptr(bx);
    return p ? *p : TG_NIL;
}

void tg_box_free(TgVal bx) {
    tg_free(tg_as_ptr(bx));
}

/* ── Tuple ─────────────────────────────────────────────────────────── */
/* Tuples are heap-allocated arrays: [len, elem0, elem1, ...] */

TgVal tg_tuple_new2(TgVal a, TgVal b) {
    TgVal* t = (TgVal*)tg_alloc(3 * sizeof(TgVal));
    t[0] = 2; t[1] = a; t[2] = b;
    return tg_from_ptr(t);
}

TgVal tg_tuple_new3(TgVal a, TgVal b, TgVal c) {
    TgVal* t = (TgVal*)tg_alloc(4 * sizeof(TgVal));
    t[0] = 3; t[1] = a; t[2] = b; t[3] = c;
    return tg_from_ptr(t);
}

TgVal tg_tuple_new4(TgVal a, TgVal b, TgVal c, TgVal d) {
    TgVal* t = (TgVal*)tg_alloc(5 * sizeof(TgVal));
    t[0] = 4; t[1] = a; t[2] = b; t[3] = c; t[4] = d;
    return tg_from_ptr(t);
}

TgVal tg_tuple_get(TgVal tup, TgVal idx) {
    TgVal* t = (TgVal*)tg_as_ptr(tup);
    if (!t || idx < 0 || idx >= t[0]) return TG_NIL;
    return t[1 + idx];
}

/* ── Closure ───────────────────────────────────────────────────────── */

TgVal tg_closure_new(TgVal (*fn)(TgVal, TgVal), TgVal env) {
    TgClosure* c = (TgClosure*)tg_alloc(sizeof(TgClosure));
    c->fn = fn;
    c->env = env;
    return tg_from_ptr(c);
}

TgVal tg_closure_call1(TgVal closure, TgVal arg) {
    TgClosure* c = (TgClosure*)tg_as_ptr(closure);
    if (!c || !c->fn) return TG_NIL;
    return c->fn(c->env, arg);
}

TgVal tg_closure_call2(TgVal closure, TgVal a1, TgVal a2) {
    /* For 2-arg closures, pack into tuple */
    TgClosure* c = (TgClosure*)tg_as_ptr(closure);
    if (!c || !c->fn) return TG_NIL;
    /* Call fn(env, tuple(a1, a2)) */
    TgVal args = tg_tuple_new2(a1, a2);
    return c->fn(c->env, args);
}

/* ── Dynamic Dispatch ──────────────────────────────────────────────── */

TgVal tg_dyn_new(void* data) {
    TgDynObj* d = (TgDynObj*)tg_alloc(sizeof(TgDynObj));
    d->data = data;
    memset(d->vtable, 0, sizeof(d->vtable));
    return tg_from_ptr(d);
}

TgVal tg_dyn_call(TgVal obj, int method_idx, TgVal a1, TgVal a2, TgVal a3) {
    TgDynObj* d = (TgDynObj*)tg_as_ptr(obj);
    if (!d || method_idx < 0 || method_idx >= 16 || !d->vtable[method_idx])
        tg_panic("vtable dispatch failed");
    return d->vtable[method_idx](tg_from_ptr(d->data), a1, a2, a3);
}

/* ── Struct / Enum helpers ─────────────────────────────────────────── */

TgVal tg_struct_alloc(int64_t n_fields) {
    TgVal* s = (TgVal*)tg_alloc((n_fields + 1) * sizeof(TgVal));
    s[0] = n_fields;
    return tg_from_ptr(s);
}

TgVal tg_enum_alloc(int64_t tag, int64_t n_payload) {
    TgVal* e = (TgVal*)tg_alloc((2 + n_payload) * sizeof(TgVal));
    e[0] = tag;
    e[1] = n_payload;  /* _nfields for tg_val_eq */
    return tg_from_ptr(e);
}

TgVal tg_field_get(TgVal obj, int64_t idx) {
    TgVal* s = (TgVal*)tg_as_ptr(obj);
    if (!s) return TG_NIL;
    return s[1 + idx];
}

TgVal tg_field_set(TgVal obj, int64_t idx, TgVal val) {
    TgVal* s = (TgVal*)tg_as_ptr(obj);
    if (s) s[1 + idx] = val;
    return TG_NIL;
}

int64_t tg_enum_tag(TgVal obj) {
    TgVal* e = (TgVal*)tg_as_ptr(obj);
    if (!e) return -1;
    return e[0];
}

TgVal tg_enum_payload(TgVal obj, int64_t idx) {
    TgVal* e = (TgVal*)tg_as_ptr(obj);
    if (!e) return TG_NIL;
    return e[2 + idx];  /* skip tag and _nfields */
}

/* ── I/O ───────────────────────────────────────────────────────────── */

TgVal tg_print(TgVal s) {
    TgString* str = (TgString*)tg_as_ptr(s);
    if (str && str->data) fwrite(str->data, 1, str->len, stdout);
    return TG_NIL;
}

TgVal tg_println(TgVal s) {
    tg_print(s);
    putchar('\n');
    fflush(stdout);
    return TG_NIL;
}

TgVal tg_eprint(TgVal s) {
    TgString* str = (TgString*)tg_as_ptr(s);
    if (str && str->data) fwrite(str->data, 1, str->len, stderr);
    return TG_NIL;
}

TgVal tg_eprintln(TgVal s) {
    tg_eprint(s);
    fputc('\n', stderr);
    fflush(stderr);
    return TG_NIL;
}

TgVal tg_read_file(TgVal path) {
    const char* p = tg_str_cstr(path);
    FILE* f = fopen(p, "rb");
    if (!f) return tg_result_err(tg_str_from_cstr("cannot open file"));
    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    fseek(f, 0, SEEK_SET);
    char* buf = (char*)tg_alloc(len + 1);
    size_t rd = fread(buf, 1, len, f);
    fclose(f);
    buf[rd] = '\0';
    TgVal s = tg_str_from_len(buf, (int64_t)rd);
    tg_free(buf);
    return tg_result_ok(s);
}

TgVal tg_write_file(TgVal path, TgVal content) {
    const char* p = tg_str_cstr(path);
    TgString* c = (TgString*)tg_as_ptr(content);
    FILE* f = fopen(p, "wb");
    if (!f) return tg_result_err(tg_str_from_cstr("cannot open file for writing"));
    if (c && c->len > 0) fwrite(c->data, 1, c->len, f);
    fclose(f);
    return tg_result_ok(TG_NIL);
}

/* ── Process ───────────────────────────────────────────────────────── */

void tg_exit(TgVal code) {
    exit((int)code);
}

TgVal tg_command_output(TgVal cmd) {
    const char* c = tg_str_cstr(cmd);
    FILE* fp = popen(c, "r");
    if (!fp) return tg_str_new();
    TgVal result = tg_str_new();
    TgString* rs = str_ptr(result);
    char buf[256];
    while (fgets(buf, sizeof(buf), fp)) {
        int64_t blen = (int64_t)strlen(buf);
        str_grow(rs, blen);
        memcpy(rs->data + rs->len, buf, blen);
        rs->len += blen;
    }
    rs->data[rs->len] = '\0';
    pclose(fp);
    return result;
}

TgVal tg_system(TgVal cmd) {
    const char* c = tg_str_cstr(cmd);
    return (TgVal)system(c);
}

TgVal tg_env_var(TgVal name) {
    const char* n = tg_str_cstr(name);
    const char* v = getenv(n);
    if (!v) return tg_option_none();
    return tg_option_some(tg_str_from_cstr(v));
}

TgVal tg_getcwd(void) {
    char buf[4096];
    if (getcwd(buf, sizeof(buf))) return tg_str_from_cstr(buf);
    return tg_str_from_cstr(".");
}

TgVal tg_file_exists(TgVal path) {
    const char* p = tg_str_cstr(path);
    struct stat st;
    return stat(p, &st) == 0 ? TG_TRUE : TG_FALSE;
}

TgVal tg_args(void) {
    TgVal v = tg_vec_new();
    for (int i = 0; i < g_argc; i++)
        tg_vec_push(v, tg_str_from_cstr(g_argv[i]));
    return v;
}

/* ── Math intrinsics ───────────────────────────────────────────────── */

TgVal tg_intrinsic_pow(TgVal base, TgVal exp) {
    double b = tg_to_double(base);
    double e = tg_to_double(exp);
    return tg_from_double(pow(b, e));
}

TgVal tg_intrinsic_to_float(TgVal i) {
    return tg_from_double((double)i);
}

TgVal tg_intrinsic_to_int(TgVal f) {
    return (TgVal)tg_to_double(f);
}

TgVal tg_abs_int(TgVal i) {
    return i < 0 ? -i : i;
}

TgVal tg_min_int(TgVal a, TgVal b) { return a < b ? a : b; }
TgVal tg_max_int(TgVal a, TgVal b) { return a > b ? a : b; }
TgVal tg_clamp_int(TgVal val, TgVal lo, TgVal hi) {
    if (val < lo) return lo;
    if (val > hi) return hi;
    return val;
}

/* ── Hashing ───────────────────────────────────────────────────────── */

int64_t tg_hash_int(TgVal v) {
    uint64_t h = (uint64_t)v;
    h ^= h >> 33;
    h *= 0xff51afd7ed558ccdULL;
    h ^= h >> 33;
    return (int64_t)h;
}

int64_t tg_hash_combine(int64_t h1, int64_t h2) {
    uint64_t h = (uint64_t)h1;
    h ^= (uint64_t)h2 + 0x9e3779b97f4a7c15ULL + (h << 6) + (h >> 2);
    return (int64_t)h;
}

/* ── Formatting helpers ────────────────────────────────────────────── */

TgVal tg_format_int(TgVal i) { return tg_int_to_string(i); }
TgVal tg_format_hex(TgVal i) {
    char buf[32];
    snprintf(buf, sizeof(buf), "0x%llx", (unsigned long long)(uint64_t)i);
    return tg_str_from_cstr(buf);
}

/* ── Temp file ─────────────────────────────────────────────────────── */

TgVal tg_temp_file(TgVal prefix, TgVal suffix) {
    const char* p = tg_str_cstr(prefix);
    const char* s = tg_str_cstr(suffix);
    char buf[256];
    snprintf(buf, sizeof(buf), "/tmp/%s_%d%s", p, (int)getpid(), s);
    return tg_str_from_cstr(buf);
}

/* ── I/O primitives for compiler ───────────────────────────────────── */

TgVal read_line(void) {
    TgVal result = tg_str_new();
    TgString* s = str_ptr(result);
    int c;
    while ((c = fgetc(stdin)) != EOF && c != '\n') {
        str_grow(s, 1);
        s->data[s->len++] = (char)c;
    }
    s->data[s->len] = '\0';
    if (s->len == 0 && c == EOF) return tg_str_from_cstr("");
    return result;
}

TgVal read_bytes(TgVal n) {
    int64_t count = (int64_t)n;
    if (count <= 0) return tg_str_from_cstr("");
    char* buf = (char*)tg_alloc((size_t)count + 1);
    size_t got = fread(buf, 1, (size_t)count, stdin);
    buf[got] = '\0';
    TgVal result = tg_str_from_len(buf, (int64_t)got);
    tg_free(buf);
    return result;
}

TgVal system_(TgVal cmd) {
    const char* c = tg_str_cstr(cmd);
    int ret = system(c);
    return (TgVal)ret;
}
