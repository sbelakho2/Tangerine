# Performance Budgets and Targets — TG-GFX-UI-SPEC-001 v0.1

> Normative reference for §23.1 of the graphics/UI development checklist.

## 1. Frame-Time Budgets

All budgets assume a single-window application with typical widget-tree complexity
(≤ 500 visible widgets, ≤ 50 draw calls per frame).

| Refresh Rate | Resolution       | Frame Budget | Draw Budget¹ | Compositor Budget | Present Budget |
|-------------|------------------|-------------|-------------|-------------------|----------------|
| 60 Hz       | 1920 × 1080      | 16.67 ms    | ≤ 10 ms     | ≤ 3 ms            | ≤ 2 ms         |
| 60 Hz       | 3840 × 2160 (4K) | 16.67 ms    | ≤ 12 ms     | ≤ 3 ms            | ≤ 2 ms         |
| 120 Hz      | 1920 × 1080      | 8.33 ms     | ≤ 5 ms      | ≤ 1.5 ms          | ≤ 1 ms         |
| 120 Hz      | 3840 × 2160 (4K) | 8.33 ms     | ≤ 6 ms      | ≤ 1.5 ms          | ≤ 1 ms         |

¹ Draw budget = `begin_frame` → all `Canvas` calls → `end_frame`, excluding present.

**Rule:** 95th-percentile frame time must stay within the frame budget on reference
hardware. 99th-percentile may exceed by up to 50 % but must never exceed 2× budget.

## 2. Startup-Time Budget

| Phase                    | Budget   | Notes                                      |
|--------------------------|----------|--------------------------------------------|
| Plugin discovery + load  | ≤ 50 ms  | Includes manifest parse + SO/DLL load      |
| Interface validation     | ≤ 10 ms  | Required + optional interface queries       |
| First window creation    | ≤ 100 ms | Includes backend surface allocation         |
| First frame rendered     | ≤ 200 ms | Total from `main()` to first `present`     |

**Rule:** Cold-start (no caches) on reference hardware must render the first frame
within 200 ms. Warm-start (OS FS cache hot) within 150 ms.

## 3. Text Layout Throughput Targets

| Workload                      | Target              | Notes                          |
|-------------------------------|---------------------|--------------------------------|
| Simple Latin paragraph (200 chars) | ≥ 10 000 layouts/s | Single-threaded                |
| Complex script (Arabic, 200 chars) | ≥ 5 000 layouts/s  | Single-threaded, with shaping  |
| Glyph cache hit rate          | ≥ 95 %              | Steady-state after warm-up     |
| Font fallback resolution      | ≤ 5 ms per miss     | Cold miss, single font family  |

## 4. Image Decode/Upload Throughput Targets

| Operation               | Target                  | Notes                               |
|--------------------------|-------------------------|-------------------------------------|
| PNG decode (1024 × 1024) | ≥ 30 images/s           | RGBA8, reference decoder            |
| PNG encode (1024 × 1024) | ≥ 20 images/s           | RGBA8, reference encoder            |
| Bitmap → surface upload   | ≤ 2 ms per 1024 × 1024  | Software backend; GPU may differ    |
| Image cache hit           | ≤ 0.1 ms               | Content-addressable lookup          |

## 5. Memory Budgets

| Subsystem               | Budget (per window) | Notes                                    |
|--------------------------|---------------------|------------------------------------------|
| UI widget tree           | ≤ 4 MiB             | 500 widgets, average 8 KiB each          |
| Glyph cache              | ≤ 16 MiB            | LRU eviction when full                   |
| Image cache              | ≤ 32 MiB            | Content-addressable, LRU eviction        |
| Compositor layer cache   | ≤ 8 MiB             | Damage-tracked layers                    |
| Path tessellation cache  | ≤ 4 MiB             | Reused across frames                     |
| **Total per window**     | **≤ 64 MiB**        | Soft limit; exceeding triggers eviction  |

**Rule:** Memory usage must be monotonically bounded — no unbounded growth over time.
Cache eviction must keep usage within budget under steady-state workloads.

## 6. Measurement and Enforcement

- All budgets are verified by CI performance benchmarks (see §22 CI jobs).
- Regressions exceeding 10 % of budget trigger automatic CI failure.
- Budget exceptions require ADR approval and documented workaround timeline.
- Budgets are reviewed and updated each release cycle per §33.
