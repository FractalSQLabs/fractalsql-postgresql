-- demo/demo-business-intelligence.sql
--
-- A business-intelligence walkthrough, not just a text-to-sql
-- walkthrough: ask a plain-English business question, generate SQL,
-- EXECUTE it, and feed the real result back into fractal_reason() for
-- a narrative answer -- the loop demo-text-to-sql.sql deliberately
-- stops short of (execution is always a separate, explicit, caller-
-- side step -- see ../docs/text-to-sql-setup.md). Also covers the
-- other half of the product: Sniper Search to define a target
-- customer archetype, and Scout Discovery to find and name real
-- customer segments -- general data reasoning, not single-query
-- translation.
--
-- The synthetic data below has real patterns baked into it on
-- purpose (a revenue dip, five RFM-style customer segments) so the
-- reasoning sections below have something genuine to discover, not
-- just a number to restate -- same trick demo.sql's alert table uses.
--
-- Prerequisites: extension installed, reasoning configured -- see
-- ../docs/reasoning-setup.md and confirm with:
--   SELECT fractal_reason('reply with a short confirmation that this connection works');
-- before running this script.
--
-- Safe to re-run: the schema is dropped and recreated at the top.

\timing on
\pset pager off
\encoding UTF8

\echo '=== 0. Sanity check: extension loaded? ==='
SELECT fractal_edition(), fractal_version();

-- fractal_text_to_sql() raises a real Postgres ERROR (aborting the
-- current statement) when it exhausts its retry budget without
-- producing valid SQL -- a real, expected outcome for a weaker model
-- or an ambiguous question, not a bug to work around. Without this
-- wrapper, \gset never gets a value on that path and every later
-- reference to the unset psql variable fails with a confusing syntax
-- error instead of a clear "generation failed" message -- confirmed
-- the hard way, comparing models of very different capability.
CREATE OR REPLACE FUNCTION bi_safe_t2s(q text, tbls text[]) RETURNS text AS $$
BEGIN
    RETURN fractal_text_to_sql(q, tbls);
EXCEPTION WHEN OTHERS THEN
    RETURN '-- fractal_text_to_sql failed: ' || SQLERRM;
END;
$$ LANGUAGE plpgsql;

-- ------------------------------------------------------------------
-- 1. Schema + seed data. 18 months of orders across 60 customers,
-- with two patterns deliberately built in:
--   - a real revenue dip 4 months back (a supply issue, say) --
--     something for Section 3 to find.
--   - five RFM (recency/frequency/monetary) customer archetypes,
--     spread across SFS's [-1,1] operating box with enough margin
--     that Scout can actually tell them apart -- see benchmark.sql's
--     own comment on why narrow clustering silently understates
--     Scout's real result.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 1. Schema + 18 months of order history, 60 customers ==='

DROP TABLE IF EXISTS bi_customer_features;
DROP TABLE IF EXISTS bi_orders;
DROP TABLE IF EXISTS bi_customers;

CREATE TABLE bi_customers (
    id       serial PRIMARY KEY,
    name     text NOT NULL,
    segment  text NOT NULL,   -- ground truth, for narrating results below -- not fed to Scout/Sniper
    status   text NOT NULL DEFAULT 'active'
);
COMMENT ON TABLE bi_customers IS 'Customers, with a ground-truth RFM segment label for narrating results below';

CREATE TABLE bi_orders (
    id            serial PRIMARY KEY,
    customer_id   int NOT NULL REFERENCES bi_customers(id),
    total_cents   int NOT NULL,
    placed_at     timestamptz NOT NULL
);
COMMENT ON TABLE bi_orders IS 'Order history; total_cents is order value in cents';

-- Five RFM archetypes: (recency, frequency, monetary), each roughly
-- in [-0.8, 0.8] -- comfortably inside the [-1,1] box with margin for
-- per-customer noise. -1 recency = very recent/good; +1 frequency/
-- monetary = high/good (recency is inverted: -1 is the "good" end).
CREATE TEMP TABLE bi_archetypes (segment text PRIMARY KEY, r float8, f float8, m float8, n_customers int);
INSERT INTO bi_archetypes (segment, r, f, m, n_customers) VALUES
    ('Champions',        -0.7,  0.7,  0.7, 14),
    ('At-Risk',           0.6,  0.5,  0.6, 10),
    ('New & Exploring',  -0.6, -0.6, -0.5, 12),
    ('Lost',               0.7, -0.7, -0.6, 14),
    ('Loyal & Modest',   -0.3,  0.4, -0.2, 10);

INSERT INTO bi_customers (name, segment)
SELECT 'customer_' || row_number() OVER (), a.segment
FROM bi_archetypes a
CROSS JOIN LATERAL generate_series(1, a.n_customers);

CREATE TABLE bi_customer_features (customer_id int PRIMARY KEY REFERENCES bi_customers(id), feature_vec float8[]);
INSERT INTO bi_customer_features (customer_id, feature_vec)
SELECT c.id, array_agg(v.val ORDER BY v.dim_idx)
FROM bi_customers c
JOIN bi_archetypes a ON a.segment = c.segment
CROSS JOIN LATERAL (VALUES
    (1, a.r + (random() - 0.5) * 0.15),
    (2, a.f + (random() - 0.5) * 0.15),
    (3, a.m + (random() - 0.5) * 0.15)
) AS v(dim_idx, val)
GROUP BY c.id;

-- Order history: order count/value roughly follows each customer's
-- own frequency/monetary features, so the two tables tell a
-- consistent story. Month 4 (of 18, counting back from today) gets a
-- deliberate ~40% revenue dip across every segment -- 4 months back
-- comfortably inside any "last 6 months" trend question regardless of
-- what today's actual date is when this script runs, unlike a fixed
-- calendar month would be.
INSERT INTO bi_orders (customer_id, total_cents, placed_at)
SELECT c.id,
       (3000 + (random() * 12000))::int
         * CASE WHEN mo.month_offset = 4 THEN 0.6 ELSE 1.0 END,
       now() - (mo.month_offset || ' months')::interval + (random() * interval '25 days')
FROM bi_customers c
JOIN bi_customer_features f ON f.customer_id = c.id
CROSS JOIN LATERAL generate_series(1, 18) AS mo(month_offset)
-- order count per customer per month scales with their frequency
-- feature (f[2]): high-frequency customers order most months,
-- low-frequency customers order occasionally.
WHERE random() < (0.15 + 0.5 * ((f.feature_vec[2] + 1) / 2));

\echo ''
\echo 'Seed data: '
SELECT (SELECT count(*) FROM bi_customers) AS customers,
       (SELECT count(*) FROM bi_orders) AS orders,
       (SELECT to_char(sum(total_cents) / 100.0, 'FM$999,999,990.00') FROM bi_orders) AS total_revenue;

-- ------------------------------------------------------------------
-- 2. Simple fact lookup: generate -> execute -> show the raw result.
-- No reasoning yet -- this section is the loop's first half only, to
-- show what "generate then execute" looks like plainly before adding
-- interpretation on top of it in Section 3.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 2. Simple fact lookup: generate, then execute ==='

SELECT bi_safe_t2s(
    'how many customers do we have and what is our total revenue?',
    ARRAY['bi_customers', 'bi_orders']
) AS generated_sql \gset
SELECT (:'generated_sql' NOT LIKE '-- fractal_text_to_sql failed%') AS generated_sql_ok \gset

\echo 'Generated:'
\echo :'generated_sql'
\echo ''

\if :generated_sql_ok
\echo 'Executing it directly:'
:generated_sql

\echo ''
\echo 'Worth noticing: if the customer count above is lower than the 60'
\echo 'from the seed summary in Section 1, the model chose an INNER JOIN'
\echo 'between customers and orders -- quietly narrowing "how many'
\echo 'customers do we have" to "how many customers have ordered". Not'
\echo 'wrong, exactly, but a real example of why fractal_text_to_sql()'
\echo 'never auto-executes: the SQL is always worth reading, not just'
\echo 'trusting the English question implies.'
\else
\echo 'Skipped execution -- generation itself failed for this question.'
\endif

-- ------------------------------------------------------------------
-- 3. The full BI loop: generate -> execute -> reason over the REAL
-- result. This is the part demo-text-to-sql.sql deliberately never
-- does. The question is designed to surface the month-4 dip baked
-- into the data above -- fractal_reason() sees the actual monthly
-- numbers, not a hint that a dip exists. Explicitly excluding the
-- current (in-progress) month, not just "last 6 months" -- otherwise
-- whatever partial month is running when this script executes always
-- looks like a fake dip, which would be a real and common BI
-- reporting mistake to bake into a demo unremarked.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 3. The full loop: generate, execute, then reason over the real result ==='

SELECT bi_safe_t2s(
    'show total revenue for each of the 6 most recent FULLY COMPLETED calendar months, excluding the current in-progress month, oldest first',
    ARRAY['bi_orders']
) AS trend_sql \gset
SELECT (:'trend_sql' NOT LIKE '-- fractal_text_to_sql failed%') AS trend_sql_ok \gset

\echo 'Generated:'
\echo :'trend_sql'

DROP TABLE IF EXISTS bi_trend_result;
\if :trend_sql_ok
CREATE TEMP TABLE bi_trend_result AS
:trend_sql;

\echo ''
\echo 'Executed -- real result:'
SELECT * FROM bi_trend_result;

\echo ''
\echo 'Reasoning over the actual result (not the question, the DATA):'
SELECT fractal_reason(
    'this is our last 6 months of revenue by month -- what happened, and does it need attention?',
    (SELECT jsonb_agg(row_to_json(t))::text FROM bi_trend_result t)
);
\else
-- Empty placeholder, same intended shape -- keeps Section 4 below
-- safe to run (an empty/null trend rather than an error) even when
-- generation failed here, instead of cascading the failure forward.
CREATE TEMP TABLE bi_trend_result (month timestamptz, total_revenue numeric);
\echo ''
\echo 'Skipped execution and reasoning -- generation itself failed for this question.'
\endif

-- ------------------------------------------------------------------
-- 4. General data reasoning: synthesize across SEVERAL facts in one
-- call, not translate one question into one query. This is the
-- capability text-to-sql alone can't offer -- a single SQL statement
-- can't hold "here's the trend AND the segment mix AND the churn
-- signal, now tell me what's really going on."
-- ------------------------------------------------------------------
\echo ''
\echo '=== 4. General reasoning: synthesize multiple facts into one narrative ==='

SELECT fractal_reason(
    'given revenue trend, customer segment mix, and status breakdown together, what is the state of the business and what would you look into first?',
    jsonb_build_object(
        'monthly_revenue', (SELECT jsonb_agg(row_to_json(t)) FROM bi_trend_result t),
        'segment_mix', (SELECT jsonb_agg(row_to_json(s)) FROM (
            SELECT segment, count(*) AS customers FROM bi_customers GROUP BY segment ORDER BY segment
        ) s),
        'status_breakdown', (SELECT jsonb_agg(row_to_json(u)) FROM (
            SELECT status, count(*) AS customers FROM bi_customers GROUP BY status
        ) u)
    )::text
);

-- ------------------------------------------------------------------
-- 5. Sniper Search: converge toward a TARGET customer archetype.
-- Not a lookup against real customers -- SFS refines toward the
-- mathematically ideal point matching the query direction, useful for
-- "what would our best-possible customer profile look like" before
-- you go find (or build toward) one.
-- ------------------------------------------------------------------
\echo ''
\echo '=== 5. Sniper Search: converge toward an ideal-customer profile ==='
\echo 'Query: recent + frequent + high-value (a "Champions"-shaped target)'

SELECT fractal_search(ARRAY[-0.7, 0.7, 0.7]::float8[], iterations => 50) AS ideal_profile;

\echo ''
\echo 'Notice the ratio between components matches the query direction,'
\echo 'but the exact magnitude varies run to run (sometimes near the'
\echo '[-1,1] box edges, sometimes a scaled-down interior point) -- cosine'
\echo 'similarity (what Sniper optimizes for) is scale-invariant, so'
\echo 'every point along the same ray as the query scores identically.'
\echo 'SFS has no pressure to pick one particular point on that ray over'
\echo 'another, only to find the right ray. Read this as a DIRECTION to'
\echo 'aim for, not a literal target coordinate.'

-- ------------------------------------------------------------------
-- 6. Scout Discovery: find real, DIVERSE customer segments from the
-- actual stored feature vectors -- then have fractal_reason() name
-- them in business language. This is the same anti-mode-collapse
-- property benchmark.sql measures numerically, applied to an actual
-- business question: "what kinds of customers do we actually have?"
-- ------------------------------------------------------------------
\echo ''
\echo '=== 6. Scout Discovery: find and name real customer segments ==='

DROP TABLE IF EXISTS bi_scout_result;
CREATE TEMP TABLE bi_scout_result AS
SELECT row_number() OVER () AS particle_id, p AS feature_vec
FROM fractal_search_explore(
    'bi_customer_features', 'feature_vec', ARRAY[0, 0, 0]::float8[],
    '{"population_size": 8, "iterations": 10, "walk": 0}'::jsonb
) AS p;

\echo 'Scout found 8 diverse profiles (recency, frequency, monetary):'
SELECT * FROM bi_scout_result;

\echo ''
\echo 'Naming the segments Scout actually found, in business language:'
SELECT fractal_reason(
    'each item is a (recency, frequency, monetary) customer profile in [-1,1], where recency -1 is very recent, frequency/monetary +1 is high. Name and describe each distinct segment in one line.',
    (SELECT jsonb_agg(feature_vec)::text FROM bi_scout_result)
);

\echo ''
\echo '================================================================'
\echo 'Demo complete. Tables left in place for inspection. Clean up with:'
\echo '  DROP TABLE bi_customer_features, bi_orders, bi_customers;'
\echo '================================================================'
