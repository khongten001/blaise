#!/usr/bin/env bash
#
# Blaise — An Object Pascal Compiler
# Copyright (c) 2026 Graeme Geldenhuys
# SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
# Licensed under the Apache License v2.0 with Runtime Library Exception.
# See LICENSE file in the project root for full license terms.
#
# Integration test: ARC string management end-to-end
#
# Tests that a Blaise program with string variables:
#   1. Compiles successfully (RTL stubs linked)
#   2. Produces correct output
#   3. Exits cleanly (no segfault from ARC calls)
#
# Usage: ./test_arc_strings.sh [path/to/blaise]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BLAISE="${1:-$PROJECT_ROOT/compiler/target/bin/blaise}"
TMPDIR_RUN="$(mktemp -d)"
PASS=0
FAIL=0

trap 'rm -rf "$TMPDIR_RUN"' EXIT

# ── helpers ──────────────────────────────────────────────────────────────────

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }

compile() {
  local src="$1" out="$2"
  "$BLAISE" --source "$src" --output "$out" 2>&1
}

# ── test 1: string literal assignment and WriteLn ────────────────────────────

cat > "$TMPDIR_RUN/t1.pas" << 'EOF'
program T1;
var
  s: string;
begin
  s := 'Hello, ARC!';
  WriteLn(s)
end.
EOF

if compile "$TMPDIR_RUN/t1.pas" "$TMPDIR_RUN/t1" > "$TMPDIR_RUN/t1.log" 2>&1; then
  ACTUAL="$("$TMPDIR_RUN/t1")"
  if [ "$ACTUAL" = "Hello, ARC!" ]; then
    pass "string assignment + WriteLn(var)"
  else
    fail "string assignment + WriteLn(var)" "expected 'Hello, ARC!' got '$ACTUAL'"
  fi
else
  fail "string assignment + WriteLn(var)" "compile failed: $(cat "$TMPDIR_RUN/t1.log")"
fi

# ── test 2: two string vars, both released at block exit ─────────────────────

cat > "$TMPDIR_RUN/t2.pas" << 'EOF'
program T2;
var
  a, b: string;
begin
  a := 'first';
  b := 'second';
  WriteLn(a);
  WriteLn(b)
end.
EOF

if compile "$TMPDIR_RUN/t2.pas" "$TMPDIR_RUN/t2" > "$TMPDIR_RUN/t2.log" 2>&1; then
  ACTUAL="$("$TMPDIR_RUN/t2")"
  EXPECTED="$(printf 'first\nsecond')"
  if [ "$ACTUAL" = "$EXPECTED" ]; then
    pass "two string vars, ARC cleanup"
  else
    fail "two string vars, ARC cleanup" "expected '$EXPECTED' got '$ACTUAL'"
  fi
else
  fail "two string vars, ARC cleanup" "compile failed: $(cat "$TMPDIR_RUN/t2.log")"
fi

# ── test 3: string var reassignment (AddRef + Release cycle) ─────────────────

cat > "$TMPDIR_RUN/t3.pas" << 'EOF'
program T3;
var
  s: string;
begin
  s := 'first value';
  s := 'second value';
  WriteLn(s)
end.
EOF

if compile "$TMPDIR_RUN/t3.pas" "$TMPDIR_RUN/t3" > "$TMPDIR_RUN/t3.log" 2>&1; then
  ACTUAL="$("$TMPDIR_RUN/t3")"
  if [ "$ACTUAL" = "second value" ]; then
    pass "string reassignment (AddRef/Release cycle)"
  else
    fail "string reassignment (AddRef/Release cycle)" "expected 'second value' got '$ACTUAL'"
  fi
else
  fail "string reassignment (AddRef/Release cycle)" "compile failed: $(cat "$TMPDIR_RUN/t3.log")"
fi

# ── test 4: empty program (no strings) still links ───────────────────────────

cat > "$TMPDIR_RUN/t4.pas" << 'EOF'
program T4;
begin end.
EOF

if compile "$TMPDIR_RUN/t4.pas" "$TMPDIR_RUN/t4" > "$TMPDIR_RUN/t4.log" 2>&1; then
  EXIT_CODE=0
  "$TMPDIR_RUN/t4" || EXIT_CODE="$?"
  if [ "$EXIT_CODE" = "0" ]; then
    pass "empty program links and exits clean"
  else
    fail "empty program links and exits clean" "exit code $EXIT_CODE"
  fi
else
  fail "empty program links and exits clean" "compile failed: $(cat "$TMPDIR_RUN/t4.log")"
fi

# ── summary ──────────────────────────────────────────────────────────────────

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
