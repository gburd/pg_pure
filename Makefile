# pg_pure -- a procedural language for PostgreSQL in Pure (libpure).
#
# Build against an installed PostgreSQL (>= 17) and an installed libpure:
#     make PG_CONFIG=/path/to/pg_config PURE_PREFIX=/path/to/pure/prefix
#     make install PG_CONFIG=... PURE_PREFIX=...
#     make installcheck PG_CONFIG=...
#
# One shared library, pg_pure.so, backs two SQL extensions: pg_pure (trusted,
# the one we ultimately ship) and pg_pureu (superuser-only). See DESIGN.md.
#
# PURE_PREFIX is the prefix libpure was installed under (its headers are in
# $PURE_PREFIX/include/pure, its library in $PURE_PREFIX/lib). The library MUST
# be built so it exports no LLVM symbols when the server itself was compiled
# against LLVM; see DESIGN.md section 5.
PURE_PREFIX ?= /usr/local

MODULE_big = pg_pure
OBJS = pg_pure.o

EXTENSION = pg_pure pg_pureu
DATA = pg_pure--0.1.sql pg_pureu--0.1.sql

REGRESS = pg_pureu

PG_CPPFLAGS = -I$(PURE_PREFIX)/include
SHLIB_LINK = -L$(PURE_PREFIX)/lib -Wl,-rpath,$(PURE_PREFIX)/lib -lpure

PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

# --- source distribution (PGXN) ---------------------------------------------
# `make dist` produces pg_pure-$(DISTVERSION).zip in PGXN layout (all files
# under a pg_pure-$(DISTVERSION)/ prefix) straight from the committed tree.
# DISTVERSION is read from META.json (single source of truth).
DISTVERSION = $(shell grep -m1 '"version"' META.json | sed -E 's/.*"version": *"([^"]+)".*/\1/')
DISTNAME = pg_pure-$(DISTVERSION)

.PHONY: dist
dist:
	@test -n "$(DISTVERSION)" || { echo "could not read version from META.json" >&2; exit 1; }
	git archive --format=zip --prefix=$(DISTNAME)/ -o $(DISTNAME).zip HEAD
	@echo "created $(DISTNAME).zip"

# --- Pure-ASCII install SQL guard -------------------------------------------
# A non-ASCII byte in an install/upgrade .sql or a .control makes CREATE
# EXTENSION fail on a non-UTF-8 server database. Keep the shipped SQL and the C
# source ASCII-only. The regression SQL under sql/ is exempt (it tests Unicode).
.PHONY: check-ascii
check-ascii:
	@bad=$$(grep -lP '[^\x00-\x7F]' pg_pure--*.sql pg_pureu--*.sql *.control pg_pure.c 2>/dev/null); \
	if [ -n "$$bad" ]; then \
		echo "ERROR: non-ASCII bytes in shipped files (breaks CREATE EXTENSION on non-UTF-8 servers):" >&2; \
		for f in $$bad; do echo "  $$f:"; grep -nP '[^\x00-\x7F]' "$$f" | head; done >&2; \
		exit 1; \
	fi; \
	echo "check-ascii: shipped SQL, control files and C source are ASCII-only"
