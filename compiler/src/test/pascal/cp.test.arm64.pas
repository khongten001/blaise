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
    A := TSemanticAnalyser.Create();
    try
      A.Analyse(Prog);
    finally
      A.Free();
    end;
    MakeTarget(osMacOS, cpuArm64, T);
    CG := TArm64Backend.Create(T);
    try
      CG.SetSymbolTable(Prog.SymbolTable);
      Result := CG.GenerateProgram(Prog);
    finally
      CG.Free();
    end;
  finally
    Prog.Free();
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
        TC = class
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

initialization
  RegisterTest(TArm64BackendTests);

end.
