{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: BSD-3-Clause
  See LICENSE file in the project root for full license terms.
}

unit cp.test.multiwrite;

{$mode objfpc}{$H+}

{ Tests for multi-argument Write and WriteLn code generation. }

interface

uses
  Classes, SysUtils, StrUtils, fpcunit, testregistry,
  uLexer, uParser, uAST, uSymbolTable, uSemantic, uCodeGenQBE;

type
  TMultiWriteTests = class(TTestCase)
  private
    function ParseSrc(const ASrc: string): TProgram;
    function AnalyseSrc(const ASrc: string): TProgram;
    function GenIR(const ASrc: string): string;
    function CountOccurrences(const AHaystack, ANeedle: string): Integer;
  published
    procedure TestCodegen_WriteLn_TwoArgs_EmitsTwoWriteCallsPlusNewline;
    procedure TestCodegen_WriteLn_ThreeArgs_EmitsTrailingNewline;
    procedure TestCodegen_Write_TwoArgs_NoTrailingNewline;
    procedure TestCodegen_WriteLn_MixedStringAndInteger;
    procedure TestCodegen_WriteLn_Empty_StillEmitsNewline;
  end;

implementation

function TMultiWriteTests.ParseSrc(const ASrc: string): TProgram;
var L: TLexer; P: TParser;
begin
  L := TLexer.Create(ASrc);
  P := TParser.Create(L);
  try Result := P.Parse; finally P.Free; L.Free; end;
end;

function TMultiWriteTests.AnalyseSrc(const ASrc: string): TProgram;
var A: TSemanticAnalyser;
begin
  Result := ParseSrc(ASrc);
  A := TSemanticAnalyser.Create;
  try A.Analyse(Result); finally A.Free; end;
end;

function TMultiWriteTests.GenIR(const ASrc: string): string;
var Prog: TProgram; CG: TCodeGenQBE;
begin
  Prog := AnalyseSrc(ASrc);
  try
    CG := TCodeGenQBE.Create;
    try CG.Generate(Prog); Result := CG.GetOutput; finally CG.Free; end;
  finally Prog.Free; end;
end;

function TMultiWriteTests.CountOccurrences(
  const AHaystack, ANeedle: string): Integer;
var Pos, I: Integer;
begin
  Result := 0;
  I      := 1;
  repeat
    Pos := PosEx(ANeedle, AHaystack, I);
    if Pos = 0 then Break;
    Inc(Result);
    I := Pos + Length(ANeedle);
  until False;
end;

procedure TMultiWriteTests.TestCodegen_WriteLn_TwoArgs_EmitsTwoWriteCallsPlusNewline;
var
  IR: string;
  WriteIntCalls, NewlineCalls: Integer;
begin
  IR := GenIR(
    'program P;'                    + LineEnding +
    'var I, J: Integer;'            + LineEnding +
    'begin'                         + LineEnding +
    '  I := 1; J := 2;'             + LineEnding +
    '  WriteLn(I, J)'               + LineEnding +
    'end.');
  WriteIntCalls := CountOccurrences(IR, 'call $_SysWriteInt(');
  NewlineCalls  := CountOccurrences(IR, 'call $_SysWriteNewline(');
  AssertEquals('2 _SysWriteInt calls for values', 2, WriteIntCalls);
  AssertEquals('1 _SysWriteNewline call', 1, NewlineCalls);
end;

procedure TMultiWriteTests.TestCodegen_WriteLn_ThreeArgs_EmitsTrailingNewline;
var IR: string;
begin
  IR := GenIR(
    'program P;'                     + LineEnding +
    'var A, B, C: Integer;'          + LineEnding +
    'begin'                          + LineEnding +
    '  A := 1; B := 2; C := 3;'      + LineEnding +
    '  WriteLn(A, B, C)'             + LineEnding +
    'end.');
  AssertTrue('emits newline call', Pos('call $_SysWriteNewline(', IR) > 0);
  AssertEquals('3 _SysWriteInt calls for values',
    3, CountOccurrences(IR, 'call $_SysWriteInt('));
end;

procedure TMultiWriteTests.TestCodegen_Write_TwoArgs_NoTrailingNewline;
var IR: string;
begin
  IR := GenIR(
    'program P;'                    + LineEnding +
    'var I, J: Integer;'            + LineEnding +
    'begin'                         + LineEnding +
    '  I := 1; J := 2;'             + LineEnding +
    '  Write(I, J)'                 + LineEnding +
    'end.');
  { Write must not issue a trailing newline call.  The format string is
    always defined in the data section, so we look specifically for the
    call (not the declaration). }
  AssertEquals('no _SysWriteNewline call', 0,
    CountOccurrences(IR, 'call $_SysWriteNewline('));
  AssertEquals('2 _SysWriteInt calls', 2,
    CountOccurrences(IR, 'call $_SysWriteInt('));
end;

procedure TMultiWriteTests.TestCodegen_WriteLn_MixedStringAndInteger;
var IR: string;
begin
  IR := GenIR(
    'program P;'                          + LineEnding +
    'var I: Integer; S: string;'          + LineEnding +
    'begin'                               + LineEnding +
    '  I := 7;'                           + LineEnding +
    '  S := ''hi'';'                      + LineEnding +
    '  WriteLn(S, I)'                     + LineEnding +
    'end.');
  AssertTrue('uses _SysWriteStr for string', Pos('call $_SysWriteStr(', IR) > 0);
  AssertTrue('uses _SysWriteInt for integer', Pos('call $_SysWriteInt(', IR) > 0);
end;

procedure TMultiWriteTests.TestCodegen_WriteLn_Empty_StillEmitsNewline;
var IR: string;
begin
  IR := GenIR(
    'program P;'                + LineEnding +
    'begin'                     + LineEnding +
    '  WriteLn'                 + LineEnding +
    'end.');
  AssertTrue('empty WriteLn still emits newline',
    Pos('call $_SysWriteNewline(w 1)', IR) > 0);
end;

initialization
  RegisterTest(TMultiWriteTests);

end.
