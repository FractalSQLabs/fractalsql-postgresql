-- demo/demo-vertical-rf-spectrum-sensing.sql
--
-- Industry vertical: RF and signal-interference monitoring -- spectrum
-- sensing for telecom operators, spectrum regulators, satellite ground
-- stations and any site that must notice when a carrier, a beacon or a
-- telemetry link loses its structure (interference, jamming, a failing
-- transmitter).  DOMAIN kit showcasing the short-time spectral entropy
-- primitive, fractal_spectrogram_entropy, composed with the periodogram
-- and change-point localization:
--
--   * fractal_periodogram -- WHICH frequencies dominate a whole capture.
--   * fractal_spectrogram_entropy -- HOW ORDERED the spectrum is, window
--     by window: low = energy in a few frequencies (a beacon, a locked
--     carrier), high = spread across the band (noise, jamming).
--   * fractal_change_point_detect -- WHEN the order changed, taken
--     straight from the entropy series (the function returns a plain
--     float8[], so it feeds the next call as-is).
--
-- Prerequisites: CREATE EXTENSION fractalsql;.  Everything except the
-- closing fractal_reason() runs with no model at all (raw primitives);
-- the narrative needs the reasoning plugin (docs/reasoning-setup.md).
-- fractalsql_agents is not needed.
--
-- Run:
--   psql -d <your_database> -f demo/demo-vertical-rf-spectrum-sensing.sql
--
-- Safe to re-run: rfs_* tables are dropped and recreated each time.
--
-- Notes:
--   * Fully deterministic fixture: noise comes from an integer LCG in a
--     recursive CTE, not random().
--   * Three channels x 256 samples of received level.  CH-A is a beacon
--     (a period-8 tone plus a little noise) that is JAMMED from sample
--     161: the tone is replaced by wideband noise.  CH-B is steady noise
--     (an empty channel).  CH-C is a steady period-16 telemetry carrier.
--   * Calibration: a pure tone reads about 0.2-0.4 after the Hann taper,
--     white noise about 0.9 (a noise periodogram is itself randomly
--     distributed, so it does not reach 1.0).  Window 32 / hop 16 gives
--     15 frames per channel; boundary indices are FRAME indices, so
--     sample position = frame_index * hop.

\echo '=== 0. Sanity check: extension loaded? ==='
SELECT fractal_edition(), fractal_version();

-- ------------------------------------------------------------------
-- 1. Capture: 3 channels x 256 samples.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 1. Capture: 3 channels x 256 samples ==='

DROP TABLE IF EXISTS rfs_capture;
CREATE TABLE rfs_capture (
    channel text,
    seq     int,
    level   float8,
    PRIMARY KEY (channel, seq)
);

INSERT INTO rfs_capture (channel, seq, level)
WITH RECURSIVE n(ch, t, x) AS (
       SELECT 'CH-A', 1, 1001::bigint UNION ALL SELECT 'CH-B', 1, 2002::bigint
       UNION ALL SELECT 'CH-C', 1, 3003::bigint
       UNION ALL
       SELECT ch, t + 1, (x * 1103515245 + 12345) % 2147483648 FROM n WHERE t < 256),
     u AS (SELECT ch, t, (((x / 65536) % 1000) - 500) / 500.0 AS noise FROM n)
SELECT ch, t,
       CASE ch
         WHEN 'CH-A' THEN CASE WHEN t <= 160 THEN sin(2 * pi() * t / 8.0) + 0.1 * noise
                               ELSE 1.2 * noise END
         WHEN 'CH-B' THEN 1.2 * noise
         ELSE sin(2 * pi() * t / 16.0) + 0.1 * noise
       END
FROM u;

SELECT channel, count(*) AS samples FROM rfs_capture GROUP BY channel ORDER BY channel;

-- ------------------------------------------------------------------
-- 2. Which frequencies dominate each channel (periodogram).  freq is
-- cycles per sample; 1/freq is samples per cycle.  CH-A is polluted by
-- its jammed second half but still shows the 1/8 beacon; CH-B has no
-- dominant line; CH-C is the 1/16 carrier.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 2. Dominant frequency per channel (fractal_periodogram) ==='

SELECT c.channel,
       round(p.freq::numeric, 4)         AS top_freq,
       round((1.0 / p.freq)::numeric, 1) AS samples_per_cycle
FROM (SELECT DISTINCT channel FROM rfs_capture) c
CROSS JOIN LATERAL fractal_periodogram(
         (SELECT array_agg(round(level::numeric, 5)::float8 ORDER BY seq)
            FROM rfs_capture r WHERE r.channel = c.channel), 1) p
ORDER BY c.channel;

-- ------------------------------------------------------------------
-- 3. How ordered is each channel, window by window
-- (fractal_spectrogram_entropy: window 32, hop 16 -> 15 frames).
-- ------------------------------------------------------------------
\echo ''
\echo '=== 3. Per-frame spectral entropy (fractal_spectrogram_entropy) ==='

DROP TABLE IF EXISTS rfs_entropy;
CREATE TABLE rfs_entropy AS
SELECT channel,
       fractal_spectrogram_entropy(array_agg(round(level::numeric, 5)::float8 ORDER BY seq), 32, 16) AS ent
  FROM rfs_capture GROUP BY channel;

SELECT channel, array_length(ent, 1) AS frames,
       round((SELECT min(v) FROM unnest(ent) v)::numeric, 3) AS min_entropy,
       round((SELECT max(v) FROM unnest(ent) v)::numeric, 3) AS max_entropy,
       round((SELECT avg(v) FROM unnest(ent) v)::numeric, 3) AS mean_entropy
FROM rfs_entropy ORDER BY channel;

\echo '--- CH-A frame by frame: ordered, then jammed ---'
SELECT u.ord - 1 AS frame, (u.ord - 1) * 16 AS first_sample, round(u.v::numeric, 3) AS entropy
FROM rfs_entropy e, unnest(e.ent) WITH ORDINALITY AS u(v, ord)
WHERE e.channel = 'CH-A' ORDER BY u.ord;

-- ------------------------------------------------------------------
-- 4. When did CH-A lose its structure?  fractal_change_point_detect on
-- the entropy series (window 3 frames, threshold 8.0 pooled-stddev
-- units).  The jam begins at sample 161; frame 9 (samples 144-175) is the
-- first to contain it, and that is the boundary reported.  A clean
-- channel's entropy series is nearly constant, so its pooled standard
-- deviation is tiny and a low threshold would flag measurement jitter --
-- keep the threshold high for entropy series.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 4. Where the order changed (change-point on the entropy series) ==='

SELECT channel, fractal_change_point_detect(ent, 3, 8.0, 16) AS change_points
FROM rfs_entropy ORDER BY channel;

-- ------------------------------------------------------------------
-- 5. Reasoning: the interference triage narrative (needs the reasoning
-- plugin).
-- ------------------------------------------------------------------
\echo ''
\echo '=== 5. Reasoning: interference triage ==='

SELECT fractal_reason(
    'one-line RF interference triage: which channel lost its structure, when, and the likely cause',
    json_build_object(
      'ch_a_entropy',       (SELECT ent FROM rfs_entropy WHERE channel = 'CH-A'),
      'ch_a_change_points', (SELECT fractal_change_point_detect(ent, 3, 8.0, 16)
                               FROM rfs_entropy WHERE channel = 'CH-A'),
      'ch_b_mean_entropy',  (SELECT round(avg(v)::numeric, 3)
                               FROM rfs_entropy e, unnest(e.ent) v WHERE e.channel = 'CH-B'))::text) AS triage;

\echo ''
\echo '=== Demo complete ==='
\echo 'Tables left in place for inspection. Clean up with:'
\echo '  DROP TABLE rfs_capture, rfs_entropy;'
