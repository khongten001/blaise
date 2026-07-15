#!/bin/sh
# Regenerate the checked-in clang fixtures.  Run from this directory.
# Requires clang (any version >= 16; format is stable for what we consume).
set -e
clang -Xclang -ast-dump=json -fsyntax-only sample.h > sample.json
clang -E -dD -w sample.h > sample.defines
# The probe mirrors what Bindgen.Macros builds at runtime: one
# (long long)-cast static const per candidate object-like macro.
cat > sample_probe.c <<PROBE
#include "sample.h"
static const long long __bgm_SAMPLE_A = (long long)(SAMPLE_A);
static const long long __bgm_SAMPLE_MASK = (long long)(SAMPLE_MASK);
static const long long __bgm_SAMPLE_NEG = (long long)(SAMPLE_NEG);
static const long long __bgm_SAMPLE_ALL = (long long)(SAMPLE_ALL);
static const long long __bgm_SAMPLE_COMBO = (long long)(SAMPLE_COMBO);
static const long long __bgm_SAMPLE_TYPE = (long long)(SAMPLE_TYPE);
PROBE
clang -Xclang -ast-dump=json -fsyntax-only -w sample_probe.c > sample_probe.json || true
rm sample_probe.c
echo "fixtures regenerated: $(wc -c < sample.json) / $(wc -c < sample.defines) / $(wc -c < sample_probe.json) bytes"
