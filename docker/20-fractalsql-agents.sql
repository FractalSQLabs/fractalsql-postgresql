-- docker-entrypoint-initdb.d runs this once, on first container start,
-- after 10-fractalsql.sql has created the base extension. The dependent
-- extension's control+SQL are COPYed into share/extension/ by the Dockerfile
-- demo stage; fractalsql_agents declares `requires = 'fractalsql'`, so the
-- base extension must be present first -- which the lexical init ordering
-- (10- before 20-) guarantees. CREATE EXTENSION tolerates the `\echo ... \quit`
-- guard at the top of the agents SQL file (the base extension ships the same
-- guard and loads the same way).
CREATE EXTENSION IF NOT EXISTS fractalsql_agents;