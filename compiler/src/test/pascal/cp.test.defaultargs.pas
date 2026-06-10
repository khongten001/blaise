{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit cp.test.defaultargs;

{ Default parameters must be materialised into the call's argument list by
  the semantic pass for EVERY call form.  AnalyseMethodCall (method call
  STATEMENTS) didn't append them: the emitted call then carried fewer
  arguments than the callee's parameter list, and the callee read garbage
  for the missing ones — caller-frame junk once the parameter fell past
  the six SysV registers.  Found 2026-06-10 via the borrowed-local elision
  crash (native EmitInterfaceCall read its stack-passed AObjExpr=nil
  default from an argument slot the caller never wrote). }

interface

uses
  Classes, SysUtils, blaise.testing, uStrCompat,
  uLexer, uParser, uAST, uSymbolTable, uSemantic, blaise.codegen.qbe;

type
  TDefaultArgsTests = class(TTestCase)
  private
    function GenIR(const ASrc: string): string;
  published
    procedure TestMethodCallStmt_OmittedDefault_Materialised;
    procedure TestMethodCallStmt_SeventhSlotDefault_Materialised;
    procedure TestImplicitSelfStmt_OmittedDefault_Materialised;
    procedure TestProcCallStmt_OmittedDefault_Materialised;
  end;

implementation

function TDefaultArgsTests.GenIR(const ASrc: string): string;
var
  L:    TLexer;
  P:    TParser;
  Prog: TProgram;
  A:    TSemanticAnalyser;
  CG:   TCodeGenQBE;
begin
  L := TLexer.Create(ASrc);
  P := TParser.Create(L);
  try
    Prog := P.Parse();
  finally
    P.Free(); L.Free();
  end;
  try
    A := TSemanticAnalyser.Create();
    try
      A.Analyse(Prog);
    finally
      A.Free();
    end;
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

procedure TDefaultArgsTests.TestMethodCallStmt_OmittedDefault_Materialised;
const
  Src = '''
      program P;
      type
        TFoo = class
        public
          procedure M(A: Integer; B: Integer = 4242);
        end;
      procedure TFoo.M(A: Integer; B: Integer = 4242);
      begin
        WriteLn(A + B)
      end;
      var F: TFoo;
      begin
        F := TFoo.Create();
        F.M(1)
      end.
      ''';
var
  IR: string;
begin
  { The omitted B must appear as the literal default in the emitted call. }
  IR := GenIR(Src);
  AssertTrue('default 4242 materialised as call argument',
    Pos('4242', IR) >= 0);
end;

procedure TDefaultArgsTests.TestMethodCallStmt_SeventhSlotDefault_Materialised;
const
  { Self + six params: the defaulted last param is the 7th integer slot —
    the stack-passed one that read caller-frame garbage before the fix. }
  Src = '''
      program P;
      type
        TFoo = class
        public
          procedure M(A, B, C, D, E: Integer; F: Integer = 7777);
        end;
      procedure TFoo.M(A, B, C, D, E: Integer; F: Integer = 7777);
      begin
        WriteLn(F)
      end;
      var X: TFoo;
      begin
        X := TFoo.Create();
        X.M(1, 2, 3, 4, 5)
      end.
      ''';
var
  IR: string;
begin
  IR := GenIR(Src);
  AssertTrue('seventh-slot default 7777 materialised',
    Pos('7777', IR) >= 0);
end;

procedure TDefaultArgsTests.TestImplicitSelfStmt_OmittedDefault_Materialised;
const
  Src = '''
      program P;
      type
        TFoo = class
        public
          procedure M(A: Integer; B: Integer = 5151);
          procedure Caller;
        end;
      procedure TFoo.M(A: Integer; B: Integer = 5151);
      begin
        WriteLn(A + B)
      end;
      procedure TFoo.Caller;
      begin
        M(1)
      end;
      var F: TFoo;
      begin
        F := TFoo.Create();
        F.Caller()
      end.
      ''';
var
  IR: string;
begin
  IR := GenIR(Src);
  AssertTrue('implicit-Self stmt default 5151 materialised',
    Pos('5151', IR) >= 0);
end;

procedure TDefaultArgsTests.TestProcCallStmt_OmittedDefault_Materialised;
const
  Src = '''
      program P;
      procedure Q(A: Integer; B: Integer = 6363);
      begin
        WriteLn(A + B)
      end;
      begin
        Q(1)
      end.
      ''';
var
  IR: string;
begin
  { Regression guard: standalone proc statements already materialise. }
  IR := GenIR(Src);
  AssertTrue('proc stmt default 6363 materialised',
    Pos('6363', IR) >= 0);
end;

initialization
  RegisterTest(TDefaultArgsTests);

end.
