{
  description = "libpure (the Pure language runtime) and the vetted Pure add-on modules, built from the gburd/pure-lang fork for use with pg_pure";

  # The fork carries the embeddable changes pg_pure needs (safe mode, hidden
  # LLVM symbols). It is not in nixpkgs, so a host that wants pg_pure would
  # otherwise maintain a bespoke LLVM build by hand; this flake removes that
  # cost. See pg_pure's DESIGN.md and ROADMAP 2.A.
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    pure-lang = {
      url = "github:gburd/pure-lang/libpure-embeddable";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, flake-utils, pure-lang }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        llvm = pkgs.llvmPackages_21;

        # libpure: the Pure runtime and interpreter. Built from the fork with
        # LLVM 21; GMP and MPFR are runtime math dependencies. The fork hides
        # LLVM symbols from the shared library so it can coexist with a server
        # whose own JIT links a different LLVM (DESIGN.md section 5).
        libpure = pkgs.stdenv.mkDerivation {
          pname = "libpure";
          version = "0.68-fork-${builtins.substring 0 7 pure-lang.rev}";
          src = pure-lang;
          sourceRoot = "source/pure";

          nativeBuildInputs = [ pkgs.autoreconfHook pkgs.pkg-config pkgs.bison pkgs.flex llvm.llvm.dev ];
          buildInputs = [ pkgs.gmp pkgs.mpfr pkgs.readline llvm.llvm ];

          # The configure script finds llvm-config-21 on PATH.
          preConfigure = ''
            export PATH=${llvm.llvm.dev}/bin:$PATH
          '';
          configureFlags = [ "--with-llvm-version=21" ];

          enableParallelBuilding = true;

          meta = with pkgs.lib; {
            description = "The Pure programming language runtime (gburd fork, embeddable)";
            homepage = "https://github.com/gburd/pure-lang";
            license = licenses.lgpl3Plus;
            platforms = platforms.unix;
          };
        };

        # pure-gsl: the GSL bindings, including gsl::linalg::cholesky_solve (the
        # compiled SPD solve pg_pure exposes). A plain Makefile that derives its
        # install dir from `pkg-config pure`, so point it at this libpure.
        pure-gsl = pkgs.stdenv.mkDerivation {
          pname = "pure-gsl";
          version = libpure.version;
          src = pure-lang;
          sourceRoot = "source/pure-gsl";

          nativeBuildInputs = [ pkgs.pkg-config pkgs.patchelf ];
          buildInputs = [ libpure pkgs.gsl pkgs.gmp pkgs.mpfr ];

          # Install into THIS derivation's $out, not into libpure's store path
          # (which is read-only). pure finds the module via PURELIB at runtime.
          makeFlags = [
            "prefix=${placeholder "out"}"
            "libdir=${placeholder "out"}/lib"
          ];
          installFlags = [
            "prefix=${placeholder "out"}"
            "libdir=${placeholder "out"}/lib"
          ];

          # The module's gsl.so dlopen's libgsl by bare name at runtime; give
          # it an RPATH to the gsl store path so it resolves without the caller
          # having to set LD_LIBRARY_PATH.
          postInstall = ''
            patchelf --set-rpath "${pkgs.gsl}/lib:${libpure}/lib" \
              $out/lib/pure/gsl.so
          '';

          meta = with pkgs.lib; {
            description = "GSL bindings for Pure, with a Cholesky/SPD solve in gsl::linalg";
            homepage = "https://github.com/gburd/pure-lang";
            license = licenses.gpl3Plus;
            platforms = platforms.unix;
          };
        };

        # A single prefix with libpure and the vetted modules merged, which is
        # what a host points PURE_PREFIX / PURELIB at. PURELIB must list both
        # the libpure prelude dir and the module dir.
        pure-with-modules = pkgs.symlinkJoin {
          name = "pure-with-modules-${libpure.version}";
          paths = [ libpure pure-gsl ];
        };
      in
      {
        packages = {
          inherit libpure pure-gsl pure-with-modules;
          default = pure-with-modules;
        };

        # A shell with pure on PATH and the module search path set, for trying
        # `using gsl::linalg` interactively or building pg_pure against it.
        devShells.default = pkgs.mkShell {
          packages = [ pure-with-modules pkgs.gsl pkgs.gmp pkgs.mpfr ];
          shellHook = ''
            export PURELIB=${pure-with-modules}/lib/pure
            export LD_LIBRARY_PATH=${pure-with-modules}/lib:${pkgs.gsl}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
            echo "pure $(${pure-with-modules}/bin/pure --version 2>/dev/null | head -1)"
            echo "PURE_PREFIX=${pure-with-modules}  (point pg_pure's build here)"
          '';
        };
      });
}
