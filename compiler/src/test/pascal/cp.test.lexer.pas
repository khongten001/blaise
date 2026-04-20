unit cp.test.lexer;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  uLexer;

type
  TLexerTests = class(TTestCase)
  private
    FLexer: TLexer;
    procedure SetLexer(const ASource: string);
  protected
    procedure TearDown; override;
  published
    { EOF and whitespace }
    procedure TestEmptySource_ReturnsEOF;
    procedure TestWhitespaceOnly_ReturnsEOF;

    { Comment skipping }
    procedure TestLineComment_Skipped;
    procedure TestBlockComment_Skipped;
    procedure TestBlockComment_MultiLine_Skipped;

    { Keywords }
    procedure TestKeyword_Program;
    procedure TestKeyword_Uses;
    procedure TestKeyword_Var;
    procedure TestKeyword_Begin;
    procedure TestKeyword_End;
    procedure TestKeywords_CaseInsensitive;
    procedure TestIdent_NotKeyword_Prefix;

    { Identifiers }
    procedure TestIdent_Simple;
    procedure TestIdent_WithUnderscore;
    procedure TestIdent_WithDigits;

    { Integer literals }
    procedure TestIntLit_SingleDigit;
    procedure TestIntLit_MultiDigit;

    { String literals }
    procedure TestStringLit_Simple;
    procedure TestStringLit_Empty;
    procedure TestStringLit_EmbeddedQuote;

    { Operators and punctuation }
    procedure TestOp_Plus;
    procedure TestOp_Minus;
    procedure TestOp_Star;
    procedure TestOp_Slash;
    procedure TestOp_Assign;
    procedure TestOp_Colon;
    procedure TestOp_LParen;
    procedure TestOp_RParen;
    procedure TestOp_Comma;
    procedure TestOp_Semicolon;
    procedure TestOp_Dot;

    { Position tracking }
    procedure TestLineTracking_SecondLine;
    procedure TestColTracking_AfterSpaces;

    { Token sequences }
    procedure TestSeq_VarDecl;
    procedure TestSeq_Assignment;
    procedure TestSeq_ProcCall;
  end;

implementation

procedure TLexerTests.SetLexer(const ASource: string);
begin
  FreeAndNil(FLexer);
  FLexer := TLexer.Create(ASource);
end;

procedure TLexerTests.TearDown;
begin
  FreeAndNil(FLexer);
end;

{ EOF and whitespace }

procedure TLexerTests.TestEmptySource_ReturnsEOF;
var
  tok: TToken;
begin
  SetLexer('');
  tok := FLexer.Next;
  AssertEquals('Kind', Ord(tkEOF), Ord(tok.Kind));
end;

procedure TLexerTests.TestWhitespaceOnly_ReturnsEOF;
var
  tok: TToken;
begin
  SetLexer('   ' + LineEnding + '  ');
  tok := FLexer.Next;
  AssertEquals('Kind', Ord(tkEOF), Ord(tok.Kind));
end;

{ Comment skipping }

procedure TLexerTests.TestLineComment_Skipped;
var
  tok: TToken;
begin
  SetLexer('// comment' + LineEnding + 'begin');
  tok := FLexer.Next;
  AssertEquals('Kind after //', Ord(tkBegin), Ord(tok.Kind));
end;

procedure TLexerTests.TestBlockComment_Skipped;
var
  tok: TToken;
begin
  SetLexer('{ comment } begin');
  tok := FLexer.Next;
  AssertEquals('Kind after {}', Ord(tkBegin), Ord(tok.Kind));
end;

procedure TLexerTests.TestBlockComment_MultiLine_Skipped;
var
  tok: TToken;
begin
  SetLexer('{ line one' + LineEnding + '  line two }' + LineEnding + 'end');
  tok := FLexer.Next;
  AssertEquals('Kind after multiline {}', Ord(tkEnd), Ord(tok.Kind));
end;

{ Keywords }

procedure TLexerTests.TestKeyword_Program;
var
  tok: TToken;
begin
  SetLexer('program');
  tok := FLexer.Next;
  AssertEquals('Kind', Ord(tkProgram), Ord(tok.Kind));
  AssertEquals('Value', 'program', tok.Value);
end;

procedure TLexerTests.TestKeyword_Uses;
var
  tok: TToken;
begin
  SetLexer('uses');
  tok := FLexer.Next;
  AssertEquals('Kind', Ord(tkUses), Ord(tok.Kind));
end;

procedure TLexerTests.TestKeyword_Var;
var
  tok: TToken;
begin
  SetLexer('var');
  tok := FLexer.Next;
  AssertEquals('Kind', Ord(tkVar), Ord(tok.Kind));
end;

procedure TLexerTests.TestKeyword_Begin;
var
  tok: TToken;
begin
  SetLexer('begin');
  tok := FLexer.Next;
  AssertEquals('Kind', Ord(tkBegin), Ord(tok.Kind));
end;

procedure TLexerTests.TestKeyword_End;
var
  tok: TToken;
begin
  SetLexer('end');
  tok := FLexer.Next;
  AssertEquals('Kind', Ord(tkEnd), Ord(tok.Kind));
end;

procedure TLexerTests.TestKeywords_CaseInsensitive;
var
  tok: TToken;
begin
  SetLexer('BEGIN');
  tok := FLexer.Next;
  AssertEquals('Uppercase BEGIN', Ord(tkBegin), Ord(tok.Kind));

  SetLexer('End');
  tok := FLexer.Next;
  AssertEquals('Mixed End', Ord(tkEnd), Ord(tok.Kind));

  SetLexer('PROGRAM');
  tok := FLexer.Next;
  AssertEquals('Uppercase PROGRAM', Ord(tkProgram), Ord(tok.Kind));
end;

procedure TLexerTests.TestIdent_NotKeyword_Prefix;
var
  tok: TToken;
begin
  { "beginning" starts with "begin" but is not a keyword }
  SetLexer('beginning');
  tok := FLexer.Next;
  AssertEquals('Kind', Ord(tkIdent), Ord(tok.Kind));
  AssertEquals('Value', 'beginning', tok.Value);
end;

{ Identifiers }

procedure TLexerTests.TestIdent_Simple;
var
  tok: TToken;
begin
  SetLexer('Hello');
  tok := FLexer.Next;
  AssertEquals('Kind', Ord(tkIdent), Ord(tok.Kind));
  AssertEquals('Value', 'Hello', tok.Value);
end;

procedure TLexerTests.TestIdent_WithUnderscore;
var
  tok: TToken;
begin
  SetLexer('_myVar');
  tok := FLexer.Next;
  AssertEquals('Kind', Ord(tkIdent), Ord(tok.Kind));
  AssertEquals('Value', '_myVar', tok.Value);
end;

procedure TLexerTests.TestIdent_WithDigits;
var
  tok: TToken;
begin
  SetLexer('item2');
  tok := FLexer.Next;
  AssertEquals('Kind', Ord(tkIdent), Ord(tok.Kind));
  AssertEquals('Value', 'item2', tok.Value);
end;

{ Integer literals }

procedure TLexerTests.TestIntLit_SingleDigit;
var
  tok: TToken;
begin
  SetLexer('7');
  tok := FLexer.Next;
  AssertEquals('Kind', Ord(tkIntLit), Ord(tok.Kind));
  AssertEquals('Value', '7', tok.Value);
end;

procedure TLexerTests.TestIntLit_MultiDigit;
var
  tok: TToken;
begin
  SetLexer('42');
  tok := FLexer.Next;
  AssertEquals('Kind', Ord(tkIntLit), Ord(tok.Kind));
  AssertEquals('Value', '42', tok.Value);
end;

{ String literals }

procedure TLexerTests.TestStringLit_Simple;
var
  tok: TToken;
begin
  SetLexer('''hello''');
  tok := FLexer.Next;
  AssertEquals('Kind', Ord(tkStringLit), Ord(tok.Kind));
  AssertEquals('Value', 'hello', tok.Value);
end;

procedure TLexerTests.TestStringLit_Empty;
var
  tok: TToken;
begin
  SetLexer('''''');
  tok := FLexer.Next;
  AssertEquals('Kind', Ord(tkStringLit), Ord(tok.Kind));
  AssertEquals('Value', '', tok.Value);
end;

procedure TLexerTests.TestStringLit_EmbeddedQuote;
var
  tok: TToken;
begin
  { Pascal ''it''''s'' represents it's }
  SetLexer('''it''''s''');
  tok := FLexer.Next;
  AssertEquals('Kind', Ord(tkStringLit), Ord(tok.Kind));
  AssertEquals('Value', 'it''s', tok.Value);
end;

{ Operators and punctuation }

procedure TLexerTests.TestOp_Plus;
var
  tok: TToken;
begin
  SetLexer('+');
  tok := FLexer.Next;
  AssertEquals('Kind', Ord(tkPlus), Ord(tok.Kind));
end;

procedure TLexerTests.TestOp_Minus;
var
  tok: TToken;
begin
  SetLexer('-');
  tok := FLexer.Next;
  AssertEquals('Kind', Ord(tkMinus), Ord(tok.Kind));
end;

procedure TLexerTests.TestOp_Star;
var
  tok: TToken;
begin
  SetLexer('*');
  tok := FLexer.Next;
  AssertEquals('Kind', Ord(tkStar), Ord(tok.Kind));
end;

procedure TLexerTests.TestOp_Slash;
var
  tok: TToken;
begin
  SetLexer('/');
  tok := FLexer.Next;
  AssertEquals('Kind', Ord(tkSlash), Ord(tok.Kind));
end;

procedure TLexerTests.TestOp_Assign;
var
  tok: TToken;
begin
  SetLexer(':=');
  tok := FLexer.Next;
  AssertEquals('Kind', Ord(tkAssign), Ord(tok.Kind));
  AssertEquals('Value', ':=', tok.Value);
end;

procedure TLexerTests.TestOp_Colon;
var
  tok: TToken;
begin
  SetLexer(':');
  tok := FLexer.Next;
  AssertEquals('Kind', Ord(tkColon), Ord(tok.Kind));
end;

procedure TLexerTests.TestOp_LParen;
var
  tok: TToken;
begin
  SetLexer('(');
  tok := FLexer.Next;
  AssertEquals('Kind', Ord(tkLParen), Ord(tok.Kind));
end;

procedure TLexerTests.TestOp_RParen;
var
  tok: TToken;
begin
  SetLexer(')');
  tok := FLexer.Next;
  AssertEquals('Kind', Ord(tkRParen), Ord(tok.Kind));
end;

procedure TLexerTests.TestOp_Comma;
var
  tok: TToken;
begin
  SetLexer(',');
  tok := FLexer.Next;
  AssertEquals('Kind', Ord(tkComma), Ord(tok.Kind));
end;

procedure TLexerTests.TestOp_Semicolon;
var
  tok: TToken;
begin
  SetLexer(';');
  tok := FLexer.Next;
  AssertEquals('Kind', Ord(tkSemicolon), Ord(tok.Kind));
end;

procedure TLexerTests.TestOp_Dot;
var
  tok: TToken;
begin
  SetLexer('.');
  tok := FLexer.Next;
  AssertEquals('Kind', Ord(tkDot), Ord(tok.Kind));
end;

{ Position tracking }

procedure TLexerTests.TestLineTracking_SecondLine;
var
  tok: TToken;
begin
  SetLexer('begin' + LineEnding + 'end');
  tok := FLexer.Next;
  AssertEquals('begin line', 1, tok.Line);
  tok := FLexer.Next;
  AssertEquals('end line', 2, tok.Line);
end;

procedure TLexerTests.TestColTracking_AfterSpaces;
var
  tok: TToken;
begin
  SetLexer('  begin');
  tok := FLexer.Next;
  AssertEquals('begin col', 3, tok.Col);
end;

{ Token sequences }

procedure TLexerTests.TestSeq_VarDecl;
var
  t: array[0..3] of TToken;
  i: Integer;
begin
  SetLexer('x : Integer');
  for i := 0 to 3 do
    t[i] := FLexer.Next;
  AssertEquals('x kind', Ord(tkIdent), Ord(t[0].Kind));
  AssertEquals('x value', 'x', t[0].Value);
  AssertEquals(': kind', Ord(tkColon), Ord(t[1].Kind));
  AssertEquals('Integer kind', Ord(tkIdent), Ord(t[2].Kind));
  AssertEquals('Integer value', 'Integer', t[2].Value);
  AssertEquals('EOF', Ord(tkEOF), Ord(t[3].Kind));
end;

procedure TLexerTests.TestSeq_Assignment;
var
  t: array[0..3] of TToken;
  i: Integer;
begin
  SetLexer('x := 42');
  for i := 0 to 3 do
    t[i] := FLexer.Next;
  AssertEquals('x', Ord(tkIdent), Ord(t[0].Kind));
  AssertEquals(':=', Ord(tkAssign), Ord(t[1].Kind));
  AssertEquals('42 kind', Ord(tkIntLit), Ord(t[2].Kind));
  AssertEquals('42 value', '42', t[2].Value);
  AssertEquals('EOF', Ord(tkEOF), Ord(t[3].Kind));
end;

procedure TLexerTests.TestSeq_ProcCall;
var
  t: array[0..4] of TToken;
  i: Integer;
begin
  SetLexer('WriteLn(''hi'')');
  for i := 0 to 4 do
    t[i] := FLexer.Next;
  AssertEquals('WriteLn kind', Ord(tkIdent), Ord(t[0].Kind));
  AssertEquals('( kind', Ord(tkLParen), Ord(t[1].Kind));
  AssertEquals('str kind', Ord(tkStringLit), Ord(t[2].Kind));
  AssertEquals('str value', 'hi', t[2].Value);
  AssertEquals(') kind', Ord(tkRParen), Ord(t[3].Kind));
  AssertEquals('EOF', Ord(tkEOF), Ord(t[4].Kind));
end;

initialization
  RegisterTest(TLexerTests);

end.
