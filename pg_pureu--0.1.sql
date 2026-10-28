/* pg_pureu--0.1.sql */

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION pg_pureu" to load this file. \quit

CREATE FUNCTION pg_pureu_call_handler() RETURNS language_handler
  AS 'MODULE_PATHNAME' LANGUAGE C;

CREATE FUNCTION pg_pureu_inline_handler(internal) RETURNS void
  STRICT AS 'MODULE_PATHNAME' LANGUAGE C;

CREATE FUNCTION pg_pureu_validator(oid) RETURNS void
  STRICT AS 'MODULE_PATHNAME' LANGUAGE C;

CREATE LANGUAGE pg_pureu
  HANDLER pg_pureu_call_handler
  INLINE pg_pureu_inline_handler
  VALIDATOR pg_pureu_validator;

COMMENT ON LANGUAGE pg_pureu IS 'PL/PureU untrusted procedural language';
