<p align="center">
  <img src="../FractalSQLforPostgreSQL.jpg" alt="FractalSQL for PostgreSQL" width="720">
</p>

# Analytics API Reference

The Analytics tier provides mathematical primitives for analyzing the "shape" of data and state, turning raw vectors into structural insights.

---

## Fractal Dimension Analysis

### `fractal_dimension_dfa`
**Detrended Fluctuation Analysis**
Calculates the scaling exponent ($\alpha$) of a time-ordered series to distinguish between white noise, pink noise, and Brownian motion.

**Signature**: `fractal_dimension_dfa(series float8[]) RETURNS float8`
**Requirement**: $\ge 16$ points.

### `fractal_dimension_boxcount`
**Minkowski-Bouligand Dimension**
Measures the spatial complexity of a point cloud using box-counting.

**Signature**: `fractal_dimension_boxcount(points float8[], dim int4) RETURNS float8`
**Requirement**: $\ge 8$ points and a non-degenerate bounding box.

### `fractal_dimension_drift`
**Regime Change Detection**
Detects changes in the DFA exponent between a recent window and the baseline.

**Signature**: `fractal_dimension_drift(series float8[], win int4) RETURNS jsonb`
**Return**: `{drift, recent_alpha, baseline_alpha}`.

---

## Domain-Specific Geometry

These functions take **pre-extracted geometry** (graphs, meshes, skeletons) as input.

| Function | Input | Output | Description |
| --- | --- | --- | --- |
| `fractal_vascular_network` | `node_coords`, `edges`, `arc_length` | `{mean_tortuosity, branch_density, fractal_dimension}` | Vessel network complexity. |
| `fractal_cortical_folding` | `vertices`, `faces` | `{mesh_area, hull_area, gyrification_index}` | Brain surface folding. |
| `fractal_nerve_plexus_metric` | `node_coords`, `dim`, `edges` | `{fiber_length_density, branch_density, fractal_dimension}` | Nerve fiber density. |
| `fractal_morphological_complexity` | `points`, `dim` | `{dimension, lacunarity}` | Pre-segmented mask complexity. |

---

## Portfolio Optimization

### `fractal_optimize_portfolio`
**Cardinality-Constrained Sharpe-Ratio Maximization**

Finds the best $K$ assets in a large universe without brute-force exponential cost.

**Signature**: `fractal_optimize_portfolio(mu float8[], cov float8[], k int4, seed int8 DEFAULT NULL, use_obl boolean DEFAULT false, diffusion_mode text DEFAULT 'gaussian') RETURNS jsonb`
**Return**: `{sharpe, weights}`.
**`use_obl`**: apply Opposition-Based Learning to each SFS trial candidate. Also evaluate its bound-reflected opposite and keep whichever fits better. Off by default; doubles the fitness-eval cost of the affected diffusion step when enabled.
**`diffusion_mode`**: `'gaussian'` (default, canonical SFS) or `'levy'`: substitutes a heavy-tailed Lévy-flight step (Mantegna's algorithm) for the Gaussian walk, which can help escape local optima on highly multimodal problems at the cost of occasional very large steps.

### `fractal_optimize_portfolio_multimodal`
**Enterprise tier.** Diverse-candidate variant of `fractal_optimize_portfolio`: runs `n_restarts` independent single-best searches and greedy-selects up to `n_restarts` structurally distinct candidates instead of one.

**Signature**: `fractal_optimize_portfolio_multimodal(mu float8[], cov float8[], k int4, n_restarts int4 DEFAULT 8, overlap_threshold float8 DEFAULT 0.15, quality_frac float8 DEFAULT 0.90, seed int8 DEFAULT NULL, use_obl boolean DEFAULT false, diffusion_mode text DEFAULT 'gaussian') RETURNS jsonb`
**Return**: `{candidates: [{sharpe, weights}, ...], n_found}`.
**`overlap_threshold`**: max allowed selected-asset overlap (0.0–1.0, Jaccard-style) between any two returned candidates.
**`quality_frac`**: a candidate must reach at least `quality_frac` × the best Sharpe found to be kept.
**`use_obl`/`diffusion_mode`**: same knobs as `fractal_optimize_portfolio`, applied uniformly to every restart. Requires an enterprise core build with OBL/Lévy-flight support: errors with a clear "predates support" hint against an older `fractalsql.enterprise_lib` if you pass non-default values.

### `fractal_optimize_portfolio_multimodal_pareto`
**Enterprise tier.** Pareto-front sibling of `fractal_optimize_portfolio_multimodal`: runs the same `n_restarts` independent searches, but scores each by decomposed **(return, risk)** instead of scalar Sharpe and reduces them to a genuine non-dominated Pareto front (NSGA-II crowding-distance truncation if the front exceeds `max_front`). This is not the sharpe-threshold + asset-overlap selection the sibling above uses. Purely additive: does not change that function's selection semantics.

**Signature**: `fractal_optimize_portfolio_multimodal_pareto(mu float8[], cov float8[], k int4, n_restarts int4 DEFAULT 8, max_front int4 DEFAULT 8, seed int8 DEFAULT NULL, use_obl boolean DEFAULT false, diffusion_mode text DEFAULT 'gaussian') RETURNS jsonb`
**Return**: `{candidates: [{return, risk, sharpe, weights}, ...], n_found}`: `sharpe = return/risk` is informational, not the selection criterion.
**`max_front`**: cap on returned front size, `1 <= max_front <= n_restarts`.

---

## Named Feature Store

A generic per-item vector store for custom metadata or flagged examples.

### `fractal_store_morphology`
Upserts a vector against a `doc_id`.
**Signature**: `fractal_store_morphology(doc_id int8, feature_array float8[]) RETURNS void`

### `fractal_mine_topology_negatives`
Brute-force k-NN scan over the feature store.
**Signature**: `fractal_mine_topology_negatives(surrogate_vector float8[], k int4) RETURNS TABLE(doc_id int8, distance float8)`
