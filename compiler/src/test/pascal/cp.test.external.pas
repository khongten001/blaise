{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit cp.test.external;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  uLexer, uParser, uAST, uSemantic, uCodeGenQBE;

type
  TExternalTests = class(TTestCase)
  private
    function ParseSrc(const ASrc: string): TProgram;
    function ParseUnit(const ASrc: string): TUnit;
    function GenIR(const ASrc: string): string;
    function IRContains(const AIR, AFragment: string): Boolean;
  published
    { Parser — standalone procedure }
    procedure TestParse_ExternalProc_IsExternal;
    procedure TestParse_ExternalProc_ExternalNameEmpty;
    procedure TestParse_ExternalProcNamed_ExternalName;
    { Parser — standalone function }
    procedure TestParse_ExternalFunc_IsExternal;
    procedure TestParse_ExternalFuncNamed_ExternalName;
    { Parser — in unit interface section }
    procedure TestParse_ExternalInUnitInterface;
    { Semantic — external proc is registered and callable }
    procedure TestSemantic_ExternalProc_Callable;
    procedure TestSemantic_ExternalFunc_CallableAsExpr;
    { Codegen — no body emitted for external declarations }
    procedure TestCodegen_ExternalProc_NoBodyEmitted;
    { Codegen — call to external proc generates a call instruction }
    procedure TestCodegen_ExternalProc_CallEmitted;
    { Codegen — call uses C symbol name when 'external name' is given }
    procedure TestCodegen_ExternalProcNamed_UsesExternalName;
  end;

implementation

function TExternalTests.ParseSrc(const ASrc: string): TProgram;
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

function TExternalTests.ParseUnit(const ASrc: string): TUnit;
var
  L: TLexer;
  P: TParser;
begin
  L := TLexer.Create(ASrc);
  P := TParser.Create(L);
  try
    Result := P.ParseUnit;
  finally
    P.Free;
    L.Free;
  end;
end;

function TExternalTests.GenIR(const ASrc: string): string;
var
  L:  TLexer;
  P:  TParser;
  Pr: TProgram;
  A:  TSemanticAnalyser;
  CG: TCodeGenQBE;
begin
  L  := TLexer.Create(ASrc);
  P  := TParser.Create(L);
  Pr := P.Parse;
  A  := TSemanticAnalyser.Create;
  try
    A.Analyse(Pr);
  finally
    A.Free;
  end;
  CG := TCodeGenQBE.Create;
  try
    CG.Generate(Pr);
    Result := CG.GetOutput;
  finally
    CG.Free;
    Pr.Free;
    P.Free;
    L.Free;
  end;
end;

function TExternalTests.IRContains(const AIR, AFragment: string): Boolean;
begin
  Result := Pos(AFragment, AIR) > 0;
end;

{ ── Parser tests ─────────────────────────────────────────────────────────── }

procedure TExternalTests.TestParse_ExternalProc_IsExternal;
var
  Prog: TProgram;
  Decl: TMethodDecl;
begin
  Prog := ParseSrc(
    'program Test;'              + LineEnding +
    'procedure Foo; external;'   + LineEnding +
    'begin'                      + LineEnding +
    'end.'
  );
  try
    AssertEquals('Should have one proc decl', 1, Prog.Block.ProcDecls.Count);
    Decl := TMethodDecl(Prog.Block.ProcDecls.Items[0]);
    AssertTrue('IsExternal should be True', Decl.IsExternal);
  finally
    Prog.Free;
  end;
end;

procedure TExternalTests.TestParse_ExternalProc_ExternalNameEmpty;
var
  Prog: TProgram;
  Decl: TMethodDecl;
begin
  Prog := ParseSrc(
    'program Test;'              + LineEnding +
    'procedure Foo; external;'   + LineEnding +
    'begin'                      + LineEnding +
    'end.'
  );
  try
    Decl := TMethodDecl(Prog.Block.ProcDecls.Items[0]);
    AssertEquals('ExternalName should be empty when no name given',
      '', Decl.ExternalName);
  finally
    Prog.Free;
  end;
end;

procedure TExternalTests.TestParse_ExternalProcNamed_ExternalName;
var
  Prog: TProgram;
  Decl: TMethodDecl;
begin
  Prog := ParseSrc(
    'program Test;'                          + LineEnding +
    'procedure Foo; external name ''c_foo'';' + LineEnding +
    'begin'                                  + LineEnding +
    'end.'
  );
  try
    Decl := TMethodDecl(Prog.Block.ProcDecls.Items[0]);
    AssertTrue('IsExternal should be True', Decl.IsExternal);
    AssertEquals('ExternalName should be c_foo', 'c_foo', Decl.ExternalName);
  finally
    Prog.Free;
  end;
end;

procedure TExternalTests.TestParse_ExternalFunc_IsExternal;
var
  Prog: TProgram;
  Decl: TMethodDecl;
begin
  Prog := ParseSrc(
    'program Test;'                        + LineEnding +
    'function Bar: Integer; external;'     + LineEnding +
    'begin'                                + LineEnding +
    'end.'
  );
  try
    AssertEquals('Should have one func decl', 1, Prog.Block.ProcDecls.Count);
    Decl := TMethodDecl(Prog.Block.ProcDecls.Items[0]);
    AssertTrue('IsExternal should be True', Decl.IsExternal);
  finally
    Prog.Free;
  end;
end;

procedure TExternalTests.TestParse_ExternalFuncNamed_ExternalName;
var
  Prog: TProgram;
  Decl: TMethodDecl;
begin
  Prog := ParseSrc(
    'program Test;'                                       + LineEnding +
    'function Bar: Integer; external name ''c_bar'';'     + LineEnding +
    'begin'                                               + LineEnding +
    'end.'
  );
  try
    Decl := TMethodDecl(Prog.Block.ProcDecls.Items[0]);
    AssertEquals('ExternalName should be c_bar', 'c_bar', Decl.ExternalName);
  finally
    Prog.Free;
  end;
end;

procedure TExternalTests.TestParse_ExternalInUnitInterface;
var
  U: TUnit;
begin
  U := ParseUnit(
    'unit MyLib;'                            + LineEnding +
    'interface'                              + LineEnding +
    'procedure Foo; external;'              + LineEnding +
    'function Bar: Integer; external;'      + LineEnding +
    'implementation'                         + LineEnding +
    'end.'
  );
  try
    AssertEquals('Interface should have 2 proc decls',
      2, U.IntfBlock.ProcDecls.Count);
    AssertTrue('Foo should be external',
      TMethodDecl(U.IntfBlock.ProcDecls.Items[0]).IsExternal);
    AssertTrue('Bar should be external',
      TMethodDecl(U.IntfBlock.ProcDecls.Items[1]).IsExternal);
  finally
    U.Free;
  end;
end;

{ ── Semantic tests ───────────────────────────────────────────────────────── }

procedure TExternalTests.TestSemantic_ExternalProc_Callable;
var
  Prog: TProgram;
  SA:   TSemanticAnalyser;
begin
  Prog := ParseSrc(
    'program Test;'              + LineEnding +
    'procedure Foo; external;'   + LineEnding +
    'begin'                      + LineEnding +
    '  Foo'                      + LineEnding +
    'end.'
  );
  SA := TSemanticAnalyser.Create;
  try
    SA.Analyse(Prog);
    AssertNotNull('Program should analyse without error', Prog.SymbolTable);
  finally
    SA.Free;
    Prog.Free;
  end;
end;

procedure TExternalTests.TestSemantic_ExternalFunc_CallableAsExpr;
var
  Prog: TProgram;
  SA:   TSemanticAnalyser;
begin
  Prog := ParseSrc(
    'program Test;'                      + LineEnding +
    'function Bar: Integer; external;'   + LineEnding +
    'var x: Integer;'                    + LineEnding +
    'begin'                              + LineEnding +
    '  x := Bar'                         + LineEnding +
    'end.'
  );
  SA := TSemanticAnalyser.Create;
  try
    SA.Analyse(Prog);
    AssertNotNull('Program should analyse without error', Prog.SymbolTable);
  finally
    SA.Free;
    Prog.Free;
  end;
end;

{ ── Codegen tests ────────────────────────────────────────────────────────── }

procedure TExternalTests.TestCodegen_ExternalProc_NoBodyEmitted;
var
  IR: string;
begin
  IR := GenIR(
    'program Test;'              + LineEnding +
    'procedure Foo; external;'   + LineEnding +
    'begin'                      + LineEnding +
    'end.'
  );
  { An external declaration must NOT emit a QBE function body for Foo }
  AssertFalse('External proc must not emit a function body',
    IRContains(IR, 'function $Foo'));
end;

procedure TExternalTests.TestCodegen_ExternalProc_CallEmitted;
var
  IR: string;
begin
  IR := GenIR(
    'program Test;'              + LineEnding +
    'procedure Foo; external;'   + LineEnding +
    'begin'                      + LineEnding +
    '  Foo'                      + LineEnding +
    'end.'
  );
  AssertTrue('Call to external proc should appear in IR',
    IRContains(IR, 'call $Foo'));
end;

procedure TExternalTests.TestCodegen_ExternalProcNamed_UsesExternalName;
var
  IR: string;
begin
  IR := GenIR(
    'program Test;'                          + LineEnding +
    'procedure Foo; external name ''c_foo'';' + LineEnding +
    'begin'                                  + LineEnding +
    '  Foo'                                  + LineEnding +
    'end.'
  );
  { Call site must use the C symbol name, not the Pascal name }
  AssertTrue('Call should use C symbol name',
    IRContains(IR, 'call $c_foo'));
  AssertFalse('Call must not use Pascal name when external name is given',
    IRContains(IR, 'call $Foo'));
end;

initialization
  RegisterTest(TExternalTests);

end.
