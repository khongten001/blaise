{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit cp.test.jumboset;

{ IR unit tests for JUMBO sets — `set of <enum>` whose enum has more than 64
  members (up to the 256 ceiling).  Jumbo sets are inline byte-array bitmaps
  operated on via the _Set* RTL helpers, unlike <=64-member sets which stay in
  a w/l register.  These tests assert the generated QBE IR routes jumbo set
  operations to the helper calls and that a <=64 set in the same file still
  uses the register path (regression). }

interface

uses
  Classes, SysUtils, blaise.testing,
  uLexer, uParser, uAST, uSymbolTable, uSemantic, blaise.codegen.qbe;

type
  TJumboSetTests = class(TTestCase)
  private
    function GenIR(const ASrc: string): string;
  published
    procedure TestSlot_SizedToBitmap;
    procedure TestZeroInit_UsesMemset;
    procedure TestIn_CallsSetIn;
    procedure TestUnion_CallsSetUnion;
    procedure TestInter_CallsSetInter;
    procedure TestDiff_CallsSetDiff;
    procedure TestEqual_CallsSetEqual;
    procedure TestInclude_CallsSetInclude;
    procedure TestExclude_CallsSetExclude;
    procedure TestAssignment_UsesMemcpy;
    procedure TestFieldAssignment_UsesMemcpy;
    procedure TestVarParamAssignment_UsesMemcpy;
    procedure TestArrayElemAssignment_UsesMemcpy;
    procedure TestConst_EmitsByteBlob;
    procedure TestSmallSet_StillUsesRegister;
  end;

implementation

const
  { An 80-member enum (b00..b79) — clears the 64 boundary cheaply. }
  EnumDecl =
    '  TBig = (b00,b01,b02,b03,b04,b05,b06,b07,b08,b09,b10,b11,b12,b13,b14,b15,' + #10 +
    '          b16,b17,b18,b19,b20,b21,b22,b23,b24,b25,b26,b27,b28,b29,b30,b31,' + #10 +
    '          b32,b33,b34,b35,b36,b37,b38,b39,b40,b41,b42,b43,b44,b45,b46,b47,' + #10 +
    '          b48,b49,b50,b51,b52,b53,b54,b55,b56,b57,b58,b59,b60,b61,b62,b63,' + #10 +
    '          b64,b65,b66,b67,b68,b69,b70,b71,b72,b73,b74,b75,b76,b77,b78,b79);' + #10 +
    '  TBigSet = set of TBig;' + #10;

function TJumboSetTests.GenIR(const ASrc: string): string;
var
  Lex:  TLexer;
  Par:  TParser;
  SA:   TSemanticAnalyser;
  CG:   TCodeGenQBE;
  Prog: TProgram;
begin
  Lex  := TLexer.Create(ASrc);
  Par  := TParser.Create(Lex);
  Prog := Par.Parse();
  Par.Free(); Lex.Free();
  SA   := TSemanticAnalyser.Create();
  SA.Analyse(Prog);
  SA.Free();
  CG   := TCodeGenQBE.Create();
  CG.Generate(Prog);
  Result := CG.GetOutput();
  CG.Free();
  Prog.Free();
end;

procedure TJumboSetTests.TestSlot_SizedToBitmap;
var IR: string;
begin
  { 80 bits -> 10 bytes -> rounded to 16: the global slot is a 16-byte blob. }
  IR := GenIR('program P;' + #10 + 'type' + #10 + EnumDecl +
              'var s: TBigSet;' + #10 + 'begin end.');
  AssertTrue('jumbo global emits a 16-byte zero blob',
    Pos('$s = { z 16 }', IR) >= 0);
end;

procedure TJumboSetTests.TestZeroInit_UsesMemset;
var IR: string;
begin
  IR := GenIR('program P;' + #10 + 'type' + #10 + EnumDecl +
              'procedure Q; var s: TBigSet; begin s := []; end;' + #10 +
              'begin end.');
  AssertTrue('jumbo local zero-init via memset', Pos('call $memset', IR) >= 0);
end;

procedure TJumboSetTests.TestIn_CallsSetIn;
var IR: string;
begin
  IR := GenIR('program P;' + #10 + 'type' + #10 + EnumDecl +
              'var s: TBigSet; b: Boolean;' + #10 +
              'begin b := b70 in s; end.');
  AssertTrue('jumbo in -> _SetIn', Pos('call $_SetIn(', IR) >= 0);
end;

procedure TJumboSetTests.TestUnion_CallsSetUnion;
var IR: string;
begin
  IR := GenIR('program P;' + #10 + 'type' + #10 + EnumDecl +
              'var a, b, c: TBigSet;' + #10 + 'begin c := a + b; end.');
  AssertTrue('jumbo + -> _SetUnion', Pos('call $_SetUnion(', IR) >= 0);
end;

procedure TJumboSetTests.TestInter_CallsSetInter;
var IR: string;
begin
  IR := GenIR('program P;' + #10 + 'type' + #10 + EnumDecl +
              'var a, b, c: TBigSet;' + #10 + 'begin c := a * b; end.');
  AssertTrue('jumbo * -> _SetInter', Pos('call $_SetInter(', IR) >= 0);
end;

procedure TJumboSetTests.TestDiff_CallsSetDiff;
var IR: string;
begin
  IR := GenIR('program P;' + #10 + 'type' + #10 + EnumDecl +
              'var a, b, c: TBigSet;' + #10 + 'begin c := a - b; end.');
  AssertTrue('jumbo - -> _SetDiff', Pos('call $_SetDiff(', IR) >= 0);
end;

procedure TJumboSetTests.TestEqual_CallsSetEqual;
var IR: string;
begin
  IR := GenIR('program P;' + #10 + 'type' + #10 + EnumDecl +
              'var a, b: TBigSet; x: Boolean;' + #10 +
              'begin x := a = b; end.');
  AssertTrue('jumbo = -> _SetEqual', Pos('call $_SetEqual(', IR) >= 0);
end;

procedure TJumboSetTests.TestInclude_CallsSetInclude;
var IR: string;
begin
  IR := GenIR('program P;' + #10 + 'type' + #10 + EnumDecl +
              'var s: TBigSet;' + #10 + 'begin Include(s, b70); end.');
  AssertTrue('jumbo Include -> _SetInclude', Pos('call $_SetInclude(', IR) >= 0);
end;

procedure TJumboSetTests.TestExclude_CallsSetExclude;
var IR: string;
begin
  IR := GenIR('program P;' + #10 + 'type' + #10 + EnumDecl +
              'var s: TBigSet;' + #10 + 'begin Exclude(s, b70); end.');
  AssertTrue('jumbo Exclude -> _SetExclude', Pos('call $_SetExclude(', IR) >= 0);
end;

procedure TJumboSetTests.TestAssignment_UsesMemcpy;
var IR: string;
begin
  IR := GenIR('program P;' + #10 + 'type' + #10 + EnumDecl +
              'var a, b: TBigSet;' + #10 + 'begin a := b; end.');
  AssertTrue('jumbo assignment via memcpy', Pos('call $memcpy', IR) >= 0);
end;

procedure TJumboSetTests.TestFieldAssignment_UsesMemcpy;
var IR: string;
begin
  { A jumbo set stored into a RECORD FIELD must copy the whole bitmap.  The old
    codegen fell through to the generic scalar store and emitted a single
    `storel <scratch-ptr>, <field-addr>` — the field then held the ADDRESS of a
    stack scratch buffer instead of a copy of the bitmap, so every member was
    silently lost. }
  IR := GenIR('program P;' + #10 + 'type' + #10 + EnumDecl +
              '  TRec = record S: TBigSet; end;' + #10 +
              'var r: TRec; b: TBigSet;' + #10 + 'begin r.S := r.S + b; end.');
  AssertTrue('jumbo field assignment via memcpy', Pos('call $memcpy', IR) >= 0);
  AssertTrue('jumbo field assignment must not scalar-store the union result',
    Pos('storel %_t', IR) < 0);
end;

procedure TJumboSetTests.TestVarParamAssignment_UsesMemcpy;
var IR: string;
begin
  { Same bug through a var parameter: the destination is the caller's bitmap
    address held in the pointer slot, so the store must be a memcpy into it. }
  IR := GenIR('program P;' + #10 + 'type' + #10 + EnumDecl +
              'procedure Q(var s: TBigSet); begin s := s + [b70]; end;' + #10 +
              'begin end.');
  AssertTrue('jumbo var-param assignment via memcpy', Pos('call $memcpy', IR) >= 0);
  AssertTrue('jumbo var-param assignment must not scalar-store the union result',
    Pos('storel %_t', IR) < 0);
end;

procedure TJumboSetTests.TestArrayElemAssignment_UsesMemcpy;
var IR: string;
begin
  { And into a static-array element. }
  IR := GenIR('program P;' + #10 + 'type' + #10 + EnumDecl +
              'var a: array[0..1] of TBigSet; b: TBigSet;' + #10 +
              'begin a[0] := b; end.');
  AssertTrue('jumbo array-element assignment via memcpy',
    Pos('call $memcpy', IR) >= 0);
end;

procedure TJumboSetTests.TestConst_EmitsByteBlob;
var IR: string;
begin
  IR := GenIR('program P;' + #10 + 'type' + #10 + EnumDecl +
              'const H: TBigSet = [b65, b70, b79];' + #10 +
              'var s: TBigSet;' + #10 + 'begin s := H; end.');
  { 80-bit bitmap blob: a data item of `b` bytes; byte 8 holds bits for 65,70. }
  AssertTrue('jumbo const emits a byte blob', Pos('data $', IR) >= 0);
  AssertTrue('blob contains byte directives', Pos('b 66', IR) >= 0);
end;

procedure TJumboSetTests.TestSmallSet_StillUsesRegister;
var IR: string;
begin
  { A <=64 set in the same shape must NOT use the _Set* helpers — it stays a
    register bitmask. }
  IR := GenIR('program P;' + #10 +
              'type TSmall = (s0,s1,s2,s3); TSmallSet = set of TSmall;' + #10 +
              'var s: TSmallSet; b: Boolean;' + #10 +
              'begin s := [s1]; b := s1 in s; end.');
  AssertTrue('small set does not call _SetIn', Pos('call $_SetIn', IR) < 0);
  AssertTrue('small set does not call _SetUnion', Pos('call $_SetUnion', IR) < 0);
end;

initialization
  RegisterTest(TJumboSetTests);

end.
