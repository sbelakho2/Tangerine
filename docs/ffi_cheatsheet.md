# Tangerine FFI Quick Reference

A one-page reference card for Tangerine interoperability.

## FFI-Safe Types

| Type | Size | Align | FFI-Safe |
|------|------|-------|----------|
| `i8/u8` | 1 | 1 | ✓ |
| `i16/u16` | 2 | 2 | ✓ |
| `i32/u32` | 4 | 4 | ✓ |
| `i64/u64` | 8 | 8 | ✓ |
| `isize/usize` | 8 | 8 | ✓ |
| `Bool` | 1 | 1 | ✓ |
| `f32` | 4 | 4 | ✓ |
| `f64` | 8 | 8 | ✓ |
| `*T` | 8 | 8 | ✓ |
| `@repr(C)` struct | varies | varies | ✓ |
| `String` | — | — | ✗ use `FfiStr` |
| `Array[T]` | — | — | ✗ use `FfiSlice[T]` |

## Common Patterns

### Export a C Function
```tangerine
@export("my_func")
extern "C" def my_func(x: i32) -> i32
  x * 2
end
```

### FFI-Safe Struct
```tangerine
@repr(C)
struct Point
  x: f64
  y: f64
end
```

### String Parameter
```tangerine
use std::ffi::FfiStr

@export("process")
extern "C" def process(s: FfiStr) -> i32
  # ...
end
```

### Array Parameter
```tangerine
use std::ffi::FfiSlice

@export("sum")
extern "C" def sum(arr: FfiSlice[i32]) -> i64
  # ...
end
```

### Return Errors
```tangerine
use std::ffi::{TgResult, tg_result_ok, tg_result_err}

@export("parse")
extern "C" def parse(s: FfiStr) -> TgResult[i64]
  if valid then
    tg_result_ok(value)
  else
    tg_result_err[i64](1)
  end
end
```

### Owned Memory
```tangerine
@ffi(alloc = "tangerine")
@export("create")
extern "C" def create(size: usize) -> Owned[*mut u8]
  # ...
end
```

### Import C Function
```tangerine
extern "C" {
    def malloc(size: usize) -> *mut u8
    def free(ptr: *mut u8)
}
```

## Ownership Qualifiers

| Qualifier | Meaning | Cleanup |
|-----------|---------|---------|
| `Borrowed[T]` | Temporary borrow | None |
| `Owned[T]` | Ownership transfers | Callee frees |
| `Shared[T]` | Ref-counted/GC | Runtime manages |

## Allocator Domains

| Domain | Attribute | Freed By |
|--------|-----------|----------|
| Tangerine | `@ffi(alloc = "tangerine")` | `tg_free()` |
| C | `@ffi(alloc = "c")` | `free()` |
| Ruby | `@ffi(alloc = "ruby")` | Ruby GC |

## Ruby GC Rules

```tangerine
# Store ruby value → must root
tg_ruby_gc_register(value)

# Release stored value → must unroot
tg_ruby_gc_unregister(value)
```

## CLI Commands

```bash
# Generate C header
tg bindgen c src/lib.tg -o api.h

# Generate Rust shim crate
tg bindgen rust src/lib.tg -o tangerine_shim

# Generate Ruby extension
tg bindgen ruby src/lib.tg -o my_ext

# Validate ABI
tg abi test

# Dump type layouts
tg abi dump src/lib.tg

# Check compatibility
tg abi check old.tg new.tg
```

## Runtime Exports

```c
// Allocation
uint8_t* tg_alloc(size_t size, size_t align);
uint8_t* tg_realloc(uint8_t* ptr, size_t size, size_t align);
void tg_free(uint8_t* ptr, size_t size, size_t align);

// Errors
int32_t tg_last_error_code(void);
tg_str tg_last_error_message(void);

// Version
tg_str tg_abi_edition(void);   // "2026"
int32_t tg_abi_revision(void); // 1
```

## C Type Mappings

| Tangerine | C |
|-----------|---|
| `Int` | `int64_t` |
| `Bool` | `uint8_t` (0/1) |
| `Float` | `double` |
| `FfiStr` | `struct { const uint8_t* ptr; size_t len; }` |
| `FfiSlice[T]` | `struct { const T* ptr; size_t len; }` |
| `TgResult[T]` | `struct { uint8_t ok; int32_t err_code; T value; }` |

## Rust Type Mappings

| Tangerine | Rust |
|-----------|------|
| `Int` | `i64` |
| `Bool` | `u8` |
| `Float` | `f64` |
| `*T` | `*const T` / `*mut T` |
| `FfiStr` | `(*const u8, usize)` |

## Symbol Mangling

```
extern "C"         → no mangling (exact name)
extern "Tangerine" → _TG{edition}_{pkgHash}_{modLen}:{mod}_{nameLen}:{name}_{sigHash}
```

## Error Codes

| Range | Category |
|-------|----------|
| 0 | Success |
| 1-99 | User-defined |
| 100-199 | I/O errors |
| 200-299 | Parse errors |
| 300-399 | Type errors |

## See Also

- [Full Interop Guide](interop.md)
- [Language Reference](language.md)

---

## Real-World FFI Examples

### SQLite Database (from `std/db`)

```tangerine
# FFI declarations
extern "C" {
  def sqlite3_open(filename: *const u8, ppDb: *mut *mut SqliteDb) -> i32
  def sqlite3_close(db: *mut SqliteDb) -> i32
  def sqlite3_exec(
    db: *mut SqliteDb,
    sql: *const u8,
    callback: *const Unit,
    arg: *const Unit,
    errmsg: *mut *mut u8
  ) -> i32
  def sqlite3_prepare_v2(
    db: *mut SqliteDb,
    sql: *const u8,
    nByte: i32,
    ppStmt: *mut *mut SqliteStmt,
    pzTail: *mut *const u8
  ) -> i32
  def sqlite3_step(stmt: *mut SqliteStmt) -> i32
  def sqlite3_finalize(stmt: *mut SqliteStmt) -> i32
  def sqlite3_column_text(stmt: *mut SqliteStmt, col: i32) -> *const u8
  def sqlite3_column_int64(stmt: *mut SqliteStmt, col: i32) -> i64
}

# Usage wrapper
struct Sqlite { handle: *mut SqliteDb }

impl Sqlite
  def open(path: &str) -> Result[Sqlite, DbError]
    let mut handle: *mut SqliteDb = std::ptr::null_mut()
    let path_c = path.as_ptr()
    
    let rc = unsafe { sqlite3_open(path_c, &mut handle) }
    if rc == SQLITE_OK then
      Result::Ok(Sqlite { handle: handle })
    else
      Result::Err(DbError::ConnectionFailed(rc))
    end
  end
end
```

### PostgreSQL (from `std/db`)

```tangerine
extern "C" {
  def PQconnectdb(conninfo: *const u8) -> *mut PGconn
  def PQstatus(conn: *const PGconn) -> i32
  def PQfinish(conn: *mut PGconn)
  def PQexec(conn: *mut PGconn, query: *const u8) -> *mut PGresult
  def PQresultStatus(res: *const PGresult) -> i32
  def PQclear(res: *mut PGresult)
  def PQntuples(res: *const PGresult) -> i32
  def PQgetvalue(res: *const PGresult, row: i32, col: i32) -> *const u8
}
```

### Zlib Compression (from `std/compress`)

```tangerine
extern "C" {
  def deflateInit_(
    strm: *mut ZStream,
    level: i32,
    version: *const u8,
    stream_size: i32
  ) -> i32
  def deflate(strm: *mut ZStream, flush: i32) -> i32
  def deflateEnd(strm: *mut ZStream) -> i32
  def inflateInit_(
    strm: *mut ZStream,
    version: *const u8,
    stream_size: i32
  ) -> i32
  def inflate(strm: *mut ZStream, flush: i32) -> i32
  def inflateEnd(strm: *mut ZStream) -> i32
}

@repr(C)
struct ZStream {
  next_in: *const u8,
  avail_in: u32,
  total_in: u64,
  next_out: *mut u8,
  avail_out: u32,
  total_out: u64,
  msg: *const u8,
  state: *mut Unit,
  zalloc: *const Unit,
  zfree: *const Unit,
  opaque: *const Unit,
  data_type: i32,
  adler: u64,
  reserved: u64,
}
```

### OpenSSL Crypto (from `std/crypto`)

```tangerine
extern "C" {
  # Hashing
  def SHA256(data: *const u8, len: usize, md: *mut u8) -> *mut u8
  def SHA512(data: *const u8, len: usize, md: *mut u8) -> *mut u8
  
  # HMAC
  def HMAC(
    evp_md: *const EVP_MD,
    key: *const u8,
    key_len: i32,
    data: *const u8,
    data_len: usize,
    md: *mut u8,
    md_len: *mut u32
  ) -> *mut u8
  def EVP_sha256() -> *const EVP_MD
  
  # AES
  def AES_set_encrypt_key(key: *const u8, bits: i32, ks: *mut AES_KEY) -> i32
  def AES_cbc_encrypt(
    in_: *const u8,
    out: *mut u8,
    length: usize,
    key: *const AES_KEY,
    iv: *mut u8,
    enc: i32
  )
  
  # Random
  def RAND_bytes(buf: *mut u8, num: i32) -> i32
}
```

### TLS/SSL (from `std/http`)

```tangerine
extern "C" {
  def SSL_library_init() -> i32
  def SSL_CTX_new(method: *const SSL_METHOD) -> *mut SSL_CTX
  def TLS_client_method() -> *const SSL_METHOD
  def SSL_new(ctx: *mut SSL_CTX) -> *mut SSL
  def SSL_set_fd(ssl: *mut SSL, fd: i32) -> i32
  def SSL_connect(ssl: *mut SSL) -> i32
  def SSL_read(ssl: *mut SSL, buf: *mut u8, num: i32) -> i32
  def SSL_write(ssl: *mut SSL, buf: *const u8, num: i32) -> i32
  def SSL_shutdown(ssl: *mut SSL) -> i32
  def SSL_free(ssl: *mut SSL)
  def SSL_CTX_free(ctx: *mut SSL_CTX)
}
```

### Terminal I/O (from `std/cli`)

```tangerine
extern "C" {
  def tcgetattr(fd: i32, termios: *mut Termios) -> i32
  def tcsetattr(fd: i32, action: i32, termios: *const Termios) -> i32
  def ioctl(fd: i32, request: u64, ...) -> i32
  def isatty(fd: i32) -> i32
}

@repr(C)
struct Termios {
  c_iflag: u64,
  c_oflag: u64,
  c_cflag: u64,
  c_lflag: u64,
  c_cc: [u8; 20],
  c_ispeed: u64,
  c_ospeed: u64,
}
```
