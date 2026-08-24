-- docker-entrypoint-initdb.d runs this once, on first container start
-- against an empty data directory (official Postgres image behavior).
CREATE EXTENSION IF NOT EXISTS fractalsql;
