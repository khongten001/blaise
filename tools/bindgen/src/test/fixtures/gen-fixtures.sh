#!/bin/sh
# Regenerate the checked-in clang AST fixtures.  Run from this directory.
# Requires clang (any version >= 16; format is stable for what we consume).
set -e
clang -Xclang -ast-dump=json -fsyntax-only sample.h > sample.json
echo "sample.json regenerated: $(wc -c < sample.json) bytes"
