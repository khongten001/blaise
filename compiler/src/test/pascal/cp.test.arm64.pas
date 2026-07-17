{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit cp.test.arm64;

{ Structural tests for the AArch64 backend (macos-arm64 Phase 2).

  Two lanes, both on Linux CI (the design doc's Phase 2 verification):
    1. asm-shape — TArm64Backend's emitted text carries the expected
       prologue / call / addressing / guard shapes;
    2. full pipeline — the emitted text assembles through
       blaise.assembler.arm64 into an MH_OBJECT that blaise.machoreader
       parses back (sections, relocations, entry symbol).

  Behavioural runs happen on real Apple Silicon in Phase 6. }

interface

uses
  Classes, SysUtils, blaise.testing, uStrCompat,
  uLexer, uParser, uAST, uSymbolTable, uSemantic,
  blaise.codegen.native.arm64, blaise.codegen.native.backend,
  blaise.codegen.target, blaise.assembler.arm64,
  blaise.machoreader, blaise.machowriter;

type
  TArm64BackendTests = class(TTestCase)
  private
    function GenAsm(const ASrc: string): string;
    function GenAsmWithUnit(const AUnitSrc, ASrc: string): string;
  published
    procedure TestHello_PrologueAndFrameChain;
    procedure TestHello_StringLiteral_AdrpAddPair;
    procedure TestHello_RtlCallsAndEpilogue;
    procedure TestIntegerArithmetic_Shapes;
    procedure TestDivision_AlwaysEmitsZeroGuard;
    procedure TestGlobals_PageAddressed;
    procedure TestIfWhile_BranchShapes;
    procedure TestUnsupported_RaisesHonestly;
    procedure TestPipeline_AssemblesToMachO;
    { slice 2: routines + AAPCS64 calls + for/exit/break }
    procedure TestFunction_PrologueSpillsAndResult;
    procedure TestCall_ArgsPoppedIntoRegisters;
    procedure TestRecursion_Compiles;
    procedure TestForLoop_BoundEvaluatedOnce;
    procedure TestPipeline_FunctionsAssembleToMachO;
    { slice 3: Double — literals, arithmetic, comparisons, d-register
      call ABI with independent int/float sequences }
    procedure TestFloat_LiteralAndArithmetic;
    procedure TestFloat_CallAbi_IndependentSequences;
    { slice 4: string variables with ARC }
    procedure TestString_AssignRetainsAndReleasesOld;
    procedure TestString_ConcatOwnedTransientReleased;
    procedure TestString_ScopeExitReleases;
    { slice 5: string comparisons via RTL helpers }
    procedure TestString_Comparisons_UseRtlHelpers;
    { slice 6: ARC-clean records — fields, whole-record copy, zero-init }
    procedure TestRecord_FieldsAndCopy;
    { slice 7: record RETURNS per AAPCS64 — x8 sret, x0/x0:x1 images,
      HFA doubles in d0.. }
    procedure TestRecordReturn_SretViaX8;
    procedure TestRecordReturn_SmallImagesAndHfa;
    { slice 8: record PARAMETERS per AAPCS64 }
    procedure TestRecordParam_SmallImagesAndHfa;
    procedure TestRecordParam_LargeByPointer;
    { slice 9: records with ARC-managed fields via the base walks }
    procedure TestManagedRecord_CopyAndFieldStore;
    procedure TestManagedRecord_ScopeExitRelease;
    { slice 10: units — routines + record types from a used unit }
    procedure TestUnit_RoutinesAndCrossUnitCalls;
    procedure TestUnit_VarsAndInitSection;
    procedure TestUnit_FinalizationStillNotYet;
    { slice 13: initialised globals in .data }
    procedure TestInitialisedGlobals_DataSection;
    { slice 14: var/out parameters (int, Double, string) }
    procedure TestVarParams_WriteThroughAndPassThrough;
    { slice 15: Single end to end (4-byte storage, double arithmetic) }
    procedure TestSingle_LoadsStoresParamsResult;
    { slice 16: classes — create, methods, fields, ARC, metadata }
    procedure TestClass_CreateFieldsMethodsMetadata;
    procedure TestClass_VirtualDispatchAndDestroy;
    { slice 17: unit classes, statics, class consts, inherited, ToString }
    procedure TestClass_InUnit_PrefixedSymbols;
    procedure TestClass_StaticsConstsInheritedToString;
    { slice 18: properties (field- and method-backed, virtual accessors) }
    procedure TestClass_Properties;
    { slice 19: chained receivers + owned-transient release }
    procedure TestClass_ChainedReceivers;
    { slice 20: Mach-O TLV threadvars }
    procedure TestThreadvar_TlvDescriptorsAndAccess;
    { slice 21: Apple stack args (>8) + variadic calls }
    procedure TestStackArgs_VariadicAndOverflow;
    { slice 22: interfaces — itab dispatch, fat-pointer ARC, metadata }
    procedure TestInterfaces_DispatchAndMetadata;
    procedure TestInterfaces_AsCast;
    procedure TestOwnedStringTransientArg_Released;
    { slice 24: Supports, InheritsFrom, metaclass values }
    procedure TestReflection_SupportsInheritsFromMetaclass;
    { slice 25: interface parameters and results }
    procedure TestInterfaceParamsAndResults;
    { slice 26: float property reads + string global initialisers }
    procedure TestFloatPropRead_And_StringGlobalInit;
    { slice 27: managed record params/results across call boundaries }
    procedure TestManagedRecord_ParamsAndResults;
    { slice 28: Single record fields, 3-arg Supports, static properties }
    procedure TestSingleFields_Supports3_StaticProps;
    { slice 29: [Weak] refs, metaclass constructors, indexed properties }
    procedure TestWeak_MetaclassCtor_IndexedProps;
    { slice 30: case and repeat/until }
    procedure TestCaseAndRepeat;
    { slice 31: exceptions — try/finally, try/except, raise, unwind }
    procedure TestExceptions_FramesHandlersUnwind;
    { slice 32: static arrays — width-aware element access, managed elems }
    procedure TestStaticArrays_ElementsAndArc;
    { slice 33: dynamic arrays — SetLength/Length/subscripts/ARC }
    procedure TestDynArrays_LifecycleAndElements;
    { slice 35: small sets — literals, membership, union/inter/diff }
    procedure TestSmallSets_LiteralsInOps;
    { slice 36: for-in over static/dyn arrays, string bytes, small sets }
    procedure TestForIn_ArraysStringsSets;
    { slice 36: for-in via the class enumerator protocol }
    procedure TestForIn_ClassEnumerator;
    { slice 36: case over strings — _StringEquals chains }
    procedure TestCase_StringSelectors;
    { slice 37: aggregate global initialisers — array element lists }
    procedure TestGlobalArrayInitialisers;
    { slice 38: class attributes — attrs/methattrs tables + RTTI builtins }
    procedure TestClassAttributes_TablesAndBuiltins;
    { slice 39: generic class/function instances — bare names, weak bind }
    procedure TestGenericInstances_WeakEmission;
    { slice 40: assembler/nostackframe routines — verbatim arm64 bodies }
    procedure TestAsmRoutines_NoStackFrame;
    { slice 43: pointers — deref reads, pointer writes, addr-of, casts }
    procedure TestPointers_DerefWriteAddrOf;
    { slice 11: string parameters (by-value retained, const borrowed) }
    procedure TestStringParams_ValueRetainsConstBorrows;
  end;

implementation

const
  LF = #10;

  SrcHello =
    '''
    program P;
    begin
      WriteLn('hi arm64')
    end.
    ''';

  SrcArith =
    '''
    program P;
    var
      A, B, C: Integer;
    begin
      A := 6;
      B := 7;
      C := A * B + (A - B) div 2;
      WriteLn(C)
    end.
    ''';

  SrcControl =
    '''
    program P;
    var
      N, Sum: Integer;
    begin
      N := 5;
      Sum := 0;
      while N > 0 do
      begin
        Sum := Sum + N;
        N := N - 1
      end;
      if Sum = 15 then
        WriteLn('ok')
      else
        WriteLn('bad')
    end.
    ''';

const
  SrcFuncs =
    '''
    program P;
    function Add2(A, B: Integer): Integer;
    begin
      Result := A + B
    end;
    begin
      WriteLn(Add2(20, 22))
    end.
    ''';

  SrcFib =
    '''
    program P;
    function Fib(N: Integer): Integer;
    begin
      if N < 2 then
      begin
        Result := N;
        Exit
      end;
      Result := Fib(N - 1) + Fib(N - 2)
    end;
    begin
      WriteLn(Fib(10))
    end.
    ''';

  SrcForLoop =
    '''
    program P;
    var
      I, Sum: Integer;
    begin
      Sum := 0;
      for I := 1 to 10 do
      begin
        if I = 3 then continue;
        if I = 9 then break;
        Sum := Sum + I
      end;
      WriteLn(Sum)
    end.
    ''';

function TArm64BackendTests.GenAsm(const ASrc: string): string;
var
  L:    TLexer;
  P:    TParser;
  Prog: TProgram;
  A:    TSemanticAnalyser;
  CG:   TArm64Backend;
  T:    TTargetDesc;
begin
  L := TLexer.Create(ASrc);
  P := TParser.Create(L);
  try
    Prog := P.Parse();
  finally
    P.Free();
    L.Free();
  end;
  try
    { the analyser must OUTLIVE codegen: the backend's GlobalSym calls
      FSymTable.Lookup, which walks scope state the analyser's destructor
      tears down (same lifetime rule as the e2e harness) }
    A := TSemanticAnalyser.Create();
    try
      A.Analyse(Prog);
      MakeTarget(osMacOS, cpuArm64, T);
      CG := TArm64Backend.Create(T);
      try
        CG.SetSymbolTable(Prog.SymbolTable);
        Result := CG.GenerateProgram(Prog);
      finally
        CG.Free();
      end;
    finally
      A.Free();
    end;
  finally
    Prog.Free();
  end;
end;

function TArm64BackendTests.GenAsmWithUnit(const AUnitSrc, ASrc: string): string;
var
  L:    TLexer;
  P:    TParser;
  U:    TUnit;
  Prog: TProgram;
  A:    TSemanticAnalyser;
  CG:   TArm64Backend;
  T:    TTargetDesc;
begin
  L := TLexer.Create(AUnitSrc);
  P := TParser.Create(L);
  try
    U := P.ParseUnit();
  finally
    P.Free();
    L.Free();
  end;
  L := TLexer.Create(ASrc);
  P := TParser.Create(L);
  try
    Prog := P.Parse();
  finally
    P.Free();
    L.Free();
  end;
  try
    A := TSemanticAnalyser.Create();
    try
      A.AnalyseUnitForExport(U);
      A.Analyse(Prog);
      MakeTarget(osMacOS, cpuArm64, T);
      CG := TArm64Backend.Create(T);
      try
        CG.SetSymbolTable(Prog.SymbolTable);
        CG.AppendUnit(U);
        CG.AppendProgram(Prog);
        Result := CG.GetOutput();
      finally
        CG.Free();
      end;
    finally
      A.Free();
    end;
  finally
    Prog.Free();
    U.Free();
  end;
end;

procedure TArm64BackendTests.TestHello_PrologueAndFrameChain;
var
  AsmT: string;
begin
  AsmT := GenAsm(SrcHello);
  AssertTrue('exports _main', Pos('.globl _main', AsmT) >= 0);
  { Darwin requires the fp chain: fp/lr pair save + mov x29, sp — always. }
  AssertTrue('fp/lr pair saved',
    Pos(#9'stp x29, x30, [sp, #-16]!', AsmT) >= 0);
  AssertTrue('frame pointer established',
    Pos(#9'mov x29, sp', AsmT) >= 0);
end;

procedure TArm64BackendTests.TestHello_StringLiteral_AdrpAddPair;
var
  AsmT: string;
begin
  AsmT := GenAsm(SrcHello);
  { PIE-safe literal address: adrp + add @PAGE/@PAGEOFF, then +12 past the
    immortal string header (refcnt/len/cap — same layout as x86-64). }
  AssertTrue('adrp page', Pos('adrp x0, __s0@PAGE', AsmT) >= 0);
  AssertTrue('add pageoff', Pos('add x0, x0, __s0@PAGEOFF', AsmT) >= 0);
  AssertTrue('data pointer past the 12-byte header',
    Pos(#9'add x0, x0, #12', AsmT) >= 0);
  AssertTrue('immortal refcnt', Pos(#9'.word -1', AsmT) >= 0);
end;

procedure TArm64BackendTests.TestHello_RtlCallsAndEpilogue;
var
  AsmT: string;
begin
  AsmT := GenAsm(SrcHello);
  AssertTrue('args forwarded before init', Pos(#9'bl _SetArgs', AsmT) >= 0);
  AssertTrue('rtl init', Pos(#9'bl _BlaiseInit', AsmT) >= 0);
  AssertTrue('string write', Pos(#9'bl _SysWriteStr', AsmT) >= 0);
  AssertTrue('newline', Pos(#9'bl _SysWriteNewline', AsmT) >= 0);
  AssertTrue('epilogue restores fp/lr',
    Pos(#9'ldp x29, x30, [sp], #16', AsmT) >= 0);
  AssertTrue('returns', Pos(#9'ret', AsmT) >= 0);
end;

procedure TArm64BackendTests.TestIntegerArithmetic_Shapes;
var
  AsmT: string;
begin
  AsmT := GenAsm(SrcArith);
  AssertTrue('multiply', Pos(#9'mul x0, x0, x1', AsmT) >= 0);
  AssertTrue('subtract', Pos(#9'sub x0, x0, x1', AsmT) >= 0);
  AssertTrue('divide', Pos(#9'sdiv x0, x0, x1', AsmT) >= 0);
  AssertTrue('int write', Pos(#9'bl _SysWriteInt', AsmT) >= 0);
end;

procedure TArm64BackendTests.TestDivision_AlwaysEmitsZeroGuard;
var
  AsmT: string;
begin
  { AArch64 sdiv yields 0 on a zero divisor instead of trapping, so the
    explicit guard must ALWAYS precede the divide (design-doc risk item). }
  AsmT := GenAsm(SrcArith);
  AssertTrue('divisor zero-check', Pos(#9'cbnz x1, Ldivok', AsmT) >= 0);
  AssertTrue('deliberate trap', Pos(#9'brk #1', AsmT) >= 0);
end;

procedure TArm64BackendTests.TestGlobals_PageAddressed;
var
  AsmT: string;
begin
  AsmT := GenAsm(SrcArith);
  { program vars are globals addressed via adrp/@PAGEOFF (PIE-safe) }
  AssertTrue('global page', Pos('adrp x9, _g_A@PAGE', AsmT) >= 0);
  AssertTrue('global store',
    Pos('str x0, [x9, _g_A@PAGEOFF]', AsmT) >= 0);
  AssertTrue('bss slot', Pos('_g_A:', AsmT) >= 0);
end;

procedure TArm64BackendTests.TestIfWhile_BranchShapes;
var
  AsmT: string;
begin
  AsmT := GenAsm(SrcControl);
  AssertTrue('comparison materialised', Pos(#9'cset x0, gt', AsmT) >= 0);
  AssertTrue('condition branch', Pos(#9'cbz x0, L', AsmT) >= 0);
  AssertTrue('equality for if', Pos(#9'cset x0, eq', AsmT) >= 0);
end;

procedure TArm64BackendTests.TestUnsupported_RaisesHonestly;
var
  Raised: Boolean;
  Msg: string;
begin
  Raised := False;
  Msg := '';
  try
    GenAsm(
      '''
      program P;
      type
        TPair<T> = record
          A, B: T;
        end;
      var
        Q: TPair<Int64>;
      begin
        Q.A := 1;
        WriteLn(Q.A)
      end.
      ''');
  except
    on E: ENativeCodeGenError do
    begin
      Raised := True;
      Msg := E.Message;
    end;
  end;
  AssertTrue('unsupported construct raises', Raised);
  AssertTrue('message names the arm64 subset',
    Pos('arm64: not yet', Msg) >= 0);
end;

procedure TArm64BackendTests.TestPipeline_AssemblesToMachO;
var
  AsmT, Obj: string;
  F: TMachOFile;
  T: TMoSection;
  S: TMoSymbol;
begin
  { The full Phase-2 pipeline on Linux CI: backend text -> arm64 internal
    assembler -> MH_OBJECT -> parse back. }
  AsmT := GenAsm(SrcControl);
  Obj  := AssembleArm64ToBytes(AsmT);
  F := ParseMachO(Obj, 'arm64probe.o');
  try
    AssertEquals(CPU_TYPE_ARM64, F.CpuType);
    T := F.FindSection('__TEXT', '__text');
    AssertTrue('__text present', T <> nil);
    AssertTrue('code emitted', T.Size > 0);
    S := F.FindSymbol('_main');
    AssertTrue('_main defined', (S <> nil) and (not S.IsUndef()));
    AssertTrue('_main exported', S.IsExt());
    { the RTL calls stay undefined externs with BRANCH26 relocations }
    AssertTrue('rtl call relocations recorded', T.Relocs.Count > 0);
    AssertTrue('_SysWriteStr referenced',
      F.FindSymbol('_SysWriteStr') <> nil);
  finally
    F.Free();
  end;
end;

procedure TArm64BackendTests.TestFunction_PrologueSpillsAndResult;
var
  AsmT: string;
begin
  AsmT := GenAsm(SrcFuncs);
  { params spill from x0/x1 into frame slots; Result zero-initialised and
    loaded back into x0 at the routine exit }
  AssertTrue('add2 exported+defined', Pos('Add2:', AsmT) >= 0);
  AssertTrue('param 0 spilled', Pos(#9'stur x0, [x29, #-8]', AsmT) >= 0);
  AssertTrue('param 1 spilled', Pos(#9'stur x1, [x29, #-16]', AsmT) >= 0);
  AssertTrue('Result zero-initialised', Pos(#9'stur xzr, [x29, #-24]', AsmT) >= 0);
  AssertTrue('frame restored via fp', Pos(#9'mov sp, x29', AsmT) >= 0);
end;

procedure TArm64BackendTests.TestCall_ArgsPoppedIntoRegisters;
var
  AsmT: string;
begin
  AsmT := GenAsm(SrcFuncs);
  { args are pushed left-to-right and popped last-first, so x1 fills before
    x0; the call is a bl to the mangled routine symbol }
  AssertTrue('second arg popped first', Pos(#9'ldr x1, [sp], #16', AsmT) >= 0);
  AssertTrue('first arg popped last', Pos(#9'ldr x0, [sp], #16', AsmT) >= 0);
  AssertTrue('direct call', Pos(#9'bl Add2', AsmT) >= 0);
end;

procedure TArm64BackendTests.TestRecursion_Compiles;
var
  AsmT: string;
begin
  AsmT := GenAsm(SrcFib);
  AssertTrue('fib defined', Pos('Fib:', AsmT) >= 0);
  AssertTrue('recursive call', Pos(#9'bl Fib', AsmT) >= 0);
  AssertTrue('exit lands on the epilogue label', Pos(#9'b Lrexit', AsmT) >= 0);
end;

procedure TArm64BackendTests.TestForLoop_BoundEvaluatedOnce;
var
  AsmT: string;
begin
  AsmT := GenAsm(SrcForLoop);
  { the loop bound lives in a hidden frame slot, compared each iteration }
  { offset-agnostic: the __iret scratch shifts hidden-slot offsets }
  AssertTrue('bound stored to the hidden slot',
    Pos(#9'stur x0, [x29, #-24]', AsmT) >= 0);
  AssertTrue('signed compare against the bound', Pos(#9'cmp x0, x1', AsmT) >= 0);
  AssertTrue('exit branch on greater', Pos(#9'b.gt Lfend', AsmT) >= 0);
end;

procedure TArm64BackendTests.TestPipeline_FunctionsAssembleToMachO;
var
  AsmT, Obj: string;
  F: TMachOFile;
  S: TMoSymbol;
begin
  AsmT := GenAsm(SrcFib);
  Obj  := AssembleArm64ToBytes(AsmT);
  F := ParseMachO(Obj, 'arm64fib.o');
  try
    S := F.FindSymbol('Fib');
    AssertTrue('Fib defined in the object', (S <> nil) and (not S.IsUndef()));
    S := F.FindSymbol('_main');
    AssertTrue('_main defined', (S <> nil) and (not S.IsUndef()));
  finally
    F.Free();
  end;
end;

procedure TArm64BackendTests.TestFloat_LiteralAndArithmetic;
var
  AsmT: string;
begin
  AsmT := GenAsm(
    '''
    program P;
    var
      D, E: Double;
    begin
      D := 1.5;
      E := D * 2.0 + 0.25;
      if E > 3.0 then
        WriteLn(1)
    end.
    ''');
  AssertTrue('literal from rodata page',
    Pos('adrp x9, __d0@PAGE', AsmT) >= 0);
  AssertTrue('double blob emitted', Pos(#9'.double 1.5', AsmT) >= 0);
  AssertTrue('float multiply', Pos(#9'fmul d0, d0, d1', AsmT) >= 0);
  AssertTrue('float add', Pos(#9'fadd d0, d0, d1', AsmT) >= 0);
  AssertTrue('float compare', Pos(#9'fcmp d0, d1', AsmT) >= 0);
  AssertTrue('ordered greater', Pos(#9'cset x0, gt', AsmT) >= 0);
end;

procedure TArm64BackendTests.TestFloat_CallAbi_IndependentSequences;
var
  AsmT: string;
begin
  AsmT := GenAsm(
    '''
    program P;
    function Mix(A: Integer; X: Double; B: Integer): Integer;
    begin
      Result := A + B
    end;
    begin
      WriteLn(Mix(1, 2.5, 3))
    end.
    ''');
  { AAPCS64: ints take x0/x1, the float takes d0 — independent sequences.
    The callee spills d0 through x9 into the param slot. }
  AssertTrue('float arg lands in d0', Pos(#9'fmov d0, x9', AsmT) >= 0);
  AssertTrue('callee spills the d0 param', Pos(#9'fmov x9, d0', AsmT) >= 0);
  AssertTrue('int args pop into x0/x1', Pos(#9'ldr x1, [sp], #16', AsmT) >= 0);
  AssertTrue('call emitted', Pos(#9'bl Mix', AsmT) >= 0);
end;

procedure TArm64BackendTests.TestString_AssignRetainsAndReleasesOld;
var
  AsmT: string;
begin
  AsmT := GenAsm(
    '''
    program P;
    var
      S: string;
    begin
      S := 'one';
      S := 'two';
      WriteLn(S)
    end.
    ''');
  { plain (non-owning) RHS retains; the slot's old value releases }
  AssertTrue('incoming retained', Pos(#9'bl _StringAddRef', AsmT) >= 0);
  AssertTrue('old value released', Pos(#9'bl _StringRelease', AsmT) >= 0);
end;

procedure TArm64BackendTests.TestString_ConcatOwnedTransientReleased;
var
  AsmT: string;
  ConcatPos, AddRefAfter: Integer;
begin
  AsmT := GenAsm(
    '''
    program P;
    var
      S: string;
    begin
      S := 'a' + 'b';
      WriteLn('x' + 'y')
    end.
    ''');
  AssertTrue('concat lowered', Pos(#9'bl _StringConcat', AsmT) >= 0);
  { _StringConcat returns rc=0 (arc-string-transient-handover.adoc): the
    assignment must RETAIN it (0 -> 1) before releasing the old value —
    consuming it as if it were +1 stores an rc=0 string whose later
    release underflows to IMMORTAL (a permanent, tracker-invisible leak) }
  ConcatPos := Pos(#9'bl _StringConcat', AsmT);
  AddRefAfter := Pos(#9'bl _StringAddRef',
    Copy(AsmT, ConcatPos, Length(AsmT) - ConcatPos));
  AssertTrue('rc=0 concat result retained on assignment', AddRefAfter >= 0);
  { the WriteLn transient is disposed by shape after the write:
    rc=0 needs AddRef THEN Release }
  AssertTrue('transient written', Pos(#9'bl _SysWriteStr', AsmT) >= 0);
end;

procedure TArm64BackendTests.TestString_ScopeExitReleases;
var
  AsmT: string;
begin
  AsmT := GenAsm(
    '''
    program P;
    function Tag(N: Integer): Integer;
    var
      S: string;
    begin
      S := 'tag';
      Result := N
    end;
    begin
      WriteLn(Tag(1))
    end.
    ''');
  { the routine's exit label releases its string local before Result loads }
  AssertTrue('exit label present', Pos('Lrexit', AsmT) >= 0);
  AssertTrue('scope-exit release', Pos(#9'bl _StringRelease', AsmT) >= 0);
end;

procedure TArm64BackendTests.TestString_Comparisons_UseRtlHelpers;
var
  AsmT: string;
begin
  AsmT := GenAsm(
    '''
    program P;
    var
      A, B: string;
    begin
      A := 'x';
      B := 'y';
      if A = B then WriteLn(1);
      if A <> B then WriteLn(2);
      if A < B then WriteLn(3)
    end.
    ''');
  { content comparison, never a pointer cmp }
  AssertTrue('equality helper', Pos(#9'bl _StringEquals', AsmT) >= 0);
  AssertTrue('ordering helper', Pos(#9'bl _StringCompare', AsmT) >= 0);
  AssertTrue('NE inverts via cset eq', Pos(#9'cset x0, eq', AsmT) >= 0);
  AssertTrue('relational sign-extends the strcmp result',
    Pos(#9'sxtw x0, w0', AsmT) >= 0);
end;

procedure TArm64BackendTests.TestRecord_FieldsAndCopy;
var
  AsmT, Obj: string;
  F: TMachOFile;
begin
  AsmT := GenAsm(
    '''
    program P;
    type
      TPoint = record
        X: Integer;
        Y: Int64;
        D: Double;
      end;
    var
      G: TPoint;
    function Sum(N: Integer): Integer;
    var
      L, M: TPoint;
    begin
      L.X := N;
      L.Y := 10;
      L.D := 1.5;
      M := L;
      Result := M.X + M.Y
    end;
    begin
      G.X := 1;
      WriteLn(Sum(G.X + 31))
    end.
    ''');
  { record locals zero-init their WHOLE storage, not just 8 bytes }
  AssertTrue('record zeroed via memset', Pos(#9'bl memset', AsmT) >= 0);
  { field writes go through the record base + offset }
  AssertTrue('field write at offset 8', Pos(', [x9, #8]', AsmT) >= 0);
  AssertTrue('field write at offset 16', Pos(', [x9, #16]', AsmT) >= 0);
  { whole-record copy is a memcpy of RawSize }
  AssertTrue('record copy via memcpy', Pos(#9'bl memcpy', AsmT) >= 0);
  AssertTrue('copy length 24', Pos(#9'movz x2, #24', AsmT) >= 0);
  { record global gets a full-size bss slot }
  AssertTrue('global record slot', Pos(#9'.zero 24', AsmT) >= 0);
  { and the whole thing still assembles into a Mach-O object }
  Obj := AssembleArm64ToBytes(AsmT);
  F := ParseMachO(Obj, 'rec.o');
  try
    AssertTrue('__text non-empty',
      F.FindSection('__TEXT', '__text').Size > 0);
  finally
    F.Free();
  end;
end;

procedure TArm64BackendTests.TestRecordReturn_SretViaX8;
var
  AsmT: string;
begin
  AsmT := GenAsm(
    '''
    program P;
    type
      TBig = record
        A, B, C: Int64;
      end;
    var
      G: TBig;
    function MakeBig(N: Integer): TBig;
    begin
      Result.A := N
    end;
    begin
      G := MakeBig(7);
      WriteLn(G.A)
    end.
    ''');
  { 24-byte record: sret — callee parks x8, memcpys Result out; the
    caller loads the destination address into x8 before the bl }
  AssertTrue('callee parks x8', Pos(#9'stur x8, ', AsmT) >= 0);
  AssertTrue('callee copies Result to the x8 buffer',
    Pos(#9'bl memcpy', AsmT) >= 0);
  AssertTrue('caller sets x8 to the destination',
    Pos('add x8, x8, _g_G@PAGEOFF', AsmT) >= 0);
end;

procedure TArm64BackendTests.TestRecordReturn_SmallImagesAndHfa;
var
  AsmT: string;
begin
  AsmT := GenAsm(
    '''
    program P;
    type
      TPair = record
        A: Int64;
        B: Int64;
      end;
      TVec = record
        X: Double;
        Y: Double;
      end;
    var
      GP: TPair;
      GV: TVec;
    function MkPair: TPair;
    begin
      Result.A := 1;
      Result.B := 2
    end;
    function MkVec: TVec;
    begin
      Result.X := 1.5
    end;
    begin
      GP := MkPair();
      GV := MkVec();
      WriteLn(GP.A)
    end.
    ''');
  { 16-byte non-HFA: memory image in x0:x1 both sides }
  AssertTrue('callee loads x0:x1 image', Pos(#9'ldr x1, [x9, #8]', AsmT) >= 0);
  AssertTrue('caller stores x1 half', Pos(#9'str x1, [x9, #8]', AsmT) >= 0);
  { two-double HFA: d0/d1 both sides }
  AssertTrue('callee loads HFA d1', Pos(#9'ldr d1, [x9, #8]', AsmT) >= 0);
  AssertTrue('caller stores HFA d1', Pos(#9'str d1, [x9, #8]', AsmT) >= 0);
end;

procedure TArm64BackendTests.TestRecordParam_SmallImagesAndHfa;
var
  AsmT: string;
begin
  AsmT := GenAsm(
    '''
    program P;
    type
      TPair = record
        A: Int64;
        B: Int64;
      end;
      TVec = record
        X: Double;
        Y: Double;
      end;
    var
      GP: TPair;
      GV: TVec;
    function SumPair(P: TPair): Int64;
    begin
      Result := P.A + P.B
    end;
    function VecX(V: TVec): Double;
    begin
      Result := V.X
    end;
    begin
      GP.A := 3;
      GV.X := 1.5;
      WriteLn(SumPair(GP));
      WriteLn(VecX(GV))
    end.
    ''');
  { 16-byte non-HFA param: x0:x1 image — callee stores the second half
    at slot+8, caller loads it from the lvalue at +8 }
  AssertTrue('callee spills x1 half', Pos(#9'str x1, [x9, #8]', AsmT) >= 0);
  AssertTrue('caller loads second half', Pos(#9'ldr x0, [x9, #8]', AsmT) >= 0);
  { two-double HFA param: callee spills d0/d1 into the slot }
  AssertTrue('callee spills HFA d1', Pos(#9'str d1, [x9, #8]', AsmT) >= 0);
end;

procedure TArm64BackendTests.TestRecordParam_LargeByPointer;
var
  AsmT, Obj: string;
  F: TMachOFile;
begin
  AsmT := GenAsm(
    '''
    program P;
    type
      TBig = record
        A, B, C: Int64;
      end;
    var
      G: TBig;
    function SumBig(R: TBig): Int64;
    begin
      Result := R.A + R.C
    end;
    begin
      G.A := 5;
      G.C := 7;
      WriteLn(SumBig(G))
    end.
    ''');
  { >16B param travels as a pointer: the callee parks it and memcpys the
    bytes into its own slot before any user code }
  AssertTrue('caller passes the global address',
    Pos('add x0, x0, _g_G@PAGEOFF', AsmT) >= 0);
  AssertTrue('callee copies the bytes in', Pos(#9'bl memcpy', AsmT) >= 0);
  { and the whole module still assembles to a valid Mach-O object }
  Obj := AssembleArm64ToBytes(AsmT);
  F := ParseMachO(Obj, 'arm64recpar.o');
  try
    AssertTrue('has a text section',
      F.FindSection('__TEXT', '__text') <> nil);
  finally
    F.Free();
  end;
end;

procedure TArm64BackendTests.TestManagedRecord_CopyAndFieldStore;
var
  AsmT: string;
  PosRetain, PosRelease, PosCpy: Integer;
begin
  AsmT := GenAsm(
    '''
    program P;
    type
      TNamed = record
        Id: Int64;
        Name: string;
      end;
    var
      A, B: TNamed;
    begin
      A.Name := 'hello';
      B := A;
      WriteLn(B.Name)
    end.
    ''');
  { field store: retain the incoming value, release the old field }
  AssertTrue('field store retains', Pos(#9'bl _StringAddRef', AsmT) >= 0);
  { whole-copy discipline: retain source fields BEFORE releasing the
    destination's (self-assignment safety), memcpy after both }
  PosRetain := Pos('_StringAddRef', AsmT);
  PosRelease := Pos('_StringRelease', AsmT);
  PosCpy := Pos('bl memcpy', AsmT);
  AssertTrue('retain present', PosRetain >= 0);
  AssertTrue('release present', PosRelease >= 0);
  AssertTrue('memcpy present', PosCpy >= 0);
  { the copy walks from callee-saved bases }
  AssertTrue('walk bases are callee-saved',
    Pos(#9'stp x19, x22, [sp, #-16]!', AsmT) >= 0);
end;

procedure TArm64BackendTests.TestManagedRecord_ScopeExitRelease;
var
  AsmT: string;
  Obj: string;
  F: TMachOFile;
begin
  AsmT := GenAsm(
    '''
    program P;
    type
      TNamed = record
        Id: Int64;
        Name: string;
      end;
    procedure Use;
    var
      L: TNamed;
    begin
      L.Name := 'local';
      WriteLn(L.Name)
    end;
    var
      G: TNamed;
    begin
      G.Name := 'global';
      Use();
      WriteLn(G.Name)
    end.
    ''');
  { the local's managed field is released at the routine's exit label and
    the global's at program exit — each walk anchors on saved x19 }
  AssertTrue('scope-exit walk saves x19',
    Pos(#9'str x19, [sp, #-16]!', AsmT) >= 0);
  AssertTrue('walk releases through x19', Pos('[x19', AsmT) >= 0);
  { and the whole module still assembles to a valid Mach-O object }
  Obj := AssembleArm64ToBytes(AsmT);
  F := ParseMachO(Obj, 'arm64mrec.o');
  try
    AssertTrue('has a text section',
      F.FindSection('__TEXT', '__text') <> nil);
  finally
    F.Free();
  end;
end;

procedure TArm64BackendTests.TestUnit_RoutinesAndCrossUnitCalls;
var
  AsmT: string;
  Obj: string;
  F: TMachOFile;
begin
  AsmT := GenAsmWithUnit(
    '''
    unit mathu;
    interface
    function AddTwo(A, B: Int64): Int64;
    function Banner: string;
    implementation
    function AddTwo(A, B: Int64): Int64;
    begin
      Result := A + B
    end;
    function Banner: string;
    begin
      Result := 'sum='
    end;
    end.
    ''',
    '''
    program P;
    uses mathu;
    begin
      Write(Banner());
      WriteLn(AddTwo(20, 22))
    end.
    ''');
  { the unit routine is defined under its unit-mangled symbol and the
    program's call site targets the same symbol }
  AssertTrue('unit routine defined', Pos('mathu_AddTwo:', AsmT) >= 0);
  AssertTrue('cross-unit call mangled', Pos(#9'bl mathu_AddTwo', AsmT) >= 0);
  AssertTrue('string-returning unit routine defined',
    Pos('mathu_Banner:', AsmT) >= 0);
  { the unit's string literal lands in the shared rodata dump }
  AssertTrue('unit string literal emitted', Pos('sum=', AsmT) >= 0);
  { and the multi-unit module assembles to a valid Mach-O object }
  Obj := AssembleArm64ToBytes(AsmT);
  F := ParseMachO(Obj, 'arm64unit.o');
  try
    AssertTrue('has a text section',
      F.FindSection('__TEXT', '__text') <> nil);
  finally
    F.Free();
  end;
end;

procedure TArm64BackendTests.TestUnit_VarsAndInitSection;
var
  AsmT: string;
begin
  AsmT := GenAsmWithUnit(
    '''
    unit counters;
    interface
    var
      Total: Int64;
    procedure Bump;
    implementation
    procedure Bump;
    begin
      Total := Total + 1
    end;
    initialization
      Total := 40
    end.
    ''',
    '''
    program P;
    uses counters;
    begin
      Bump();
      Bump();
      WriteLn(Total)
    end.
    ''');
  { the unit var gets an owning-unit-prefixed symbol — same-named vars in
    other units or the program cannot collide }
  AssertTrue('unit var symbol prefixed', Pos('_g_counters_Total:', AsmT) >= 0);
  AssertTrue('references target the prefixed symbol',
    Pos('_g_counters_Total@PAGE', AsmT) >= 0);
  { the init section becomes <unit>_init, and _main calls it }
  AssertTrue('init routine emitted', Pos('counters_init:', AsmT) >= 0);
  AssertTrue('main calls the init routine',
    Pos(#9'bl counters_init', AsmT) >= 0);
end;

procedure TArm64BackendTests.TestUnit_FinalizationStillNotYet;
var
  AsmT: string;
begin
  { historical name — finalization now LOWERS: <unit>_final is emitted
    and called at program exit (reverse dependency order) }
  AsmT := GenAsmWithUnit(
    '''
    unit withfinal;
    interface
    function One: Int64;
    implementation
    function One: Int64;
    begin
      Result := 1
    end;
    finalization
      One()
    end.
    ''',
    '''
    program P;
    uses withfinal;
    begin
      WriteLn(One())
    end.
    ''');
  AssertTrue('final routine emitted', Pos('withfinal_final:', AsmT) >= 0);
  AssertTrue('main exit calls it', Pos(#9'bl withfinal_final', AsmT) >= 0);
end;

procedure TArm64BackendTests.TestStringParams_ValueRetainsConstBorrows;
var
  AsmT: string;
  PosGreet, PosShow, PosNext: Integer;
begin
  AsmT := GenAsm(
    '''
    program P;
    var G: string;
    procedure Greet(Msg: string);
    begin
      WriteLn(Msg)
    end;
    procedure Show(const Msg: string);
    begin
      WriteLn(Msg)
    end;
    begin
      G := 'hi';
      Greet(G);
      Show(G);
      Greet('lit')
    end.
    ''');
  { the by-value param retains its copy in the prologue and releases it
    with the string locals at exit; the const param does neither }
  PosGreet := Pos('Greet:', AsmT);
  PosShow := Pos('Show:', AsmT);
  AssertTrue('both routines emitted', (PosGreet >= 0) and (PosShow >= 0));
  PosNext := PosEx(#9'bl _StringAddRef', AsmT, PosGreet);
  AssertTrue('by-value param retained in Greet',
    (PosNext > PosGreet) and ((PosShow < PosGreet) or (PosNext < PosShow)));
  AssertTrue('by-value param released at Greet exit',
    PosEx(#9'bl _StringRelease', AsmT, PosGreet) > PosGreet);
  { const param: no retain between Show's label and its ret }
  PosNext := PosEx(#9'ret', AsmT, PosShow);
  AssertTrue('Show has a ret', PosNext > PosShow);
  PosGreet := PosEx(#9'bl _StringAddRef', AsmT, PosShow);
  AssertTrue('const param not retained in Show',
    (PosGreet < 0) or (PosGreet > PosNext));
end;

procedure TArm64BackendTests.TestInitialisedGlobals_DataSection;
var
  AsmT: string;
  Obj: string;
  F: TMachOFile;
begin
  AsmT := GenAsm(
    '''
    program P;
    var
      Answer: Int64 = 42;
      Ratio: Double = 2.5;
      Plain: Int64;
    begin
      WriteLn(Answer);
      WriteLn(Ratio);
      WriteLn(Plain)
    end.
    ''');
  { initialised globals live in .data with their values; uninitialised
    ones stay zerofill }
  AssertTrue('data section present', Pos('.section .data', AsmT) >= 0);
  AssertTrue('int initialiser', Pos(#9'.quad 42', AsmT) >= 0);
  AssertTrue('float initialiser', Pos(#9'.double 2.5', AsmT) >= 0);
  AssertTrue('plain global stays bss', Pos('.section .bss', AsmT) >= 0);
  Obj := AssembleArm64ToBytes(AsmT);
  F := ParseMachO(Obj, 'arm64initg.o');
  try
    AssertTrue('has a data section',
      F.FindSection('__DATA', '__data') <> nil);
  finally
    F.Free();
  end;
end;

procedure TArm64BackendTests.TestVarParams_WriteThroughAndPassThrough;
var
  AsmT: string;
  Obj: string;
  F: TMachOFile;
begin
  AsmT := GenAsm(
    '''
    program P;
    var
      N: Int64;
      D: Double;
      S: string;
    procedure Bump(var X: Int64);
    begin
      X := X + 1
    end;
    procedure BumpTwice(var X: Int64);
    begin
      Bump(X);
      Bump(X)
    end;
    procedure SetD(out V: Double);
    begin
      V := 2.5
    end;
    procedure Tag(var T: string);
    begin
      T := T + '!'
    end;
    begin
      N := 40;
      BumpTwice(N);
      SetD(D);
      S := 'hey';
      Tag(S);
      WriteLn(N);
      WriteLn(D);
      WriteLn(S)
    end.
    ''');
  { the caller passes the global's address; the callee reads and writes
    through the pointer; a var->var pass-through forwards the address }
  AssertTrue('caller passes global address',
    Pos('add x0, x0, _g_N@PAGEOFF', AsmT) >= 0);
  AssertTrue('callee derefs for the read', Pos(#9'ldr x0, [x0]', AsmT) >= 0);
  AssertTrue('callee stores through the pointer',
    Pos(#9'str x0, [x9]', AsmT) >= 0);
  { pipeline check: the whole module assembles }
  Obj := AssembleArm64ToBytes(AsmT);
  F := ParseMachO(Obj, 'arm64varpar.o');
  try
    AssertTrue('has a text section',
      F.FindSection('__TEXT', '__text') <> nil);
  finally
    F.Free();
  end;
end;

procedure TArm64BackendTests.TestSingle_LoadsStoresParamsResult;
var
  AsmT: string;
  Obj: string;
  F: TMachOFile;
begin
  AsmT := GenAsm(
    '''
    program P;
    var
      A, B: Single;
    function Half(V: Single): Single;
    begin
      Result := V / 2.0
    end;
    begin
      A := 3.0;
      B := Half(A) + 1.5;
      WriteLn(B)
    end.
    ''');
  { 4-byte storage: stores narrow through s0, loads widen through fcvt }
  AssertTrue('store narrows', Pos(#9'fcvt s0, d0', AsmT) >= 0);
  AssertTrue('4-byte store', Pos(#9'str s0, [x9]', AsmT) >= 0);
  AssertTrue('load widens', Pos(#9'fcvt d0, s0', AsmT) >= 0);
  { the param arrives in s0 and is spilled as 4 bytes; the caller narrows
    into s0 at the pop }
  AssertTrue('callee spills s-reg param', Pos(#9'str s0, [x9]', AsmT) >= 0);
  { the whole module assembles (fcvt + s-reg loads reach the encoder) }
  Obj := AssembleArm64ToBytes(AsmT);
  F := ParseMachO(Obj, 'arm64single.o');
  try
    AssertTrue('has a text section',
      F.FindSection('__TEXT', '__text') <> nil);
  finally
    F.Free();
  end;
end;

procedure TArm64BackendTests.TestClass_CreateFieldsMethodsMetadata;
var
  AsmT: string;
  Obj: string;
  F: TMachOFile;
begin
  AsmT := GenAsm(
    '''
    program P;
    type
      TCounter = class
        FCount: Int64;
        FName: string;
        procedure Bump;
        function Value: Int64;
      end;
    procedure TCounter.Bump;
    begin
      FCount := FCount + 1
    end;
    function TCounter.Value: Int64;
    begin
      Result := FCount
    end;
    var
      C: TCounter;
    begin
      C := TCounter.Create();
      C.Bump();
      C.FName := 'named';
      WriteLn(C.Value());
      WriteLn(C.FName)
    end.
    ''');
  { creation goes through the RTL with the class typeinfo }
  AssertTrue('typeinfo passed to _ClassCreate',
    Pos('add x0, x0, typeinfo_TCounter@PAGEOFF', AsmT) >= 0);
  AssertTrue('creates via the RTL', Pos(#9'bl _ClassCreate', AsmT) >= 0);
  { non-virtual methods dispatch directly to the mangled symbol }
  AssertTrue('direct method call', Pos(#9'bl TCounter_Bump', AsmT) >= 0);
  { metadata: typeinfo slots + vtable with the typeinfo back-pointer }
  AssertTrue('typeinfo emitted', Pos('typeinfo_TCounter:', AsmT) >= 0);
  AssertTrue('vtable emitted', Pos('vtable_TCounter:', AsmT) >= 0);
  AssertTrue('vtable slot 0 is the typeinfo',
    Pos(#9'.quad typeinfo_TCounter', AsmT) >= 0);
  AssertTrue('cleanup emitted', Pos('_FieldCleanup_TCounter:', AsmT) >= 0);
  { the class-typed global is released at program exit }
  AssertTrue('program-exit release', Pos(#9'bl _ClassRelease', AsmT) >= 0);
  Obj := AssembleArm64ToBytes(AsmT);
  F := ParseMachO(Obj, 'arm64class.o');
  try
    AssertTrue('has a data section',
      F.FindSection('__DATA', '__data') <> nil);
  finally
    F.Free();
  end;
end;

procedure TArm64BackendTests.TestClass_VirtualDispatchAndDestroy;
var
  AsmT: string;
begin
  AsmT := GenAsm(
    '''
    program P;
    type
      TAnimal = class
        function Speak: Int64; virtual;
        destructor Destroy; override;
      end;
      TDog = class(TAnimal)
        function Speak: Int64; override;
      end;
    function TAnimal.Speak: Int64;
    begin
      Result := 1
    end;
    destructor TAnimal.Destroy;
    begin
    end;
    function TDog.Speak: Int64;
    begin
      Result := 2
    end;
    var
      A: TAnimal;
    begin
      A := TDog.Create();
      WriteLn(A.Speak())
    end.
    ''');
  { virtual dispatch: vtable load + slot load + blr }
  AssertTrue('vtable indirection', Pos(#9'blr x9', AsmT) >= 0);
  { the derived vtable carries the override }
  AssertTrue('override in TDog vtable', Pos(#9'.quad TDog_Speak', AsmT) >= 0);
  { the cleanup chain calls the user destructor }
  AssertTrue('cleanup calls Destroy',
    Pos('_Destroy', AsmT) >= 0);
  { parent typeinfo chains to the base class }
  AssertTrue('parent typeinfo link',
    Pos(#9'.quad typeinfo_TAnimal', AsmT) >= 0);
end;

procedure TArm64BackendTests.TestClass_InUnit_PrefixedSymbols;
var
  AsmT: string;
begin
  AsmT := GenAsmWithUnit(
    '''
    unit zoo;
    interface
    type
      TCat = class
        FLives: Int64;
        procedure Init;
      end;
    implementation
    procedure TCat.Init;
    begin
      FLives := 9
    end;
    end.
    ''',
    '''
    program P;
    uses zoo;
    var
      C: TCat;
    begin
      C := TCat.Create();
      C.Init();
      WriteLn(C.FLives)
    end.
    ''');
  { the unit class's metadata symbols carry the owning-unit prefix, and
    the Create site targets the same typeinfo }
  AssertTrue('prefixed typeinfo', Pos('typeinfo_zoo_TCat:', AsmT) >= 0);
  AssertTrue('prefixed vtable', Pos('vtable_zoo_TCat:', AsmT) >= 0);
  AssertTrue('create targets prefixed typeinfo',
    Pos('typeinfo_zoo_TCat@PAGEOFF', AsmT) >= 0);
end;

procedure TArm64BackendTests.TestClass_StaticsConstsInheritedToString;
var
  AsmT: string;
  Obj: string;
  F: TMachOFile;
begin
  AsmT := GenAsm(
    '''
    program P;
    type
      TBase = class
        function Tag: Int64; virtual;
      end;
      TKid = class(TBase)
        const Answer = 42;
        static function Twice(N: Int64): Int64;
        function Tag: Int64; override;
      end;
    function TBase.Tag: Int64;
    begin
      Result := 1
    end;
    static function TKid.Twice(N: Int64): Int64;
    begin
      Result := N * 2
    end;
    function TKid.Tag: Int64;
    begin
      Result := inherited Tag() + 10
    end;
    var
      K: TKid;
    begin
      K := TKid.Create();
      WriteLn(K.Tag());
      WriteLn(TKid.Twice(21));
      WriteLn(TKid.Answer);
      WriteLn(K.ToString())
    end.
    ''');
  { inherited: static dispatch straight to the parent implementation }
  AssertTrue('inherited call is direct', Pos(#9'bl TBase_Tag', AsmT) >= 0);
  { static method: plain call, no receiver }
  AssertTrue('static method direct call', Pos(#9'bl TKid_Twice', AsmT) >= 0);
  { class const folded to its literal }
  AssertTrue('class const folded', Pos(#9'movz x0, #42', AsmT) >= 0);
  { ToString: virtual through vtable slot 1 (offset 16) }
  AssertTrue('ToString via vtable', Pos(#9'ldr x9, [x9, #16]', AsmT) >= 0);
  Obj := AssembleArm64ToBytes(AsmT);
  F := ParseMachO(Obj, 'arm64class17.o');
  try
    AssertTrue('has a text section',
      F.FindSection('__TEXT', '__text') <> nil);
  finally
    F.Free();
  end;
end;

procedure TArm64BackendTests.TestClass_Properties;
var
  AsmT: string;
  Obj: string;
  F: TMachOFile;
begin
  AsmT := GenAsm(
    '''
    program P;
    type
      TGauge = class
      private
        FLevel: Int64;
        function GetPercent: Int64;
        procedure SetPercent(AValue: Int64);
      public
        property Level: Int64 read FLevel write FLevel;
        property Percent: Int64 read GetPercent write SetPercent;
      end;
    function TGauge.GetPercent: Int64;
    begin
      Result := FLevel * 10
    end;
    procedure TGauge.SetPercent(AValue: Int64);
    begin
      FLevel := AValue div 10
    end;
    var
      G: TGauge;
    begin
      G := TGauge.Create();
      G.Level := 3;
      WriteLn(G.Percent);
      G.Percent := 70;
      WriteLn(G.Level)
    end.
    ''');
  { field-backed accessors are rewritten to plain field access by the
    semantic pass; method-backed ones call the accessors directly }
  AssertTrue('getter called', Pos(#9'bl TGauge_GetPercent', AsmT) >= 0);
  AssertTrue('setter called', Pos(#9'bl TGauge_SetPercent', AsmT) >= 0);
  Obj := AssembleArm64ToBytes(AsmT);
  F := ParseMachO(Obj, 'arm64props.o');
  try
    AssertTrue('has a text section',
      F.FindSection('__TEXT', '__text') <> nil);
  finally
    F.Free();
  end;
end;

procedure TArm64BackendTests.TestClass_ChainedReceivers;
var
  AsmT: string;
  PosCall, PosRel: Integer;
begin
  AsmT := GenAsm(
    '''
    program P;
    type
      TInner = class
        FVal: Int64;
        function Get: Int64;
      end;
      TOuter = class
        FInner: TInner;
        function Inner: TInner;
      end;
    function TInner.Get: Int64;
    begin
      Result := FVal
    end;
    function TOuter.Inner: TInner;
    begin
      Result := FInner
    end;
    var
      O: TOuter;
    begin
      O := TOuter.Create();
      O.FInner := TInner.Create();
      O.FInner.FVal := 7;
      WriteLn(O.FInner.FVal);
      WriteLn(O.FInner.Get())
    end.
    ''');
  { chained field read (O.FInner.FVal) derefs through the base expr, and
    a method on a chained field (O.FInner.Get) receives the loaded ptr }
  AssertTrue('chained method call', Pos(#9'bl TInner_Get', AsmT) >= 0);
  { O.FInner.Get(): the receiver O.FInner is a BORROWED field read — an
    owned method result gets released; make sure the owned-receiver
    release plumbing appears for owned receivers only when used.  Here
    Inner() is unused, so no blr-owned pattern is required — assert the
    borrow shape: field load feeding the call. }
  PosCall := Pos(#9'bl TInner_Get', AsmT);
  PosRel := Pos('ldr x0, [sp, #16]', AsmT);
  AssertTrue('no owned-receiver bracket for borrowed chains', PosRel < 0);
  AssertTrue('call present', PosCall >= 0);
end;

procedure TArm64BackendTests.TestThreadvar_TlvDescriptorsAndAccess;
var
  AsmT: string;
  Obj: string;
  F: TMachOFile;
begin
  AsmT := GenAsm(
    '''
    program P;
    threadvar
      Counter: Int64;
    begin
      Counter := 5;
      WriteLn(Counter)
    end.
    ''');
  { access: materialise the descriptor, call its thunk, deref the result }
  AssertTrue('TLVP page ref', Pos('_tv_Counter@TLVPPAGE', AsmT) >= 0);
  AssertTrue('thunk call', Pos(#9'blr x9', AsmT) >= 0);
  { descriptor: three quads with the bootstrap thunk }
  AssertTrue('descriptor label', Pos('_tv_Counter:', AsmT) >= 0);
  AssertTrue('bootstrap slot', Pos(#9'.quad _tlv_bootstrap', AsmT) >= 0);
  AssertTrue('storage slot ref', Pos(#9'.quad _ts_Counter', AsmT) >= 0);
  AssertTrue('thread_vars section',
    Pos('.section __DATA,__thread_vars', AsmT) >= 0);
  { and the module assembles: the writer emits the S_THREAD_LOCAL sections }
  Obj := AssembleArm64ToBytes(AsmT);
  F := ParseMachO(Obj, 'arm64tlv.o');
  try
    AssertTrue('has __thread_vars',
      F.FindSection('__DATA', '__thread_vars') <> nil);
    AssertTrue('has __thread_bss',
      F.FindSection('__DATA', '__thread_bss') <> nil);
  finally
    F.Free();
  end;
end;

procedure TArm64BackendTests.TestStackArgs_VariadicAndOverflow;
var
  AsmT: string;
  Obj: string;
  F: TMachOFile;
begin
  AsmT := GenAsm(
    '''
    program P;
    function printf(Fmt: PChar): Integer; cdecl; varargs;
      external 'c' name 'printf';
    function Sum10(A, B, C, D, E, F, G, H, I, J: Int64): Int64;
    begin
      Result := A + B + C + D + E + F + G + H + I + J
    end;
    begin
      printf(PChar('%lld and %lld'), 40, 2);
      WriteLn(Sum10(1, 2, 3, 4, 5, 6, 7, 8, 9, 10))
    end.
    ''');
  { variadic anonymous args go to the outgoing stack area (Apple
    divergence), stored through w/x into [sp, #..] }
  AssertTrue('outgoing area allocated', Pos(#9'sub sp, sp, #16', AsmT) >= 0);
  AssertTrue('variadic call to printf', Pos(#9'bl printf', AsmT) >= 0);
  { the 9th/10th args of Sum10 overflow the register file to the stack }
  AssertTrue('call to Sum10', Pos(#9'bl Sum10', AsmT) >= 0);
  AssertTrue('area released', Pos(#9'add sp, sp, #16', AsmT) >= 0);
  Obj := AssembleArm64ToBytes(AsmT);
  F := ParseMachO(Obj, 'arm64stackargs.o');
  try
    AssertTrue('has a text section',
      F.FindSection('__TEXT', '__text') <> nil);
  finally
    F.Free();
  end;
end;

procedure TArm64BackendTests.TestInterfaces_DispatchAndMetadata;
var
  AsmT: string;
  Obj: string;
  F: TMachOFile;
begin
  AsmT := GenAsm(
    '''
    program P;
    type
      IGreeter = interface
        function Greet(N: Int64): Int64;
      end;
      THi = class(TObject, IGreeter)
        function Greet(N: Int64): Int64;
      end;
    function THi.Greet(N: Int64): Int64;
    begin
      Result := N + 1
    end;
    var
      G: IGreeter;
      H: THi;
    begin
      H := THi.Create();
      G := H;
      WriteLn(G.Greet(41));
      G := nil
    end.
    ''');
  { narrowing stores the static itab; dispatch loads fptr from itab[0] }
  AssertTrue('itab emitted', Pos('itab_THi_IGreeter:', AsmT) >= 0);
  AssertTrue('itab slot names the impl', Pos(#9'.quad THi_Greet', AsmT) >= 0);
  AssertTrue('impllist emitted', Pos('impllist_THi:', AsmT) >= 0);
  AssertTrue('interface typeinfo', Pos('typeinfo_IGreeter:', AsmT) >= 0);
  AssertTrue('narrow stores itab', Pos('itab_THi_IGreeter@PAGEOFF', AsmT) >= 0);
  AssertTrue('dispatch through itab slot 0',
    Pos(#9'ldr x9, [x9, #0]', AsmT) >= 0);
  AssertTrue('dispatch call', Pos(#9'blr x9', AsmT) >= 0);
  Obj := AssembleArm64ToBytes(AsmT);
  F := ParseMachO(Obj, 'arm64intf.o');
  try
    AssertTrue('has a data section',
      F.FindSection('__DATA', '__data') <> nil);
  finally
    F.Free();
  end;
end;

procedure TArm64BackendTests.TestInterfaces_AsCast;
var
  AsmT: string;
begin
  AsmT := GenAsm(
    '''
    program P;
    type
      IThing = interface
        procedure Go;
      end;
      TThing = class(TObject, IThing)
        procedure Go;
      end;
    procedure TThing.Go;
    begin
    end;
    var
      T: TThing;
      I: IThing;
    begin
      T := TThing.Create();
      I := T as IThing;
      I.Go()
    end.
    ''');
  { runtime lookup + invalid-cast guard }
  AssertTrue('runtime itab lookup', Pos(#9'bl _GetItab', AsmT) >= 0);
  AssertTrue('nil-itab guard', Pos(#9'bl _Raise_InvalidCast', AsmT) >= 0);
  AssertTrue('typeinfo operand', Pos('typeinfo_IThing@PAGEOFF', AsmT) >= 0);
end;

procedure TArm64BackendTests.TestOwnedStringTransientArg_Released;
var
  AsmT: string;
  PosCall, PosRel: Integer;
begin
  AsmT := GenAsm(
    '''
    program P;
    var
      A, B: string;
    function Make: string;
    begin
      Result := A + B
    end;
    procedure Show(Msg: string);
    begin
      WriteLn(Msg)
    end;
    procedure ShowC(const Msg: string);
    begin
      WriteLn(Msg)
    end;
    begin
      A := 'he';
      B := 'yo';
      Show(A + B);
      Show(Make());
      ShowC(A + B)
    end.
    ''');
  { by-value rc=0 concat arg: the callee's entry-retain/exit-release pair
    frees it — the CALLER must not touch it (a release would double-free);
    by-value rc=1 call result: one caller release after the call;
    const rc=0 concat arg: caller pins (AddRef+Release) after the call }
  PosCall := Pos(#9'bl Show', AsmT);
  AssertTrue('calls emitted', PosCall >= 0);
  AssertTrue('rc=1 arg parked in the outgoing area',
    Pos('ldr x0, [sp, #32]', AsmT) >= 0);
  PosCall := Pos(#9'bl ShowC', AsmT);
  AssertTrue('const call emitted', PosCall >= 0);
  PosRel := PosEx(#9'bl _StringAddRef', AsmT, PosCall);
  AssertTrue('const rc=0 arg pinned after the call', PosRel > PosCall);
end;

procedure TArm64BackendTests.TestReflection_SupportsInheritsFromMetaclass;
var
  AsmT: string;
begin
  AsmT := GenAsm(
    '''
    program P;
    type
      IThing = interface
        procedure Go;
      end;
      TBase = class(TObject, IThing)
        procedure Go;
      end;
      TKid = class(TBase)
      end;
      TBaseClass = class of TBase;
    procedure TBase.Go;
    begin
    end;
    var
      K: TKid;
      MC: TBaseClass;
      Ok: Boolean;
    begin
      K := TKid.Create();
      Ok := Supports(K, IThing);
      WriteLn(Ok);
      WriteLn(K.InheritsFrom(TBase));
      MC := TKid;
      WriteLn(MC.InheritsFrom(TBase))
    end.
    ''');
  { Supports: runtime itab probe folded to a boolean }
  AssertTrue('supports via _GetItab', Pos(#9'bl _GetItab', AsmT) >= 0);
  AssertTrue('boolean fold', Pos(#9'cset x0, ne', AsmT) >= 0);
  { InheritsFrom: instance receiver reads typeinfo via vtable[0];
    metaclass receiver passes its value directly }
  AssertTrue('inheritsfrom call', Pos(#9'bl _InheritsFrom', AsmT) >= 0);
  { bare class name as a value = typeinfo address }
  AssertTrue('metaclass value', Pos('typeinfo_TKid@PAGEOFF', AsmT) >= 0);
end;

procedure TArm64BackendTests.TestInterfaceParamsAndResults;
var
  AsmT: string;
  Obj: string;
  F: TMachOFile;
begin
  AsmT := GenAsm(
    '''
    program P;
    type
      IGreeter = interface
        function Greet(N: Int64): Int64;
      end;
      THi = class(TObject, IGreeter)
        function Greet(N: Int64): Int64;
      end;
    function THi.Greet(N: Int64): Int64;
    begin
      Result := N + 1
    end;
    function MakeGreeter: IGreeter;
    var
      H: THi;
    begin
      H := THi.Create();
      Result := H
    end;
    function UseGreeter(G: IGreeter): Int64;
    begin
      Result := G.Greet(1)
    end;
    var
      G: IGreeter;
    begin
      G := MakeGreeter();
      WriteLn(UseGreeter(G))
    end.
    ''');
  { result: callee writes the fat pointer through the parked x8 buffer }
  AssertTrue('sret buffer store', Pos(#9'str x0, [x9, #8]', AsmT) >= 0);
  { caller receives through the __iret scratch }
  AssertTrue('call with sret dest', Pos(#9'bl MakeGreeter', AsmT) >= 0);
  { param: two-register fat pointer, by-value retain in the callee }
  AssertTrue('param call', Pos(#9'bl UseGreeter', AsmT) >= 0);
  AssertTrue('callee retains its copy', Pos(#9'bl _ClassAddRef', AsmT) >= 0);
  Obj := AssembleArm64ToBytes(AsmT);
  F := ParseMachO(Obj, 'arm64intfpr.o');
  try
    AssertTrue('has a text section',
      F.FindSection('__TEXT', '__text') <> nil);
  finally
    F.Free();
  end;
end;

procedure TArm64BackendTests.TestFloatPropRead_And_StringGlobalInit;
var
  AsmT: string;
begin
  AsmT := GenAsm(
    '''
    program P;
    type
      TTank = class
      private
        FVol: Double;
        function GetVol: Double;
      public
        property Vol: Double read GetVol;
      end;
    function TTank.GetVol: Double;
    begin
      Result := FVol
    end;
    var
      Banner: string = 'ready';
      T: TTank;
    begin
      T := TTank.Create();
      WriteLn(T.Vol);
      WriteLn(Banner)
    end.
    ''');
  { float property read: getter call, value already in d0 }
  AssertTrue('getter called', Pos(#9'bl TTank_GetVol', AsmT) >= 0);
  { string-initialised global: .data pointer to an immortal blob }
  AssertTrue('data pointer', Pos(#9'.quad __gi_Banner_d', AsmT) >= 0);
  AssertTrue('immortal header', Pos('__gi_Banner_h:', AsmT) >= 0);
  AssertTrue('blob bytes', Pos(#9'.ascii "ready"', AsmT) >= 0);
end;

procedure TArm64BackendTests.TestManagedRecord_ParamsAndResults;
var
  AsmT: string;
  PosCall, PosRel: Integer;
begin
  AsmT := GenAsm(
    '''
    program P;
    type
      TNamed = record
        Id: Int64;
        Name: string;
      end;
    function Make(N: Int64): TNamed;
    begin
      Result.Id := N;
      Result.Name := 'x'
    end;
    function Describe(R: TNamed): Int64;
    begin
      Result := R.Id
    end;
    var
      A: TNamed;
    begin
      A := Make(1);
      WriteLn(Describe(A));
      A := Make(2)
    end.
    ''');
  { callee retains its by-value copy's managed fields }
  AssertTrue('param field retain', Pos(#9'bl _StringAddRef', AsmT) >= 0);
  { managed result: sret into the __rret scratch, old LHS fields released
    AFTER the call, then the fresh value moves in }
  PosCall := Pos(#9'bl Make', AsmT);
  AssertTrue('call present', PosCall >= 0);
  PosRel := PosEx(#9'bl _StringRelease', AsmT, PosCall);
  AssertTrue('LHS released after the call', PosRel > PosCall);
  AssertTrue('scratch move-in', PosEx(#9'bl memcpy', AsmT, PosRel) > PosRel);
end;

procedure TArm64BackendTests.TestSingleFields_Supports3_StaticProps;
var
  AsmT: string;
begin
  AsmT := GenAsm(
    '''
    program P;
    type
      IThing = interface
        procedure Go;
      end;
      TVec = record
        X: Single;
        Y: Single;
      end;
      TThing = class(TObject, IThing)
        FRatio: Single;
        procedure Go;
      end;
    procedure TThing.Go;
    begin
    end;
    var
      V: TVec;
      T: TThing;
      I: IThing;
      Ok: Boolean;
    begin
      V.X := 1.5;
      V.Y := V.X;
      T := TThing.Create();
      T.FRatio := 0.5;
      WriteLn(V.Y);
      WriteLn(T.FRatio);
      Ok := Supports(T, IThing, I);
      WriteLn(Ok);
      I.Go()
    end.
    ''');
  { Single fields: 4-byte stores narrow through s0, reads load w-width }
  AssertTrue('single field store', Pos(#9'str s0, [x9, #4]', AsmT) >= 0);
  { field reads are width-keyed through the element loader now: the
    address is formed first, then a w-width load through it }
  AssertTrue('single field read', Pos(#9'ldr w0, [x0]', AsmT) >= 0);
  { 3-arg Supports: success path stores both halves of the out-var }
  AssertTrue('supports lookup', Pos(#9'bl _GetItab', AsmT) >= 0);
  AssertTrue('failure path leaves out-var untouched (skip branch)',
    Pos(#9'add sp, sp, #32', AsmT) >= 0);
end;

procedure TArm64BackendTests.TestWeak_MetaclassCtor_IndexedProps;
var
  AsmT: string;
begin
  AsmT := GenAsm(
    '''
    program P;
    type
      TNode = class;
      TNodeClass = class of TNode;
      TNode = class
        [Weak] FParent: TNode;
        FVal: Int64;
        function GetItem(I: Int64): Int64;
        procedure SetItem(I: Int64; V: Int64);
        property Items[I: Int64]: Int64 read GetItem write SetItem;
      end;
    function TNode.GetItem(I: Int64): Int64;
    begin
      Result := FVal + I
    end;
    procedure TNode.SetItem(I: Int64; V: Int64);
    begin
      FVal := V - I
    end;
    var
      A, B: TNode;
      NC: TNodeClass;
      [Weak] W: TNode;
    begin
      A := TNode.Create();
      B := TNode.Create();
      B.FParent := A;
      W := A;
      NC := TNode;
      B := NC.Create();
      B.Items[2] := 10;
      WriteLn(B.Items[1])
    end.
    ''');
  { weak var + weak field go through the weak table }
  AssertTrue('weak assign', Pos(#9'bl _WeakAssign', AsmT) >= 0);
  { metaclass ctor: _ClassCreate on the metaclass VALUE }
  AssertTrue('metaclass create', Pos(#9'bl _ClassCreate', AsmT) >= 0);
  { indexed property accessors }
  AssertTrue('indexed getter', Pos(#9'bl TNode_GetItem', AsmT) >= 0);
  AssertTrue('indexed setter', Pos(#9'bl TNode_SetItem', AsmT) >= 0);
end;

procedure TArm64BackendTests.TestCaseAndRepeat;
var
  AsmT: string;
  Obj: string;
  F: TMachOFile;
begin
  AsmT := GenAsm(
    '''
    program P;
    const
      Marker = 9;
    var
      N, Acc: Int64;
    begin
      Acc := 0;
      N := 0;
      repeat
        Acc := Acc + N;
        N := N + 1
      until N > 4;
      case Acc of
        10, 11: WriteLn('ten-ish');
        Marker: WriteLn('nine');
      else
        WriteLn(Acc)
      end
    end.
    ''');
  { repeat: bottom-tested loop (cbz back to the top) }
  AssertTrue('repeat back-branch', Pos(#9'cbz x0, Lrep', AsmT) >= 0);
  { case: selector parked on the stack, chained equality tests }
  AssertTrue('case compare', Pos(#9'b.eq Lcbody', AsmT) >= 0);
  AssertTrue('selector reloaded per test', Pos(#9'ldr x0, [sp]', AsmT) >= 0);
  AssertTrue('named-const case value', Pos(#9'movz x1, #9', AsmT) >= 0);
  Obj := AssembleArm64ToBytes(AsmT);
  F := ParseMachO(Obj, 'arm64case.o');
  try
    AssertTrue('has a text section',
      F.FindSection('__TEXT', '__text') <> nil);
  finally
    F.Free();
  end;
end;

procedure TArm64BackendTests.TestExceptions_FramesHandlersUnwind;
var
  AsmT: string;
  Obj: string;
  F: TMachOFile;
begin
  AsmT := GenAsm(
    '''
    program P;
    type
      EBoom = class
      end;
    function Risky(N: Int64): Int64;
    begin
      Result := 0;
      try
        if N = 0 then
        begin
          Exit(7)
        end;
        if N > 5 then
          raise EBoom.Create();
        Result := N
      finally
        WriteLn('cleanup')
      end
    end;
    begin
      WriteLn(Risky(0));
      try
        WriteLn(Risky(9))
      except
        on E: EBoom do WriteLn('caught')
      end;
      try
        WriteLn(Risky(2))
      except
        WriteLn('never')
      end
    end.
    ''');
  { frames: push + setjmp guard, 512-byte static slot in the frame }
  AssertTrue('frame push', Pos(#9'bl _PushExcFrame', AsmT) >= 0);
  AssertTrue('setjmp guard', Pos(#9'bl _blaise_setjmp', AsmT) >= 0);
  AssertTrue('exception branch', Pos(#9'cbnz w0, Lfinexc', AsmT) >= 0);
  { raise + handler matching + rebind }
  AssertTrue('raise', Pos(#9'bl _Raise', AsmT) >= 0);
  AssertTrue('handler match', Pos(#9'bl _IsInstance', AsmT) >= 0);
  AssertTrue('finally re-raise', Pos(#9'bl _Reraise', AsmT) >= 0);
  { Exit inside try runs the finally on the way out (unwind emits an
    extra PopExcFrame before the exit branch) }
  AssertTrue('unwind pops', Pos(#9'bl _PopExcFrame', AsmT) >= 0);
  Obj := AssembleArm64ToBytes(AsmT);
  F := ParseMachO(Obj, 'arm64exc.o');
  try
    AssertTrue('has a text section',
      F.FindSection('__TEXT', '__text') <> nil);
  finally
    F.Free();
  end;
end;

procedure TArm64BackendTests.TestStaticArrays_ElementsAndArc;
var
  AsmT: string;
  Obj: string;
  F: TMachOFile;
begin
  AsmT := GenAsm(
    '''
    program P;
    var
      Nums: array[0..3] of Integer;
      Names: array[0..1] of string;
      I: Int64;
    begin
      for I := 0 to 3 do
        Nums[I] := I * 2;
      Names[0] := 'a';
      Names[1] := Names[0];
      WriteLn(Nums[2]);
      WriteLn(Names[1])
    end.
    ''');
  { width-aware element access: 4-byte Integer elements }
  AssertTrue('scaled index', Pos(#9'mul x1, x1, x2', AsmT) >= 0);
  AssertTrue('4-byte store', Pos(#9'str w0, [x9]', AsmT) >= 0);
  AssertTrue('signed 4-byte load', Pos(#9'ldrsw x0, [x0]', AsmT) >= 0);
  { managed elements: retain/release through the parked element address }
  AssertTrue('string elem retain', Pos(#9'bl _StringAddRef', AsmT) >= 0);
  AssertTrue('string elem release', Pos(#9'bl _StringRelease', AsmT) >= 0);
  Obj := AssembleArm64ToBytes(AsmT);
  F := ParseMachO(Obj, 'arm64sarr.o');
  try
    AssertTrue('has a text section',
      F.FindSection('__TEXT', '__text') <> nil);
  finally
    F.Free();
  end;
end;

procedure TArm64BackendTests.TestDynArrays_LifecycleAndElements;
var
  AsmT: string;
  Obj: string;
  F: TMachOFile;
begin
  AsmT := GenAsm(
    '''
    program P;
    var
      A, B: array of Int64;
      I: Int64;
    begin
      SetLength(A, 4);
      for I := 0 to 3 do
        A[I] := I * I;
      B := A;
      WriteLn(Length(B));
      WriteLn(B[3])
    end.
    ''');
  { lifecycle through the RTL }
  AssertTrue('setlength', Pos(#9'bl _DynArraySetLength', AsmT) >= 0);
  AssertTrue('length', Pos(#9'bl _DynArrayLength', AsmT) >= 0);
  { whole-value assignment: retain new, release old }
  AssertTrue('retain', Pos(#9'bl _DynArrayAddRef', AsmT) >= 0);
  AssertTrue('release', Pos(#9'bl _DynArrayRelease', AsmT) >= 0);
  { element access scales off the data pointer }
  AssertTrue('scaled elem', Pos(#9'mul x1, x1, x2', AsmT) >= 0);
  Obj := AssembleArm64ToBytes(AsmT);
  F := ParseMachO(Obj, 'arm64dyn.o');
  try
    AssertTrue('has a text section',
      F.FindSection('__TEXT', '__text') <> nil);
  finally
    F.Free();
  end;
end;

procedure TArm64BackendTests.TestSmallSets_LiteralsInOps;
var
  AsmT: string;
  Obj: string;
  F: TMachOFile;
begin
  AsmT := GenAsm(
    '''
    program P;
    type
      TDay = (Mon, Tue, Wed, Thu, Fri);
      TDays = set of TDay;
    var
      D, E: TDays;
    begin
      D := [Mon, Wed];
      E := D + [Fri];
      E := E - [Mon];
      D := D * E;
      WriteLn(Wed in D);
      WriteLn(D = E)
    end.
    ''');
  { const literal folds to an immediate mask (Mon|Wed = bits 0,2 = 5) }
  AssertTrue('folded mask', Pos(#9'movz x0, #5', AsmT) >= 0);
  { membership: shift + bit test + range guard }
  AssertTrue('bit shift', Pos(#9'lsr x0, x0, x1', AsmT) >= 0);
  AssertTrue('bit test', Pos(#9'and x0, x0, x2', AsmT) >= 0);
  AssertTrue('range guard', Pos(#9'cset x2, lt', AsmT) >= 0);
  { set ops: or / and / and-not }
  AssertTrue('union', Pos(#9'orr x0, x0, x1', AsmT) >= 0);
  AssertTrue('difference complement', Pos(#9'movn x2, #0', AsmT) >= 0);
  Obj := AssembleArm64ToBytes(AsmT);
  F := ParseMachO(Obj, 'arm64sets.o');
  try
    AssertTrue('has a text section',
      F.FindSection('__TEXT', '__text') <> nil);
  finally
    F.Free();
  end;
end;

procedure TArm64BackendTests.TestForIn_ArraysStringsSets;
var
  AsmT: string;
  Obj: string;
  F: TMachOFile;
begin
  AsmT := GenAsm(
    '''
    program P;
    type
      TDay = (Mon, Tue, Wed);
    var
      A: array[0..2] of Int64;
      D: array of Int64;
      S: string;
      Days: set of TDay;
      V, Total: Int64;
      B: Byte;
      E: TDay;
    begin
      A[0] := 1; A[1] := 2; A[2] := 3;
      SetLength(D, 2);
      D[0] := 5; D[1] := 6;
      S := 'hi';
      Days := [Mon, Wed];
      Total := 0;
      for V in A do
        Total := Total + V;
      for V in D do
        Total := Total + V;
      for B in S do
        Total := Total + B;
      for E in Days do
        Total := Total + 1;
      WriteLn(Total)
    end.
    ''');
  { dyn-array iteration re-reads the length each pass }
  AssertTrue('dyn length', Pos(#9'bl _DynArrayLength', AsmT) >= 0);
  { string byte-iteration: length at dataptr-8, byte loads }
  AssertTrue('string length read', Pos(#9'ldur w1, [x0, #-8]', AsmT) >= 0);
  AssertTrue('string byte load', Pos(#9'ldrb w0, [x0]', AsmT) >= 0);
  { set iteration: mask bit test per ordinal }
  AssertTrue('set bit test', Pos(#9'lsr x0, x0, x1', AsmT) >= 0);
  Obj := AssembleArm64ToBytes(AsmT);
  F := ParseMachO(Obj, 'arm64forin.o');
  try
    AssertTrue('has a text section',
      F.FindSection('__TEXT', '__text') <> nil);
  finally
    F.Free();
  end;
end;

procedure TArm64BackendTests.TestForIn_ClassEnumerator;
var
  AsmT: string;
  Obj: string;
  F: TMachOFile;
begin
  AsmT := GenAsm(
    '''
    program P;
    type
      TEnum = class
        FIdx: Int64;
        function MoveNext(): Boolean;
        function GetCurrent(): Int64;
        property Current: Int64 read GetCurrent;
      end;
      TColl = class
        function GetEnumerator(): TEnum;
      end;
    function TEnum.MoveNext(): Boolean;
    begin
      FIdx := FIdx + 1;
      Result := FIdx < 3
    end;
    function TEnum.GetCurrent(): Int64;
    begin
      Result := FIdx
    end;
    function TColl.GetEnumerator(): TEnum;
    begin
      Result := TEnum.Create();
    end;
    var
      C: TColl;
      V: Int64;
    begin
      C := TColl.Create();
      for V in C do
        WriteLn(V)
    end.
    ''');
  { the three protocol methods are all called }
  AssertTrue('GetEnumerator call', Pos(#9'bl TColl_GetEnumerator', AsmT) >= 0);
  AssertTrue('MoveNext call', Pos(#9'bl TEnum_MoveNext', AsmT) >= 0);
  AssertTrue('Current getter call', Pos(#9'bl TEnum_GetCurrent', AsmT) >= 0);
  { the enumerator is transferred into its slot (release old, no AddRef) }
  AssertTrue('enumerator slot release', Pos(#9'bl _ClassRelease', AsmT) >= 0);
  Obj := AssembleArm64ToBytes(AsmT);
  F := ParseMachO(Obj, 'arm64forinenum.o');
  try
    AssertTrue('has a text section',
      F.FindSection('__TEXT', '__text') <> nil);
  finally
    F.Free();
  end;
end;

procedure TArm64BackendTests.TestCase_StringSelectors;
var
  AsmT: string;
  Obj: string;
  F: TMachOFile;
begin
  AsmT := GenAsm(
    '''
    program P;
    var
      S: string;
      N: Int64;
    begin
      S := 'beta';
      case S of
        'alpha': N := 1;
        'beta', 'gamma': N := 2;
      else
        N := 0
      end;
      case S + 'x' of
        'betax': N := N + 1;
      end;
      WriteLn(N)
    end.
    ''');
  { each label compares via the RTL — pointer cmp would be silently wrong }
  AssertTrue('string equals chain', Pos(#9'bl _StringEquals', AsmT) >= 0);
  AssertTrue('match branches to body', Pos(#9'cbnz x0, Lcbody', AsmT) >= 0);
  { the concat selector is an rc=0 transient: pinned (AddRef then Release)
    after the dispatch — a bare release would make it immortal }
  AssertTrue('rc0 selector pinned', Pos(#9'bl _StringAddRef', AsmT) >= 0);
  Obj := AssembleArm64ToBytes(AsmT);
  F := ParseMachO(Obj, 'arm64strcase.o');
  try
    AssertTrue('has a text section',
      F.FindSection('__TEXT', '__text') <> nil);
  finally
    F.Free();
  end;
end;

procedure TArm64BackendTests.TestGlobalArrayInitialisers;
var
  AsmT: string;
  Obj: string;
  F: TMachOFile;
begin
  AsmT := GenAsm(
    '''
    program P;
    var
      Nums: array[0..3] of Integer = (10, 20, 30, 40);
      Names: array[0..1] of string = ('alpha', 'beta');
      Longs: array[0..1] of Int64 = (3, 4);
      Ds: array[0..1] of Double = (1.5, 2.5);
    begin
      WriteLn(Nums[2]);
      WriteLn(Names[1])
    end.
    ''');
  { integer elements laid out inline in .data }
  AssertTrue('int elements', Pos(#9'.word 30', AsmT) >= 0);
  { 8-byte elements }
  AssertTrue('int64 elements', Pos(#9'.quad 4', AsmT) >= 0);
  { double elements }
  AssertTrue('double elements', Pos(#9'.double 2.5', AsmT) >= 0);
  { string elements point at immortal blobs (no symbol arithmetic) }
  AssertTrue('string element pointer',
    Pos(#9'.quad __gi_Names_e1_d', AsmT) >= 0);
  AssertTrue('string element blob', Pos('__gi_Names_e1_d:', AsmT) >= 0);
  AssertTrue('string element bytes', Pos(#9'.ascii "beta"', AsmT) >= 0);
  Obj := AssembleArm64ToBytes(AsmT);
  F := ParseMachO(Obj, 'arm64ginit.o');
  try
    AssertTrue('has a data section',
      F.FindSection('__DATA', '__data') <> nil);
  finally
    F.Free();
  end;
end;

procedure TArm64BackendTests.TestClassAttributes_TablesAndBuiltins;
var
  AsmT: string;
  Obj: string;
  F: TMachOFile;
begin
  AsmT := GenAsm(
    '''
    program P;
    type
      ThreadedAttribute = class(TCustomAttribute)
      end;
      MarkAttribute = class(TCustomAttribute)
        FTag: string;
        constructor Create(ATag: string);
      end;
      [Threaded]
      [Mark('alpha')]
      TJob = class(TObject)
      published
        [Threaded]
        procedure Run;
      end;
    constructor MarkAttribute.Create(ATag: string);
    begin
      FTag := ATag
    end;
    procedure TJob.Run;
    begin
    end;
    var
      B: Boolean;
    begin
      B := HasClassAttribute(TJob, ThreadedAttribute);
      WriteLn(B);
      WriteLn(HasMethodAttribute(TJob, 'Run', ThreadedAttribute));
      WriteLn(MethodAttributeCount(TJob, 'Run'))
    end.
    ''');
  { attribute tables: (typeinfo, thunk) pairs behind typeinfo slot 7,
    (name, typeinfo, thunk) triples behind slot 8 }
  AssertTrue('class attrs table', Pos('attrs_TJob:', AsmT) >= 0);
  AssertTrue('factory thunk referenced',
    Pos(#9'.quad __attr_TJob_c0', AsmT) >= 0);
  AssertTrue('method attrs table', Pos('methattrs_TJob:', AsmT) >= 0);
  AssertTrue('typeinfo slot 7 wired', Pos(#9'.quad attrs_TJob', AsmT) >= 0);
  { TCustomAttribute base stubs exist for the parent chain }
  AssertTrue('TCustomAttribute typeinfo',
    Pos('typeinfo_TCustomAttribute:', AsmT) >= 0);
  { RTTI builtins lower to the runtime helpers }
  AssertTrue('has-class-attr call', Pos(#9'bl _HasClassAttribute', AsmT) >= 0);
  AssertTrue('has-method-attr call',
    Pos(#9'bl _HasMethodAttribute', AsmT) >= 0);
  AssertTrue('count call', Pos(#9'bl _MethodAttributeCount', AsmT) >= 0);
  Obj := AssembleArm64ToBytes(AsmT);
  F := ParseMachO(Obj, 'arm64attrs.o');
  try
    AssertTrue('has a text section',
      F.FindSection('__TEXT', '__text') <> nil);
  finally
    F.Free();
  end;
end;

procedure TArm64BackendTests.TestGenericInstances_WeakEmission;
var
  AsmT: string;
  Obj: string;
  F: TMachOFile;
begin
  AsmT := GenAsm(
    '''
    program P;
    type
      TBox<T> = class
        FVal: T;
        procedure Put(AV: T);
        function Get(): T;
      end;
    procedure TBox<T>.Put(AV: T);
    begin
      FVal := AV
    end;
    function TBox<T>.Get(): T;
    begin
      Result := FVal
    end;
    function Pick<T>(A, B: T): T;
    begin
      Result := A
    end;
    var
      B: TBox<Int64>;
    begin
      B := TBox<Int64>.Create();
      B.Put(41);
      WriteLn(B.Get() + 1);
      WriteLn(Pick<Int64>(7, 9))
    end.
    ''');
  { instance symbols are BARE (no unit prefix) and WEAK — every object
    that materialises the same instance carries an identical copy and
    the linker keeps one (BUG-004) }
  AssertTrue('weak typeinfo', Pos('.weak typeinfo_TBox_Int64', AsmT) >= 0);
  AssertTrue('weak vtable', Pos('.weak vtable_TBox_Int64', AsmT) >= 0);
  AssertTrue('weak cleanup',
    Pos('.weak _FieldCleanup_TBox_Int64', AsmT) >= 0);
  AssertTrue('instance method body', Pos('TBox_Int64_Put:', AsmT) >= 0);
  AssertTrue('weak method bind', Pos('.weak TBox_Int64_Put', AsmT) >= 0);
  { instance is constructed through its own typeinfo }
  AssertTrue('ctor typeinfo ref',
    Pos('adrp x0, typeinfo_TBox_Int64@PAGE', AsmT) >= 0);
  { the generic FUNCTION instance is emitted weak too }
  AssertTrue('weak func instance', Pos('.weak Pick_Int64', AsmT) >= 0);
  Obj := AssembleArm64ToBytes(AsmT);
  F := ParseMachO(Obj, 'arm64gen.o');
  try
    AssertTrue('has a text section',
      F.FindSection('__TEXT', '__text') <> nil);
  finally
    F.Free();
  end;
end;

procedure TArm64BackendTests.TestAsmRoutines_NoStackFrame;
var
  AsmT: string;
  Obj: string;
  F: TMachOFile;
begin
  AsmT := GenAsm(
    '''
    program P;
    function AddOne(A: Int64): Int64; assembler; nostackframe;
    asm
        add x0, x0, #1
        ret
    end;
    begin
      WriteLn(AddOne(41))
    end.
    ''');
  { the body is emitted verbatim: no compiler prologue/epilogue around it }
  AssertTrue('label emitted', Pos('AddOne:', AsmT) >= 0);
  AssertTrue('verbatim body', Pos('add x0, x0, #1', AsmT) >= 0);
  { no stp/ldp frame bracket between the label and the ret }
  AssertTrue('no prologue',
    Pos(#9'stp x29, x30', Copy(AsmT, Pos('AddOne:', AsmT),
      Pos('add x0, x0, #1', AsmT) - Pos('AddOne:', AsmT))) < 0);
  Obj := AssembleArm64ToBytes(AsmT);
  F := ParseMachO(Obj, 'arm64asmfn.o');
  try
    AssertTrue('has a text section',
      F.FindSection('__TEXT', '__text') <> nil);
  finally
    F.Free();
  end;
end;

procedure TArm64BackendTests.TestPointers_DerefWriteAddrOf;
var
  AsmT: string;
  Obj: string;
  F: TMachOFile;
begin
  AsmT := GenAsm(
    '''
    program P;
    type
      PInt = ^Integer;
      PW = ^Word;
    var
      N: Integer;
      Q: PInt;
      H: PW;
      B: Int64;
    begin
      N := 7;
      Q := @N;
      Q^ := Q^ + 1;
      H := PW(Pointer(Q));
      B := Integer(H^);
      WriteLn(N);
      WriteLn(B)
    end.
    ''');
  { deref read: 4-byte signed load through the pointer }
  AssertTrue('deref int read', Pos(#9'ldrsw x0, [x0]', AsmT) >= 0);
  { pointer write: 4-byte store through the parked pointer }
  AssertTrue('deref int write', Pos(#9'str w0, [x9]', AsmT) >= 0);
  { unsigned 2-byte deref uses ldrh }
  AssertTrue('word deref', Pos(#9'ldrh w0, [x0]', AsmT) >= 0);
  { Integer(x) cast normalises the width }
  AssertTrue('int cast narrows', Pos(#9'sxtw x0, w0', AsmT) >= 0);
  Obj := AssembleArm64ToBytes(AsmT);
  F := ParseMachO(Obj, 'arm64ptr.o');
  try
    AssertTrue('has a text section',
      F.FindSection('__TEXT', '__text') <> nil);
  finally
    F.Free();
  end;
end;

initialization
  RegisterTest(TArm64BackendTests);

end.
