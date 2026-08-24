<p align="center">
  <img src="../FractalSQLforPostgreSQL.jpg" alt="FractalSQL for PostgreSQL" width="720">
</p>

# Discovery API Reference

The Discovery tier provides high-precision and diverse retrieval mechanisms. Unlike traditional vector search, it treats the embedding space as a continuous optimization problem.

---

## `fractal_search`
**Sniper Mode Convergence**

Converges to the single best point minimizing cosine distance to a query over the unit box $[-1, 1]^d$. It is a precision tool for finding the absolute global minimum.

### Signature
```sql
fractal_search(
    query            float8[],
    iterations       int4 DEFAULT 30,
    population_size  int4 DEFAULT 50,
    diffusion_factor int4 DEFAULT 2
) RETURNS float8[]
```

### Arguments
| Argument | Type | Default | Range | Description |
| --- | --- | --- | --- | --- |
| `query` | `float8[]` | (Required) | — | The target vector to converge toward. |
| `iterations` | `int4` | `30` | 1–10,000 | Number of SFS generations to run. |
| `population_size` | `int4` | `50` | 1–100,000 | Number of particles per generation. |
| `diffusion_factor` | `int4` | `2` | 1–32 | SFS MDN (walk-per-particle count). |

---

## `fractal_search_debug`
**Sniper Mode with Trajectory Trace**

Identical signature to `fractal_search`, but returns a detailed trace of the convergence process.

### Signature
```sql
fractal_search_debug(
    query            float8[],
    iterations       int4 DEFAULT 30,
    population_size  int4 DEFAULT 50,
    diffusion_factor int4 DEFAULT 2
) RETURNS jsonb
```

### Return Value
Returns a JSONB document with the following keys:
- `dim`: Vector dimensionality.
- `generations`: Total iterations run.
- `population_size`: Particles per generation.
- `best_point`: The final converged vector.
- `best_fit`: Final cosine distance.
- `best_fit_per_gen`: Array of best fits across all generations.
- `paths`: Full particle trajectories for visualization.

---

## `fractal_search_explore`
**Scout Discovery Mode**

Scans a stored corpus and returns a diverse population of results. It uses a brute-force relevance scan followed by **Maximal Marginal Relevance (MMR)** to prevent "mode collapse."

### Signature
```sql
fractal_search_explore(
    table_name  text,
    vector_col  text,
    query       float8[],
    options     jsonb DEFAULT '{}'::jsonb
) RETURNS SETOF float8[]
```

### Arguments
| Argument | Type | Default | Description |
| --- | --- | --- | --- |
| `table_name` | `text` | (Required) | The table containing the embeddings. |
| `vector_col` | `text` | (Required) | The `float8[]` or `fractal_vector` column. |
| `query` | `float8[]` | (Required) | The target vector for relevance scoring. |
| `options` | `jsonb` | `{}` | Tuning parameters (see below). |

### Options (jsonb keys)
| Key | Type | Default | Range | Description |
| --- | --- | --- | --- | --- |
| `population_size` | `int` | `50` | — | Number of results to return. |
| `mmr_lambda` | `float` | `0.5` | $[0, 1]$ | Tradeoff between relevance ($1.0$) and diversity ($0.0$). Lower it when a query lands inside a dense cluster. |
| `iterations` | `int` | — | — | (Backward compatibility) No effect on Scout output. |
| `diffusion_factor` | `int` | — | — | (Backward compatibility) No effect on Scout output. |

---

## `fractal_search_telemetry`
**Ground-Truth Row Retrieval**

A deterministic primitive that returns the $K$ nearest real table rows to a query. This is the foundation for all higher-order agency functions.

### Signature
```sql
fractal_search_telemetry(
    table_name  text,
    vector_col  text,
    query       float8[],
    k           int4
) RETURNS TABLE(doc_id int8, distance float8)
```

### Arguments
| Argument | Type | Description |
| --- | --- | --- |
| `table_name` | `text` | The table containing the embeddings. |
| `vector_col` | `text` | The `float8[]` or `fractal_vector` column. |
| `query` | `float8[]` | The target vector. |
| `k` | `int4` | Number of nearest neighbors to return. |

---

## `fractal_hybrid_clinical_search`
**Cohort-Restricted Telemetry**

Wraps `fractal_search_telemetry` but restricts the search to a specific subset of documents.

### Signature
```sql
fractal_hybrid_clinical_search(
    table_name  text,
    vector_col  text,
    query       float8[],
    doc_ids     int8[],
    k           int4
) RETURNS TABLE(doc_id int8, distance float8)
```

### Arguments
| Argument | Type | Description |
| --- | --- | --- |
| `doc_ids` | `int8[]` | The subset of row indices to search. Must be computed via SQL (e.g., `SELECT array_agg(...)`). |

---

## `fractal_search_trajectory`
**Drift-Vector Search**

Searches near the delta between two states ($\Delta = V_{current} - V_{baseline}$) to find a matching trajectory in historical data.

### Signature
```sql
fractal_search_trajectory(
    table_name       text,
    vector_col       text,
    baseline_vector  float8[],
    current_vector   float8[],
    k                int4
) RETURNS TABLE(doc_id int8, distance float8)
```

### Overloads
Also available with `fractal_vector` arguments for direct varlena read performance.

---

## `fractal_cross_modal_search`
**Weighted Modality Concatenation**

Searches a combined space of two different modalities (e.g., morphology and clinical data) using a weighted concatenation.

### Signature
```sql
fractal_cross_modal_search(
    table_name         text,
    vector_col         text,
    morphology_vector  float8[],
    clinical_vector    float8[],
    alpha_weight       float8,
    k                  int4
) RETURNS TABLE(doc_id int8, distance float8)
```

### Arguments
| Argument | Type | Range | Description |
| --- | --- | --- | --- |
| `alpha_weight` | `float8` | $[0, 1]$ | Weight given to the morphology vector. $(1 - \text{alpha})$ is given to the clinical vector. |

### Overloads
Also available with `fractal_vector` arguments.

---

## Stateful Diversify & Feedback

Scout Discovery (`fractal_search_explore`) is *stateless* diversity: MMR
spreads one result set within a single call. The **Diversify/Repulsion**
layer adds *stateful* diversity **across searches**: a session records which
results the user rejected, and subsequent searches actively avoid the
neighborhoods of those rejected results ("shadows"). This is the real
differentiator over plain top-K or MMR — neither of which is stateful across
searches.

The layer is **off by default** (bit-for-bit identical to v1.0 behavior); it
must be enabled per session, and it is session-scoped — shadows do not persist
across connections.

### `fractal_diversify_enable()` / `fractal_diversify_disable()`
Turn the Diversify/Repulsion layer on or off for the current session. Both
return `void`.

### `fractal_diversify_set_params(...)`
Tunes the repulsion layer. Every argument is optional (default `NULL`):
supplying `NULL` for a field keeps the core's current value, so you only
override the fields you name.

```sql
fractal_diversify_set_params(
    window_n               int4   DEFAULT NULL,
    stall_threshold        float8 DEFAULT NULL,
    repulsion_sigma        float8 DEFAULT NULL,
    repulsion_weight       float8 DEFAULT NULL,
    max_shadows_considered int4   DEFAULT NULL,
    tail_buffer_cap        int4   DEFAULT NULL
) RETURNS void
```

| Argument | Description |
| --- | --- |
| `window_n` | Search-context window size the repulsion layer tracks. |
| `stall_threshold` | Diversity-stall threshold below which repulsion intensifies. |
| `repulsion_sigma` | Gaussian width of each shadow's repulsion field. |
| `repulsion_weight` | Overall strength of the repulsion penalty. |
| `max_shadows_considered` | Cap on how many recorded shadows influence a search. |
| `tail_buffer_cap` | Cap on the tail buffer of recent results. |

Takes effect on the next `fractal_search` call.

### `fractal_detect_collapse()` → `float8`
Returns the current **D_q** (diversity quotient) from the last search on this
session's context. Low values indicate the search population has collapsed
toward a single basin. Returns `NaN` if no search has run yet or Diversify is
disabled.

### `fractal_explain_result()` → `jsonb`
Session-level Diversify diagnostics: `{dq, diversify_enabled, overhead_p99_us}`.
This is a session health readout, **not** a per-candidate "this result was
penalized by shadow X" trace — the core ABI does not currently expose
shadow attribution at that granularity.

### `fractal_feedback_report(result_handle, kind, dwell_ms)` → `void`
Reports engagement on a prior search result, feeding the shadow store when
Diversify is enabled (inert otherwise).

| Argument | Type | Description |
| --- | --- | --- |
| `result_handle` | `int8` | The 0-based corpus row index the result came from (matches the `doc_id` returned by the telemetry search functions). |
| `kind` | `text` | One of `'dwell'`, `'positive'`, `'negative'`. Anything else raises `kind must be one of ...`. |
| `dwell_ms` | `int4` | Optional dwell time in ms (omitted for a bare negative report). |

`fractal_isolate_background(result_handle)` is a convenience wrapper that
reports negative engagement with no dwell time.

### The stateful loop
The canonical usage is a feedback-driven re-search loop (exercised end to end
in `demo/demo-vertical-recommendation-search.sql`):

```sql
SELECT fractal_diversify_enable();           -- 1. turn on the repulsion layer
SELECT fractal_search_explore(               -- 2. first (diverse) search
    'catalog', 'emb', ARRAY[...]::float8[]);
SELECT fractal_feedback_report(0, 'negative'); -- 3. reject the top result
SELECT fractal_search_explore(               -- 4. re-search the SAME query
    'catalog', 'emb', ARRAY[...]::float8[]);
-- 5. confirm the rejected row's neighborhood is now avoided
SELECT fractal_explain_result();             -- -> {dq, diversify_enabled, ...}
SELECT fractal_diversify_disable();          -- 6. turn it off when done
```
