# Tangerine Web Development Guide

> **Edition**: 2026 · **Modules**: `std::web`, `std::web_ext`, `std::validation`, `std::opentelemetry`

## Overview

Tangerine provides a production-grade web framework with routing, middleware, templates, authentication, rate limiting, background tasks, graceful shutdown, and observability. The ownership system guarantees memory safety without a garbage collector, making Tangerine web services both fast and reliable.

## Quick Start

### Project Setup

```toml
# Tangerine.toml
[package]
name = "my_api"
version = "0.1.0"
edition = "2026"

[dependencies]
std_web = { path = "std/web" }
std_web_ext = { path = "std/web_ext" }
std_validation = { path = "std/validation" }
std_opentelemetry = { path = "std/opentelemetry" }
```

### Hello World Server

```tangerine
use std::web::{App, Context}

def main() -> Result[Unit, Error]
  let mut app = App.new()

  app.get("/", |ctx: &mut Context| async
    ctx.response.text("Hello, Tangerine!")
    Ok(())
  end)

  app.listen("0.0.0.0:8080").await?
  Ok(())
end
```

## Routing

### Basic Routes

```tangerine
app.get("/users", list_users)
app.post("/users", create_user)
app.put("/users/:id", update_user)
app.delete("/users/:id", delete_user)
app.patch("/users/:id", patch_user)
```

### Path Parameters

```tangerine
app.get("/users/:id/posts/:post_id", |ctx: &mut Context| async
  let user_id = ctx.params.get("id").unwrap()
  let post_id = ctx.params.get("post_id").unwrap()
  ctx.response.json(&get_posts(user_id, post_id).await?)
  Ok(())
end)
```

### Query Parameters

```tangerine
app.get("/search", |ctx: &mut Context| async
  let query = ctx.query.get("q").unwrap_or("".to_string())
  let page: u32 = ctx.query.get("page")
    .and_then(|p| p.parse().ok())
    .unwrap_or(1)
  // ...
  Ok(())
end)
```

### Route Groups

```tangerine
let api = app.group("/api/v1")
api.get("/users", list_users)
api.post("/users", create_user)

let admin = app.group("/admin")
admin.use_middleware(auth_required)
admin.get("/dashboard", dashboard)
```

## Middleware

There is deliberately **no recovery middleware**: the panic state is
ABORT-ONLY (a panic aborts the process; there is no catch/panic-recovery
machinery), so a catch-based recovery middleware cannot be implemented.
The honest recovery policy is process restart by the supervisor.

### Built-in Middleware

```tangerine
use std::web::{Middleware}
use std::web_ext::{
  RateLimiter, RateLimitStrategy, RateLimitKey,
  CorsMiddleware, CorsConfig,
  RequestIdMiddleware,
}

let mut app = App.new()

## CORS
app.use_middleware(CorsMiddleware.new(CorsConfig.permissive()))

## Request ID tracking
app.use_middleware(RequestIdMiddleware.new())

## Rate limiting: 100 requests/minute per IP
app.use_middleware(RateLimiter.new(
  RateLimitStrategy.FixedWindow {
    max_requests: 100,
    window: Duration.from_secs(60),
  },
  RateLimitKey.IpAddress,
))
```

### Custom Middleware

```tangerine
use std::web::{Context, Middleware, MiddlewareResult}

struct LoggingMiddleware end

impl Middleware for LoggingMiddleware
  async def call(self, ctx: &mut Context, next: fn(&mut Context) -> MiddlewareResult) -> MiddlewareResult
    let start = Instant.now()
    let method = ctx.request.method().to_string()
    let path = ctx.request.path().to_string()

    let result = next(ctx).await

    let elapsed = start.elapsed()
    println("{method} {path} - {status} ({elapsed:?})",
      status = ctx.response.status_code())

    result
  end
end
```

## Request Validation

```tangerine
use std::validation::{Validate, Required, MinLength, Email, Range}

struct CreateUserRequest
  @[validate(Required, MinLength(3))]
  pub username: String

  @[validate(Required, Email)]
  pub email: String

  @[validate(Range(18, 120))]
  pub age: u32
end

app.post("/users", |ctx: &mut Context| async
  let body: CreateUserRequest = ctx.request.json()?
  let errors = body.validate()
  if errors.has_errors() then
    ctx.response.status(422).json(&errors.to_json())
    return Ok(())
  end
  ## Process valid request...
  Ok(())
end)
```

## Authentication

### JWT Authentication

```tangerine
use std::web::auth::{JwtConfig, JwtMiddleware, Claims}

let jwt_config = JwtConfig {
  secret: "your-secret-key".to_string(),
  algorithm: Algorithm.HS256,
  expiration: Duration.from_hours(24),
}

## Protect routes
app.use_middleware(JwtMiddleware.new(jwt_config.clone()))

## Issue tokens
app.post("/login", |ctx: &mut Context| async
  let creds: LoginRequest = ctx.request.json()?
  if authenticate(&creds).await? then
    let claims = Claims.new()
      .subject(creds.username)
      .expires_in(Duration.from_hours(24))
    let token = jwt_config.encode(&claims)?
    ctx.response.json(&LoginResponse { token })
  else
    ctx.response.status(401).json(&Error { message: "invalid credentials" })
  end
  Ok(())
end)
```

### Session Authentication

```tangerine
use std::web::auth::{SessionConfig, SessionMiddleware}

let session_config = SessionConfig {
  cookie_name: "session_id".to_string(),
  max_age: Duration.from_hours(24),
  secure: true,
  http_only: true,
  same_site: SameSite.Strict,
}

app.use_middleware(SessionMiddleware.new(session_config))

app.get("/profile", |ctx: &mut Context| async
  let session = ctx.session()?
  let user_id = session.get("user_id")
    .ok_or(Error.unauthorized("not logged in"))?
  // ...
  Ok(())
end)
```

## File Uploads

### Multipart Form Handling

```tangerine
use std::web_ext::{parse_multipart, MultipartConfig}

let upload_config = MultipartConfig {
  max_body_size: 50 * 1024 * 1024,  ## 50 MB
  max_file_size: 10 * 1024 * 1024,  ## 10 MB per file
  max_parts: 20,
  allowed_content_types: Some(vec![
    "image/jpeg", "image/png", "image/webp", "application/pdf",
  ].map(String::from)),
}

app.post("/upload", |ctx: &mut Context| async
  let parts = parse_multipart(ctx, &upload_config)?

  for part in parts.iter() do
    if part.is_file() then
      let filename = part.filename.as_ref().unwrap()
      let save_path = format!("uploads/{}", filename)
      part.save_to(&save_path)?
      println("Saved: {} ({} bytes)", filename, part.size())
    end
  end

  ctx.response.json(&UploadResponse { count: parts.len() })
  Ok(())
end)
```

## Background Tasks

```tangerine
use std::web_ext::{TaskPool, TaskPriority}

let pool = TaskPool.new(4)  ## 4 worker threads

app.post("/reports", |ctx: &mut Context| async
  let params: ReportRequest = ctx.request.json()?

  let handle = pool.submit(TaskPriority.Normal, move ||
    let report = generate_report(&params)
    save_report(&report)
    send_notification(&params.email, &report)
  end)

  ctx.response.status(202).json(&TaskAccepted {
    task_id: handle.id(),
    message: "Report generation started",
  })
  Ok(())
end)

## Check task status
app.get("/tasks/:id", |ctx: &mut Context| async
  let id: u64 = ctx.params.get("id").unwrap().parse()?
  let status = get_task_status(id)
  ctx.response.json(&status)
  Ok(())
end)
```

## Graceful Shutdown

```tangerine
use std::web_ext::{GracefulShutdown, install_signal_handler}

let shutdown = Arc.new(GracefulShutdown.new(Duration.from_secs(30)))
install_signal_handler(shutdown.clone())

## Register cleanup hooks
shutdown.on_shutdown(Box.new(||
  println("Closing database connections...")
  db_pool.close()
))

shutdown.on_shutdown(Box.new(||
  println("Flushing telemetry...")
  tracer_provider.shutdown()
))

## Start server with shutdown awareness
app.listen_with_shutdown("0.0.0.0:8080", shutdown).await?
```

## Health Checks

```tangerine
use std::web_ext::{add_health_checks, HealthCheck, HealthStatus}

add_health_checks(&mut app, vec![
  HealthCheck {
    name: "database".to_string(),
    check: || match db_pool.ping()
      Ok(_) => HealthStatus.Healthy
      Err(e) => HealthStatus.Unhealthy(e.to_string())
    end,
  },
  HealthCheck {
    name: "redis".to_string(),
    check: || match redis.ping()
      Ok(_) => HealthStatus.Healthy
      Err(e) => HealthStatus.Degraded(e.to_string())
    end,
  },
])
```

This registers `/health`, `/health/ready`, and `/health/live` endpoints.

## Observability

### OpenTelemetry Integration

```tangerine
use std::opentelemetry::{
  TracerProvider, OtlpHttpSpanExporter, Sampler,
  Counter, HistogramMetric,
}

## Setup tracing
let exporter = OtlpHttpSpanExporter.new("http://otel-collector:4318/v1/traces")?
let provider = TracerProvider.builder()
  .with_exporter(exporter)
  .with_sampler(Sampler.trace_id_ratio(0.1))  ## 10% sampling
  .with_resource("my-api", "1.0.0")
  .build()

let tracer = provider.tracer("http")

## Add tracing middleware
app.use_middleware(OtelMiddleware.new(tracer))

## Custom metrics
let request_counter = Counter.new("http_requests_total", "Total HTTP requests")
let latency_histogram = HistogramMetric.new("http_request_duration_seconds", "Request latency")
```

## Rate Limiting Strategies

| Strategy | Use Case | Behavior |
|----------|----------|----------|
| `FixedWindow` | Simple API limits | N requests per time window |
| `SlidingWindow` | Smoother limiting | Sliding window log |
| `TokenBucket` | Burst-friendly | Steady rate with burst capacity |
| `LeakyBucket` | Steady output | Fixed output rate |

```tangerine
## Per-API-key rate limiting
app.use_middleware(RateLimiter.new(
  RateLimitStrategy.TokenBucket { rate: 50.0, burst: 100 },
  RateLimitKey.Header("X-API-Key".to_string()),
))

## Per-route rate limiting
let login_limiter = RateLimiter.new(
  RateLimitStrategy.FixedWindow {
    max_requests: 5,
    window: Duration.from_secs(300),  ## 5 attempts per 5 minutes
  },
  RateLimitKey.IpAddress,
)
app.post("/login", login_limiter.wrap(login_handler))
```

## Database Integration

```tangerine
use std::db::{Pool, PoolConfig}

let pool = Pool.connect(PoolConfig {
  url: "postgres://user:pass@localhost/mydb",
  max_connections: 20,
  min_connections: 5,
  idle_timeout: Duration.from_secs(300),
}).await?

app.state(pool.clone())

app.get("/users/:id", |ctx: &mut Context| async
  let id: i64 = ctx.params.get("id").unwrap().parse()?
  let pool = ctx.state.get::<Pool>()?
  let user = pool.query_one("SELECT * FROM users WHERE id = $1", &[&id]).await?
  ctx.response.json(&user)
  Ok(())
end)
```

## Deployment

### Production Checklist

- [ ] Enable TLS (use a reverse proxy or native TLS)
- [ ] Set `mode = "production"` in Tangerine.toml
- [ ] Configure rate limiting on public endpoints
- [ ] Enable health check endpoints
- [ ] Set up OpenTelemetry export
- [ ] Configure graceful shutdown with appropriate timeout
- [ ] Enable CORS with specific origins (not `*`)
- [ ] Set secure cookie flags (httpOnly, secure, sameSite)
- [ ] Run with `--release` optimization

### Docker

```dockerfile
FROM tangerine:latest AS builder
WORKDIR /app
COPY . .
RUN tg build --release

FROM debian:bookworm-slim
COPY --from=builder /app/target/release/my_api /usr/local/bin/
EXPOSE 8080
CMD ["my_api"]
```

## See Also

- [std/web.tg](../std/web.tg) — Core web framework API
- [std/web_ext.tg](../std/web_ext.tg) — Extensions (rate limiting, CORS, etc.)
- [std/validation.tg](../std/validation.tg) — Validation framework
- [std/opentelemetry.tg](../std/opentelemetry.tg) — Observability
- [examples/web_service.tg](../examples/web_service.tg) — Full example
