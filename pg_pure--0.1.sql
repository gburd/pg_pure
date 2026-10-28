/* pg_pure--0.1.sql */

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION pg_pure" to load this file. \quit

CREATE FUNCTION pg_pure_call_handler() RETURNS language_handler
  AS 'MODULE_PATHNAME' LANGUAGE C;

CREATE FUNCTION pg_pure_inline_handler(internal) RETURNS void
  STRICT AS 'MODULE_PATHNAME' LANGUAGE C;

CREATE FUNCTION pg_pure_validator(oid) RETURNS void
  STRICT AS 'MODULE_PATHNAME' LANGUAGE C;

CREATE TRUSTED LANGUAGE pg_pure
  HANDLER pg_pure_call_handler
  INLINE pg_pure_inline_handler
  VALIDATOR pg_pure_validator;

COMMENT ON LANGUAGE pg_pure IS 'PL/Pure trusted procedural language';
