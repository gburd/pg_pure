/*
 * pg_pure.c
 *		A PostgreSQL procedural language whose functions are written in
 *		Pure (https://agraef.github.io/pure-lang/), embedding libpure.
 *
 * The module backs two SQL languages that differ only in trust, each with its
 * own backend-local interpreter:
 *
 *	 pg_pure			 trusted; any user may create functions. Its interpreter is
 *					 created with libpure's --safe mode and armed after the SPI
 *					 bridge and the allowlisted modules are set up, so a function
 *					 body cannot escape the language (no extern, inline C, eval,
 *					 evalcmd, native/off-allowlist using, or dangerous prelude
 *					 functions). DESIGN.md section 9.
 *	 pg_pureu	 untrusted; superuser only. Its interpreter is unrestricted, so
 *					 Pure code may call any C function through extern -- the
 *					 plperlu analogue.
 *
 * A function body is a single Pure expression over the SQL argument names.
 * It is compiled once per backend as
 *		__pg_pure_<oid> a b = (<body>);
 * cached per (oid, xmin, tid), and every call is a pure_appxv of the cached
 * closure. The parentheses around <body> keep a stray ';' in the body from
 * leaking a global definition into the interpreter.
 *
 * Everything pg_pure adds to Pure lives in the "sql" namespace: sql::query,
 * sql::exec, sql::notice, sql::warning, sql::null, sql::error.
 *
 * The Pure/PostgreSQL boundary rules (DESIGN.md section 4) are correctness
 * invariants: no PostgreSQL ERROR may longjmp through Pure frames (SPI runs
 * under PG_TRY in an internal subtransaction and turns a SQL error into the
 * Pure exception sql::error), and no Pure exception may escape into
 * PostgreSQL (the x-variants hand the exception back and the handler turns it
 * into ereport after Pure has returned).
 */
#include "postgres.h"

#include "access/htup_details.h"
#include "access/xact.h"
#include "catalog/pg_proc.h"
#include "catalog/pg_type.h"
#include "commands/event_trigger.h"
#include "commands/trigger.h"
#include "executor/spi.h"
#include "fmgr.h"
#include "funcapi.h"
#include "miscadmin.h"
#include "nodes/miscnodes.h"
#include "storage/ipc.h"
#include "utils/builtins.h"
#include "utils/guc.h"
#include "utils/lsyscache.h"
#include "utils/memutils.h"
#include "utils/numeric.h"
#include "utils/resowner.h"
#include "utils/syscache.h"

/*
 * max_stack_depth moved from tcop/tcopprot.h (PG <= 17) to miscadmin.h (PG
 * 18). Include tcopprot.h unconditionally; on 18 it is harmless.
 */
#include "tcop/tcopprot.h"

#include <pure/runtime.h>

PG_MODULE_MAGIC;

PG_FUNCTION_INFO_V1(pg_pure_call_handler);
PG_FUNCTION_INFO_V1(pg_pure_inline_handler);
PG_FUNCTION_INFO_V1(pg_pure_validator);
PG_FUNCTION_INFO_V1(pg_pureu_call_handler);
PG_FUNCTION_INFO_V1(pg_pureu_inline_handler);
PG_FUNCTION_INFO_V1(pg_pureu_validator);

void		_PG_init(void);

static Datum call_function(const char *lang, bool trusted, FunctionCallInfo fcinfo);
static Datum inline_block(const char *lang, bool trusted, FunctionCallInfo fcinfo);
static void validate_function(const char *lang, bool trusted, Oid fn_oid, FunctionCallInfo fcinfo);

/* GUC: modules every interpreter loads. */
static char *pg_pure_using = NULL;

/*
 * Two interpreters per backend (backends are processes): an unrestricted one
 * for pg_pureu, and a sandboxed (--safe, armed) one for the trusted pg_pure.
 * They must not be shared: once armed, the safe interpreter refuses the
 * externs the untrusted setup needs. Each is created on first use of its
 * language. Symbols (sql::null, sql::error) have the same numeric tag in
 * either interpreter because libpure's symbol table is process-global.
 */
static pure_interp *interp_untrusted = NULL;
static pure_interp *interp_trusted = NULL;
static int32_t sym_sql_null = 0;
static int32_t sym_sql_error = 0;

typedef struct CachedFunc
{
	Oid			fn_oid;
	TransactionId fn_xmin;
	ItemPointerData fn_tid;
	pure_expr  *fun;			/* the compiled closure, pure_new'd */
	pure_interp *ip;			/* the interpreter it was compiled in */
	int			nargs;
	Oid			argtypes[FUNC_MAX_ARGS];
	Oid			rettype;
	struct CachedFunc *next;
} CachedFunc;

static CachedFunc *func_cache = NULL;

/* A SQL error caught inside an SPI call, waiting to be re-raised. */
static ErrorData *pending_pg_error = NULL;

static pure_expr *datum_to_pure(Datum d, bool isnull, Oid type);
static pure_interp *ensure_interp(bool trusted);

/* --- cooperative cancel ------------------------------------------------ */

static int
interrupt_hook(void)
{
	/* Read-only check of PostgreSQL's flags; no ereport from inside Pure. */
	return (QueryCancelPending || ProcDiePending) ? 2 : 0;
}

static void
pg_pure_exit(int code, Datum arg)
{
	if (interp_untrusted)
	{
		pure_delete_interp(interp_untrusted);
		interp_untrusted = NULL;
	}
	if (interp_trusted)
	{
		pure_delete_interp(interp_trusted);
		interp_trusted = NULL;
	}
}

static void
report_pure_failure(const char *lang, const char *what, pure_expr *exc)
{
	char	   *msg = NULL;

	/* An uncaught sql::error from SPI: re-raise the original SQL error. */
	if (pending_pg_error)
	{
		ErrorData  *edata = pending_pg_error;
		bool		is_sql_error = false;

		pending_pg_error = NULL;

		/*
		 * sql::error st msg is the nested application ((sql::error st) msg),
		 * so peel two levels and check the head symbol.
		 */
		if (exc)
		{
			pure_expr  *f1,
					   *a1,
					   *f2,
					   *a2;
			int32_t		sym;

			if (pure_is_app(exc, &f1, &a1) && pure_is_app(f1, &f2, &a2) &&
				pure_is_symbol(f2, &sym) && sym == sym_sql_error)
				is_sql_error = true;
		}
		if (is_sql_error)
		{
			pure_freenew(exc);	/* x-variants return it unreferenced */
			ReThrowError(edata);
		}
		FreeErrorData(edata);	/* Pure caught it and failed otherwise */
	}
	/* Cancel/terminate: let PostgreSQL raise its own error. */
	CHECK_FOR_INTERRUPTS();
	if (exc)
	{
		char	   *s = str(exc);

		msg = pstrdup(s ? s : "?");
		free(s);
		pure_freenew(exc);
	}
	else
	{
		const char *e = lasterr();

		msg = pstrdup(e && *e ? e : "failed match");
	}
	ereport(ERROR,
			(errcode(ERRCODE_EXTERNAL_ROUTINE_EXCEPTION),
			 errmsg("%s: %s: %s", lang, what, msg)));
}

/* --- SPI exported to Pure ---------------------------------------------- */

/*
 * Run sql in an internal subtransaction, as PL/Python does, so that if it
 * fails and Pure code catches the error and carries on, the resources the
 * failed query held (locks, pins, catalog cache references, memory) are
 * released with the subtransaction.
 */
static pure_expr *
spi_run(const char *sql, bool want_rows)
{
	pure_expr  *volatile result = NULL;
	MemoryContext oldcxt = CurrentMemoryContext;
	ResourceOwner oldowner = CurrentResourceOwner;
	char	   *volatile sqlstate_copy = NULL;
	char	   *volatile errmsg_copy = NULL;

	BeginInternalSubTransaction(NULL);
	MemoryContextSwitchTo(oldcxt);
	PG_TRY();
	{
		int			rc = SPI_execute(sql, false, 0);

		if (rc < 0)
			elog(ERROR, "SPI_execute failed: %s", SPI_result_code_string(rc));
		if (!want_rows)
			result = pure_int64((int64_t) SPI_processed);
		else
		{
			uint64		n = SPI_processed;
			pure_expr **rows = palloc(sizeof(pure_expr *) * (n ? n : 1));
			TupleDesc	td = SPI_tuptable ? SPI_tuptable->tupdesc : NULL;

			for (uint64 i = 0; i < n; i++)
			{
				int			nc = td->natts;
				pure_expr **cols = palloc(sizeof(pure_expr *) * nc);

				for (int c = 0; c < nc; c++)
				{
					bool		isnull;
					Datum		dv = SPI_getbinval(SPI_tuptable->vals[i], td, c + 1, &isnull);

					cols[c] = datum_to_pure(dv, isnull, TupleDescAttr(td, c)->atttypid);
				}
				rows[i] = nc == 1 ? cols[0] : pure_tuplev(nc, cols);
				pfree(cols);
			}
			result = pure_listv(n, rows);
			pfree(rows);
		}
		ReleaseCurrentSubTransaction();
		MemoryContextSwitchTo(oldcxt);
		CurrentResourceOwner = oldowner;
	}
	PG_CATCH();
	{
		ErrorData  *edata;

		/*
		 * Copy the error in a context that outlives the subtransaction we are
		 * about to roll back, then flush. CopyErrorData requires we are not in
		 * ErrorContext, so switch to TopMemoryContext first.
		 */
		MemoryContextSwitchTo(TopMemoryContext);
		edata = CopyErrorData();
		FlushErrorState();
		RollbackAndReleaseCurrentSubTransaction();
		MemoryContextSwitchTo(oldcxt);
		CurrentResourceOwner = oldowner;
		if (pending_pg_error)
			FreeErrorData(pending_pg_error);
		pending_pg_error = edata;
		sqlstate_copy = pstrdup(unpack_sql_state(edata->sqlerrcode));
		errmsg_copy = pstrdup(edata->message ? edata->message : "");
		if (result)
			pure_freenew(result);
		result = NULL;
	}
	PG_END_TRY();
	if (!result)
	{
		/*
		 * Throw sql::error "SQLSTATE" "message". This unwinds the Pure frames,
		 * not PostgreSQL's. If Pure catches it the transaction continues; if
		 * not, report_pure_failure re-raises pending_pg_error unchanged.
		 */
		pure_expr  *e = pure_symbol(sym_sql_error);

		e = pure_app(e, pure_cstring_dup(sqlstate_copy ? sqlstate_copy : "XX000"));
		e = pure_app(e, pure_cstring_dup(errmsg_copy ? errmsg_copy : ""));
		pure_throw(e);
	}
	return result;
}

PGDLLEXPORT pure_expr *pg_pure_spi_query(const char *sql);
PGDLLEXPORT pure_expr *pg_pure_spi_exec(const char *sql);
PGDLLEXPORT void pg_pure_notice(const char *msg);
PGDLLEXPORT void pg_pure_warning(const char *msg);

pure_expr *
pg_pure_spi_query(const char *sql)
{
	return spi_run(sql, true);
}

pure_expr *
pg_pure_spi_exec(const char *sql)
{
	return spi_run(sql, false);
}

void
pg_pure_notice(const char *msg)
{
	ereport(NOTICE, (errmsg_internal("%s", msg ? msg : "")));
}

void
pg_pure_warning(const char *msg)
{
	ereport(WARNING, (errmsg_internal("%s", msg ? msg : "")));
}

/* --- type mapping ------------------------------------------------------ */

static bool
type_supported(Oid t)
{
	switch (t)
	{
		case INT2OID:
		case INT4OID:
		case INT8OID:
		case FLOAT4OID:
		case FLOAT8OID:
		case BOOLOID:
		case TEXTOID:
		case VARCHAROID:
		case NUMERICOID:
			return true;
		default:
			return false;
	}
}

/*
 * numeric -> Pure. An integral numeric becomes a Pure bigint (exact); a
 * fractional one becomes an exact rational num % den (needs the math module).
 * NaN and +/-Infinity have no rational form and become doubles. Nothing is
 * rounded. Built as text handed to pure_eval so we need no GMP headers here.
 */
static pure_expr *
numeric_to_pure(Datum d)
{
	Numeric		n = DatumGetNumeric(d);
	char	   *s;
	pure_expr  *x;
	StringInfoData buf;

	if (numeric_is_nan(n) || numeric_is_inf(n))
		return pure_double(DatumGetFloat8(DirectFunctionCall1(numeric_float8, d)));

	s = DatumGetCString(DirectFunctionCall1(numeric_out, d));
	initStringInfo(&buf);
	if (strchr(s, '.') == NULL && strchr(s, 'e') == NULL && strchr(s, 'E') == NULL)
		/* Integral: a bigint literal, e.g. 42L. */
		appendStringInfo(&buf, "%sL", s);
	else
	{
		/*
		 * Fractional: rational (mantissa * 10^-scale), e.g. 12.5 becomes
		 * 125L%10L, which math normalizes to 25L%2L. Build it from the digits
		 * so no double is involved.
		 */
		char	   *dot = strchr(s, '.');
		int			scale = dot ? (int) strlen(dot + 1) : 0;
		char	   *digits = palloc(strlen(s) + 1);
		char	   *w = digits;
		bool		neg = (*s == '-');

		for (char *r = s; *r; r++)
			if (*r != '.' && *r != '-' && *r != '+')
				*w++ = *r;
		*w = '\0';
		/* scale is bounded by numeric's digit count, so 10^scale as a literal is fine. */
		appendStringInfo(&buf, "%s%sL%%1", neg ? "-" : "", digits);
		for (int i = 0; i < scale; i++)
			appendStringInfoChar(&buf, '0');
		appendStringInfoString(&buf, "L");
	}
	x = pure_eval(buf.data);
	pfree(buf.data);
	pfree(s);
	if (!x)
		ereport(ERROR,
				(errcode(ERRCODE_EXTERNAL_ROUTINE_EXCEPTION),
				 errmsg("pg_pure: cannot represent numeric value as a Pure number"),
				 errhint("A rational result needs the math module; it is loaded by default via pg_pure.using.")));
	return x;
}

static pure_expr *
datum_to_pure(Datum d, bool isnull, Oid type)
{
	if (isnull)
		return pure_symbol(sym_sql_null);
	switch (type)
	{
		case INT2OID:
			return pure_int(DatumGetInt16(d));
		case INT4OID:
			return pure_int(DatumGetInt32(d));
		case INT8OID:
			return pure_int64(DatumGetInt64(d));
		case FLOAT4OID:
			return pure_double(DatumGetFloat4(d));
		case FLOAT8OID:
			return pure_double(DatumGetFloat8(d));
		case BOOLOID:
			return pure_int(DatumGetBool(d) ? 1 : 0);
		case NUMERICOID:
			return numeric_to_pure(d);
		default:
			{
				/* text, varchar, and (via SPI) any other type: its text form */
				Oid			out;
				bool		isvarlena;
				char	   *s;
				pure_expr  *x;

				getTypeOutputInfo(type, &out, &isvarlena);
				s = OidOutputFunctionCall(out, d);
				x = pure_string_dup(s);
				pfree(s);
				return x;
			}
	}
}

/*
 * Extract a 64-bit integer from a Pure int or bigint. Returns false if x is
 * neither, or if a bigint does not fit in int64.
 */
static bool
pure_to_int64(pure_expr *x, int64 *out)
{
	int32_t		i;
	char	   *s;
	ErrorSaveContext escontext = {T_ErrorSaveContext};
	Datum		v;

	if (pure_is_int(x, &i))
	{
		*out = i;
		return true;
	}
	if (!pure_is_mpz(x, NULL))
		return false;

	/*
	 * A bigint: parse its printed form (e.g. "123L") with int8in, which
	 * range-checks into int64. Strip the trailing 'L'. pure_get_int64
	 * truncates silently, so it is not used here.
	 */
	s = str(x);
	if (s == NULL)
		return false;
	for (char *q = s; *q; q++)
		if (*q == 'L')
		{
			*q = '\0';
			break;
		}
	if (!DirectInputFunctionCallSafe(int8in, s, InvalidOid, -1,
									 (Node *) &escontext, &v))
	{
		free(s);
		return false;
	}
	free(s);
	if (escontext.error_occurred)
		return false;
	*out = DatumGetInt64(v);
	return true;
}

/*
 * Pure -> Datum, range-checked. Returns false if x has no representation in
 * type (the caller reports a type mismatch) and sets *overflow when x is the
 * right kind of number but out of the type's range (the caller raises
 * numeric_value_out_of_range).
 */
static bool
pure_to_datum(pure_expr *x, Oid type, Datum *d, bool *isnull, bool *overflow)
{
	int32_t		i;
	double		f;
	const char *s;
	int32_t		sym;
	int64		n64;

	*isnull = false;
	*overflow = false;
	if (pure_is_symbol(x, &sym) && sym == sym_sql_null)
	{
		*isnull = true;
		return true;
	}
	switch (type)
	{
		case INT2OID:
			if (!pure_to_int64(x, &n64))
				return false;
			if (n64 < PG_INT16_MIN || n64 > PG_INT16_MAX)
				return (*overflow = true), false;
			*d = Int16GetDatum((int16) n64);
			return true;
		case INT4OID:
			if (!pure_to_int64(x, &n64))
				return false;
			if (n64 < PG_INT32_MIN || n64 > PG_INT32_MAX)
				return (*overflow = true), false;
			*d = Int32GetDatum((int32) n64);
			return true;
		case BOOLOID:
			if (!pure_is_int(x, &i))
				return false;
			*d = BoolGetDatum(i != 0);
			return true;
		case INT8OID:
			if (!pure_to_int64(x, &n64))
				return false;
			*d = Int64GetDatum(n64);
			return true;
		case FLOAT4OID:
		case FLOAT8OID:
			if (pure_is_double(x, &f))
				;
			else if (pure_to_int64(x, &n64))
				f = (double) n64;
			else
				return false;
			*d = type == FLOAT4OID ? Float4GetDatum((float4) f) : Float8GetDatum(f);
			return true;
		case NUMERICOID:
			{
				/*
				 * Exact where Pure is exact. A double goes through
				 * float8_numeric. An int or bigint prints as "123L" and a
				 * rational as "25L%2L"; parse those into numerics with no
				 * double in between.
				 */
				char	   *t;
				char	   *pct;

				if (pure_is_double(x, &f))
				{
					*d = DirectFunctionCall1(float8_numeric, Float8GetDatum(f));
					return true;
				}
				if (!pure_is_mpz(x, NULL) && !pure_is_int(x, &i))
				{
					/* Could still be a rational application %\ x y. */
					pure_expr  *f1,
							   *a1;

					if (!pure_is_app(x, &f1, &a1))
						return false;
				}
				t = str(x);
				if (t == NULL)
					return false;
				pct = strchr(t, '%');
				if (pct == NULL)
				{
					/* integral bigint/int: "123L" -> numeric */
					char	   *num = pstrdup(t);

					for (char *p = num; *p; p++)
						if (*p == 'L')
							*p = '\0';
					*d = DirectFunctionCall3(numeric_in, CStringGetDatum(num),
											 ObjectIdGetDatum(InvalidOid), Int32GetDatum(-1));
					pfree(num);
				}
				else
				{
					/*
					 * Rational "NUM L % DEN L". numeric_div picks a result scale
					 * from the operand magnitudes, which for large operands
					 * rounds the fraction away. Force a scale wide enough: for a
					 * power-of-ten denominator (the form numeric_to_pure built)
					 * the digit count of DEN minus one is exact; otherwise it is a
					 * sensible display scale. A non-terminating rational like 1%3
					 * is rounded to that scale, as numeric division always is.
					 */
					char	   *num = pstrdup(t);
					char	   *den;
					int			den_digits;
					int			scale;
					Datum		nn,
								dd,
								q;

					den = strchr(num, '%');
					*den++ = '\0';
					for (char *p = num; *p; p++)
						if (*p == 'L')
							*p = '\0';
					for (char *p = den; *p; p++)
						if (*p == 'L')
							*p = '\0';
					/*
					 * numeric_to_pure writes a terminating fraction as
					 * mantissa % 10^k, so the denominator "1" followed by k zeros
					 * has k+1 characters and the exact scale is k.
					 */
					den_digits = (int) strlen(den) - (den[0] == '-' ? 1 : 0);
					scale = den_digits > 1 ? den_digits - 1 : 1;
					if (scale > NUMERIC_MAX_DISPLAY_SCALE)
						scale = NUMERIC_MAX_DISPLAY_SCALE;
					nn = DirectFunctionCall3(numeric_in, CStringGetDatum(num),
											 ObjectIdGetDatum(InvalidOid), Int32GetDatum(-1));

					/*
					 * Give the divisor a display scale so numeric_div keeps that
					 * many fractional digits in the quotient; without it the
					 * division of large operands rounds the fraction away.
					 */
					{
						StringInfoData dbuf;

						initStringInfo(&dbuf);
						appendStringInfoString(&dbuf, den);
						appendStringInfoChar(&dbuf, '.');
						for (int z = 0; z < scale; z++)
							appendStringInfoChar(&dbuf, '0');
						dd = DirectFunctionCall3(numeric_in, CStringGetDatum(dbuf.data),
												 ObjectIdGetDatum(InvalidOid), Int32GetDatum(-1));
						pfree(dbuf.data);
					}
					q = DirectFunctionCall2(numeric_div, nn, dd);
					*d = DirectFunctionCall2(numeric_round, q, Int32GetDatum(scale));
					pfree(num);
				}
				free(t);
				return true;
			}
		case TEXTOID:
		case VARCHAROID:
			/*
			 * A text result must be a Pure string. An application that no rule
			 * matched is a normal form (not a string), and turning it into
			 * text with str would hide a type error as wrong text.
			 */
			if (pure_is_string(x, &s))
			{
				*d = type == TEXTOID ? CStringGetTextDatum(s)
					: DirectFunctionCall3(varcharin, CStringGetDatum(s),
										  ObjectIdGetDatum(InvalidOid), Int32GetDatum(-1));
				return true;
			}
			return false;
	}
	return false;
}

/* --- interpreter and function cache ------------------------------------ */

/*
 * Return the backend's interpreter for the given language trust, creating it
 * on first use. The untrusted interpreter is unrestricted; the trusted one is
 * created with --safe, set up with the SPI bridge and the allowlisted modules
 * while still trusted, then armed so user code cannot escape the language.
 */
static pure_interp *
ensure_interp(bool trusted)
{
	char	   *argv_u[] = {"pg_pure", NULL};
	char	   *argv_s[] = {"pg_pure", "--safe", NULL};
	pure_interp **slot = trusted ? &interp_trusted : &interp_untrusted;
	pure_interp *ip;
	pure_expr  *x;
	int32_t		two = 0;
	const char *problem = NULL;
	StringInfoData setup;

	if (*slot)
		return *slot;
	ip = trusted ? pure_create_interp(2, argv_s) : pure_create_interp(1, argv_u);
	if (!ip)
		ereport(ERROR,
				(errcode(ERRCODE_EXTERNAL_ROUTINE_EXCEPTION),
				 errmsg("pg_pure: cannot create the Pure interpreter")));
	pure_switch_interp(ip);

	/*
	 * Declare the sql namespace (sql::null and sql::error must be constant
	 * symbols, or they would be variables in patterns) and bind the SPI/notice
	 * externs. In the trusted interpreter this must happen before arming,
	 * because arming refuses all externs; these are pg_pure's own C functions
	 * and are safe.
	 */
	initStringInfo(&setup);
	appendStringInfoString(&setup,
						   "namespace sql;\n"
						   "nonfix null;\n"
						   "public error query exec;\n"
						   "extern expr* pg_pure_spi_query(char*) = query;\n"
						   "extern expr* pg_pure_spi_exec(char*) = exec;\n"
						   "extern void pg_pure_notice(char*) = notice;\n"
						   "extern void pg_pure_warning(char*) = warning;\n"
						   "namespace;\n");
	x = pure_eval(setup.data);
	pfree(setup.data);
	if (!x && *lasterr())
		problem = pstrdup(lasterr());

	/*
	 * Load the configured modules. In the trusted interpreter, load each one
	 * while still trusted and then allow it, so armed user code may say
	 * "using <module>;" for a vetted module. A module that itself declares
	 * externs (math declares log, pure_rational, ...) must be loaded here.
	 */
	if (!problem && pg_pure_using && *pg_pure_using)
	{
		char	   *list = pstrdup(pg_pure_using);
		char	   *tok;

		for (tok = strtok(list, " ,\t"); tok && !problem; tok = strtok(NULL, " ,\t"))
		{
			StringInfoData u;

			initStringInfo(&u);
			appendStringInfo(&u, "using %s;", tok);
			clear_lasterr();
			x = pure_eval(u.data);
			pfree(u.data);
			if (!x && *lasterr())
			{
				problem = psprintf("cannot load module \"%s\": %s", tok, lasterr());
				break;
			}
			if (trusted)
				pure_safe_allow_using(tok);
		}
		pfree(list);
	}

	if (!problem)
	{
		clear_lasterr();
		x = pure_eval("1+1");
		if (!x || !pure_is_int(x, &two) || two != 2)
			problem = "the Pure prelude did not load; set PURELIB in the "
				"server's environment to the directory holding prelude.pure";
		if (x)
			pure_freenew(x);
	}
	if (problem)
	{
		pure_delete_interp(ip);
		ereport(ERROR,
				(errcode(ERRCODE_EXTERNAL_ROUTINE_EXCEPTION),
				 errmsg("pg_pure: cannot set up the %s interpreter: %s",
						trusted ? "trusted" : "untrusted", problem)));
	}

	/* Turn on sandbox enforcement last, after all trusted setup is done. */
	if (trusted)
		pure_safe_arm();

	sym_sql_null = pure_sym("sql::null");
	sym_sql_error = pure_sym("sql::error");
	pure_set_interrupt_hook(interrupt_hook);
	if (!IsUnderPostmaster)
		return ip;				/* preloading: the postmaster keeps it for fork */
	if (!interp_untrusted && !interp_trusted)
		on_proc_exit(pg_pure_exit, 0);
	*slot = ip;
	return ip;
}

static void
set_stack_limit(void)
{
	char		here;

	/* Give Pure half of what is left of max_stack_depth from this frame. */
	pure_set_stack_limit(&here, (size_t) max_stack_depth * 1024L / 2);
}

static CachedFunc *
compile_function(const char *lang, pure_interp *ip, Oid fn_oid)
{
	HeapTuple	tup;
	Form_pg_proc proc;
	Datum		src;
	char	   *body;
	char	  **argnames;
	Oid		   *argtypes;
	char	   *argmodes;
	int			nargs;
	StringInfoData def;
	CachedFunc *cf;
	pure_expr  *fun;
	char		fname[64];

	tup = SearchSysCache1(PROCOID, ObjectIdGetDatum(fn_oid));
	if (!HeapTupleIsValid(tup))
		elog(ERROR, "cache lookup failed for function %u", fn_oid);
	proc = (Form_pg_proc) GETSTRUCT(tup);

	for (cf = func_cache; cf; cf = cf->next)
		if (cf->fn_oid == fn_oid && cf->ip == ip)
		{
			if (cf->fn_xmin == HeapTupleHeaderGetRawXmin(tup->t_data) &&
				ItemPointerEquals(&cf->fn_tid, &tup->t_self))
			{
				ReleaseSysCache(tup);
				return cf;
			}
			break;				/* stale: recompile below, reuse the entry */
		}

	nargs = get_func_arg_info(tup, &argtypes, &argnames, &argmodes);
	if (argmodes)
		for (int i = 0; i < nargs; i++)
			if (argmodes[i] != PROARGMODE_IN)
				ereport(ERROR, (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
								errmsg("%s functions support only IN arguments", lang)));
	if (!type_supported(proc->prorettype))
		ereport(ERROR, (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
						errmsg("%s functions cannot return type %s",
							   lang, format_type_be(proc->prorettype))));
	for (int i = 0; i < nargs; i++)
	{
		if (!type_supported(argtypes[i]))
			ereport(ERROR, (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
							errmsg("%s functions cannot take type %s",
								   lang, format_type_be(argtypes[i]))));
		if (!argnames || !argnames[i] || !*argnames[i])
			ereport(ERROR, (errcode(ERRCODE_INVALID_FUNCTION_DEFINITION),
							errmsg("%s function arguments must be named", lang)));
	}
	src = SysCacheGetAttrNotNull(PROCOID, tup, Anum_pg_proc_prosrc);
	body = TextDatumGetCString(src);

	snprintf(fname, sizeof fname, "__pg_pure_%u", fn_oid);
	initStringInfo(&def);

	/*
	 * Leading "using MODULE;" statements load modules into the interpreter,
	 * so they must sit at top level, not inside the function body. Peel them
	 * off the front of the body and emit them before the definition. The rest
	 * of the body is one expression.
	 */
	while (1)
	{
		char	   *p = body;
		char	   *semi;

		while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r')
			p++;
		if (strncmp(p, "using", 5) != 0 ||
			(p[5] != ' ' && p[5] != '\t' && p[5] != '\n'))
			break;
		semi = strchr(p, ';');
		if (!semi)
			break;
		appendBinaryStringInfo(&def, p, semi - p + 1);
		appendStringInfoChar(&def, '\n');
		body = semi + 1;
	}

	appendStringInfoString(&def, fname);
	for (int i = 0; i < nargs; i++)
		appendStringInfo(&def, " %s", argnames[i]);
	if (nargs == 0)
		appendStringInfoString(&def, " ()");	/* a zero-arg call takes () */
	/* Parenthesize the body so a stray ';' cannot define a global rule. */
	appendStringInfo(&def, " = (%s);\n%s;", body, fname);

	set_stack_limit();
	pure_switch_interp(ip);
	if (cf)
	{
		/* CREATE OR REPLACE: drop old rules, which Pure appends to otherwise. */
		char		clr[80];
		char	   *out;

		snprintf(clr, sizeof clr, "clear %s\n", fname);
		out = pure_evalcmd(clr);
		free(out);
	}
	clear_lasterr();
	fun = pure_eval(def.data);
	if (!fun || *lasterr())
	{
		char	   *e = pstrdup(*lasterr() ? lasterr() : "no value");

		if (fun)
			pure_freenew(fun);
		ReleaseSysCache(tup);
		ereport(ERROR,
				(errcode(ERRCODE_SYNTAX_ERROR),
				 errmsg("%s: cannot compile function \"%s\"", lang, NameStr(proc->proname)),
				 errdetail("%s", e)));
	}

	if (!cf)
	{
		cf = MemoryContextAllocZero(TopMemoryContext, sizeof(CachedFunc));
		cf->next = func_cache;
		func_cache = cf;
	}
	else if (cf->fun)
		pure_free(cf->fun);
	cf->fn_oid = fn_oid;
	cf->ip = ip;
	cf->fn_xmin = HeapTupleHeaderGetRawXmin(tup->t_data);
	cf->fn_tid = tup->t_self;
	cf->fun = pure_new(fun);
	cf->nargs = nargs;
	memcpy(cf->argtypes, argtypes, sizeof(Oid) * nargs);
	cf->rettype = proc->prorettype;
	ReleaseSysCache(tup);
	return cf;
}

/* --- entry points ------------------------------------------------------ */

static Datum
call_function(const char *lang, bool trusted, FunctionCallInfo fcinfo)
{
	pure_interp *ip;
	CachedFunc *cf;
	pure_expr  *args[FUNC_MAX_ARGS];
	pure_expr  *res,
			   *exc = NULL;
	Datum		d = (Datum) 0;
	bool		isnull,
				overflow;
	int			rc;

	if (CALLED_AS_TRIGGER(fcinfo))
		ereport(ERROR, (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
						errmsg("%s does not support triggers yet", lang)));
	if (CALLED_AS_EVENT_TRIGGER(fcinfo))
		ereport(ERROR, (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
						errmsg("%s does not support event triggers yet", lang)));
	ip = ensure_interp(trusted);
	pure_switch_interp(ip);
	cf = compile_function(lang, ip, fcinfo->flinfo->fn_oid);

	/* Convert arguments outside of any Pure call: they may ereport. */
	for (int i = 0; i < cf->nargs; i++)
		args[i] = datum_to_pure(fcinfo->args[i].value, fcinfo->args[i].isnull, cf->argtypes[i]);
	if (cf->nargs == 0)
		args[0] = pure_tuplel(0);

	if ((rc = SPI_connect()) != SPI_OK_CONNECT)
		elog(ERROR, "SPI_connect failed: %s", SPI_result_code_string(rc));
	set_stack_limit();
	pending_pg_error = NULL;
	res = pure_appxv(cf->fun, cf->nargs ? cf->nargs : 1, args, &exc);
	if (!res)
	{
		SPI_finish();
		report_pure_failure(lang, "uncaught exception", exc);
	}
	if (!pure_to_datum(res, cf->rettype, &d, &isnull, &overflow))
	{
		char	   *s = str(res);
		char	   *msg = pstrdup(s ? s : "?");

		free(s);
		pure_freenew(res);
		SPI_finish();
		if (overflow)
			ereport(ERROR,
					(errcode(ERRCODE_NUMERIC_VALUE_OUT_OF_RANGE),
					 errmsg("%s: result %s is out of range for %s",
							lang, msg, format_type_be(cf->rettype))));
		ereport(ERROR,
				(errcode(ERRCODE_DATATYPE_MISMATCH),
				 errmsg("%s: result %s cannot be converted to %s",
						lang, msg, format_type_be(cf->rettype)),
				 errhint("Check the argument types your rules expect; an "
						 "unmatched application stays unevaluated in Pure.")));
	}
	pure_freenew(res);
	/* Copy a by-reference result out of SPI's memory before SPI_finish. */
	if (!isnull && !get_typbyval(cf->rettype))
		d = SPI_datumTransfer(d, false, get_typlen(cf->rettype));
	SPI_finish();
	fcinfo->isnull = isnull;
	return d;
}

static void
validate_function(const char *lang, bool trusted, Oid fn_oid, FunctionCallInfo fcinfo)
{
	pure_interp *ip;

	if (!CheckFunctionValidatorAccess(fcinfo->flinfo->fn_oid, fn_oid))
		return;
	if (!check_function_bodies)
		return;
	ip = ensure_interp(trusted);
	pure_switch_interp(ip);
	(void) compile_function(lang, ip, fn_oid);
}

Datum
pg_pure_call_handler(PG_FUNCTION_ARGS)
{
	return call_function("pg_pure", true, fcinfo);
}

Datum
pg_pure_inline_handler(PG_FUNCTION_ARGS)
{
	return inline_block("pg_pure", true, fcinfo);
}

Datum
pg_pure_validator(PG_FUNCTION_ARGS)
{
	validate_function("pg_pure", true, PG_GETARG_OID(0), fcinfo);
	PG_RETURN_VOID();
}

Datum
pg_pureu_call_handler(PG_FUNCTION_ARGS)
{
	return call_function("pg_pureu", false, fcinfo);
}

static Datum
inline_block(const char *lang, bool trusted, FunctionCallInfo fcinfo)
{
	InlineCodeBlock *codeblock = (InlineCodeBlock *) DatumGetPointer(PG_GETARG_DATUM(0));
	pure_interp *ip;
	pure_expr  *res,
			   *exc = NULL;
	StringInfoData def;
	char	   *out;
	int			rc;

	ip = ensure_interp(trusted);
	pure_switch_interp(ip);
	set_stack_limit();
	/* Compile the block as a temporary niladic function, call, then clear. */
	initStringInfo(&def);
	appendStringInfo(&def, "__pg_pure_do () = (%s);\n", codeblock->source_text);
	clear_lasterr();
	res = pure_eval(def.data);
	if (res)
		pure_freenew(res);
	if (*lasterr())
	{
		char	   *e = pstrdup(lasterr());

		pfree(def.data);
		ereport(ERROR,
				(errcode(ERRCODE_SYNTAX_ERROR),
				 errmsg("%s: cannot compile DO block", lang),
				 errdetail("%s", e)));
	}
	pfree(def.data);

	if ((rc = SPI_connect()) != SPI_OK_CONNECT)
		elog(ERROR, "SPI_connect failed: %s", SPI_result_code_string(rc));
	pending_pg_error = NULL;
	{
		pure_expr  *f = pure_symbol(pure_sym("__pg_pure_do"));
		pure_expr  *arg = pure_tuplel(0);

		res = pure_appxv(f, 1, &arg, &exc);
	}
	out = pure_evalcmd("clear __pg_pure_do\n");
	free(out);
	if (!res)
	{
		SPI_finish();
		report_pure_failure(lang, "uncaught exception in DO block", exc);
	}
	pure_freenew(res);
	SPI_finish();
	PG_RETURN_VOID();
}

Datum
pg_pureu_inline_handler(PG_FUNCTION_ARGS)
{
	return inline_block("pg_pureu", false, fcinfo);
}

Datum
pg_pureu_validator(PG_FUNCTION_ARGS)
{
	validate_function("pg_pureu", false, PG_GETARG_OID(0), fcinfo);
	PG_RETURN_VOID();
}

void
_PG_init(void)
{
	if (IsBinaryUpgrade)
		return;

	DefineCustomStringVariable("pg_pure.using",
							   "Pure modules every interpreter loads.",
							   "A space- or comma-separated list passed to a "
							   "Pure \"using\" declaration when the interpreter "
							   "is created. The default, math, provides exact "
							   "rationals.",
							   &pg_pure_using,
							   "math",
							   PGC_SIGHUP,
							   GUC_SUPERUSER_ONLY,
							   NULL, NULL, NULL);
	MarkGUCPrefixReserved("pg_pure");

	/*
	 * When preloaded, build and warm both interpreters in the postmaster so
	 * every backend inherits them through fork. The first warm call pays the
	 * one-time LLVM codegen cost once, not per backend. DESIGN.md section 3.
	 */
	if (process_shared_preload_libraries_in_progress)
	{
		for (int t = 0; t < 2; t++)
		{
			pure_interp *ip = ensure_interp(t == 1);
			pure_expr  *w;
			char	   *out;

			pure_switch_interp(ip);
			w = pure_eval("__pg_pure_warm x y = (x*y+1); __pg_pure_warm 6 7;");
			if (w)
				pure_freenew(w);
			out = pure_evalcmd("clear __pg_pure_warm\n");
			free(out);
		}
	}
}
