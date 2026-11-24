# Releasing pg_pure

Releases are **tag-triggered**.  The version lives in `META.json` (in three
places); the git tag is `v<version>` (e.g. `v0.12.0`).  Pushing the tag to the
canonical remote (Codeberg) mirrors it to GitHub, where the Release workflow
builds the PGXN source zip, attaches it to a GitHub Release, publishes to PGXN,
and runs `ci/announce.sh` (a no-op without extra secrets; pg_pure does not post
to the PostgreSQL announce lists).

## Before you tag: the gate

All green on the EC2 build box (never on a laptop; every build and test runs on
an EC2 Debian box, ROADMAP "Decided"), for **PostgreSQL 17, 18 and 19**:

```sh
# on the box, with libpure + the vetted modules installed under $PURE_PREFIX:
for V in 17 18 19; do
  PG_CONFIG=/usr/lib/postgresql/$V/bin/pg_config PURE_PREFIX=$HOME/pure-inst \
    bash ci/gate.sh $V
done
make check-ascii
doc/build-html.sh          # the SGML must render with no errors
```

`ci/gate.sh` builds pg_pure, runs both regression suites (`pg_pureu`,
`pg_pure`) and the TAP suite (`t/*.pl`) with `jit=on` and
`pg_pure.using='math gsl::linalg'`, and fails if the server log has any
`terminated by signal` line.  A release where every case did not actually run
its own Pure code is not qualified; check the output, do not trust an exit code
(ROADMAP rule 1).

## Cut a release

1. Bump the version and land it on `main`:
   - `META.json`: the top-level `version` and both `provides.*.version`
     (leave `meta-spec.version` = 1.0.0).  The control files keep
     `default_version = '0.1'` (the SQL script version is stable across
     releases; the shared object is versioned by the tag, not the SQL).
   - Add a `CHANGELOG.md` entry under a new `## [<version>] - <date>` heading.
     Anything previously published that this release shows to be wrong goes
     under a **"Retracted"** heading, stated plainly.  The project's
     credibility rests on that heading existing (ROADMAP: "When a published
     claim turns out wrong, the CHANGELOG says so under Retracted").
   - If a benchmark number or a capability claim changed, the README and
     `doc/pg_pure.sgml` change in the same commit.  They have drifted from the
     measured numbers before.
   - If the release adds a TAP test, it goes into `ci/gate.sh` in the same
     commit (project AGENTS.md: "Every new TAP test goes into `ci/gate.sh`").
   - Stage files by explicit path.  Do not stage agent artifacts or the
     `.unison.*.tmp` sync files.
2. Commit, then push `main` to the canonical remote:
   ```sh
   git push origin main
   ```
3. Tag and push the tag:
   ```sh
   git tag -a vX.Y.Z -m "pg_pure X.Y.Z

   <one-paragraph summary of what changed>"
   git push origin vX.Y.Z
   ```
   The tag-push triggers the Release workflow once GitHub sees the tag.

## The mirror, and why to wait rather than push GitHub directly

Codeberg is the canonical `origin`; it mirrors to the GitHub repo
(`gburd/pg_pure`).  **Do not push to the GitHub mirror directly** and do not
force the two forges to diverge.  When the mirror lags (GitHub behind on the
same linear history), wait: it self-recovers, and the Release workflow fires
when the tag lands on GitHub.  GitHub Actions is the only CI (Codeberg Actions
are disabled per the AI terms of service).

The Release workflow guards against the stale-tag race itself: it refuses to
build if `META.json`'s version does not match the tag.  Still, verify after:

```sh
# a few minutes after the tag lands on GitHub:
curl -fsS -o /dev/null "https://api.pgxn.org/dist/pg_pure/X.Y.Z/META.json" \
  && echo "live on PGXN"
```

api.pgxn.org can lag the upload by several minutes; the workflow's 4-minute
poll is sometimes too short, so confirm by hand if it warns.  A `303` from the
PGXN upload is success; a `409` means either a duplicate version or a rejected
META.json (the workflow distinguishes them by the response body).

## If a duplicate workflow run appears

A `workflow_dispatch` re-run and the tag-push run can both be queued.  Keep the
tag-push run and cancel the duplicate; the tag-push run is the one that built
from the tagged commit.

## What a release produces

- `pg_pure-X.Y.Z.zip` (the PGXN source distribution, `make dist`), attached to
  the GitHub Release.
- The release on PGXN (both `pg_pure` and `pg_pureu` providers).
- The HTML reference on GitHub Pages (the Docs workflow, on push to `main`).

pg_pure ships as source: it is a C extension that links an out-of-tree libpure,
so there is no prebuilt binary or distro package.  A consumer installs libpure
(from the fork, see the README) and builds pg_pure with PGXS.
