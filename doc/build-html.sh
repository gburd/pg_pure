#!/usr/bin/env bash
# Render the DocBook <sect1> fragment doc/pg_pure.sgml to a standalone HTML page.
#
# doc/pg_pure.sgml is a fragment (as PostgreSQL's own supplied-module docs are),
# not a standalone XML document: it starts at <sect1> and uses SGML/DocBook
# entities (&rarr; &nbsp;) with no DTD. To render it we wrap it in a minimal
# DocBook <article> shell that declares those entities and pulls the fragment
# in as a system entity, then run it through the DocBook HTML XSL.
#
# Usage:  doc/build-html.sh            # needs xsltproc + the docbook-xsl-ns
#         DOCBOOK_XSL=/path/... doc/build-html.sh
#
# Env:
#   XSLTPROC      xsltproc binary (default: xsltproc on PATH)
#   DOCBOOK_XSL   path to the docbook html/docbook.xsl (auto-detected if unset)
#   OUTDIR        output directory (default: doc/html)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
src="$here/pg_pure.sgml"
outdir="${OUTDIR:-$here/html}"
xsltproc_bin="${XSLTPROC:-xsltproc}"

# Locate the DocBook HTML stylesheet if not given.
if [ -z "${DOCBOOK_XSL:-}" ]; then
  for c in \
    /usr/share/xml/docbook/stylesheet/docbook-xsl-ns/html/docbook.xsl \
    /usr/share/xml/docbook/stylesheet/nwalsh/html/docbook.xsl \
    /usr/share/sgml/docbook/xsl-ns-stylesheets/html/docbook.xsl; do
    [ -f "$c" ] && DOCBOOK_XSL="$c" && break
  done
fi
if [ -z "${DOCBOOK_XSL:-}" ] || [ ! -f "$DOCBOOK_XSL" ]; then
  echo "error: docbook-xsl HTML stylesheet not found; set DOCBOOK_XSL=/path/to/html/docbook.xsl" >&2
  exit 1
fi

mkdir -p "$outdir"
wrapper="$(mktemp -d)/pg_pure-doc.xml"
# The fragment is referenced by absolute path as a system entity; the entity
# declarations supply the DocBook character entities the XSL does not define.
cat > "$wrapper" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE article [
  <!ENTITY mdash "&#8212;">
  <!ENTITY rarr  "&#8594;">
  <!ENTITY nbsp  "&#160;">
  <!ENTITY pgpure SYSTEM "$src">
]>
<article lang="en">
  <title>pg_pure - write PostgreSQL functions in Pure</title>
  &pgpure;
</article>
XML

"$xsltproc_bin" --nonet --novalid -o "$outdir/pg_pure.html" "$DOCBOOK_XSL" "$wrapper"

# The DocBook XSL emits a legacy ISO-8859-1 <meta>; all non-ASCII output is
# numeric character references, so normalize the declared charset to UTF-8.
sed -i 's/charset=ISO-8859-1/charset=UTF-8/' "$outdir/pg_pure.html"

# A trivial index.html so a Pages site root lands on the reference doc.
cp "$outdir/pg_pure.html" "$outdir/index.html"

rm -rf "$(dirname "$wrapper")"
echo "OK: rendered $outdir/pg_pure.html (and index.html)"
