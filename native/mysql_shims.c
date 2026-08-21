/*
 * Tangerine std::db — MySQL native shim (mysql_shims.c)
 *
 * In-repository implementation of the tg_mysql_* extern family declared
 * in std/db.tg. The Tangerine module NO LONGER hand-writes the
 * st_mysql_bind (MYSQL_BIND) layout: every call that must touch a real
 * MYSQL_BIND lives HERE, compiled against the real mysql.h, and
 * manipulates the real struct internally. The Tangerine side passes only
 * its own stable, layout-probed descriptors:
 *
 *   tg_mysql_param          — one parameter: type (0 = SQL NULL, 1 =
 *                             text, 2 = blob), the payload pointer, the
 *                             byte length
 *   tg_mysql_result_cell    — one result column: the output buffer, its
 *                             capacity, the length/is_null out cells, the
 *                             MYSQL_TYPE_* value
 *
 *   - tg_mysql_stmt_bind_and_execute: builds the MYSQL_BIND array from
 *     the parameter descriptors (with per-parameter length/is_null
 *     cells), runs mysql_stmt_bind_param + mysql_stmt_execute, and frees
 *     the array — the descriptor payloads stay owned by the Tangerine
 *     side for the call's duration.
 *   - tg_mysql_stmt_bind_result: builds the MYSQL_BIND array from the
 *     result cells (the client writes the fetched values into the
 *     Tangerine-owned buffers and length/is_null cells).
 *   - tg_mysql_stmt_fetch_column: the large-value refetch — builds a
 *     ONE-OFF MYSQL_BIND from the cell's CURRENT buffer/capacity (the
 *     Tangerine side resized its buffer and updated the descriptor
 *     before calling) and runs mysql_stmt_fetch_column.
 *   - tg_mysql_layout_probe: prints and returns the C-side
 *     sizeof/_Alignof/offsetof facts of MYSQL_BIND, MYSQL_FIELD,
 *     tg_mysql_param and tg_mysql_result_cell; the Tangerine layout
 *     probe test asserts its @repr(C) layouts against those facts.
 *
 * Build (CI, .github/workflows/ci.yml db-integration-mysql job):
 *   cc -fPIC -shared -o build/libtg_mysql_shims.dylib native/mysql_shims.c \
 *     -I"$(brew --prefix mysql)/include/mysql" \
 *     -L"$(brew --prefix mysql)/lib" -lmysqlclient
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stddef.h>

#include <mysql.h>

/* The Tangerine-facing parameter descriptor — the layout is probed. */
typedef struct tg_mysql_param {
  int type;                 /* 0 = SQL NULL, 1 = text, 2 = blob */
  const unsigned char *data;
  unsigned long len;
} tg_mysql_param;

/* The Tangerine-facing result cell — the layout is probed. */
typedef struct tg_mysql_result_cell {
  unsigned char *buffer;
  unsigned long capacity;
  unsigned long *length;
  unsigned char *is_null;
  int type;
} tg_mysql_result_cell;

#define TG_MYSQL_PARAM_NULL  0
#define TG_MYSQL_PARAM_TEXT  1
#define TG_MYSQL_PARAM_BLOB  2

/* ————————————————————————————————————————————————————————————
 * The layout probe
 * ———————————————————————————————————————————————————————————— */

int tg_mysql_layout_probe(long long *out, unsigned long out_len) {
  static const long long facts[] = {
    (long long)sizeof(MYSQL_BIND),
    (long long)_Alignof(MYSQL_BIND),
    (long long)offsetof(MYSQL_BIND, length),
    (long long)offsetof(MYSQL_BIND, is_null),
    (long long)offsetof(MYSQL_BIND, buffer),
    (long long)offsetof(MYSQL_BIND, buffer_length),
    (long long)offsetof(MYSQL_BIND, buffer_type),
    (long long)offsetof(MYSQL_BIND, is_unsigned),
    (long long)sizeof(struct tg_mysql_param),
    (long long)_Alignof(struct tg_mysql_param),
    (long long)offsetof(struct tg_mysql_param, type),
    (long long)offsetof(struct tg_mysql_param, data),
    (long long)offsetof(struct tg_mysql_param, len),
    (long long)sizeof(struct tg_mysql_result_cell),
    (long long)_Alignof(struct tg_mysql_result_cell),
    (long long)offsetof(struct tg_mysql_result_cell, buffer),
    (long long)offsetof(struct tg_mysql_result_cell, capacity),
    (long long)offsetof(struct tg_mysql_result_cell, length),
    (long long)offsetof(struct tg_mysql_result_cell, is_null),
    (long long)offsetof(struct tg_mysql_result_cell, type),
    (long long)sizeof(MYSQL_FIELD),
    (long long)offsetof(MYSQL_FIELD, name),
    (long long)offsetof(MYSQL_FIELD, type)
  };
  enum { FACTS_LEN = (int)(sizeof(facts) / sizeof(facts[0])) };
  if (out == NULL || out_len < (unsigned long)FACTS_LEN) {
    return -1;
  }
  for (int i = 0; i < FACTS_LEN; i++) {
    out[i] = facts[i];
  }
  printf("tg_mysql_layout_probe: sizeof(MYSQL_BIND)=%lld align=%lld "
         "length@%lld is_null@%lld buffer@%lld buffer_length@%lld "
         "buffer_type@%lld is_unsigned@%lld\n",
         facts[0], facts[1], facts[2], facts[3], facts[4], facts[5],
         facts[6], facts[7]);
  printf("tg_mysql_layout_probe: tg_mysql_param sizeof=%lld align=%lld "
         "type@%lld data@%lld len@%lld\n",
         facts[8], facts[9], facts[10], facts[11], facts[12]);
  printf("tg_mysql_layout_probe: tg_mysql_result_cell sizeof=%lld "
         "align=%lld buffer@%lld capacity@%lld length@%lld is_null@%lld "
         "type@%lld\n",
         facts[13], facts[14], facts[15], facts[16], facts[17], facts[18],
         facts[19]);
  printf("tg_mysql_layout_probe: sizeof(MYSQL_FIELD)=%lld name@%lld "
         "type@%lld\n", facts[20], facts[21], facts[22]);
  return FACTS_LEN;
}

/* ————————————————————————————————————————————————————————————
 * The parameter binding + execute
 * ———————————————————————————————————————————————————————————— */

int tg_mysql_stmt_bind_and_execute(void *stmt, const tg_mysql_param *params,
                                   unsigned long count) {
  if (count == 0) {
    return mysql_stmt_execute((MYSQL_STMT *)stmt);
  }
  MYSQL_BIND *binds = (MYSQL_BIND *)calloc(count, sizeof(MYSQL_BIND));
  if (binds == NULL) return 1;
  unsigned long *lengths = (unsigned long *)calloc(count, sizeof(unsigned long));
  my_bool *nulls = (my_bool *)calloc(count, sizeof(my_bool));
  if (lengths == NULL || nulls == NULL) {
    free(binds);
    free(lengths);
    free(nulls);
    return 1;
  }
  int rc = 0;
  for (unsigned long i = 0; i < count; i++) {
    MYSQL_BIND *b = &binds[i];
    const tg_mysql_param *p = &params[i];
    b->length = &lengths[i];
    b->is_null = &nulls[i];
    if (p->type == TG_MYSQL_PARAM_NULL) {
      b->buffer_type = MYSQL_TYPE_NULL;
      b->buffer = NULL;
      b->buffer_length = 0;
      nulls[i] = 1;
    } else {
      b->buffer_type = (p->type == TG_MYSQL_PARAM_BLOB)
        ? MYSQL_TYPE_BLOB : MYSQL_TYPE_STRING;
      b->buffer = (void *)p->data;
      b->buffer_length = p->len;
      lengths[i] = p->len;
    }
  }
  rc = mysql_stmt_bind_param((MYSQL_STMT *)stmt, binds);
  if (rc == 0) {
    rc = mysql_stmt_execute((MYSQL_STMT *)stmt);
  }
  free(nulls);
  free(lengths);
  free(binds);
  return rc;
}

/* ————————————————————————————————————————————————————————————
 * The result binding
 * ———————————————————————————————————————————————————————————— */

int tg_mysql_stmt_bind_result(void *stmt, const tg_mysql_result_cell *cells,
                              unsigned long count) {
  if (count == 0) return 0;
  MYSQL_BIND *binds = (MYSQL_BIND *)calloc(count, sizeof(MYSQL_BIND));
  if (binds == NULL) return 1;
  for (unsigned long i = 0; i < count; i++) {
    MYSQL_BIND *b = &binds[i];
    const tg_mysql_result_cell *c = &cells[i];
    b->buffer_type = (enum enum_field_types)c->type;
    b->buffer = c->buffer;
    b->buffer_length = c->capacity;
    b->length = c->length;
    b->is_null = (my_bool *)c->is_null;
  }
  int rc = mysql_stmt_bind_result((MYSQL_STMT *)stmt, binds);
  free(binds);
  return rc;
}

/* ————————————————————————————————————————————————————————————
 * The large-value refetch (mysql_stmt_fetch_column)
 * ———————————————————————————————————————————————————————————— */

int tg_mysql_stmt_fetch_column(void *stmt, const tg_mysql_result_cell *cell,
                               unsigned long column, unsigned long offset) {
  if (cell == NULL || cell->buffer == NULL) return 1;
  MYSQL_BIND bind;
  memset(&bind, 0, sizeof(bind));
  bind.buffer_type = (enum enum_field_types)cell->type;
  bind.buffer = cell->buffer;
  bind.buffer_length = cell->capacity;
  bind.length = cell->length;
  bind.is_null = (my_bool *)cell->is_null;
  return mysql_stmt_fetch_column((MYSQL_STMT *)stmt, &bind,
                                 (unsigned int)column, offset);
}
