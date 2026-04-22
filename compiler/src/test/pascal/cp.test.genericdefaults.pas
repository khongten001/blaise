unit cp.test.genericdefaults;

{$mode objfpc}{$H+}

{ Tests for Generics.Defaults: IEqualityComparer<T>, IComparer<T>, and the
  concrete implementations TIntegerEqualityComparer and TIntegerComparer.
  Exercises generic interface parsing, semantic instantiation, and codegen. }

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  uLexer, uParser, uAST, uSymbolTable, uSemantic, uCodeGenQBE;

type
  TGenericDefaultsTests = class(TTestCase)
  private
    function ParseSrc(const ASrc: string): TProgram;
    function AnalyseSrc(const ASrc: string): TProgram;
    function GenIR(const ASrc: string): string;
  published
    { ------------------------------------------------------------------ }
    { Parser                                                               }
    { ------------------------------------------------------------------ }
    procedure TestParse_IEqualityComparer_IsGenericInterfaceDef;
    procedure TestParse_IComparer_IsGenericInterfaceDef;
    procedure TestParse_TIntegerEqualityComparer_ImplementsGenericIntf;

    { ------------------------------------------------------------------ }
    { Semantic                                                             }
    { ------------------------------------------------------------------ }
    procedure TestSemantic_IEqualityComparer_Integer_Instantiates;
    procedure TestSemantic_IComparer_Integer_Instantiates;
    procedure TestSemantic_TIntegerEqualityComparer_ImplementsOK;
    procedure TestSemantic_TIntegerComparer_ImplementsOK;
    procedure TestSemantic_Var_IEqualityComparer_Integer_IsInterface;

    { ------------------------------------------------------------------ }
    { Codegen                                                              }
    { ------------------------------------------------------------------ }
    procedure TestCodegen_TIntegerEqualityComparer_TypeinfoEmitted;
    procedure TestCodegen_IEqualityComparer_Integer_TypeinfoEmitted;
    procedure TestCodegen_TIntegerEqualityComparer_ItabEmitted;
    procedure TestCodegen_TIntegerComparer_ItabEmitted;
    procedure TestCodegen_EqualityDispatch_IndirectCall;
  end;

implementation

{ ------------------------------------------------------------------ }
{ Source constants                                                      }
{ ------------------------------------------------------------------ }

const
  SrcIEqualityComparerDecl =
    'program P;'                                                   + LineEnding +
    'type'                                                         + LineEnding +
    '  IEqualityComparer<T> = interface'                           + LineEnding +
    '    function Equals(A, B: T): Boolean;'                       + LineEnding +
    '    function GetHashCode(Value: T): Integer;'                 + LineEnding +
    '  end;'                                                       + LineEnding +
    'begin end.';

  SrcIComparerDecl =
    'program P;'                                                   + LineEnding +
    'type'                                                         + LineEnding +
    '  IComparer<T> = interface'                                   + LineEnding +
    '    function Compare(A, B: T): Integer;'                      + LineEnding +
    '  end;'                                                       + LineEnding +
    'begin end.';

  SrcTIntegerEqualityComparerDecl =
    'program P;'                                                   + LineEnding +
    'type'                                                         + LineEnding +
    '  IEqualityComparer<T> = interface'                           + LineEnding +
    '    function Equals(A, B: T): Boolean;'                       + LineEnding +
    '    function GetHashCode(Value: T): Integer;'                 + LineEnding +
    '  end;'                                                       + LineEnding +
    '  TIntegerEqualityComparer = class(IEqualityComparer<Integer>)' + LineEnding +
    '    function Equals(A, B: Integer): Boolean;'                 + LineEnding +
    '    begin'                                                     + LineEnding +
    '      Result := A = B'                                        + LineEnding +
    '    end;'                                                     + LineEnding +
    '    function GetHashCode(Value: Integer): Integer;'           + LineEnding +
    '    begin'                                                     + LineEnding +
    '      Result := Value'                                        + LineEnding +
    '    end;'                                                     + LineEnding +
    '  end;'                                                       + LineEnding +
    'begin end.';

  SrcTIntegerComparerDecl =
    'program P;'                                                   + LineEnding +
    'type'                                                         + LineEnding +
    '  IComparer<T> = interface'                                   + LineEnding +
    '    function Compare(A, B: T): Integer;'                      + LineEnding +
    '  end;'                                                       + LineEnding +
    '  TIntegerComparer = class(IComparer<Integer>)'               + LineEnding +
    '    function Compare(A, B: Integer): Integer;'                + LineEnding +
    '    begin'                                                     + LineEnding +
    '      if A < B then'                                          + LineEnding +
    '        Result := -1'                                         + LineEnding +
    '      else if A > B then'                                     + LineEnding +
    '        Result := 1'                                          + LineEnding +
    '      else'                                                   + LineEnding +
    '        Result := 0'                                          + LineEnding +
    '    end;'                                                     + LineEnding +
    '  end;'                                                       + LineEnding +
    'begin end.';

  SrcVarIEqualityComparerInteger =
    'program P;'                                                   + LineEnding +
    'type'                                                         + LineEnding +
    '  IEqualityComparer<T> = interface'                           + LineEnding +
    '    function Equals(A, B: T): Boolean;'                       + LineEnding +
    '    function GetHashCode(Value: T): Integer;'                 + LineEnding +
    '  end;'                                                       + LineEnding +
    '  TIntegerEqualityComparer = class(IEqualityComparer<Integer>)' + LineEnding +
    '    function Equals(A, B: Integer): Boolean;'                 + LineEnding +
    '    begin'                                                     + LineEnding +
    '      Result := A = B'                                        + LineEnding +
    '    end;'                                                     + LineEnding +
    '    function GetHashCode(Value: Integer): Integer;'           + LineEnding +
    '    begin'                                                     + LineEnding +
    '      Result := Value'                                        + LineEnding +
    '    end;'                                                     + LineEnding +
    '  end;'                                                       + LineEnding +
    'var'                                                          + LineEnding +
    '  C: IEqualityComparer<Integer>;'                             + LineEnding +
    '  OK: Boolean;'                                               + LineEnding +
    'begin'                                                        + LineEnding +
    '  C  := TIntegerEqualityComparer.Create;'                     + LineEnding +
    '  OK := C.Equals(1, 1)'                                       + LineEnding +
    'end.';

{ ------------------------------------------------------------------ }
{ Helpers                                                              }
{ ------------------------------------------------------------------ }

function TGenericDefaultsTests.ParseSrc(const ASrc: string): TProgram;
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

function TGenericDefaultsTests.AnalyseSrc(const ASrc: string): TProgram;
var
  SA: TSemanticAnalyser;
begin
  Result := ParseSrc(ASrc);
  SA     := TSemanticAnalyser.Create;
  try
    SA.Analyse(Result);
  finally
    SA.Free;
  end;
end;

function TGenericDefaultsTests.GenIR(const ASrc: string): string;
var
  CG:   TCodeGenQBE;
  Prog: TProgram;
begin
  Prog := AnalyseSrc(ASrc);
  CG   := TCodeGenQBE.Create;
  try
    CG.Generate(Prog);
    Result := CG.GetOutput;
  finally
    CG.Free;
    Prog.Free;
  end;
end;

{ ------------------------------------------------------------------ }
{ Parser tests                                                         }
{ ------------------------------------------------------------------ }

procedure TGenericDefaultsTests.TestParse_IEqualityComparer_IsGenericInterfaceDef;
var
  Prog: TProgram;
  TD:   TTypeDecl;
begin
  Prog := ParseSrc(SrcIEqualityComparerDecl);
  try
    AssertEquals('One type decl', 1, Prog.Block.TypeDecls.Count);
    TD := TTypeDecl(Prog.Block.TypeDecls[0]);
    AssertTrue('Def is TGenericInterfaceDef', TD.Def is TGenericInterfaceDef);
  finally
    Prog.Free;
  end;
end;

procedure TGenericDefaultsTests.TestParse_IComparer_IsGenericInterfaceDef;
var
  Prog: TProgram;
  TD:   TTypeDecl;
begin
  Prog := ParseSrc(SrcIComparerDecl);
  try
    AssertEquals('One type decl', 1, Prog.Block.TypeDecls.Count);
    TD := TTypeDecl(Prog.Block.TypeDecls[0]);
    AssertTrue('Def is TGenericInterfaceDef', TD.Def is TGenericInterfaceDef);
  finally
    Prog.Free;
  end;
end;

procedure TGenericDefaultsTests.TestParse_TIntegerEqualityComparer_ImplementsGenericIntf;
var
  Prog: TProgram;
  TD:   TTypeDecl;
  CD:   TClassTypeDef;
begin
  Prog := ParseSrc(SrcTIntegerEqualityComparerDecl);
  try
    { Second type decl is TIntegerEqualityComparer }
    TD := TTypeDecl(Prog.Block.TypeDecls[1]);
    AssertTrue('Is class', TD.Def is TClassTypeDef);
    CD := TClassTypeDef(TD.Def);
    AssertTrue('Has IEqualityComparer<Integer>',
      (CD.ParentName = 'IEqualityComparer<Integer>') or
      (CD.ImplementsNames.IndexOf('IEqualityComparer<Integer>') >= 0));
  finally
    Prog.Free;
  end;
end;

{ ------------------------------------------------------------------ }
{ Semantic tests                                                        }
{ ------------------------------------------------------------------ }

procedure TGenericDefaultsTests.TestSemantic_IEqualityComparer_Integer_Instantiates;
var
  Prog: TProgram;
begin
  Prog := AnalyseSrc(SrcTIntegerEqualityComparerDecl);
  Prog.Free;
end;

procedure TGenericDefaultsTests.TestSemantic_IComparer_Integer_Instantiates;
var
  Prog: TProgram;
begin
  Prog := AnalyseSrc(SrcTIntegerComparerDecl);
  Prog.Free;
end;

procedure TGenericDefaultsTests.TestSemantic_TIntegerEqualityComparer_ImplementsOK;
var
  Prog: TProgram;
begin
  Prog := AnalyseSrc(SrcTIntegerEqualityComparerDecl);
  Prog.Free;
end;

procedure TGenericDefaultsTests.TestSemantic_TIntegerComparer_ImplementsOK;
var
  Prog: TProgram;
begin
  Prog := AnalyseSrc(SrcTIntegerComparerDecl);
  Prog.Free;
end;

procedure TGenericDefaultsTests.TestSemantic_Var_IEqualityComparer_Integer_IsInterface;
var
  Prog: TProgram;
  VD:   TVarDecl;
begin
  Prog := AnalyseSrc(SrcVarIEqualityComparerInteger);
  try
    VD := TVarDecl(Prog.Block.Decls[0]);
    AssertEquals('Variable type is tyInterface',
      Ord(tyInterface), Ord(VD.ResolvedType.Kind));
  finally
    Prog.Free;
  end;
end;

{ ------------------------------------------------------------------ }
{ Codegen tests                                                         }
{ ------------------------------------------------------------------ }

procedure TGenericDefaultsTests.TestCodegen_TIntegerEqualityComparer_TypeinfoEmitted;
var
  IR: string;
begin
  IR := GenIR(SrcTIntegerEqualityComparerDecl);
  AssertTrue('Typeinfo for TIntegerEqualityComparer emitted',
    Pos('typeinfo_TIntegerEqualityComparer', IR) > 0);
end;

procedure TGenericDefaultsTests.TestCodegen_IEqualityComparer_Integer_TypeinfoEmitted;
var
  IR: string;
begin
  IR := GenIR(SrcTIntegerEqualityComparerDecl);
  AssertTrue('Typeinfo for IEqualityComparer_Integer emitted',
    Pos('typeinfo_IEqualityComparer_Integer', IR) > 0);
end;

procedure TGenericDefaultsTests.TestCodegen_TIntegerEqualityComparer_ItabEmitted;
var
  IR: string;
begin
  IR := GenIR(SrcTIntegerEqualityComparerDecl);
  AssertTrue('Itab for TIntegerEqualityComparer/IEqualityComparer_Integer emitted',
    Pos('itab_TIntegerEqualityComparer_IEqualityComparer_Integer', IR) > 0);
end;

procedure TGenericDefaultsTests.TestCodegen_TIntegerComparer_ItabEmitted;
var
  IR: string;
begin
  IR := GenIR(SrcTIntegerComparerDecl);
  AssertTrue('Itab for TIntegerComparer/IComparer_Integer emitted',
    Pos('itab_TIntegerComparer_IComparer_Integer', IR) > 0);
end;

procedure TGenericDefaultsTests.TestCodegen_EqualityDispatch_IndirectCall;
var
  IR: string;
begin
  IR := GenIR(SrcVarIEqualityComparerInteger);
  AssertTrue('Interface dispatch emits indirect call',
    Pos('call %', IR) > 0);
end;

initialization
  RegisterTest(TGenericDefaultsTests);

end.
