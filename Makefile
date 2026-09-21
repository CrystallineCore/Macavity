# macavity -- deterministic fault injection for PostgreSQL (TEST CLUSTERS ONLY)

MODULE_big = macavity
OBJS = \
	src/macavity.o \
	src/macavity_state.o \
	src/macavity_action.o \
	src/macavity_api.o

EXTENSION = macavity
DATA = sql/macavity--0.2.0.sql sql/macavity--0.1.0--0.2.0.sql
PGFILEDESC = "macavity - deterministic fault injection for testing"

# Regression tests.  sql/ holds both the extension install scripts (installed
# via DATA, above) and the pg_regress inputs; expected/ holds the expected
# output.  The crash action is covered separately by test/crash_test.sh,
# because a crashing backend makes the postmaster reset the cluster and
# pg_regress cannot survive that.
REGRESS = macavity_basic macavity_errors macavity_counters macavity_faults macavity_events

PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
