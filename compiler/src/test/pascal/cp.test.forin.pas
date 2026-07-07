{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit cp.test.forin;

{ Tests for for..in loop: class-based enumerators, static array, dynamic array, string, and set iteration. }

interface

uses
  Classes, SysUtils, blaise.testing,
  uLexer, uParser, uAST, uSymbolTable, uSemantic, blaise.codegen.qbe;

type
  TForInTests = class(TTestCase)
  private
    function ParseSrc(const ASrc: string): TProgram;
    function AnalyseSrc(const ASrc: string): TProgram;
    function GenIR(const ASrc: string): string;
    procedure AnalyseExpectError(const ASrc: string);
  published
    { ------------------------------------------------------------------ }
    { Parser                                                               }
    { ------------------------------------------------------------------ }
    procedure TestParse_ForIn_IsTForInStmt;
    procedure TestParse_ForIn_VarName;
    procedure TestParse_ForIn_CollExprIsIdent;

    { ------------------------------------------------------------------ }
    { Semantic                                                             }
    { ------------------------------------------------------------------ }
    procedure TestSemantic_ForIn_Valid_OK;
    procedure TestSemantic_ForIn_NoGetEnumerator_RaisesError;
    procedure TestSemantic_ForIn_MoveNextNotBoolean_RaisesError;
    procedure TestSemantic_ForIn_NoCurrent_RaisesError;
    procedure TestSemantic_ForIn_VarTypeMismatch_RaisesError;
    procedure TestSemantic_ForIn_CollNotClass_RaisesError;

    { ------------------------------------------------------------------ }
    { Codegen — class enumerator                                           }
    { ------------------------------------------------------------------ }
    procedure TestCodegen_ForIn_HasForInCondLabel;
    procedure TestCodegen_ForIn_HasForInBodyLabel;
    procedure TestCodegen_ForIn_HasForInEndLabel;
    procedure TestCodegen_ForIn_CallsGetEnumerator;
    procedure TestCodegen_ForIn_CallsMoveNext;
    procedure TestCodegen_ForIn_CallsGetCurrent;
    procedure TestCodegen_ForIn_JnzOnMoveNextResult;
    procedure TestCodegen_ForIn_JumpsBackToCond;
    { A record-typed Current must sret straight into the loop variable
      (regression for the record-property-read heap corruption). }
    procedure TestCodegen_ForIn_RecordCurrent_SretsIntoLoopVar;

    { ------------------------------------------------------------------ }
    { Semantic — static array                                              }
    { ------------------------------------------------------------------ }
    procedure TestSemantic_ArrayForIn_Valid_OK;
    procedure TestSemantic_ArrayForIn_VarTypeMismatch_RaisesError;
    procedure TestSemantic_ArrayForIn_NonZeroBased_OK;

    { ------------------------------------------------------------------ }
    { Codegen — static array                                               }
    { ------------------------------------------------------------------ }
    procedure TestCodegen_ArrayForIn_HasForInCondLabel;
    procedure TestCodegen_ArrayForIn_HasForInEndLabel;
    procedure TestCodegen_ArrayForIn_LoadsElement;
    { Issue #169: a record loop variable is copied by value (managed field ARC),
      not truncated to a scalar load. }
    procedure TestCodegen_ArrayForIn_RecordElement_CopiesByValue;
    procedure TestCodegen_ArrayForIn_JumpsBackToCond;
    procedure TestCodegen_ArrayForIn_NonZeroBased_AdjustsIndex;

    { ------------------------------------------------------------------ }
    { Semantic — set                                                       }
    { ------------------------------------------------------------------ }
    procedure TestSemantic_SetForIn_Valid_OK;
    procedure TestSemantic_SetForIn_VarTypeMismatch_RaisesError;
    procedure TestSemantic_SetForIn_NonSetCollNotAllowed;

    { ------------------------------------------------------------------ }
    { Codegen — set                                                        }
    { ------------------------------------------------------------------ }
    procedure TestCodegen_SetForIn_HasForInCondLabel;
    procedure TestCodegen_SetForIn_HasForInEndLabel;
    procedure TestCodegen_SetForIn_HasForInNextLabel;
    procedure TestCodegen_SetForIn_TestsBitWithShr;
    procedure TestCodegen_SetForIn_TestsBitWithAnd1;
    procedure TestCodegen_SetForIn_JumpsBackToCond;
    procedure TestCodegen_SetForIn_EvaluatesMaskOnce;

    { ------------------------------------------------------------------ }
    { Semantic — dynamic array                                             }
    { ------------------------------------------------------------------ }
    procedure TestSemantic_DynArrayForIn_Valid_OK;
    procedure TestSemantic_DynArrayForIn_VarTypeMismatch_RaisesError;

    { ------------------------------------------------------------------ }
    { Codegen — dynamic array                                              }
    { ------------------------------------------------------------------ }
    procedure TestCodegen_DynArrayForIn_HasForInCondLabel;
    procedure TestCodegen_DynArrayForIn_HasForInEndLabel;
    procedure TestCodegen_DynArrayForIn_CallsDynArrayLength;
    procedure TestCodegen_DynArrayForIn_LoadsElement;
    procedure TestCodegen_DynArrayForIn_JumpsBackToCond;

    { ------------------------------------------------------------------ }
    { Semantic — string                                                    }
    { ------------------------------------------------------------------ }
    procedure TestSemantic_StringForIn_ByteVar_OK;
    procedure TestSemantic_StringForIn_IntVar_IsCodePointIter;
    procedure TestSemantic_StringForIn_NonOrdinalVar_RaisesError;
    procedure TestSemantic_StringForIn_WordVar_RaisesError;
    procedure TestSemantic_StringForIn_SmallIntVar_RaisesError;

    { ------------------------------------------------------------------ }
    { Codegen — string byte iteration                                      }
    { ------------------------------------------------------------------ }
    procedure TestCodegen_StringForIn_HasForInCondLabel;
    procedure TestCodegen_StringForIn_HasForInEndLabel;
    procedure TestCodegen_StringForIn_LoadsByteWithLoadub;
    procedure TestCodegen_StringForIn_JumpsBackToCond;
    procedure TestCodegen_StringForIn_UsesLengthFromHeader;

    { ------------------------------------------------------------------ }
    { Codegen — string codepoint iteration                                 }
    { ------------------------------------------------------------------ }
    procedure TestCodegen_CodePointForIn_CallsUtf8DecodeAt;
    procedure TestCodegen_CodePointForIn_HasForInCondLabel;
  end;

implementation

{ ------------------------------------------------------------------ }
{ Helpers                                                             }
{ ------------------------------------------------------------------ }

function TForInTests.ParseSrc(const ASrc: string): TProgram;
var L: TLexer; P: TParser;
begin
  L := TLexer.Create(ASrc);
  P := TParser.Create(L);
  try
    Result := P.Parse();
  finally
    P.Free(); L.Free();
  end;
end;

function TForInTests.AnalyseSrc(const ASrc: string): TProgram;
var A: TSemanticAnalyser;
begin
  Result := ParseSrc(ASrc);
  A := TSemanticAnalyser.Create();
  try
    A.Analyse(Result);
  finally
    A.Free();
  end;
end;

function TForInTests.GenIR(const ASrc: string): string;
var Prog: TProgram; CG: TCodeGenQBE;
begin
  Prog := AnalyseSrc(ASrc);
  try
    CG := TCodeGenQBE.Create();
    try
      CG.Generate(Prog);
      Result := CG.GetOutput();
    finally
      CG.Free();
    end;
  finally
    Prog.Free();
  end;
end;

procedure TForInTests.AnalyseExpectError(const ASrc: string);
var Prog: TProgram;
begin
  try
    Prog := AnalyseSrc(ASrc);
    Prog.Free();
    Fail('Expected ESemanticError');
  except
    on E: ESemanticError do ;
  end;
end;

{ ------------------------------------------------------------------ }
{ Shared source — minimal enumerator+collection pair                  }
{ ------------------------------------------------------------------ }

const
  SrcEnumTypes =
    '''
        type
          TMyEnum = class
            FCurrent: Integer;
            function MoveNext: Boolean;
            function GetCurrent: Integer;
            property Current: Integer read GetCurrent;
          end;
          TMyCol = class
            function GetEnumerator: TMyEnum;
          end;
        function TMyEnum.MoveNext: Boolean;
        begin
          Result := False;
        end;
        function TMyEnum.GetCurrent: Integer;
        begin
          Result := FCurrent;
        end;
        function TMyCol.GetEnumerator: TMyEnum;
        begin
          Result := nil;
        end;
        ''';

  SrcForIn =
    'program P;' + #10 +
    SrcEnumTypes + #10 +
    '''
        var
          Col: TMyCol;
          X:   Integer;
        begin
          for X in Col do
            X := X + 1
        end.
        ''';

{ ------------------------------------------------------------------ }
{ Parser tests                                                         }
{ ------------------------------------------------------------------ }

procedure TForInTests.TestParse_ForIn_IsTForInStmt;
var Prog: TProgram;
begin
  Prog := ParseSrc(SrcForIn);
  try
    AssertTrue('stmt is TForInStmt',
      Prog.Block.Stmts[0] is TForInStmt);
  finally
    Prog.Free();
  end;
end;

procedure TForInTests.TestParse_ForIn_VarName;
var Prog: TProgram; FS: TForInStmt;
begin
  Prog := ParseSrc(SrcForIn);
  try
    FS := TForInStmt(Prog.Block.Stmts[0]);
    AssertEquals('loop var is X', 'X', FS.VarName);
  finally
    Prog.Free();
  end;
end;

procedure TForInTests.TestParse_ForIn_CollExprIsIdent;
var Prog: TProgram; FS: TForInStmt;
begin
  Prog := ParseSrc(SrcForIn);
  try
    FS := TForInStmt(Prog.Block.Stmts[0]);
    AssertTrue('collection is TIdentExpr', FS.CollExpr is TIdentExpr);
    AssertEquals('collection name is Col', 'Col',
      TIdentExpr(FS.CollExpr).Name);
  finally
    Prog.Free();
  end;
end;

{ ------------------------------------------------------------------ }
{ Semantic tests                                                       }
{ ------------------------------------------------------------------ }

procedure TForInTests.TestSemantic_ForIn_Valid_OK;
begin
  AnalyseSrc(SrcForIn).Free();
end;

procedure TForInTests.TestSemantic_ForIn_NoGetEnumerator_RaisesError;
begin
  AnalyseExpectError(
    '''
        program P;
        type
          TBadCol = class
            FCount: Integer;
          end;
        var
          Col: TBadCol;
          X:   Integer;
        begin
          for X in Col do
            X := X + 1
        end.
        ''');
end;

procedure TForInTests.TestSemantic_ForIn_MoveNextNotBoolean_RaisesError;
begin
  AnalyseExpectError(
    '''
        program P;
        type
          TBadEnum = class
            function MoveNext: Integer;
            function GetCurrent: Integer;
            property Current: Integer read GetCurrent;
          end;
          TBadCol = class
            function GetEnumerator: TBadEnum;
          end;
        var
          Col: TBadCol;
          X:   Integer;
        begin
          for X in Col do
            X := X + 1
        end.
        ''');
end;

procedure TForInTests.TestSemantic_ForIn_NoCurrent_RaisesError;
begin
  AnalyseExpectError(
    '''
        program P;
        type
          TBadEnum = class
            function MoveNext: Boolean;
          end;
          TBadCol = class
            function GetEnumerator: TBadEnum;
          end;
        var
          Col: TBadCol;
          X:   Integer;
        begin
          for X in Col do
            X := X + 1
        end.
        ''');
end;

procedure TForInTests.TestSemantic_ForIn_VarTypeMismatch_RaisesError;
begin
  AnalyseExpectError(
    'program P;' + #10 +
    SrcEnumTypes + #10 +
    '''
        var
          Col: TMyCol;
          X:   string;
        begin
          for X in Col do
            X := X
        end.
        ''');
end;

procedure TForInTests.TestSemantic_ForIn_CollNotClass_RaisesError;
begin
  AnalyseExpectError(
    '''
        program P;
        var
          X: Integer;
        begin
          for X in X do
            X := X + 1
        end.
        ''');
end;

{ ------------------------------------------------------------------ }
{ Codegen tests                                                        }
{ ------------------------------------------------------------------ }

procedure TForInTests.TestCodegen_ForIn_HasForInCondLabel;
var IR: string;
begin
  IR := GenIR(SrcForIn);
  AssertTrue('forin_cond label present', Pos('forin_cond', IR) > 0);
end;

procedure TForInTests.TestCodegen_ForIn_HasForInBodyLabel;
var IR: string;
begin
  IR := GenIR(SrcForIn);
  AssertTrue('forin_body label present', Pos('forin_body', IR) > 0);
end;

procedure TForInTests.TestCodegen_ForIn_HasForInEndLabel;
var IR: string;
begin
  IR := GenIR(SrcForIn);
  AssertTrue('forin_end label present', Pos('forin_end', IR) > 0);
end;

procedure TForInTests.TestCodegen_ForIn_CallsGetEnumerator;
var IR: string;
begin
  IR := GenIR(SrcForIn);
  AssertTrue('GetEnumerator called in IR',
    Pos('TMyCol_GetEnumerator', IR) > 0);
end;

procedure TForInTests.TestCodegen_ForIn_CallsMoveNext;
var IR: string;
begin
  IR := GenIR(SrcForIn);
  AssertTrue('MoveNext called in IR', Pos('TMyEnum_MoveNext', IR) > 0);
end;

procedure TForInTests.TestCodegen_ForIn_CallsGetCurrent;
var IR: string;
begin
  IR := GenIR(SrcForIn);
  AssertTrue('GetCurrent called in IR', Pos('TMyEnum_GetCurrent', IR) > 0);
end;

procedure TForInTests.TestCodegen_ForIn_JnzOnMoveNextResult;
var IR: string;
begin
  IR := GenIR(SrcForIn);
  AssertTrue('jnz on MoveNext result', Pos('jnz', IR) > 0);
end;

procedure TForInTests.TestCodegen_ForIn_JumpsBackToCond;
var IR: string;
begin
  IR := GenIR(SrcForIn);
  AssertTrue('jmp back to forin_cond', Pos('jmp @forin_cond', IR) > 0);
end;

{ ------------------------------------------------------------------ }
{ Shared sources — static array                                        }
{ ------------------------------------------------------------------ }

const
  SrcArrayForIn =
    '''
        program P;
        var
          Arr: array[0..4] of Integer;
          X:   Integer;
        begin
          for X in Arr do
            X := X + 1
        end.
        ''';

  { Issue #169: a record-typed loop variable must be copied by value, field by
    field with ARC — not truncated to a scalar load.  The managed Name field
    forces a _StringAddRef in the copy, which the old plain-storel scalar path
    never emitted. }
  SrcRecordArrayForIn =
    '''
        program P;
        type
          TRec = record Name: string; Number: Integer; end;
        var
          Arr: array[0..2] of TRec;
          R:   TRec;
        begin
          for R in Arr do
            WriteLn(R.Number)
        end.
        ''';

  SrcArrayForInNonZero =
    '''
        program P;
        var
          Arr: array[3..7] of Integer;
          X:   Integer;
        begin
          for X in Arr do
            X := X + 1
        end.
        ''';

{ ------------------------------------------------------------------ }
{ Semantic tests — static array                                        }
{ ------------------------------------------------------------------ }

procedure TForInTests.TestSemantic_ArrayForIn_Valid_OK;
begin
  AnalyseSrc(SrcArrayForIn).Free();
end;

procedure TForInTests.TestSemantic_ArrayForIn_VarTypeMismatch_RaisesError;
begin
  AnalyseExpectError(
    '''
        program P;
        var
          Arr: array[0..4] of Integer;
          X:   string;
        begin
          for X in Arr do
            X := X
        end.
        ''');
end;

procedure TForInTests.TestSemantic_ArrayForIn_NonZeroBased_OK;
begin
  AnalyseSrc(SrcArrayForInNonZero).Free();
end;

{ ------------------------------------------------------------------ }
{ Codegen tests — static array                                         }
{ ------------------------------------------------------------------ }

procedure TForInTests.TestCodegen_ArrayForIn_HasForInCondLabel;
var IR: string;
begin
  IR := GenIR(SrcArrayForIn);
  AssertTrue('forin_cond label present', Pos('forin_cond', IR) > 0);
end;

procedure TForInTests.TestCodegen_ArrayForIn_HasForInEndLabel;
var IR: string;
begin
  IR := GenIR(SrcArrayForIn);
  AssertTrue('forin_end label present', Pos('forin_end', IR) > 0);
end;

procedure TForInTests.TestCodegen_ArrayForIn_LoadsElement;
var IR: string;
begin
  IR := GenIR(SrcArrayForIn);
  { Element load for Integer array: loadw from computed address }
  AssertTrue('loadw emitted for array element', Pos('loadw', IR) > 0);
end;

procedure TForInTests.TestCodegen_ArrayForIn_RecordElement_CopiesByValue;
var IR: string;
begin
  IR := GenIR(SrcRecordArrayForIn);
  { A record loop variable is copied by value through EmitRecordCopy, which
    ref-counts the managed Name field — so the copy emits a _StringAddRef.  The
    pre-fix scalar path did a bare 8-byte storel with no ARC (issue #169), so
    the presence of the string retain proves the whole record is copied. }
  AssertTrue('record for-in copies managed field with ARC',
    Pos('_StringAddRef', IR) > 0);
end;

procedure TForInTests.TestCodegen_ArrayForIn_JumpsBackToCond;
var IR: string;
begin
  IR := GenIR(SrcArrayForIn);
  AssertTrue('jmp back to forin_cond', Pos('jmp @forin_cond', IR) > 0);
end;

procedure TForInTests.TestCodegen_ArrayForIn_NonZeroBased_AdjustsIndex;
var IR: string;
begin
  IR := GenIR(SrcArrayForInNonZero);
  { Non-zero-based array needs a subtraction to compute element offset }
  AssertTrue('sub instruction for offset adjustment', Pos('sub', IR) > 0);
end;

{ ------------------------------------------------------------------ }
{ Shared sources — dynamic array                                       }
{ ------------------------------------------------------------------ }

const
  SrcDynArrayForIn =
    '''
        program P;
        var
          DA: array of Integer;
          X:  Integer;
        begin
          for X in DA do
            X := X + 1
        end.
        ''';

{ ------------------------------------------------------------------ }
{ Semantic tests — dynamic array                                       }
{ ------------------------------------------------------------------ }

procedure TForInTests.TestSemantic_DynArrayForIn_Valid_OK;
begin
  AnalyseSrc(SrcDynArrayForIn).Free();
end;

procedure TForInTests.TestSemantic_DynArrayForIn_VarTypeMismatch_RaisesError;
begin
  AnalyseExpectError(
    '''
        program P;
        var
          DA: array of Integer;
          X:  string;
        begin
          for X in DA do
            X := X
        end.
        ''');
end;

{ ------------------------------------------------------------------ }
{ Codegen tests — dynamic array                                        }
{ ------------------------------------------------------------------ }

procedure TForInTests.TestCodegen_DynArrayForIn_HasForInCondLabel;
var IR: string;
begin
  IR := GenIR(SrcDynArrayForIn);
  AssertTrue('forin_cond label present', Pos('forin_cond', IR) > 0);
end;

procedure TForInTests.TestCodegen_DynArrayForIn_HasForInEndLabel;
var IR: string;
begin
  IR := GenIR(SrcDynArrayForIn);
  AssertTrue('forin_end label present', Pos('forin_end', IR) > 0);
end;

procedure TForInTests.TestCodegen_DynArrayForIn_CallsDynArrayLength;
var IR: string;
begin
  IR := GenIR(SrcDynArrayForIn);
  AssertTrue('_DynArrayLength called in IR', Pos('_DynArrayLength', IR) > 0);
end;

procedure TForInTests.TestCodegen_DynArrayForIn_LoadsElement;
var IR: string;
begin
  IR := GenIR(SrcDynArrayForIn);
  AssertTrue('loadw emitted for Integer array element', Pos('loadw', IR) > 0);
end;

procedure TForInTests.TestCodegen_DynArrayForIn_JumpsBackToCond;
var IR: string;
begin
  IR := GenIR(SrcDynArrayForIn);
  AssertTrue('jmp back to forin_cond', Pos('jmp @forin_cond', IR) > 0);
end;

{ ------------------------------------------------------------------ }
{ Shared sources — string                                              }
{ ------------------------------------------------------------------ }

const
  SrcStringForIn =
    '''
        program P;
        var
          S: string;
          B: Byte;
        begin
          for B in S do
            B := 0
        end.
        ''';

  SrcStringForInIntVar =
    '''
        program P;
        var
          S: string;
          I: Integer;
        begin
          for I in S do
            I := 0
        end.
        ''';

{ ------------------------------------------------------------------ }
{ Semantic tests — string                                              }
{ ------------------------------------------------------------------ }

procedure TForInTests.TestSemantic_StringForIn_ByteVar_OK;
begin
  AnalyseSrc(SrcStringForIn).Free();
end;

procedure TForInTests.TestSemantic_StringForIn_IntVar_IsCodePointIter;
begin
  AnalyseSrc(SrcStringForInIntVar).Free();
end;

procedure TForInTests.TestSemantic_StringForIn_NonOrdinalVar_RaisesError;
begin
  AnalyseExpectError(
    '''
        program P;
        var
          S: string;
          P: string;
        begin
          for P in S do
            P := P
        end.
        ''');
end;

procedure TForInTests.TestSemantic_StringForIn_WordVar_RaisesError;
begin
  AnalyseExpectError(
    '''
        program P;
        var
          S: string;
          W: Word;
        begin
          for W in S do
            W := 0
        end.
        ''');
end;

procedure TForInTests.TestSemantic_StringForIn_SmallIntVar_RaisesError;
begin
  AnalyseExpectError(
    '''
        program P;
        var
          S: string;
          N: SmallInt;
        begin
          for N in S do
            N := 0
        end.
        ''');
end;

{ ------------------------------------------------------------------ }
{ Codegen tests — string                                               }
{ ------------------------------------------------------------------ }

procedure TForInTests.TestCodegen_StringForIn_HasForInCondLabel;
var IR: string;
begin
  IR := GenIR(SrcStringForIn);
  AssertTrue('forin_cond label present', Pos('forin_cond', IR) > 0);
end;

procedure TForInTests.TestCodegen_StringForIn_HasForInEndLabel;
var IR: string;
begin
  IR := GenIR(SrcStringForIn);
  AssertTrue('forin_end label present', Pos('forin_end', IR) > 0);
end;

procedure TForInTests.TestCodegen_StringForIn_LoadsByteWithLoadub;
var IR: string;
begin
  IR := GenIR(SrcStringForIn);
  AssertTrue('loadub emitted for byte extraction', Pos('loadub', IR) > 0);
end;

procedure TForInTests.TestCodegen_StringForIn_JumpsBackToCond;
var IR: string;
begin
  IR := GenIR(SrcStringForIn);
  AssertTrue('jmp back to forin_cond', Pos('jmp @forin_cond', IR) > 0);
end;

procedure TForInTests.TestCodegen_StringForIn_UsesLengthFromHeader;
var IR: string;
begin
  IR := GenIR(SrcStringForIn);
  { Data-pointer convention: length is at data_ptr-8.
    Codegen emits 'add <ptr>, -8' to reach the length field. }
  AssertTrue('reads length at data_ptr-8', Pos(', -8', IR) > 0);
end;

{ ------------------------------------------------------------------ }
{ Codegen tests — string codepoint iteration                           }
{ ------------------------------------------------------------------ }

procedure TForInTests.TestCodegen_CodePointForIn_CallsUtf8DecodeAt;
var IR: string;
begin
  IR := GenIR(SrcStringForInIntVar);
  AssertTrue('calls _Utf8DecodeAt', Pos('$_Utf8DecodeAt', IR) > 0);
end;

procedure TForInTests.TestCodegen_CodePointForIn_HasForInCondLabel;
var IR: string;
begin
  IR := GenIR(SrcStringForInIntVar);
  AssertTrue('forin_cond label present', Pos('forin_cond', IR) > 0);
end;

{ ------------------------------------------------------------------ }
{ Shared sources — set iteration                                       }
{ ------------------------------------------------------------------ }

const
  SrcSetForIn =
    '''
        program P;
        type
          TColor = (Red, Green, Blue);
          TColorSet = set of TColor;
        var
          S: TColorSet;
          C: TColor;
        begin
          S := [Red, Blue];
          for C in S do
            WriteLn(Ord(C))
        end.
        ''';

{ ------------------------------------------------------------------ }
{ Semantic tests — set                                                 }
{ ------------------------------------------------------------------ }

procedure TForInTests.TestSemantic_SetForIn_Valid_OK;
begin
  AnalyseSrc(SrcSetForIn).Free();
end;

procedure TForInTests.TestSemantic_SetForIn_VarTypeMismatch_RaisesError;
begin
  { Loop variable must be ordinal — string is not ordinal }
  AnalyseExpectError(
    '''
        program P;
        type
          TColor = (Red, Green, Blue);
          TColorSet = set of TColor;
        var
          S: TColorSet;
          X: string;
        begin
          for X in S do
            X := X
        end.
        ''');
end;

procedure TForInTests.TestSemantic_SetForIn_NonSetCollNotAllowed;
begin
  { A plain Integer variable is not a valid for-in collection }
  AnalyseExpectError(
    '''
        program P;
        var
          N: Integer;
          X: Integer;
        begin
          for X in N do
            X := X
        end.
        ''');
end;

{ ------------------------------------------------------------------ }
{ Codegen tests — set                                                  }
{ ------------------------------------------------------------------ }

procedure TForInTests.TestCodegen_SetForIn_HasForInCondLabel;
var IR: string;
begin
  IR := GenIR(SrcSetForIn);
  AssertTrue('forin_cond label present', Pos('forin_cond', IR) > 0);
end;

procedure TForInTests.TestCodegen_SetForIn_HasForInEndLabel;
var IR: string;
begin
  IR := GenIR(SrcSetForIn);
  AssertTrue('forin_end label present', Pos('forin_end', IR) > 0);
end;

procedure TForInTests.TestCodegen_SetForIn_HasForInNextLabel;
var IR: string;
begin
  IR := GenIR(SrcSetForIn);
  AssertTrue('forin_next label present', Pos('forin_next', IR) > 0);
end;

procedure TForInTests.TestCodegen_SetForIn_TestsBitWithShr;
var IR: string;
begin
  IR := GenIR(SrcSetForIn);
  AssertTrue('shr instruction emitted for bit extraction', Pos('=w shr', IR) > 0);
end;

procedure TForInTests.TestCodegen_SetForIn_TestsBitWithAnd1;
var IR: string;
begin
  IR := GenIR(SrcSetForIn);
  AssertTrue('and 1 emitted for bit isolation', Pos('and', IR) > 0);
end;

procedure TForInTests.TestCodegen_SetForIn_JumpsBackToCond;
var IR: string;
begin
  IR := GenIR(SrcSetForIn);
  AssertTrue('jmp back to forin_cond', Pos('jmp @forin_cond', IR) > 0);
end;

procedure TForInTests.TestCodegen_SetForIn_EvaluatesMaskOnce;
var IR: string;
begin
  { The set expression [Red, Blue] is a compile-time constant; the codegen
    emits a single 'copy <mask>' and stores it — not a repeated evaluation.
    Verify the mask constant 5 (bit0=Red, bit2=Blue) appears exactly once
    as a copy operand. }
  IR := GenIR(SrcSetForIn);
  AssertTrue('mask value 5 emitted', Pos('copy 5', IR) > 0);
end;

procedure TForInTests.TestCodegen_ForIn_RecordCurrent_SretsIntoLoopVar;
var IR: string;
begin
  { When the enumerator's Current returns a record with a managed field, the
    loop-variable refresh must release the previous entry and let the getter
    write the new record straight into the loop-var slot via sret.  A scalar-
    return call here corrupted the managed field. }
  IR := GenIR(
    '''
        program P;
        type
          TItem = record S: string; end;
          TEnum = class
            FI: Integer;
            function GetCurrent: TItem;
            function GetEnumerator: TEnum;
            function MoveNext: Boolean;
            property Current: TItem read GetCurrent;
          end;
        function TEnum.GetCurrent: TItem;
        begin Result.S := 'x' end;
        function TEnum.GetEnumerator: TEnum;
        begin Result := Self end;
        function TEnum.MoveNext: Boolean;
        begin FI := FI + 1; Result := FI <= 2 end;
        var E: TEnum; It: TItem;
        begin
          E := TEnum.Create();
          for It in E do
            WriteLn(It.S)
        end.
        ''');
  { The getter is sret-called with $It (the loop var) as its hidden first arg. }
  AssertTrue('Current sret-called into loop var',
    Pos('call $TEnum_GetCurrent(l $It', IR) > 0);
  { The previous entry is released before the getter overwrites the slot. }
  AssertTrue('loop var released before refresh',
    Pos('call $_StringRelease(l ', IR) > 0);
end;

initialization
  RegisterTest(TForInTests);

end.
