#!/usr/bin/env bash
# Per-unit RTL archive link guard for the Blaise toolchain.
#
# WHAT IT GUARDS:
#   The RTL Makefile builds blaise_rtl.a as an archive of SEPARATE per-unit
#   objects (runtime.atomic.o, runtime.mem.o, …), each compiled
#   whole-program-per-unit (--no-incremental, WITHOUT --skip-dep-codegen).
#   In that mode a dependency unit's bodies are inlined into every importing
#   object, so two archive members can end up defining the same bare RTL
#   symbol.  When an end-user program pulls BOTH members at link time (e.g.
#   _AtomicAddInt32 defined in both runtime.atomic.o and runtime.mem.o once
#   runtime.mem started using runtime.atomic), ld reports a multiple-definition
#   error and the link fails.  This is exactly GH #180.
#
#   The fix emits RTL-owned function symbols WEAK (mirroring the RTL-global
#   weak treatment of GH #174), so duplicate copies collapse at link time.
#   This script asserts a trivial program links against the archive and runs.
#
# WHY IT EXISTS, separately from the other fixpoints:
#   - fixpoint.sh / fixpoint-native.sh drive the WHOLE-PROGRAM model (every
#     unit AppendUnit'd into ONE object), so there is only one object and no
#     cross-member duplicate can arise.
#   - The e2e test harness (TE2ETestCase) also uses the whole-program model
#     and source-builds the RTL — it never links against a per-unit archive.
#   - The compiler's own link pulls each RTL symbol from only the FIRST
#     defining member, so a duplicate that only bites when a SECOND member is
#     also pulled stays invisible.
#   None of them link an ordinary program against the per-unit archive the way
#   an end user (and the RTL Makefile) does — this script is the only guard
#   that does.
#
# Requires: a compiler at compiler/target/blaise, vendor/qbe/qbe (for the QBE
# arm), and gcc (external link).

set -e

if [ ! -f "compiler/src/main/pascal/Blaise.pas" ]; then
  echo "Run this script from the project root: ./scripts/fixpoint-rtl-archive.sh" >&2
  exit 1
fi

COMPILER="${1:-compiler/target/blaise}"
if [ ! -x "$COMPILER" ]; then
  echo "Compiler not found: $COMPILER" >&2
  echo "Build it first: pasbuild compile -m blaise-compiler --compiler ..." >&2
  exit 10
fi

UNIT_ARGS="--unit-path runtime/src/main/pascal --unit-path stdlib/src/main/pascal"

# Build the per-unit RTL archive with the DEFAULT Makefile flags — this is the
# path that produces the multiply-defined members.  make install copies the
# archive to compiler/target/blaise_rtl.a beside the compiler binary.
echo "[1/4] build per-unit RTL archive (default Makefile flags)"
( cd runtime && make clean >/dev/null 2>&1 && make >/tmp/fra_rtl.log 2>&1 \
    && make install >>/tmp/fra_rtl.log 2>&1 ) || {
  echo "RTL_BUILD_FAIL"; tail -20 /tmp/fra_rtl.log; exit 2; }

ARCHIVE=compiler/target/blaise_rtl.a
if [ ! -f "$ARCHIVE" ]; then
  echo "ARCHIVE_MISSING $ARCHIVE"; exit 3
fi

# Assert there are no STRONG (T/D) duplicate definitions across archive members.
# Weak (W) duplicates are expected and legal — the linker keeps one.
echo "[2/4] check for strong duplicate definitions in the archive"
DUPS=$(nm "$ARCHIVE" 2>/dev/null | awk '/ [TD] /{print $3}' | sort | uniq -d)
if [ -n "$DUPS" ]; then
  echo "STRONG_DUPLICATE_SYMBOLS (would fail an end-user link):"
  echo "$DUPS"
  exit 4
fi

# A trivial program: linking it against the archive must not hit a
# multiple-definition error.  WriteLn + the implicit RTL startup pull the
# memory manager (runtime.mem) and its atomic dependency (runtime.atomic) —
# the two members that clashed in GH #180.
PROG=/tmp/fra_hello.pas
cat > "$PROG" <<'PROG_EOF'
program fra_hello;
begin
  WriteLn('Hello');
end.
PROG_EOF

echo "[3/4] QBE arm: compile -> qbe -> gcc link against the archive -> run"
if ! "$COMPILER" --source "$PROG" $UNIT_ARGS --backend qbe --emit-ir \
     > /tmp/fra_hello.ssa 2>/tmp/fra_qbe.err; then
  echo "QBE_EMIT_FAIL"; head -5 /tmp/fra_qbe.err; exit 5
fi
vendor/qbe/qbe -o /tmp/fra_hello.s /tmp/fra_hello.ssa
if ! gcc -o /tmp/fra_hello_q /tmp/fra_hello.s "$ARCHIVE" 2>/tmp/fra_qlink.err; then
  echo "QBE_LINK_FAIL (multiple-definition regression?)"; head -12 /tmp/fra_qlink.err; exit 6
fi
OUT=$(/tmp/fra_hello_q); RC=$?
if [ "$RC" -ne 0 ] || [ "$OUT" != "Hello" ]; then
  echo "QBE_RUN_FAIL rc=$RC out=[$OUT]"; exit 7
fi

echo "[4/4] native arm: compile+link against the archive -> run"
# The default native pipeline links the RTL itself; force the archive link path
# by using the external linker against the just-built archive is implicit in the
# driver's FindRTL (it links compiler/target/blaise_rtl.a).  A successful
# native build+run confirms the native arm too.
if ! "$COMPILER" --source "$PROG" $UNIT_ARGS --output /tmp/fra_hello_n \
     2>/tmp/fra_nlink.err; then
  echo "NATIVE_LINK_FAIL (multiple-definition regression?)"; head -12 /tmp/fra_nlink.err; exit 8
fi
OUT=$(/tmp/fra_hello_n); RC=$?
if [ "$RC" -ne 0 ] || [ "$OUT" != "Hello" ]; then
  echo "NATIVE_RUN_FAIL rc=$RC out=[$OUT]"; exit 9
fi

echo "RTL_ARCHIVE_OK"
exit 0
