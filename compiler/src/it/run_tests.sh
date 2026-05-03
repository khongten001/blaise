#!/bin/bash
#
# Blaise — An Object Pascal Compiler
# Copyright (c) 2026 Graeme Geldenhuys
# SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
# Licensed under the Apache License v2.0 with Runtime Library Exception.
# See LICENSE file in the project root for full license terms.
#
#
# Integration Test Runner for PDR Debugger — Blaise Compiler
#
# Compiles test programs using the Blaise compiler with --debug-opdf,
# then drives PDR interactively via .commands files and compares
# output against .expected files.
#
# Usage:
#   ./run_tests.sh                 — run all test_*.pas files
#   ./run_tests.sh test_02.pas     — run a single test
#   BLAISE=/path/to/blaise ./run_tests.sh
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Counters
PASSED=0
FAILED=0
SKIPPED=0

# PDR binary
PDR_BIN="pdr"

# Blaise compiler binary discovery:
#   1. BLAISE environment variable
#   2. compiler/target/blaise in the project tree
if [ -n "$BLAISE" ]; then
  BLAISE_BIN="$BLAISE"
else
  BLAISE_BIN="$PROJECT_ROOT/compiler/target/blaise"
fi

echo "=== PDR Integration Test Runner (Blaise) ==="
echo

if ! command -v "$PDR_BIN" > /dev/null 2>&1; then
  echo -e "${RED}ERROR: pdr not found in PATH${NC}"
  exit 1
fi

if [ ! -x "$BLAISE_BIN" ]; then
  echo -e "${RED}ERROR: Blaise compiler not found: $BLAISE_BIN${NC}"
  echo "  Set BLAISE=/path/to/blaise or run 'pasbuild compile -m blaise-compiler' first"
  exit 1
fi

echo "Blaise : $BLAISE_BIN"
echo "PDR    : $(command -v $PDR_BIN)"
echo

# Filter non-deterministic output — identical to the OPDF integration runner.
# Keeps: variable assignments (2+ char names), step messages, callstack frames.
# Drops: single-char names (A, B), program WriteLn output, [INFO]/[DEBUG] lines.
filter_output() {
  sed 's/^(pdr) //' | \
  sed -E 's/ \(0x[0-9A-Fa-f ]+\)//' | \
  sed -E 's/\(\$[0-9A-Fa-f]+\)/(<ptr>)/' | \
  grep -E "^(([A-Za-z][A-Za-z0-9_.]+(\[[0-9]+\])? = )|(\[INFO\] )?[Ss]tepped to line:|\[CALLSTACK\]|#[0-9]+ |Exception: [A-Za-z]+ —)" | \
  sed 's/^\[INFO\] //' || true
}

run_test() {
  local test_name=$1
  local test_base="${test_name%.pas}"

  echo -e "${YELLOW}Running: $test_base${NC}"

  # Compile with Blaise OPDF support
  echo "  [1/3] Compiling..."
  if ! "$BLAISE_BIN" --source "$test_name" --output "$test_base" --debug-opdf \
      > "$test_base.compile.log" 2>&1; then
    echo -e "${RED}  FAILED: Compilation${NC}"
    cat "$test_base.compile.log"
    ((FAILED++))
    return 1
  fi

  # Run PDR with command script
  echo "  [2/3] Running PDR..."
  if [ ! -f "$test_base.commands" ]; then
    echo -e "${YELLOW}  SKIPPED: No commands file${NC}"
    ((SKIPPED++))
    return 0
  fi
  cat "$test_base.commands" | "$PDR_BIN" --verbose "./$test_base" 2>&1 \
    | filter_output > "$test_base.actual"

  # Compare against expected output (case-insensitive, address-normalised)
  echo "  [3/3] Comparing output..."
  if [ ! -f "$test_base.expected" ]; then
    echo -e "${YELLOW}  SKIPPED: No expected file${NC}"
    ((SKIPPED++))
    return 0
  fi
  if diff -u \
      <(sed -E 's/@\$[0-9A-Fa-f]+/@$<addr>/g' "$test_base.expected" | tr '[:upper:]' '[:lower:]') \
      <(sed -E 's/@\$[0-9A-Fa-f]+/@$<addr>/g' "$test_base.actual"   | tr '[:upper:]' '[:lower:]') \
      > "$test_base.diff"; then
    echo -e "${GREEN}  PASSED${NC}"
    ((PASSED++))
    return 0
  else
    echo -e "${RED}  FAILED${NC}"
    cat "$test_base.diff"
    ((FAILED++))
    return 1
  fi
}

cd "$SCRIPT_DIR"

if [ $# -eq 1 ]; then
  TEST_NAME=$1
  [[ ! "$TEST_NAME" =~ \.pas$ ]] && TEST_NAME="${TEST_NAME}.pas"
  run_test "$TEST_NAME"
else
  for test_file in test_*_*.pas; do
    [ -f "$test_file" ] && run_test "$test_file" && echo
  done
fi

echo "==================================="
echo -e "Passed : ${GREEN}$PASSED${NC}"
echo -e "Failed : ${RED}$FAILED${NC}"
echo -e "Skipped: ${YELLOW}$SKIPPED${NC}"
echo "==================================="

[ $FAILED -eq 0 ] && exit 0 || exit 1
