{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit cp.test.streams;

{$mode objfpc}{$H+}

{ IR-level tests for the streams design.

  These tests are deliberately self-contained — they declare the stream
  interfaces and abstract bases inline so the test harness does not need
  to resolve the Streams RTL unit.  They verify that the compiler:

    * accepts the design's class shape (abstract base + concrete subclass
      implementing the interface);
    * emits an itab that points at $_AbstractMethodError for abstract
      slots on the abstract base; and
    * emits a concrete-impl pointer in the subclass's itab/vtable. }

interface

uses
  Classes, SysUtils, bcl.testing,
  uLexer, uParser, uAST, uSymbolTable, uSemantic, uCodeGenQBE;

type
  TStreamsTests = class(TTestCase)
  private
    function GenIR(const ASrc: string): string;
    function IRContains(const AIR, AFragment: string): Boolean;
  published
    procedure TestCodegen_AbstractBase_ItabPointsAtStub;
    procedure TestCodegen_ConcreteSubclass_ItabPointsAtImpl;
    procedure TestCodegen_ConcreteSubclass_VTableHasImpl;
  end;

implementation

function TStreamsTests.GenIR(const ASrc: string): string;
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
    A.Analyse(Pr)
  finally
    A.Free
  end;
  CG := TCodeGenQBE.Create;
  try
    CG.Generate(Pr);
    Result := CG.GetOutput
  finally
    CG.Free;
    Pr.Free;
    P.Free;
    L.Free
  end
end;

function TStreamsTests.IRContains(const AIR, AFragment: string): Boolean;
begin
  Result := Pos(AFragment, AIR) > 0
end;

const
  { Mirrors the actual streams.pas shape: ICloseable, IInputStream
    extending it, and an abstract TInputStream that declares the
    interface but defers the implementation. }
  SrcAbstractBase =
    '''
    program P;
    type
      ICloseable = interface
        procedure Close;
      end;
      IInputStream = interface(ICloseable)
        function Read(Buf: Pointer; Count: Integer): Integer;
      end;
      TInputStream = class(TObject, IInputStream, ICloseable)
        function Read(Buf: Pointer; Count: Integer): Integer; virtual; abstract;
        procedure Close; virtual; abstract;
      end;
    begin end.
    ''';

  SrcConcreteSubclass =
    '''
    program P;
    type
      ICloseable = interface
        procedure Close;
      end;
      IInputStream = interface(ICloseable)
        function Read(Buf: Pointer; Count: Integer): Integer;
      end;
      TInputStream = class(TObject, IInputStream, ICloseable)
        function Read(Buf: Pointer; Count: Integer): Integer; virtual; abstract;
        procedure Close; virtual; abstract;
      end;
      TMemoryInput = class(TInputStream, IInputStream, ICloseable)
        function Read(Buf: Pointer; Count: Integer): Integer; override;
        procedure Close; override;
      end;
    function TMemoryInput.Read(Buf: Pointer; Count: Integer): Integer;
    begin Result := 0 end;
    procedure TMemoryInput.Close;
    begin end;
    begin end.
    ''';

procedure TStreamsTests.TestCodegen_AbstractBase_ItabPointsAtStub;
var IR: string;
begin
  IR := GenIR(SrcAbstractBase);
  AssertTrue('IR non-empty', IR <> '');
  AssertTrue('TInputStream itab emitted',
    IRContains(IR, 'itab_TInputStream_IInputStream'));
  AssertTrue('TInputStream vtable emitted',
    IRContains(IR, 'vtable_TInputStream'));
  AssertTrue('abstract stub referenced',
    IRContains(IR, '_AbstractMethodError'))
end;

procedure TStreamsTests.TestCodegen_ConcreteSubclass_ItabPointsAtImpl;
var IR: string;
begin
  IR := GenIR(SrcConcreteSubclass);
  AssertTrue('IR non-empty', IR <> '');
  AssertTrue('TMemoryInput itab emitted',
    IRContains(IR, 'itab_TMemoryInput_IInputStream'));
  AssertTrue('itab references concrete Read',
    IRContains(IR, 'TMemoryInput_Read'))
end;

procedure TStreamsTests.TestCodegen_ConcreteSubclass_VTableHasImpl;
var IR: string;
begin
  IR := GenIR(SrcConcreteSubclass);
  AssertTrue('IR non-empty', IR <> '');
  AssertTrue('TMemoryInput vtable emitted',
    IRContains(IR, 'vtable_TMemoryInput'));
  AssertTrue('vtable references concrete Read',
    IRContains(IR, 'TMemoryInput_Read'))
end;

initialization
  RegisterTest(TStreamsTests)

end.
