/*  Tangerine Runtime Library — Stage0 Bootstrap
 *
 *  Provides implementations of Tangerine's standard library types:
 *  String, Vec, Map, Set, Option, Result, Box, and I/O primitives.
 *
 *  Design: All Tangerine values are represented as int64_t (8 bytes).
 *  - Integers: stored directly
 *  - Floats: stored via bit-cast (memcpy)
 *  - Booleans: 0 or 1
 *  - Pointers (String, Vec, Map, Set, structs, enums): cast to int64_t
 *  - nil: 0
 */

#ifndef TG_RUNTIME_H
#define TG_RUNTIME_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ── Value representation ──────────────────────────────────────────── */

typedef int64_t TgVal;

static inline void* tg_as_ptr(TgVal v) { return (void*)(intptr_t)v; }
static inline TgVal tg_from_ptr(void* p) { return (TgVal)(intptr_t)p; }

static inline TgVal tg_from_double(double f) {
    TgVal v; memcpy(&v, &f, 8); return v;
}
static inline double tg_to_double(TgVal v) {
    double f; memcpy(&f, &v, 8); return f;
}

#define TG_NIL ((TgVal)0)
#define TG_TRUE ((TgVal)1)
#define TG_FALSE ((TgVal)0)

/* ── Panic / assert ────────────────────────────────────────────────── */

void tg_panic(const char* msg);
void tg_assert(TgVal cond, const char* msg);
TgVal tg_debug_val(TgVal v);

/* ── Memory allocation ─────────────────────────────────────────────── */

void* tg_alloc(size_t size);
void* tg_realloc(void* ptr, size_t size);
void  tg_free(void* ptr);

size_t tg_debug_alloc_total(void);
size_t tg_debug_free_total(void);
size_t tg_debug_alloc_peak(void);
size_t tg_debug_alloc_count(void);
size_t tg_debug_free_count(void);

/* ── String ────────────────────────────────────────────────────────── */

typedef struct TgString {
    char*   data;
    int64_t len;
    int64_t cap;
} TgString;

/* Constructors */
TgVal tg_str_new(void);
TgVal tg_str_from_cstr(const char* s);
TgVal tg_str_from_len(const char* s, int64_t len);
TgVal tg_str_clone(TgVal s);
void  tg_str_free(TgVal s);

/* Properties */
int64_t tg_str_len(TgVal s);
TgVal   tg_str_is_empty(TgVal s);

/* Mutation */
TgVal tg_str_push_char(TgVal s, TgVal ch);
TgVal tg_str_push_str(TgVal s, TgVal other);

/* Concatenation (returns new string) */
TgVal tg_str_concat(TgVal a, TgVal b);
TgVal tg_str_concat_cstr(TgVal a, const char* b);

/* Queries */
TgVal tg_str_contains(TgVal s, TgVal sub);
TgVal tg_str_starts_with(TgVal s, TgVal prefix);
TgVal tg_str_ends_with(TgVal s, TgVal suffix);
TgVal tg_str_find(TgVal s, TgVal sub);

/* Transformations */
TgVal tg_str_slice(TgVal s, TgVal start, TgVal end);
TgVal tg_str_char_at(TgVal s, TgVal idx);
TgVal tg_str_to_lowercase(TgVal s);
TgVal tg_str_to_uppercase(TgVal s);
TgVal tg_str_trim(TgVal s);
TgVal tg_str_replace(TgVal s, TgVal from, TgVal to);

/* Splitting / joining */
TgVal tg_str_split(TgVal s, TgVal delim);
TgVal tg_str_lines(TgVal s);

/* Comparison */
TgVal tg_str_eq(TgVal a, TgVal b);
TgVal tg_str_neq(TgVal a, TgVal b);
TgVal tg_val_eq(TgVal a, TgVal b);
TgVal tg_val_neq(TgVal a, TgVal b);
TgVal tg_str_cmp(TgVal a, TgVal b);
int64_t tg_str_hash(TgVal s);

/* Conversion */
TgVal tg_str_to_int(TgVal s);
TgVal tg_str_parse_float(TgVal s);
TgVal tg_int_to_string(TgVal i);
TgVal tg_uint_to_string(TgVal u);
TgVal tg_float_to_string(TgVal f);
TgVal tg_bool_to_string(TgVal b);
TgVal tg_char_to_string(TgVal c);

/* Raw access */
const char* tg_str_cstr(TgVal s);
TgVal tg_str_bytes(TgVal s);
TgVal tg_str_chars(TgVal s);

/* ── Vec ───────────────────────────────────────────────────────────── */

typedef struct TgVec {
    TgVal*  data;
    int64_t len;
    int64_t cap;
} TgVec;

/* Constructors */
TgVal tg_vec_new(void);
TgVal tg_vec_with_capacity(int64_t cap);
TgVal tg_vec_from_array(TgVal* arr, int64_t len);
TgVal tg_vec_clone(TgVal v);
void  tg_vec_free(TgVal v);

/* Properties */
int64_t tg_vec_len(TgVal v);
TgVal   tg_vec_is_empty(TgVal v);

/* Element access */
TgVal tg_vec_get(TgVal v, TgVal idx);
TgVal tg_vec_set(TgVal v, TgVal idx, TgVal val);
TgVal tg_vec_last(TgVal v);

/* Mutation */
TgVal tg_vec_push(TgVal v, TgVal item);
TgVal tg_vec_pop(TgVal v);
TgVal tg_vec_insert(TgVal v, TgVal idx, TgVal item);
TgVal tg_vec_remove(TgVal v, TgVal idx);
TgVal tg_vec_clear(TgVal v);
TgVal tg_vec_truncate(TgVal v, TgVal new_len);
TgVal tg_vec_reverse(TgVal v);
TgVal tg_vec_extend(TgVal v, TgVal other);
TgVal tg_vec_extend_from_slice(TgVal v, TgVal other);

/* Queries */
TgVal tg_vec_contains(TgVal v, TgVal item);

/* Sorting */
TgVal tg_vec_sort(TgVal v);
TgVal tg_vec_sort_by(TgVal v, TgVal cmp_fn);

/* Iteration / functional */
TgVal tg_vec_map(TgVal v, TgVal fn);
TgVal tg_vec_filter(TgVal v, TgVal fn);
TgVal tg_vec_filter_map(TgVal v, TgVal fn);
TgVal tg_vec_any(TgVal v, TgVal fn);
TgVal tg_vec_all(TgVal v, TgVal fn);
TgVal tg_vec_find(TgVal v, TgVal fn);
TgVal tg_vec_enumerate(TgVal v);
TgVal tg_vec_for_each(TgVal v, TgVal fn);
TgVal tg_vec_iter(TgVal v);

/* Join (for Vec[String]) */
TgVal tg_vec_join(TgVal v, TgVal sep);
TgVal tg_vec_collect(TgVal v);

/* ── Map ───────────────────────────────────────────────────────────── */

typedef struct TgMapEntry {
    TgVal   key;
    TgVal   value;
    int64_t hash;
    int     state;  /* 0 = empty, 1 = occupied, 2 = tombstone */
} TgMapEntry;

typedef struct TgMap {
    TgMapEntry* buckets;
    int64_t     capacity;
    int64_t     len;
    int         key_is_string;  /* if 1, keys are TgString* and need string comparison */
} TgMap;

/* Constructors */
TgVal tg_map_new(void);
TgVal tg_map_new_string_keys(void);
TgVal tg_map_clone(TgVal m);
void  tg_map_free(TgVal m);

/* Properties */
int64_t tg_map_len(TgVal m);
TgVal   tg_map_is_empty(TgVal m);

/* Access */
TgVal tg_map_insert(TgVal m, TgVal key, TgVal value);
TgVal tg_map_get(TgVal m, TgVal key);
TgVal tg_map_get_mut(TgVal m, TgVal key);
TgVal tg_map_contains_key(TgVal m, TgVal key);
TgVal tg_map_remove(TgVal m, TgVal key);

/* Iteration */
TgVal tg_map_entries(TgVal m);
TgVal tg_map_keys(TgVal m);
TgVal tg_map_values(TgVal m);

/* ── Set ───────────────────────────────────────────────────────────── */

typedef struct TgSet {
    TgMapEntry* buckets;
    int64_t     capacity;
    int64_t     len;
    int         key_is_string;
} TgSet;

TgVal tg_set_new(void);
TgVal tg_set_new_string_keys(void);
TgVal tg_set_clone(TgVal s);
void  tg_set_free(TgVal s);

int64_t tg_set_len(TgVal s);
TgVal   tg_set_is_empty(TgVal s);

TgVal tg_set_insert(TgVal s, TgVal key);
TgVal tg_set_remove(TgVal s, TgVal key);
TgVal tg_set_contains(TgVal s, TgVal key);
TgVal tg_set_to_vec(TgVal s);
TgVal tg_set_into_vec(TgVal s);

/* ── Option ────────────────────────────────────────────────────────── */

typedef struct TgOption {
    int64_t _tag;      /* 0 = Some, 1 = None  (matches generated enum layout) */
    int64_t _nfields;  /* number of payload fields (for tg_val_eq) */
    TgVal   value;
} TgOption;

TgVal tg_option_some(TgVal val);
TgVal tg_option_none(void);
TgVal tg_option_is_some(TgVal opt);
TgVal tg_option_is_none(TgVal opt);
TgVal tg_option_unwrap(TgVal opt);
TgVal tg_option_unwrap_or(TgVal opt, TgVal default_val);
TgVal tg_option_map(TgVal opt, TgVal fn);

/* ── Result ────────────────────────────────────────────────────────── */

typedef struct TgResult {
    int64_t _tag;      /* 0 = Ok, 1 = Err  (matches generated enum layout) */
    int64_t _nfields;  /* number of payload fields (for tg_val_eq) */
    TgVal   value;
} TgResult;

TgVal tg_result_ok(TgVal val);
TgVal tg_result_err(TgVal err);
TgVal tg_result_is_ok(TgVal res);
TgVal tg_result_is_err(TgVal res);
TgVal tg_result_unwrap(TgVal res);
TgVal tg_result_unwrap_err(TgVal res);
TgVal tg_result_map_err(TgVal res, TgVal fn);

/* ── Box ───────────────────────────────────────────────────────────── */

TgVal tg_box_new(TgVal val);
TgVal tg_box_deref(TgVal bx);
void  tg_box_free(TgVal bx);

/* ── Tuple ─────────────────────────────────────────────────────────── */

TgVal tg_tuple_new2(TgVal a, TgVal b);
TgVal tg_tuple_new3(TgVal a, TgVal b, TgVal c);
TgVal tg_tuple_new4(TgVal a, TgVal b, TgVal c, TgVal d);
TgVal tg_tuple_get(TgVal tup, TgVal idx);

/* ── Closure ───────────────────────────────────────────────────────── */
/* A closure is a pair of (function_pointer, captured_env) */

typedef struct TgClosure {
    TgVal (*fn)(TgVal env, TgVal arg);
    TgVal env;
} TgClosure;

TgVal tg_closure_new(TgVal (*fn)(TgVal, TgVal), TgVal env);
TgVal tg_closure_call1(TgVal closure, TgVal arg);
TgVal tg_closure_call2(TgVal closure, TgVal a1, TgVal a2);

/* ── Dynamic Dispatch (trait objects) ──────────────────────────────── */

typedef struct TgDynObj {
    void*    data;
    TgVal  (*vtable[16])(TgVal self, TgVal a1, TgVal a2, TgVal a3);
} TgDynObj;

TgVal tg_dyn_new(void* data);
TgVal tg_dyn_call(TgVal obj, int method_idx, TgVal a1, TgVal a2, TgVal a3);

/* ── Enum / struct helpers ─────────────────────────────────────────── */

/* Allocate a struct with n fields (all int64_t) */
TgVal tg_struct_alloc(int64_t n_fields);

/* Allocate an enum: tag + n payload fields */
TgVal tg_enum_alloc(int64_t tag, int64_t n_payload);

/* Get/set struct field by index */
TgVal tg_field_get(TgVal obj, int64_t idx);
TgVal tg_field_set(TgVal obj, int64_t idx, TgVal val);

/* Get enum tag */
int64_t tg_enum_tag(TgVal obj);
/* Get enum payload field */
TgVal tg_enum_payload(TgVal obj, int64_t idx);

/* ── I/O ───────────────────────────────────────────────────────────── */

TgVal tg_print(TgVal s);
TgVal tg_println(TgVal s);
TgVal tg_eprint(TgVal s);
TgVal tg_eprintln(TgVal s);
TgVal tg_read_file(TgVal path);
TgVal tg_write_file(TgVal path, TgVal content);

/* ── Process ───────────────────────────────────────────────────────── */

void  tg_exit(TgVal code);
TgVal tg_command_output(TgVal cmd);
TgVal tg_system(TgVal cmd);
TgVal tg_env_var(TgVal name);
TgVal tg_getcwd(void);
TgVal tg_file_exists(TgVal path);

/* ── Global argv for command_line_args ─────────────────────────────── */

void  tg_init(int argc, char** argv);
TgVal tg_args(void);

/* ── Math intrinsics ───────────────────────────────────────────────── */

TgVal tg_intrinsic_pow(TgVal base, TgVal exp);
TgVal tg_intrinsic_to_float(TgVal i);
TgVal tg_intrinsic_to_int(TgVal f);
TgVal tg_abs_int(TgVal i);
TgVal tg_min_int(TgVal a, TgVal b);
TgVal tg_max_int(TgVal a, TgVal b);
TgVal tg_clamp_int(TgVal val, TgVal lo, TgVal hi);

/* ── Hashing ───────────────────────────────────────────────────────── */

int64_t tg_hash_int(TgVal v);
int64_t tg_hash_combine(int64_t h1, int64_t h2);

/* ── Formatting helpers ────────────────────────────────────────────── */

TgVal tg_format_int(TgVal i);
TgVal tg_format_hex(TgVal i);

/* ── Temp file ─────────────────────────────────────────────────────── */

TgVal tg_temp_file(TgVal prefix, TgVal suffix);

/* ── I/O primitives for compiler ───────────────────────────────────── */

TgVal read_line(void);
TgVal read_bytes(TgVal n);
TgVal system_(TgVal cmd);

/* ── Convenience macros for generated code ─────────────────────────── */

#define TG_STRUCT_FIELD(obj, type, field) (((type*)tg_as_ptr(obj))->field)
#define TG_ENUM_TAG(obj) (*((int64_t*)tg_as_ptr(obj)))
#define TG_ENUM_FIELD(obj, idx) (((int64_t*)tg_as_ptr(obj))[1 + (idx)])

#endif /* TG_RUNTIME_H */
