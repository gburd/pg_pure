# Nix package for libpure and the vetted Pure modules

The Pure runtime pg_pure embeds (libpure) is not in nixpkgs, and it must be
built from the `gburd/pure-lang` fork against a recent LLVM. This flake does
that build once, so a host that wants to run pg_pure does not have to maintain
a bespoke LLVM build by hand. (This is the pg.ddx.io evaluation's top
operational blocker; see pg_pure's ROADMAP phase 2.A.)

## What it provides

- `packages.libpure` -- the Pure runtime and interpreter, LLVM 21, with its
  LLVM symbols hidden so it coexists with a PostgreSQL whose own JIT links a
  different LLVM (DESIGN.md section 5).
- `packages.pure-gsl` -- the GSL bindings, including
  `gsl::linalg::cholesky_solve` (the compiled SPD solve pg_pure exposes).
- `packages.pure-with-modules` (the default) -- libpure and the modules merged
  into one prefix, which is what you point `PURE_PREFIX` / `PURELIB` at.
- `devShells.default` -- a shell with `pure` on `PATH` and `PURELIB` set.

## Use it

Build the merged prefix:

    nix build github:gburd/pg_pure?dir=nix#pure-with-modules
    # ./result is a prefix with bin/pure, lib/libpure.so, lib/pure/gsl/...

Try the compiled solve interactively:

    nix develop github:gburd/pg_pure?dir=nix
    $ echo 'using gsl::linalg; gsl::linalg::cholesky_solve (dmatrix {4.0,1.0;1.0,3.0}) (dmatrix {1.0;2.0});' | pure -i -q
    {0.0909090909090909,0.636363636363636}

Build pg_pure against it (from the repo root, with a PostgreSQL's pg_config):

    make PG_CONFIG=/path/to/pg_config PURE_PREFIX="$(nix build --no-link --print-out-paths .#pure-with-modules)"

## Notes

- Pin the fork: the `pure-lang` input tracks the `libpure-embeddable` branch.
  Run `nix flake update pure-lang` to move to a newer fork commit, then
  re-qualify pg_pure against it.
- Known cosmetic warning: loading a gsl module prints
  `gsl/common.pure, line 12: libgsl: cannot open shared object file`. This is
  the fork module's redundant explicit `using "lib:libgsl"`; the module still
  loads (its gsl.so carries the correct RPATH) and results are correct. The
  fix belongs in the fork's common.pure, not here.
- Because the libraries are built against the Nix glibc, the cleanest result
  is when pg_pure is also built under Nix (or at least run against the Nix
  loader). Mixing a Nix-built libpure with a host-built server can surface a
  glibc version mismatch; build the whole stack under one toolchain.
