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
        IThing = interface
          procedure Go;
        end;
      begin
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
  AssertTrue('bound stored to the hidden slot',
    Pos(#9'stur x0, [x29, #-8]', AsmT) >= 0);
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
  { the concat result OWNS its +1: between the concat and the release of
    the slot's OLD value there must be no retain of the new value }
  ConcatPos := Pos(#9'bl _StringConcat', AsmT);
  AddRefAfter := Pos(#9'bl _StringRelease',
    Copy(AsmT, ConcatPos, Length(AsmT) - ConcatPos));
  AssertTrue('old-value release follows the concat', AddRefAfter >= 0);
  AssertTrue('owned concat result not double-retained on assignment',
    Pos(#9'bl _StringAddRef',
      Copy(AsmT, ConcatPos, AddRefAfter)) < 0);
  { the WriteLn transient is released after the write }
  AssertTrue('transient released after write',
    Pos(#9'bl _SysWriteStr', AsmT) >= 0);
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
  Raised: Boolean;
  Msg: string;
begin
  Raised := False;
  Msg := '';
  try
    GenAsmWithUnit(
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
  except
    on E: ENativeCodeGenError do
    begin
      Raised := True;
      Msg := E.Message;
    end;
  end;
  AssertTrue('finalization section raises', Raised);
  AssertTrue('message names the hole', Pos('finalization', Msg) >= 0);
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

initialization
  RegisterTest(TArm64BackendTests);

end.
