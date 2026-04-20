unit cp.test.control;

{$mode objfpc}{$H+}

{ Tests for control flow: if/else, comparison operators, compound statements.
  Future: while, repeat, for. }

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  uLexer, uParser, uAST, uSymbolTable, uSemantic, uCodeGenQBE;

type
  TControlTests = class(TTestCase)
  private
    function ParseSrc(const ASrc: string): TProgram;
    function AnalyseSrc(const ASrc: string): TProgram;
    function GenIR(const ASrc: string): string;
    procedure AnalyseExpectError(const ASrc: string);
  published
    { ------------------------------------------------------------------ }
    { Lexer                                                                }
    { ------------------------------------------------------------------ }
    procedure TestLexer_If_Keyword;
    procedure TestLexer_Then_Keyword;
    procedure TestLexer_Else_Keyword;
    procedure TestLexer_Equals_CompareOp;
    procedure TestLexer_NotEquals;
    procedure TestLexer_LessThan;
    procedure TestLexer_GreaterThan;
    procedure TestLexer_LessEqual;
    procedure TestLexer_GreaterEqual;

    { ------------------------------------------------------------------ }
    { Parser                                                               }
    { ------------------------------------------------------------------ }
    procedure TestParse_If_IsIfStmt;
    procedure TestParse_If_HasCondition;
    procedure TestParse_If_ConditionIsBinaryExpr;
    procedure TestParse_If_NoElse;
    procedure TestParse_IfElse_HasElseStmt;
    procedure TestParse_If_ThenIsAssignment;
    procedure TestParse_IfElse_ElseIsAssignment;
    procedure TestParse_Compound_IsCompoundStmt;
    procedure TestParse_Compound_StmtCount;
    procedure TestParse_If_ThenIsCompound;
    procedure TestParse_IfElse_ElseIsCompound;

    { ------------------------------------------------------------------ }
    { Semantic                                                             }
    { ------------------------------------------------------------------ }
    procedure TestSemantic_If_Resolves;
    procedure TestSemantic_IfElse_Resolves;
    procedure TestSemantic_Comparison_EQ_TypeIsBoolean;
    procedure TestSemantic_Comparison_NE_TypeIsBoolean;
    procedure TestSemantic_Comparison_LT_TypeIsBoolean;
    procedure TestSemantic_Comparison_GT_TypeIsBoolean;
    procedure TestSemantic_Comparison_LE_TypeIsBoolean;
    procedure TestSemantic_Comparison_GE_TypeIsBoolean;
    procedure TestSemantic_Comparison_TypeMismatch_RaisesError;
    procedure TestSemantic_If_NonBooleanCondition_RaisesError;

    { ------------------------------------------------------------------ }
    { Code generation                                                      }
    { ------------------------------------------------------------------ }
    procedure TestCodegen_If_EmitsJnz;
    procedure TestCodegen_If_EmitsThenLabel;
    procedure TestCodegen_If_EmitsEndLabel;
    procedure TestCodegen_IfElse_EmitsElseLabel;
    procedure TestCodegen_IfElse_ThenJumpsToEnd;
    procedure TestCodegen_Comparison_EQ_UsescEqw;
    procedure TestCodegen_Comparison_LT_UsescLtw;
    procedure TestCodegen_Comparison_GT_UsescGtw;
    procedure TestCodegen_Comparison_NE_UsescNew;
    procedure TestCodegen_Compound_EmitsAllStmts;
  end;

implementation

{ ------------------------------------------------------------------ }
{ Helpers                                                             }
{ ------------------------------------------------------------------ }

function TControlTests.ParseSrc(const ASrc: string): TProgram;
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

function TControlTests.AnalyseSrc(const ASrc: string): TProgram;
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

function TControlTests.GenIR(const ASrc: string): string;
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

procedure TControlTests.AnalyseExpectError(const ASrc: string);
var
  Prog: TProgram;
begin
  try
    Prog := AnalyseSrc(ASrc);
    Prog.Free;
    Fail('Expected ESemanticError');
  except
    on E: ESemanticError do ;
  end;
end;

{ ------------------------------------------------------------------ }
{ Shared source snippets                                               }
{ ------------------------------------------------------------------ }

const
  SrcIfOnly =
    'program P;'              + LineEnding +
    'var N: Integer;'         + LineEnding +
    'begin'                   + LineEnding +
    '  N := 5;'               + LineEnding +
    '  if N = 5 then'         + LineEnding +
    '    N := 1'              + LineEnding +
    'end.';

  SrcIfElse =
    'program P;'              + LineEnding +
    'var N: Integer;'         + LineEnding +
    'begin'                   + LineEnding +
    '  N := 3;'               + LineEnding +
    '  if N > 0 then'         + LineEnding +
    '    N := 1'              + LineEnding +
    '  else'                  + LineEnding +
    '    N := 0'              + LineEnding +
    'end.';

  SrcCompound =
    'program P;'              + LineEnding +
    'var N: Integer;'         + LineEnding +
    'begin'                   + LineEnding +
    '  N := 10;'              + LineEnding +
    '  if N > 5 then'         + LineEnding +
    '  begin'                 + LineEnding +
    '    WriteLn(N);'         + LineEnding +
    '    N := 0'              + LineEnding +
    '  end'                   + LineEnding +
    '  else'                  + LineEnding +
    '  begin'                 + LineEnding +
    '    N := 1'              + LineEnding +
    '  end'                   + LineEnding +
    'end.';

{ ------------------------------------------------------------------ }
{ Lexer tests                                                         }
{ ------------------------------------------------------------------ }

procedure TControlTests.TestLexer_If_Keyword;
var L: TLexer; T: TToken;
begin
  L := TLexer.Create('if');
  try
    T := L.Next;
    AssertEquals('if token', Ord(tkIf), Ord(T.Kind));
  finally L.Free; end;
end;

procedure TControlTests.TestLexer_Then_Keyword;
var L: TLexer; T: TToken;
begin
  L := TLexer.Create('then');
  try
    T := L.Next;
    AssertEquals('then token', Ord(tkThen), Ord(T.Kind));
  finally L.Free; end;
end;

procedure TControlTests.TestLexer_Else_Keyword;
var L: TLexer; T: TToken;
begin
  L := TLexer.Create('else');
  try
    T := L.Next;
    AssertEquals('else token', Ord(tkElse), Ord(T.Kind));
  finally L.Free; end;
end;

procedure TControlTests.TestLexer_Equals_CompareOp;
var L: TLexer; T: TToken;
begin
  L := TLexer.Create('=');
  try
    T := L.Next;
    AssertEquals('equals token', Ord(tkEquals), Ord(T.Kind));
  finally L.Free; end;
end;

procedure TControlTests.TestLexer_NotEquals;
var L: TLexer; T: TToken;
begin
  L := TLexer.Create('<>');
  try
    T := L.Next;
    AssertEquals('<> token', Ord(tkNotEquals), Ord(T.Kind));
  finally L.Free; end;
end;

procedure TControlTests.TestLexer_LessThan;
var L: TLexer; T: TToken;
begin
  L := TLexer.Create('<');
  try
    T := L.Next;
    AssertEquals('< token', Ord(tkLessThan), Ord(T.Kind));
  finally L.Free; end;
end;

procedure TControlTests.TestLexer_GreaterThan;
var L: TLexer; T: TToken;
begin
  L := TLexer.Create('>');
  try
    T := L.Next;
    AssertEquals('> token', Ord(tkGreaterThan), Ord(T.Kind));
  finally L.Free; end;
end;

procedure TControlTests.TestLexer_LessEqual;
var L: TLexer; T: TToken;
begin
  L := TLexer.Create('<=');
  try
    T := L.Next;
    AssertEquals('<= token', Ord(tkLessEqual), Ord(T.Kind));
  finally L.Free; end;
end;

procedure TControlTests.TestLexer_GreaterEqual;
var L: TLexer; T: TToken;
begin
  L := TLexer.Create('>=');
  try
    T := L.Next;
    AssertEquals('>= token', Ord(tkGreaterEqual), Ord(T.Kind));
  finally L.Free; end;
end;

{ ------------------------------------------------------------------ }
{ Parser tests                                                        }
{ ------------------------------------------------------------------ }

procedure TControlTests.TestParse_If_IsIfStmt;
var Prog: TProgram;
begin
  Prog := ParseSrc(SrcIfOnly);
  try
    AssertTrue('second stmt is TIfStmt', Prog.Block.Stmts[1] is TIfStmt);
  finally Prog.Free; end;
end;

procedure TControlTests.TestParse_If_HasCondition;
var Prog: TProgram; S: TIfStmt;
begin
  Prog := ParseSrc(SrcIfOnly);
  try
    S := TIfStmt(Prog.Block.Stmts[1]);
    AssertNotNull('condition not nil', S.Condition);
  finally Prog.Free; end;
end;

procedure TControlTests.TestParse_If_ConditionIsBinaryExpr;
var Prog: TProgram; S: TIfStmt;
begin
  Prog := ParseSrc(SrcIfOnly);
  try
    S := TIfStmt(Prog.Block.Stmts[1]);
    AssertTrue('condition is TBinaryExpr', S.Condition is TBinaryExpr);
  finally Prog.Free; end;
end;

procedure TControlTests.TestParse_If_NoElse;
var Prog: TProgram; S: TIfStmt;
begin
  Prog := ParseSrc(SrcIfOnly);
  try
    S := TIfStmt(Prog.Block.Stmts[1]);
    AssertNull('no else stmt', S.ElseStmt);
  finally Prog.Free; end;
end;

procedure TControlTests.TestParse_IfElse_HasElseStmt;
var Prog: TProgram; S: TIfStmt;
begin
  Prog := ParseSrc(SrcIfElse);
  try
    S := TIfStmt(Prog.Block.Stmts[1]);
    AssertNotNull('else stmt present', S.ElseStmt);
  finally Prog.Free; end;
end;

procedure TControlTests.TestParse_If_ThenIsAssignment;
var Prog: TProgram; S: TIfStmt;
begin
  Prog := ParseSrc(SrcIfOnly);
  try
    S := TIfStmt(Prog.Block.Stmts[1]);
    AssertTrue('then is TAssignment', S.ThenStmt is TAssignment);
  finally Prog.Free; end;
end;

procedure TControlTests.TestParse_IfElse_ElseIsAssignment;
var Prog: TProgram; S: TIfStmt;
begin
  Prog := ParseSrc(SrcIfElse);
  try
    S := TIfStmt(Prog.Block.Stmts[1]);
    AssertTrue('else is TAssignment', S.ElseStmt is TAssignment);
  finally Prog.Free; end;
end;

procedure TControlTests.TestParse_Compound_IsCompoundStmt;
var Prog: TProgram; S: TIfStmt;
begin
  Prog := ParseSrc(SrcCompound);
  try
    S := TIfStmt(Prog.Block.Stmts[1]);
    AssertTrue('then is TCompoundStmt', S.ThenStmt is TCompoundStmt);
  finally Prog.Free; end;
end;

procedure TControlTests.TestParse_Compound_StmtCount;
var Prog: TProgram; S: TIfStmt; C: TCompoundStmt;
begin
  Prog := ParseSrc(SrcCompound);
  try
    S := TIfStmt(Prog.Block.Stmts[1]);
    C := TCompoundStmt(S.ThenStmt);
    AssertEquals('two stmts in then block', 2, C.Stmts.Count);
  finally Prog.Free; end;
end;

procedure TControlTests.TestParse_If_ThenIsCompound;
var Prog: TProgram; S: TIfStmt;
begin
  Prog := ParseSrc(SrcCompound);
  try
    S := TIfStmt(Prog.Block.Stmts[1]);
    AssertTrue('then is TCompoundStmt', S.ThenStmt is TCompoundStmt);
  finally Prog.Free; end;
end;

procedure TControlTests.TestParse_IfElse_ElseIsCompound;
var Prog: TProgram; S: TIfStmt;
begin
  Prog := ParseSrc(SrcCompound);
  try
    S := TIfStmt(Prog.Block.Stmts[1]);
    AssertTrue('else is TCompoundStmt', S.ElseStmt is TCompoundStmt);
  finally Prog.Free; end;
end;

{ ------------------------------------------------------------------ }
{ Semantic tests                                                      }
{ ------------------------------------------------------------------ }

procedure TControlTests.TestSemantic_If_Resolves;
begin
  AnalyseSrc(SrcIfOnly).Free;
end;

procedure TControlTests.TestSemantic_IfElse_Resolves;
begin
  AnalyseSrc(SrcIfElse).Free;
end;

procedure TControlTests.TestSemantic_Comparison_EQ_TypeIsBoolean;
var
  Prog: TProgram;
  S:    TIfStmt;
begin
  Prog := AnalyseSrc(SrcIfOnly);
  try
    S := TIfStmt(Prog.Block.Stmts[1]);
    AssertNotNull('condition resolved type', S.Condition.ResolvedType);
    AssertEquals('condition is Boolean',
      Ord(tyBoolean), Ord(S.Condition.ResolvedType.Kind));
  finally Prog.Free; end;
end;

procedure TControlTests.TestSemantic_Comparison_NE_TypeIsBoolean;
var
  Prog: TProgram;
  S:    TIfStmt;
begin
  Prog := AnalyseSrc(
    'program P;'       + LineEnding +
    'var N: Integer;'  + LineEnding +
    'begin'            + LineEnding +
    '  N := 1;'        + LineEnding +
    '  if N <> 0 then' + LineEnding +
    '    N := 0'       + LineEnding +
    'end.');
  try
    S := TIfStmt(Prog.Block.Stmts[1]);
    AssertEquals('NE result is Boolean',
      Ord(tyBoolean), Ord(S.Condition.ResolvedType.Kind));
  finally Prog.Free; end;
end;

procedure TControlTests.TestSemantic_Comparison_LT_TypeIsBoolean;
var
  Prog: TProgram;
  S:    TIfStmt;
begin
  Prog := AnalyseSrc(
    'program P;'       + LineEnding +
    'var N: Integer;'  + LineEnding +
    'begin'            + LineEnding +
    '  N := 1;'        + LineEnding +
    '  if N < 5 then'  + LineEnding +
    '    N := 0'       + LineEnding +
    'end.');
  try
    S := TIfStmt(Prog.Block.Stmts[1]);
    AssertEquals('LT result is Boolean',
      Ord(tyBoolean), Ord(S.Condition.ResolvedType.Kind));
  finally Prog.Free; end;
end;

procedure TControlTests.TestSemantic_Comparison_GT_TypeIsBoolean;
var
  Prog: TProgram;
  S:    TIfStmt;
begin
  Prog := AnalyseSrc(SrcIfElse);
  try
    S := TIfStmt(Prog.Block.Stmts[1]);
    AssertEquals('GT result is Boolean',
      Ord(tyBoolean), Ord(S.Condition.ResolvedType.Kind));
  finally Prog.Free; end;
end;

procedure TControlTests.TestSemantic_Comparison_LE_TypeIsBoolean;
var
  Prog: TProgram;
  S:    TIfStmt;
begin
  Prog := AnalyseSrc(
    'program P;'       + LineEnding +
    'var N: Integer;'  + LineEnding +
    'begin'            + LineEnding +
    '  N := 1;'        + LineEnding +
    '  if N <= 5 then' + LineEnding +
    '    N := 0'       + LineEnding +
    'end.');
  try
    S := TIfStmt(Prog.Block.Stmts[1]);
    AssertEquals('LE result is Boolean',
      Ord(tyBoolean), Ord(S.Condition.ResolvedType.Kind));
  finally Prog.Free; end;
end;

procedure TControlTests.TestSemantic_Comparison_GE_TypeIsBoolean;
var
  Prog: TProgram;
  S:    TIfStmt;
begin
  Prog := AnalyseSrc(
    'program P;'       + LineEnding +
    'var N: Integer;'  + LineEnding +
    'begin'            + LineEnding +
    '  N := 1;'        + LineEnding +
    '  if N >= 1 then' + LineEnding +
    '    N := 0'       + LineEnding +
    'end.');
  try
    S := TIfStmt(Prog.Block.Stmts[1]);
    AssertEquals('GE result is Boolean',
      Ord(tyBoolean), Ord(S.Condition.ResolvedType.Kind));
  finally Prog.Free; end;
end;

procedure TControlTests.TestSemantic_Comparison_TypeMismatch_RaisesError;
begin
  AnalyseExpectError(
    'program P;'          + LineEnding +
    'var N: Integer;'     + LineEnding +
    'begin'               + LineEnding +
    '  N := 1;'           + LineEnding +
    '  if N = ''hello'' then' + LineEnding +
    '    N := 0'          + LineEnding +
    'end.');
end;

procedure TControlTests.TestSemantic_If_NonBooleanCondition_RaisesError;
begin
  AnalyseExpectError(
    'program P;'       + LineEnding +
    'var N: Integer;'  + LineEnding +
    'begin'            + LineEnding +
    '  N := 1;'        + LineEnding +
    '  if N then'      + LineEnding +
    '    N := 0'       + LineEnding +
    'end.');
end;

{ ------------------------------------------------------------------ }
{ Code generation tests                                               }
{ ------------------------------------------------------------------ }

procedure TControlTests.TestCodegen_If_EmitsJnz;
begin
  AssertTrue('jnz emitted', Pos('jnz', GenIR(SrcIfOnly)) > 0);
end;

procedure TControlTests.TestCodegen_If_EmitsThenLabel;
begin
  AssertTrue('@if_then label', Pos('@if_then', GenIR(SrcIfOnly)) > 0);
end;

procedure TControlTests.TestCodegen_If_EmitsEndLabel;
begin
  AssertTrue('@if_end label', Pos('@if_end', GenIR(SrcIfOnly)) > 0);
end;

procedure TControlTests.TestCodegen_IfElse_EmitsElseLabel;
begin
  AssertTrue('@if_else label', Pos('@if_else', GenIR(SrcIfElse)) > 0);
end;

procedure TControlTests.TestCodegen_IfElse_ThenJumpsToEnd;
begin
  AssertTrue('jmp @if_end after then', Pos('jmp @if_end', GenIR(SrcIfElse)) > 0);
end;

procedure TControlTests.TestCodegen_Comparison_EQ_UsescEqw;
begin
  AssertTrue('ceqw for =', Pos('ceqw', GenIR(SrcIfOnly)) > 0);
end;

procedure TControlTests.TestCodegen_Comparison_LT_UsescLtw;
begin
  AssertTrue('csltw for <', Pos('csltw', GenIR(
    'program P;' + LineEnding +
    'var N: Integer;' + LineEnding +
    'begin' + LineEnding +
    '  N := 1;' + LineEnding +
    '  if N < 5 then N := 0' + LineEnding +
    'end.'
  )) > 0);
end;

procedure TControlTests.TestCodegen_Comparison_GT_UsescGtw;
begin
  AssertTrue('csgtw for >', Pos('csgtw', GenIR(SrcIfElse)) > 0);
end;

procedure TControlTests.TestCodegen_Comparison_NE_UsescNew;
begin
  AssertTrue('cnew for <>', Pos('cnew', GenIR(
    'program P;' + LineEnding +
    'var N: Integer;' + LineEnding +
    'begin' + LineEnding +
    '  N := 1;' + LineEnding +
    '  if N <> 0 then N := 0' + LineEnding +
    'end.'
  )) > 0);
end;

procedure TControlTests.TestCodegen_Compound_EmitsAllStmts;
var IR: string;
begin
  IR := GenIR(SrcCompound);
  { Compound then branch has WriteLn + assignment, so printf should appear }
  AssertTrue('printf in compound branch', Pos('printf', IR) > 0);
end;

initialization
  RegisterTest(TControlTests);

end.
