# fractalsql_agents/Makefile
#
# Pure-PL/pgSQL dependent extension over fractalsql. There is no C to build
# and no shared library: PGXS installs only the .control + .sql into
# $(sharedir)/extension. Built/installed with:
#     cd fractalsql_agents && make && make install

EXTENSION  = fractalsql_agents
DATA       = sql/fractalsql_agents--1.0.sql
PGFILEDESC = "fractalsql_agents - PL/pgSQL Domain Agent engines over fractalsql"

PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)