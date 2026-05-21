{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit cp.test.records;

interface

uses
  blaise.testing,
  uLexer, uParser, uAST, uSymbolTable, uSemantic, uCodeGenQBE;

type
  TRecordTests = class(TTestCase)
  private
    function ParseSrc(const ASrc: string): TProgram;
    function AnalyseSrc(const ASrc: string): TProgram;
    function GenIR(const ASrc: string): string;
    procedure AnalyseExpectError(const ASrc: string);
  published
    { ------------------------------------------------------------------ }
    { Lexer — new keywords                                                }
    { ------------------------------------------------------------------ }
    procedure TestLexer_Type_Keyword;
    procedure TestLexer_Record_Keyword;

    { ------------------------------------------------------------------ }
    { Parser — type section and record body                               }
    { ------------------------------------------------------------------ }
    procedure TestParse_TypeSection_Exists;
    procedure TestParse_RecordType_Name;
    procedure TestParse_RecordType_SingleField;
    procedure TestParse_RecordType_MultipleFields;
    procedure TestParse_RecordType_MultiNameField;
    procedure TestParse_VarOfRecordType;
    procedure TestParse_FieldAssignment;
    procedure TestParse_FieldAccessInExpr;

    { ------------------------------------------------------------------ }
    { Semantic — record type resolution                                   }
    { ------------------------------------------------------------------ }
    procedure TestSemantic_RecordType_Registered;
    procedure TestSemantic_RecordType_FieldsResolved;
    procedure TestSemantic_RecordVar_HasRecordType;
    procedure TestSemantic_FieldAssign_OK;
    procedure TestSemantic_FieldAssign_TypeMismatch_RaisesError;
    procedure TestSemantic_FieldAccess_TypeIsFieldType;
    procedure TestSemantic_FieldAccess_UnknownField_RaisesError;
    procedure TestSemantic_FieldAccess_OnNonRecord_RaisesError;

    { ------------------------------------------------------------------ }
    { Code generation                                                     }
    { ------------------------------------------------------------------ }
    procedure TestCodegen_RecordVar_HasAlloc;
    procedure TestCodegen_FieldStore_EmitsOffset;
    procedure TestCodegen_FieldLoad_EmitsOffset;
    procedure TestCodegen_TwoIntFields_CorrectSize;
    procedure TestCodegen_StringField_CorrectSize;
  end;

implementation

{ ------------------------------------------------------------------ }
{ Helpers                                                             }
{ ------------------------------------------------------------------ }

function TRecordTests.ParseSrc(const ASrc: string): TProgram;
var
  L: TLexer;
  P: TParser;
begin
  L := TLexer.Create(ASrc);
  P := TParser.Create(L);
  try
    Result := P.Parse;
  finally
    P.Free;
    L.Free;
  end;
end;

function TRecordTests.AnalyseSrc(const ASrc: string): TProgram;
var
  A: TSemanticAnalyser;
begin
  Result := ParseSrc(ASrc);
  A := TSemanticAnalyser.Create;
  try
    A.Analyse(Result);
  finally
    A.Free;
  end;
end;

function TRecordTests.GenIR(const ASrc: string): string;
var
  Prog: TProgram;
  CG:   TCodeGenQBE;
begin
  Prog := AnalyseSrc(ASrc);
  try
    CG := TCodeGenQBE.Create;
    try
      CG.Generate(Prog);
      Result := CG.GetOutput;
    finally
      CG.Free;
    end;
  finally
    Prog.Free;
  end;
end;

procedure TRecordTests.AnalyseExpectError(const ASrc: string);
var
  Prog: TProgram;
begin
  try
    Prog := AnalyseSrc(ASrc);
    Prog.Free;
    Fail('Expected ESemanticError');
  except
    on E: ESemanticError do ; { expected }
  end;
end;

{ ------------------------------------------------------------------ }
{ Lexer                                                               }
{ ------------------------------------------------------------------ }

procedure TRecordTests.TestLexer_Type_Keyword;
var
  L: TLexer;
  T: TToken;
begin
  L := TLexer.Create('type');
  try
    T := L.Next;
    AssertEquals('type token', Ord(tkType), Ord(T.Kind));
  finally
    L.Free;
  end;
end;

procedure TRecordTests.TestLexer_Record_Keyword;
var
  L: TLexer;
  T: TToken;
begin
  L := TLexer.Create('record');
  try
    T := L.Next;
    AssertEquals('record token', Ord(tkRecord), Ord(T.Kind));
  finally
    L.Free;
  end;
end;

{ ------------------------------------------------------------------ }
{ Parser                                                              }
{ ------------------------------------------------------------------ }

procedure TRecordTests.TestParse_TypeSection_Exists;
var
  Prog: TProgram;
begin
  Prog := ParseSrc(
    '''
        program P;
        type
          TPoint = record
            X: Integer;
          end;
        begin end.
        ''');
  try
    AssertEquals('1 type decl', 1, Prog.Block.TypeDecls.Count);
  finally
    Prog.Free;
  end;
end;

procedure TRecordTests.TestParse_RecordType_Name;
var
  Prog: TProgram;
  TD:   TTypeDecl;
begin
  Prog := ParseSrc(
    '''
        program P;
        type
          TPoint = record
            X: Integer;
          end;
        begin end.
        ''');
  try
    TD := TTypeDecl(Prog.Block.TypeDecls.Items[0]);
    AssertEquals('Type name', 'TPoint', TD.Name);
    AssertTrue('Is TRecordTypeDef', TD.Def is TRecordTypeDef);
  finally
    Prog.Free;
  end;
end;

procedure TRecordTests.TestParse_RecordType_SingleField;
var
  Prog: TProgram;
  Rec:  TRecordTypeDef;
  Fld:  TFieldDecl;
begin
  Prog := ParseSrc(
    '''
        program P;
        type
          TPoint = record
            X: Integer;
          end;
        begin end.
        ''');
  try
    Rec := TRecordTypeDef(TTypeDecl(Prog.Block.TypeDecls.Items[0]).Def);
    AssertEquals('1 field', 1, Rec.Fields.Count);
    Fld := TFieldDecl(Rec.Fields.Items[0]);
    AssertEquals('Field name', 'X', Fld.Names.Strings[0]);
    AssertEquals('Field type', 'Integer', Fld.TypeName);
  finally
    Prog.Free;
  end;
end;

procedure TRecordTests.TestParse_RecordType_MultipleFields;
var
  Prog: TProgram;
  Rec:  TRecordTypeDef;
begin
  Prog := ParseSrc(
    '''
        program P;
        type
          TPoint = record
            X: Integer;
            Y: Integer;
          end;
        begin end.
        ''');
  try
    Rec := TRecordTypeDef(TTypeDecl(Prog.Block.TypeDecls.Items[0]).Def);
    AssertEquals('2 fields', 2, Rec.Fields.Count);
    AssertEquals('First field', 'X', TFieldDecl(Rec.Fields.Items[0]).Names.Strings[0]);
    AssertEquals('Second field', 'Y', TFieldDecl(Rec.Fields.Items[1]).Names.Strings[0]);
  finally
    Prog.Free;
  end;
end;

procedure TRecordTests.TestParse_RecordType_MultiNameField;
var
  Prog: TProgram;
  Rec:  TRecordTypeDef;
  Fld:  TFieldDecl;
begin
  Prog := ParseSrc(
    '''
        program P;
        type
          TPoint = record
            X, Y: Integer;
          end;
        begin end.
        ''');
  try
    Rec := TRecordTypeDef(TTypeDecl(Prog.Block.TypeDecls.Items[0]).Def);
    AssertEquals('1 field group', 1, Rec.Fields.Count);
    Fld := TFieldDecl(Rec.Fields.Items[0]);
    AssertEquals('2 names', 2, Fld.Names.Count);
    AssertEquals('First',  'X', Fld.Names.Strings[0]);
    AssertEquals('Second', 'Y', Fld.Names.Strings[1]);
  finally
    Prog.Free;
  end;
end;

procedure TRecordTests.TestParse_VarOfRecordType;
var
  Prog: TProgram;
  Decl: TVarDecl;
begin
  Prog := ParseSrc(
    '''
        program P;
        type
          TPoint = record
            X: Integer;
          end;
        var P: TPoint;
        begin end.
        ''');
  try
    AssertEquals('1 var', 1, Prog.Block.Decls.Count);
    Decl := TVarDecl(Prog.Block.Decls.Items[0]);
    AssertEquals('Var name', 'P', Decl.Names.Strings[0]);
    AssertEquals('Var type', 'TPoint', Decl.TypeName);
  finally
    Prog.Free;
  end;
end;

procedure TRecordTests.TestParse_FieldAssignment;
var
  Prog: TProgram;
  Stmt: TFieldAssignment;
begin
  Prog := ParseSrc(
    '''
        program P;
        type
          TPoint = record
            X: Integer;
          end;
        var Pt: TPoint;
        begin
          Pt.X := 10
        end.
        ''');
  try
    AssertEquals('1 stmt', 1, Prog.Block.Stmts.Count);
    AssertTrue('Is TFieldAssignment',
      Prog.Block.Stmts.Items[0] is TFieldAssignment);
    Stmt := TFieldAssignment(Prog.Block.Stmts.Items[0]);
    AssertEquals('Record var', 'Pt',  Stmt.RecordName);
    AssertEquals('Field name', 'X',   Stmt.FieldName);
    AssertTrue('Expr is TIntLiteral', Stmt.Expr is TIntLiteral);
  finally
    Prog.Free;
  end;
end;

procedure TRecordTests.TestParse_FieldAccessInExpr;
var
  Prog: TProgram;
  Bin:  TBinaryExpr;
begin
  Prog := ParseSrc(
    '''
        program P;
        type
          TPoint = record
            X: Integer;
          end;
        var Pt: TPoint; N: Integer;
        begin
          N := Pt.X + 1
        end.
        ''');
  try
    Bin := TBinaryExpr(TAssignment(Prog.Block.Stmts.Items[0]).Expr);
    AssertTrue('Left is TFieldAccessExpr', Bin.Left is TFieldAccessExpr);
    AssertEquals('Record', 'Pt', TFieldAccessExpr(Bin.Left).RecordName);
    AssertEquals('Field',  'X',  TFieldAccessExpr(Bin.Left).FieldName);
  finally
    Prog.Free;
  end;
end;

{ ------------------------------------------------------------------ }
{ Semantic                                                            }
{ ------------------------------------------------------------------ }

procedure TRecordTests.TestSemantic_RecordType_Registered;
var
  Prog: TProgram;
begin
  Prog := AnalyseSrc(
    '''
        program P;
        type
          TPoint = record
            X: Integer;
          end;
        begin end.
        ''');
  try
    AssertNotNull('TPoint in symbol table',
      Prog.SymbolTable.FindType('TPoint'));
    AssertEquals('TPoint is tyRecord',
      Ord(tyRecord),
      Ord(Prog.SymbolTable.FindType('TPoint').Kind));
  finally
    Prog.Free;
  end;
end;

procedure TRecordTests.TestSemantic_RecordType_FieldsResolved;
var
  Prog: TProgram;
  RT:   TRecordTypeDesc;
begin
  Prog := AnalyseSrc(
    '''
        program P;
        type
          TPoint = record
            X: Integer;
            Y: Integer;
          end;
        begin end.
        ''');
  try
    RT := TRecordTypeDesc(Prog.SymbolTable.FindType('TPoint'));
    AssertEquals('2 fields', 2, RT.Fields.Count);
    AssertEquals('X type',
      Ord(tyInteger), Ord(TFieldInfo(RT.Fields.Items[0]).TypeDesc.Kind));
    AssertEquals('Y type',
      Ord(tyInteger), Ord(TFieldInfo(RT.Fields.Items[1]).TypeDesc.Kind));
  finally
    Prog.Free;
  end;
end;

procedure TRecordTests.TestSemantic_RecordVar_HasRecordType;
var
  Prog: TProgram;
begin
  Prog := AnalyseSrc(
    '''
        program P;
        type
          TPoint = record
            X: Integer;
          end;
        var Pt: TPoint;
        begin end.
        ''');
  try
    AssertEquals('Var is tyRecord',
      Ord(tyRecord),
      Ord(TVarDecl(Prog.Block.Decls.Items[0]).ResolvedType.Kind));
  finally
    Prog.Free;
  end;
end;

procedure TRecordTests.TestSemantic_FieldAssign_OK;
begin
  AnalyseSrc(
    '''
        program P;
        type
          TPoint = record
            X: Integer;
          end;
        var Pt: TPoint;
        begin
          Pt.X := 42
        end.
        '''
  ).Free;
end;

procedure TRecordTests.TestSemantic_FieldAssign_TypeMismatch_RaisesError;
begin
  AnalyseExpectError(
    '''
        program P;
        type
          TPoint = record
            X: Integer;
          end;
        var Pt: TPoint;
        begin
          Pt.X := 'hello'
        end.
        ''');
end;

procedure TRecordTests.TestSemantic_FieldAccess_TypeIsFieldType;
var
  Prog:   TProgram;
  Access: TFieldAccessExpr;
begin
  Prog := AnalyseSrc(
    '''
        program P;
        type
          TPoint = record
            X: Integer;
          end;
        var Pt: TPoint; N: Integer;
        begin
          N := Pt.X
        end.
        ''');
  try
    Access := TFieldAccessExpr(TAssignment(Prog.Block.Stmts.Items[0]).Expr);
    AssertEquals('Field access type',
      Ord(tyInteger), Ord(Access.ResolvedType.Kind));
  finally
    Prog.Free;
  end;
end;

procedure TRecordTests.TestSemantic_FieldAccess_UnknownField_RaisesError;
begin
  AnalyseExpectError(
    '''
        program P;
        type
          TPoint = record
            X: Integer;
          end;
        var Pt: TPoint; N: Integer;
        begin
          N := Pt.Z
        end.
        ''');
end;

procedure TRecordTests.TestSemantic_FieldAccess_OnNonRecord_RaisesError;
begin
  AnalyseExpectError(
    '''
        program P;
        var N: Integer;
        begin
          N := N.X
        end.
        ''');
end;

{ ------------------------------------------------------------------ }
{ Code generation                                                     }
{ ------------------------------------------------------------------ }

procedure TRecordTests.TestCodegen_RecordVar_HasAlloc;
var
  IR: string;
begin
  IR := GenIR(
    '''
        program P;
        type
          TPoint = record
            X: Integer;
          end;
        var Pt: TPoint;
        begin end.
        ''');
  { Program-level record var Pt is a data-section global }
  AssertTrue('data decl for Pt', Pos('$Pt', IR) > 0);
end;

procedure TRecordTests.TestCodegen_FieldStore_EmitsOffset;
var
  IR: string;
begin
  IR := GenIR(
    '''
        program P;
        type
          TPoint = record
            X: Integer;
          end;
        var Pt: TPoint;
        begin
          Pt.X := 10
        end.
        ''');
  AssertTrue('storew in IR', Pos('storew', IR) > 0);
end;

procedure TRecordTests.TestCodegen_FieldLoad_EmitsOffset;
var
  IR: string;
begin
  IR := GenIR(
    '''
        program P;
        type
          TPoint = record
            X: Integer;
          end;
        var Pt: TPoint; N: Integer;
        begin
          N := Pt.X
        end.
        ''');
  AssertTrue('loadw in IR', Pos('loadw', IR) > 0);
end;

procedure TRecordTests.TestCodegen_TwoIntFields_CorrectSize;
var
  IR: string;
begin
  IR := GenIR(
    '''
        program P;
        type
          TRect = record
            L: Integer;
            T: Integer;
          end;
        var R: TRect;
        begin end.
        ''');
  { Two Integer fields = 8 bytes total; program-level record uses data section }
  AssertTrue('8-byte record in data section', Pos('z 8', IR) > 0);
end;

procedure TRecordTests.TestCodegen_StringField_CorrectSize;
var
  IR: string;
begin
  IR := GenIR(
    '''
        program P;
        type
          TPerson = record
            Name: string;
          end;
        var Person: TPerson;
        begin end.
        ''');
  { One string field = 8 bytes; program-level record uses data section }
  AssertTrue('8-byte record in data section', Pos('z 8', IR) > 0);
end;

initialization
  RegisterTest(TRecordTests);

end.
