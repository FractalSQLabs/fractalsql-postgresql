-- demo/demo-text-to-sql.sql
-- Runnable walkthrough of the REAL fractal_text_to_sql() feature,
-- against a richer schema with real foreign keys -- distinct from
-- demo/text-to-sql-spike-*.sql, which were throwaway hand-rolled
-- validation spikes run before this function existed (single-table,
-- no FKs, driving fractal_reason() directly). See
-- ../docs/text-to-sql-setup.md for the full pipeline explanation, the
-- GUC reference, and the security model.
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

DROP TABLE IF EXISTS order_items;
DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS customers;

CREATE TABLE customers (
    id      serial PRIMARY KEY,
    name    text NOT NULL,
    status  text NOT NULL DEFAULT 'active'
);
COMMENT ON TABLE customers IS 'People or companies who place orders';
COMMENT ON COLUMN customers.status IS 'one of: active, churned';

CREATE TABLE orders (
    id          serial PRIMARY KEY,
    customer_id int NOT NULL REFERENCES customers(id),
    placed_at   timestamptz NOT NULL DEFAULT now(),
    status      text NOT NULL DEFAULT 'pending'
);
COMMENT ON COLUMN orders.status IS 'one of: pending, paid, refunded, cancelled';

CREATE TABLE order_items (
    id          serial PRIMARY KEY,
    order_id    int NOT NULL REFERENCES orders(id),
    sku         text NOT NULL,
    quantity    int NOT NULL,
    unit_cents  int NOT NULL
);
COMMENT ON TABLE order_items IS 'Line items within an order; total = quantity * unit_cents';

INSERT INTO customers (name, status) VALUES
    ('acme',       'active'),
    ('globex',     'active'),
    ('initech',    'churned');

INSERT INTO orders (customer_id, status) VALUES
    (1, 'paid'), (1, 'paid'), (1, 'refunded'),
    (2, 'paid'),
    (3, 'cancelled');

INSERT INTO order_items (order_id, sku, quantity, unit_cents) VALUES
    (1, 'widget-a', 3, 500),
    (1, 'widget-b', 1, 1200),
    (2, 'widget-a', 2, 500),
    (3, 'widget-c', 1, 4000),
    (4, 'widget-b', 5, 1200);

\echo '=== Section 1: schema context (what GENERATE actually sees) ==='
SELECT fractal_schema_context(ARRAY['customers', 'orders', 'order_items']);

\echo ''
\echo '=== Section 2: a simple single-table question ==='
SELECT fractal_text_to_sql(
    'How many customers have status active?',
    ARRAY['customers']
);

\echo ''
\echo '=== Section 3: a question requiring a join across the FK chain ==='
SELECT fractal_text_to_sql(
    'List the names of customers who have at least one paid order, '
    'with how many paid orders each has.',
    ARRAY['customers', 'orders']
);

\echo ''
\echo '=== Section 4: a question requiring all three tables ==='
SELECT fractal_text_to_sql(
    'For each customer, what is the total value in cents of their paid orders '
    '(quantity times unit price, summed across all line items)?',
    ARRAY['customers', 'orders', 'order_items']
);

\echo ''
\echo '=== Section 5: run the generated SQL yourself ==='
\echo 'fractal_text_to_sql() never executes what it generates -- that is'
\echo 'always a separate, explicit step. Capture a result and run it:'
SELECT fractal_text_to_sql(
    'What is the average number of line items per order?',
    ARRAY['orders', 'order_items']
) AS generated_sql \gset
\echo 'Generated:'
\echo :generated_sql
\echo ''
\echo 'Executing it directly:'
:generated_sql;

\echo ''
\echo '================================================================'
\echo 'Next: docs/text-to-sql-setup.md for the GUC reference, the'
\echo 'execution-role grant pattern (do not run generated SQL as a'
\echo 'superuser in production), and how to validate against your own'
\echo 'local models with tests/test_text_to_sql_shadow.py.'
\echo ''
\echo 'Clean up: DROP TABLE order_items, orders, customers;'
\echo '================================================================'
