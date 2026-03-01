# Tangerine Style Guide

This document defines the canonical formatting and naming conventions for Tangerine
source code. The `tg fmt` tool enforces these rules automatically.

## Naming Conventions

### Functions and Variables

Use `snake_case` for all function names, variable names, and parameter names.

```tangerine
def calculate_total(item_count: Int, price_per_unit: Float) -> Float
  let total_price = item_count.to_float() * price_per_unit
  total_price
end
```

### Types and Traits

Use `PascalCase` for struct names, enum names, trait names, and type aliases.

```tangerine
struct HttpRequest
  url: String
  method: HttpMethod
  headers: Map[String, String]
end

enum HttpMethod
  Get
  Post
  Put
  Delete
end

trait Serializable
  def serialize(self) -> Vec[u8]
end
```

### Enum Variants

Use `PascalCase` for enum variants.

```tangerine
enum Color
  Red
  Green
  Blue
  Custom(r: u8, g: u8, b: u8)
end
```

### Constants

Use `SCREAMING_SNAKE_CASE` for module-level constants.

```tangerine
const MAX_BUFFER_SIZE: UInt = 65536
const DEFAULT_TIMEOUT_MS: Int = 5000
```

### Module and File Names

Use `snake_case` for file names and module names: `my_module.tg`.

## Formatting Rules

### Indentation

Use **2 spaces** per indentation level. Never use tabs.

```tangerine
def example() -> Unit
  if condition then
    do_something()
  else
    do_other()
  end
end
```

### Line Length

Maximum **100 characters** per line. Break long expressions at logical points:

```tangerine
# Good: break before operators
let result = very_long_variable_name
  + another_long_variable
  * scaling_factor

# Good: break after opening paren for function calls
let output = transform(
  input_data,
  config.max_iterations,
  config.tolerance
)
```

### Braces and Blocks

Tangerine uses `end` to close blocks. The `end` keyword aligns with the opening keyword:

```tangerine
def process(items: &Vec[Item]) -> Result[Summary, Error]
  for item in items do
    match item.kind
    when ItemKind::Simple then
      handle_simple(item)
    when ItemKind::Complex(ref data) then
      handle_complex(data)
    end
  end
  
  Result::Ok(Summary::new())
end
```

### Blank Lines

- **Two** blank lines between top-level definitions (functions, structs, enums).
- **One** blank line to separate logical sections within a function.
- **No** trailing blank lines at end of file.
- **One** newline at end of file.

### Trailing Whitespace

No trailing whitespace on any line.

### Imports

Group imports in this order, separated by blank lines:

1. Standard library imports (`std/`)
2. Third-party package imports
3. Local project imports

```tangerine
use std::collections::HashMap
use std::io::File

use http::Request
use json::Value

use crate::config::Config
use crate::handler::Handler
```

Sort imports alphabetically within each group.

### Function Signatures

- Short signatures on one line.
- Long signatures: break after `(`, one parameter per line, `)` on its own line.

```tangerine
# Short — fits on one line
def add(a: Int, b: Int) -> Int

# Long — break across lines
def create_connection(
  host: String,
  port: UInt,
  timeout_ms: Int,
  tls_config: Option[TlsConfig]
) -> Result[Connection, IoError]
```

### Match Expressions

Align `when` clauses with the `match`:

```tangerine
match value
when Pattern::First then
  handle_first()
when Pattern::Second(x) then
  handle_second(x)
when _ then
  handle_default()
end
```

Single-expression arms may be on the same line:

```tangerine
match color
when Color::Red then 0xFF0000
when Color::Green then 0x00FF00
when Color::Blue then 0x0000FF
end
```

### Comments

- Use `#` for line comments. Place a space after `#`.
- Use `##` for doc comments (parsed by `tg doc`).
- Comments should explain *why*, not *what*.

```tangerine
## Sorts the list using an adaptive merge sort.
##
## Time complexity: O(n log n) worst case.
## Space complexity: O(n) auxiliary.
def sort[T: Ord](list: &mut Vec[T]) -> Unit
  # Use insertion sort for small lists — faster due to cache locality
  if list.len() <= 32 then
    insertion_sort(list)
    return
  end
  
  merge_sort(list)
end
```

### Struct Initialization

```tangerine
# Short structs on one line
let point = Point { x: 10, y: 20 }

# Longer structs across multiple lines
let config = ServerConfig {
  host: "0.0.0.0".to_string(),
  port: 8080,
  max_connections: 1024,
  tls: Option::None
}
```

### Error Handling

Prefer `?` operator for propagation. Use `match` only when you need to transform the error:

```tangerine
# Good: propagate with ?
def read_config(path: String) -> Result[Config, Error]
  let content = read_file(path)?
  let config = parse_toml(&content)?
  Result::Ok(config)
end

# Good: transform error
def load_data() -> Result[Data, AppError]
  match fetch_remote()
  when Result::Ok(raw) then parse(raw)
  when Result::Err(e) then Result::Err(AppError::Network(e))
  end
end
```

### Unsafe Code

Every `unsafe` block must have a `# SAFETY:` comment:

```tangerine
# SAFETY: `ptr` was allocated by our allocator and has not been freed.
# The alignment is guaranteed by the alloc call above.
unsafe
  let value = *ptr
end
```

## Anti-Patterns

### Avoid

- Single-letter variable names (except `i`, `j`, `k` for loop indices, `x`, `y` for coordinates).
- Nested `match` deeper than 3 levels — extract helper functions.
- Functions longer than 100 lines — split into smaller units.
- `mut` on variables that are never mutated.
- Returning `Unit` explicitly when it can be omitted.
- Empty `else` branches — just omit them.

### Prefer

- Iterator methods (`map`, `filter`, `fold`) over manual loops when clearer.
- Named constants over magic numbers.
- Early returns to reduce nesting.
- Descriptive variable names over comments that explain variable purpose.

## Standard Library Idioms

### Serialization

```tangerine
use std::serde::{Serialize, Deserialize}
use std::json::Json

@derive(Serialize, Deserialize)
struct Config
  host: String
  port: Int
end

# Use ? for error propagation
let config: Config = Json::parse(&json_str)?
let output = Json::stringify(&config)
```

### HTTP Requests

```tangerine
use std::http::HttpClient

let client = HttpClient::new()
let response = client.get("https://api.example.com/data")?

if response.status().is_success() then
  let body = response.text()?
  process(body)
end
```

### Database Access

```tangerine
use std::db::{Sqlite, Connection}

let db = Sqlite::open("app.db")?

# Use parameterized queries — never string interpolation
db.execute_params("INSERT INTO users (name, age) VALUES (?, ?)", (name, age))?

# Use QueryBuilder for complex queries
let query = QueryBuilder::new()
  .select("*")
  .from("users")
  .where_clause("active = ?")
  .order_by("name")
```

### Web Framework

```tangerine
use std::web::{App, Context, middleware}

let app = App::new()

# Chain middleware
app.middleware(middleware::logger)
app.middleware(middleware::cors)

# Route handlers return HttpResponse
app.get("/users/:id", |ctx: &mut Context| {
  let id = ctx.param("id").unwrap_or("0")
  ctx.json_response(&get_user(id)?)
})
```

### Cryptography

```tangerine
use std::crypto::{sha256, random_bytes, base64}

# Generate secure random data
let key = random_bytes(32)
let iv = random_bytes(16)

# Hash sensitive data
let password_hash = sha256(password.as_bytes())

# Always use constant-time comparison for security-sensitive checks
let valid = crypto::constant_time_eq(&stored_hash, &computed_hash)
```

### Logging

```tangerine
use std::log::{Logger, Level, info, warn, error}

# Initialize once at startup
Logger::init(Level::Info)

# Use structured fields
info!("Request processed", user_id: user.id, duration_ms: elapsed.as_millis())
warn!("Connection pool low", available: pool.available(), total: pool.size())
error!("Database error", error: e.to_string())
```

## See Also

- [Language Reference](language.md) - Language syntax and semantics
- [Interoperability Guide](interop.md) - FFI conventions
- [Grammar Specification](grammar.md) - Formal grammar
