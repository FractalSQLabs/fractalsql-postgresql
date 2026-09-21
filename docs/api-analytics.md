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

## Time-Series and Topology

### `fractal_change_point_detect`
**Change-Point Localization**
DFA's complement: localizes *where* a series' mean and/or variance shifted, instead of only characterizing its overall scaling behavior.

**Signature**: `fractal_change_point_detect(series float8[], win int4, threshold float8 DEFAULT 2.0, max_points int4 DEFAULT 16) RETURNS int8[]`
Sliding two-sample test over adjacent windows of `win` samples; flags a boundary when the mean differs by more than `threshold` pooled-standard-deviation units or the variance ratio exceeds `threshold` squared. Returns ascending boundary indices, up to `max_points`. Requires at least `2 * win` points.

### `fractal_periodogram`
**Classical Periodogram**
Power at each positive Fourier frequency, computed by direct $O(n^2)$ DFT (exact, not an FFT approximation).

**Signature**: `fractal_periodogram(series float8[], max_peaks int4 DEFAULT 8) RETURNS TABLE(freq float8, power float8)`
**Return**: only the `max_peaks` bins with highest power, sorted descending. `freq` is cycles per sample in $(0, 0.5]$; `1.0/freq` is samples per cycle. Useful for network-beaconing and retry-loop cadence detection that DFA alone is blind to. Requires at least 4 points.

### `fractal_tda_persistence_diagram`
**Topological Persistence**
Topological analysis over a point cloud's Vietoris-Rips filtration, capped at 512 points.

**Signature**: `fractal_tda_persistence_diagram(points float8[], dim int4, max_dim int4 DEFAULT 1, max_thresh float8 DEFAULT 1.0, max_h0_bars int4 DEFAULT 64) RETURNS record`
**Return**: `h0_bars` (jsonb birth/death pairs) is an exact 0-dimensional persistence computation (single-linkage clustering). `betti1` (only computed when `max_dim = 1`) is the underlying graph's cycle rank, **not** full simplicial $H_1$: it over-counts true $H_1$ whenever a filled triangle exists in the data. A full simplicial computation (what Ripser/GUDHI do via boundary-matrix reduction) is out of scope.

### `fractal_state_fingerprint`
**SimHash State Fingerprint**
Random-hyperplane SimHash (Charikar 2002): projects a state vector onto `n_bits` random hyperplanes (deterministic from `seed`) and packs the sign of each projection MSB-first into bytes.

**Signature**: `fractal_state_fingerprint(v float8[], n_bits int4 DEFAULT 128, seed float8 DEFAULT 42.0) RETURNS bytea`
Two nearly-identical states collapse to the same or a very low Hamming-distance fingerprint, unlike an exact hash's all-or-nothing sensitivity to floating-point noise.

### `fractal_cycle_detect`
**Streaming Cycle Detection**
Brent's algorithm (1980) run over an array of `fractal_state_fingerprint` outputs, fed through one detector in order.

**Signature**: `fractal_cycle_detect(fingerprints bytea[], hamming_threshold int4 DEFAULT 0) RETURNS TABLE(at_index int4, cycle_len int8)`
**Return**: one row per cycle closure. `at_index` is the position in `fingerprints` where the cycle closed, `cycle_len` its length. The detector re-arms after each closure, so multiple independent cycles in the same stream are all caught. `hamming_threshold = 0` requires byte-exact fingerprint matches; above that, near-identical states count. Every fingerprint must be the same length.

These two pair into tolerant "have I basically been in this state before" loop detection; `fractal_agent_detect_loop` composes them (see [api-agency.md](api-agency.md)).

---

## Vector Math and Quantization

Utilities over the `fractal_vector` type (see [vectorizer-setup.md](vectorizer-setup.md)).

### `fractal_vector_lp_distance`
**Generalized $L_p$ Distance**

**Signature**: `fractal_vector_lp_distance(a fractal_vector, b fractal_vector, p float8) RETURNS float8`
$(\sum_i |a_i - b_i|^p)^{1/p}$ for $p > 0$. `p = 2` matches the `<->` operator mathematically but not bit-for-bit (different code path). For $0 < p < 1$ this is **not** a proper metric (the triangle inequality does not hold), so never substitute it silently for `<->` as a default distance; use it explicitly where fractional-$p$ contrast at high dimensionality is wanted, such as high-dimensional genomic or embedding similarity.

### `fractal_vector_quantize_int8` / `fractal_vector_quantize_binary`
**Per-Vector Quantization**

- `fractal_vector_quantize_int8(v fractal_vector) RETURNS record` → `(codes bytea, scale float4)`: symmetric int8 quantization, 4x compression. `codes` is one raw signed byte per dimension, `scale` lets the caller dequantize `v[i] ≈ codes[i] * scale`.
- `fractal_vector_quantize_binary(v fractal_vector) RETURNS bytea`: 1-bit quantization, 32x compression. Bit $i$ is 1 if `v[i] >= 0`, packed MSB-first. Pairs with `fractal_vector_hamming_distance(bytea, bytea)` for cheap candidate filtering ahead of a full-precision `<->` / `<=>` re-rank.

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

### `fractal_optimize_subset`
**Value-Weighted k-Subset Allocation**

Generalizes `fractal_optimize_portfolio`'s cardinality-constrained search into a pluggable-objective optimizer; this SQL entry point hardcodes value-weighted allocation: maximize `sum(weight[i] * item_values[i])` subject to at most `k` of `n_items` nonzero, each `weight <= upper_bounds[i]`, weights summing to 1.0.

**Signature**: `fractal_optimize_subset(item_values float8[], upper_bounds float8[], k int4, prev_weights float8[] DEFAULT NULL, turnover_penalty float8 DEFAULT 0.0, seed int8 DEFAULT NULL) RETURNS jsonb`
**Return**: `{score, weights}` where `score` is the achieved total value (higher is better). `prev_weights` + `turnover_penalty` (both optional) steer the search away from reallocating when set, for rebalancing use cases. The sum of the `k` largest `upper_bounds` must reach 1.0 or no feasible k-subset exists.

---

## Named Feature Store

A generic per-item vector store for custom metadata or flagged examples.

### `fractal_store_morphology`
Upserts a vector against a `doc_id`.
**Signature**: `fractal_store_morphology(doc_id int8, feature_array float8[]) RETURNS void`

### `fractal_mine_topology_negatives`
Brute-force k-NN scan over the feature store.
**Signature**: `fractal_mine_topology_negatives(surrogate_vector float8[], k int4) RETURNS TABLE(doc_id int8, distance float8)`
