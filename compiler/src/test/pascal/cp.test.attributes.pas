{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit cp.test.attributes;

{ Tests for the custom attribute system.

  Covers:
    * Parser: [Attr] syntax before class declarations stored on TClassTypeDef
    * Semantic: suffix convention; unknown attribute error; [Weak] unaffected
    * Codegen: 8-slot typeinfo; $attrs_ table format; HasClassAttribute IR
    * E2E: HasClassAttribute returns correct Boolean at runtime }

interface

uses
  Classes, SysUtils, Process, blaise.testing,
  uLexer, uParser, uAST, uSymbolTable, uSemantic, blaise.codegen.qbe,
  cp.test.rtllink;

function ProjectRootAttr: string;
function RunCmdAttr(const AExe: string; const AArgs: array of string): Integer;

type
  TCustomAttributeTests = class(TTestCase)
  private
    function ParseSrc(const ASrc: string): TProgram;
    function AnalyseSrc(const ASrc: string): TProgram;
    function GenIR(const ASrc: string): string;
    function CompileAndRun(const ASrc: string): string;
  published
    { Parser }
    procedure TestParse_AttributeOnClass_StoredOnClassTypeDef;
    procedure TestParse_MultipleAttributes_BothStored;
    procedure TestParse_AttributeWithArgs_NameStored;
    procedure TestParse_AttributeArgs_CapturedAsExprs;
    procedure TestParse_MethodAttribute_StoredOnMethodDecl;
    procedure TestParse_NoAttribute_EmptyList;
    procedure TestParse_AttributeOnGenericClass_Stored;

    { Semantic }
    procedure TestSemantic_KnownAttribute_Resolves;
    procedure TestSemantic_SuffixConvention_ThreadedResolvesToThreadedAttribute;
    procedure TestSemantic_UnknownAttribute_RaisesError;
    procedure TestSemantic_UnknownMethodAttribute_RaisesError;
    procedure TestSemantic_WeakOnField_StillWorks;

    { Codegen }
    procedure TestCodegen_TypeInfo_HasNineSlots;
    procedure TestCodegen_NoAttrs_AttrsSlotZero;
    procedure TestCodegen_WithAttrs_AttrsTableEmitted;
    procedure TestCodegen_AttrsTable_PairsWithFactoryThunk;
    procedure TestCodegen_AttrThunk_FunctionEmitted;
    procedure TestCodegen_MethodAttrs_TableEmitted;
    procedure TestCodegen_HasClassAttribute_EmitsRuntimeCall;
    procedure TestCodegen_TCustomAttribute_StubsEmitted;

    { End-to-end }
    procedure TestE2E_HasClassAttribute_True;
    procedure TestE2E_HasClassAttribute_False;
    procedure TestE2E_HasClassAttribute_InheritedFromParent;
    procedure TestE2E_HasClassAttribute_MultipleAttributes;
    procedure TestE2E_GetClassAttribute_ReifiesConstructorArgs;
    procedure TestE2E_GetClassAttribute_AbsentReturnsNil;
    procedure TestE2E_MethodAttributes_HasGetCountAt;
  end;

implementation

function TCustomAttributeTests.ParseSrc(const ASrc: string): TProgram;
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

function TCustomAttributeTests.AnalyseSrc(const ASrc: string): TProgram;
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

function TCustomAttributeTests.GenIR(const ASrc: string): string;
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

function ProjectRootAttr: string;
var
  Dir, Parent: string;
  Steps:       Integer;
begin
  Result := GetEnvironmentVariable('BLAISE_PROJECT_ROOT');
  if Result <> '' then
  begin
    Result := IncludeTrailingPathDelimiter(Result);
    Exit;
  end;
  Dir := GetCurrentDir();
  for Steps := 0 to 6 do
  begin
    if FileExists(IncludeTrailingPathDelimiter(Dir) + 'vendor/qbe/qbe') then
    begin
      Result := IncludeTrailingPathDelimiter(Dir);
      Exit;
    end;
    Parent := ExtractFileDir(Dir);
    if (Parent = '') or (Parent = Dir) then Break;
    Dir := Parent;
  end;
  Result := IncludeTrailingPathDelimiter(GetCurrentDir());
end;

function RunCmdAttr(const AExe: string; const AArgs: array of string): Integer;
var
  Proc: TProcess;
  I:    Integer;
  Chunk: string;
begin
  Proc := TProcess.Create(nil);
  try
    Proc.Executable := AExe;
    for I := Low(AArgs) to High(AArgs) do
      Proc.Parameters.Add(AArgs[I]);
    Proc.Execute();
    repeat Chunk := Proc.ReadOutput(); until (Chunk = '') and not Proc.Running;
    Proc.WaitOnExit();
    Result := Proc.ExitCode;
  finally
    Proc.Free();
  end;
end;

function TCustomAttributeTests.CompileAndRun(const ASrc: string): string;
var
  IR:                       string;
  Root:                     string;
  QBE, Scratch:             string;
  IRFile, AsmFile, BinFile: string;
  Lst:                      TStringList;
  Proc:                     TProcess;
  Chunk:                    string;
begin
  Result := '';
  Root   := ProjectRootAttr();
  QBE    := Root + 'vendor/qbe/qbe';
  if not RTLLinkToolchainAvailable(Root) then
  begin
    Result := '<toolchain-missing>';
    Exit;
  end;
  Scratch := Root + 'compiler/target/test-attributes';
  ForceDirectories(Scratch);
  IRFile  := IncludeTrailingPathDelimiter(Scratch) + 'case.ssa';
  AsmFile := IncludeTrailingPathDelimiter(Scratch) + 'case.s';
  BinFile := IncludeTrailingPathDelimiter(Scratch) + 'case.bin';

  IR := GenIR(ASrc);
  Lst := TStringList.Create();
  try
    Lst.Text := IR;
    Lst.SaveToFile(IRFile);
  finally
    Lst.Free();
  end;

  if RunCmdAttr(QBE, ['-o', AsmFile, IRFile]) <> 0 then
  begin
    Result := '<qbe-failed>';
    Exit;
  end;

  if LinkProgramWithRTL(Root, AsmFile, BinFile) <> 0 then
  begin
    Result := '<link-failed>';
    Exit;
  end;

  Proc := TProcess.Create(nil);
  try
    Proc.Executable := BinFile;
    Proc.Execute();
    Result := '';
    repeat
      Chunk := Proc.ReadOutput();
      Result := Result + Chunk;
    until (Chunk = '') and not Proc.Running;
    Proc.WaitOnExit();
  finally
    Proc.Free();
  end;
end;

{ ------------------------------------------------------------------ }
{ Parser tests                                                         }
{ ------------------------------------------------------------------ }

procedure TCustomAttributeTests.TestParse_AttributeOnClass_StoredOnClassTypeDef;
const
  Src =
    '''
    program P;
    type
      MyAttr = class(TCustomAttribute) end;
      [MyAttr]
      TFoo = class(TObject) end;
    begin end.
    ''';
var
  Prog: TProgram;
  TD:   TTypeDecl;
  CD:   TClassTypeDef;
begin
  Prog := ParseSrc(Src);
  try
    AssertEquals('two type decls', 2, Prog.Block.TypeDecls.Count);
    TD := TTypeDecl(Prog.Block.TypeDecls.Items[1]);
    AssertEquals('second type is TFoo', 'TFoo', TD.Name);
    AssertTrue('def is TClassTypeDef', TD.Def is TClassTypeDef);
    CD := TClassTypeDef(TD.Def);
    AssertEquals('one attribute stored', 1, CD.Attributes.Count);
    AssertEquals('attribute name', 'MyAttr', CD.Attributes.Strings[0]);
  finally
    Prog.Free();
  end;
end;

procedure TCustomAttributeTests.TestParse_MultipleAttributes_BothStored;
const
  Src =
    '''
    program P;
    type
      [AttrA]
      [AttrB]
      TFoo = class(TObject) end;
    begin end.
    ''';
var
  Prog: TProgram;
  CD:   TClassTypeDef;
begin
  Prog := ParseSrc(Src);
  try
    CD := TClassTypeDef(TTypeDecl(Prog.Block.TypeDecls.Items[0]).Def);
    AssertEquals('two attributes stored', 2, CD.Attributes.Count);
    AssertEquals('first attr', 'AttrA', CD.Attributes.Strings[0]);
    AssertEquals('second attr', 'AttrB', CD.Attributes.Strings[1]);
  finally
    Prog.Free();
  end;
end;

procedure TCustomAttributeTests.TestParse_AttributeWithArgs_NameStored;
const
  Src =
    '''
    program P;
    type
      [MyAttr(42, 'hello')]
      TFoo = class(TObject) end;
    begin end.
    ''';
var
  Prog: TProgram;
  CD:   TClassTypeDef;
begin
  Prog := ParseSrc(Src);
  try
    CD := TClassTypeDef(TTypeDecl(Prog.Block.TypeDecls.Items[0]).Def);
    AssertEquals('one attribute stored', 1, CD.Attributes.Count);
    AssertEquals('attribute name', 'MyAttr', CD.Attributes.Strings[0]);
  finally
    Prog.Free();
  end;
end;

procedure TCustomAttributeTests.TestParse_AttributeArgs_CapturedAsExprs;
const
  Src =
    '''
    program P;
    type
      [MyAttr(42, 'hello')]
      TFoo = class(TObject) end;
    begin end.
    ''';
var
  Prog: TProgram;
  CD:   TClassTypeDef;
  AU:   TAttributeUse;
begin
  Prog := ParseSrc(Src);
  try
    CD := TClassTypeDef(TTypeDecl(Prog.Block.TypeDecls.Items[0]).Def);
    AssertEquals('one attribute use captured', 1, CD.AttrUses.Count);
    AU := TAttributeUse(CD.AttrUses.Items[0]);
    AssertEquals('use name', 'MyAttr', AU.Name);
    AssertEquals('two argument expressions', 2, AU.Args.Count);
    AssertTrue('first arg is an integer literal',
      TObject(AU.Args.Items[0]) is TIntLiteral);
    AssertTrue('second arg is a string literal',
      TObject(AU.Args.Items[1]) is TStringLiteral);
  finally
    Prog.Free();
  end;
end;

procedure TCustomAttributeTests.TestParse_MethodAttribute_StoredOnMethodDecl;
const
  Src =
    '''
    program P;
    type
      TFoo = class(TObject)
      published
        [MyAttr('x')]
        [Other]
        procedure Run;
      end;
    begin end.
    ''';
var
  Prog: TProgram;
  CD:   TClassTypeDef;
  MD:   TMethodDecl;
begin
  Prog := ParseSrc(Src);
  try
    CD := TClassTypeDef(TTypeDecl(Prog.Block.TypeDecls.Items[0]).Def);
    AssertEquals('one method parsed', 1, CD.Methods.Count);
    MD := TMethodDecl(CD.Methods.Items[0]);
    AssertTrue('method is published', MD.IsPublished);
    AssertEquals('two attribute uses on the method', 2, MD.AttrUses.Count);
    AssertEquals('first use name', 'MyAttr',
      TAttributeUse(MD.AttrUses.Items[0]).Name);
    AssertEquals('first use arg count', 1,
      TAttributeUse(MD.AttrUses.Items[0]).Args.Count);
    AssertEquals('second use name', 'Other',
      TAttributeUse(MD.AttrUses.Items[1]).Name);
  finally
    Prog.Free();
  end;
end;

procedure TCustomAttributeTests.TestParse_NoAttribute_EmptyList;
const
  Src =
    '''
    program P;
    type
      TFoo = class(TObject) end;
    begin end.
    ''';
var
  Prog: TProgram;
  CD:   TClassTypeDef;
begin
  Prog := ParseSrc(Src);
  try
    CD := TClassTypeDef(TTypeDecl(Prog.Block.TypeDecls.Items[0]).Def);
    AssertEquals('no attributes', 0, CD.Attributes.Count);
  finally
    Prog.Free();
  end;
end;

procedure TCustomAttributeTests.TestParse_AttributeOnGenericClass_Stored;
const
  Src =
    '''
    program P;
    type
      [MyAttr]
      TBox<T> = class(TObject) end;
    begin end.
    ''';
var
  Prog: TProgram;
  GD:   TGenericTypeDef;
begin
  Prog := ParseSrc(Src);
  try
    AssertTrue('def is TGenericTypeDef',
      TTypeDecl(Prog.Block.TypeDecls.Items[0]).Def is TGenericTypeDef);
    GD := TGenericTypeDef(TTypeDecl(Prog.Block.TypeDecls.Items[0]).Def);
    AssertEquals('one attribute on generic class', 1, GD.ClassDef.Attributes.Count);
    AssertEquals('attribute name', 'MyAttr', GD.ClassDef.Attributes.Strings[0]);
  finally
    Prog.Free();
  end;
end;

{ ------------------------------------------------------------------ }
{ Semantic tests                                                        }
{ ------------------------------------------------------------------ }

procedure TCustomAttributeTests.TestSemantic_KnownAttribute_Resolves;
const
  Src =
    '''
    program P;
    type
      MyAttr = class(TCustomAttribute) end;
      [MyAttr]
      TFoo = class(TObject) end;
    begin end.
    ''';
var Prog: TProgram;
begin
  Prog := AnalyseSrc(Src);
  Prog.Free();
  AssertTrue('no semantic error raised', True);
end;

procedure TCustomAttributeTests.TestSemantic_SuffixConvention_ThreadedResolvesToThreadedAttribute;
const
  Src =
    '''
    program P;
    type
      ThreadedAttribute = class(TCustomAttribute) end;
      [Threaded]
      TFoo = class(TObject) end;
    begin end.
    ''';
var Prog: TProgram;
begin
  Prog := AnalyseSrc(Src);
  Prog.Free();
  AssertTrue('suffix convention resolves [Threaded] to ThreadedAttribute', True);
end;

procedure TCustomAttributeTests.TestSemantic_UnknownAttribute_RaisesError;
const
  Src =
    '''
    program P;
    type
      [NonExistent]
      TFoo = class(TObject) end;
    begin end.
    ''';
var
  Prog: TProgram;
  OK:   Boolean;
begin
  OK := False;
  try
    Prog := AnalyseSrc(Src);
    Prog.Free();
  except
    on E: Exception do
      if Pos('Unknown attribute', E.Message) >= 0 then
        OK := True;
    on E: TObject do
      if Pos('Unknown attribute', E.ClassName) >= 0 then
        OK := True;
  end;
  AssertTrue('unknown attribute raises semantic error', OK);
end;

procedure TCustomAttributeTests.TestSemantic_UnknownMethodAttribute_RaisesError;
const
  Src =
    '''
    program P;
    type
      TFoo = class(TObject)
      published
        [NonExistent]
        procedure Run;
      end;
    procedure TFoo.Run;
    begin
    end;
    begin end.
    ''';
var
  Prog: TProgram;
  OK:   Boolean;
begin
  OK := False;
  try
    Prog := AnalyseSrc(Src);
    Prog.Free();
  except
    on E: Exception do
      if Pos('Unknown attribute', E.Message) >= 0 then
        OK := True;
    on E: TObject do
      if Pos('Unknown attribute', E.ClassName) >= 0 then
        OK := True;
  end;
  AssertTrue('unknown attribute on a method raises semantic error', OK);
end;

procedure TCustomAttributeTests.TestSemantic_WeakOnField_StillWorks;
const
  Src =
    '''
    program P;
    type
      TFoo = class(TObject)
        [Weak]
        FRef: TObject;
      end;
    begin end.
    ''';
var Prog: TProgram;
begin
  Prog := AnalyseSrc(Src);
  Prog.Free();
  AssertTrue('[Weak] on field still resolves correctly', True);
end;

{ ------------------------------------------------------------------ }
{ Codegen tests                                                         }
{ ------------------------------------------------------------------ }

procedure TCustomAttributeTests.TestCodegen_TypeInfo_HasNineSlots;
const
  Src =
    '''
    program P;
    type TFoo = class(TObject) end;
    begin end.
    ''';
var IR: string;
begin
  IR := GenIR(Src);
  AssertTrue('typeinfo emits 9 l-slots (attrs + method-attrs slots = l 0 ' +
             'when no attributes)',
    Pos('$typeinfo_TFoo = { l $typeinfo_TObject, l 0, l $__cn_TFoo + 12, l 0' +
        ', l 8, l $_FieldCleanup_TFoo, l $vtable_TFoo, l 0, l 0 }', IR) > 0);
end;

procedure TCustomAttributeTests.TestCodegen_NoAttrs_AttrsSlotZero;
const
  Src =
    '''
    program P;
    type TFoo = class(TObject) end;
    begin end.
    ''';
var IR: string;
begin
  IR := GenIR(Src);
  AssertTrue('attrs + method-attrs slots are l 0 when no attributes applied',
    Pos(', l $vtable_TFoo, l 0, l 0 }', IR) > 0);
  AssertTrue('no $attrs_TFoo data block emitted', Pos('$attrs_TFoo', IR) < 0);
end;

procedure TCustomAttributeTests.TestCodegen_WithAttrs_AttrsTableEmitted;
const
  Src =
    '''
    program P;
    type
      MyAttr = class(TCustomAttribute) end;
      [MyAttr]
      TFoo = class(TObject) end;
    begin end.
    ''';
var IR: string;
begin
  IR := GenIR(Src);
  AssertTrue('$attrs_TFoo data block emitted',
    Pos('$attrs_TFoo', IR) > 0);
  AssertTrue('typeinfo refs $attrs_TFoo in slot 7 (method-attrs slot 8 = 0)',
    Pos(', l $vtable_TFoo, l $attrs_TFoo, l 0 }', IR) > 0);
end;

procedure TCustomAttributeTests.TestCodegen_AttrsTable_PairsWithFactoryThunk;
const
  Src =
    '''
    program P;
    type
      MyAttr = class(TCustomAttribute) end;
      [MyAttr]
      TFoo = class(TObject) end;
    begin end.
    ''';
var IR: string;
begin
  IR := GenIR(Src);
  AssertTrue('attrs table has count=1 and (typeinfo, thunk) pair for MyAttr',
    Pos('$attrs_TFoo = { l 1, l $typeinfo_MyAttr, l $__attr_TFoo_c0 }', IR) > 0);
end;

procedure TCustomAttributeTests.TestCodegen_AttrThunk_FunctionEmitted;
const
  Src =
    '''
    program P;
    type
      MyAttr = class(TCustomAttribute) end;
      [MyAttr]
      TFoo = class(TObject) end;
    begin end.
    ''';
var IR: string;
begin
  IR := GenIR(Src);
  AssertTrue('factory thunk $__attr_TFoo_c0 emitted as a function',
    Pos('$__attr_TFoo_c0(', IR) > 0);
end;

procedure TCustomAttributeTests.TestCodegen_MethodAttrs_TableEmitted;
const
  Src =
    '''
    program P;
    type
      MyAttr = class(TCustomAttribute) end;
      TFoo = class(TObject)
      published
        [MyAttr]
        procedure Run;
      end;
    procedure TFoo.Run;
    begin
    end;
    begin end.
    ''';
var IR: string;
begin
  IR := GenIR(Src);
  AssertTrue('$methattrs_TFoo data block emitted with count=1',
    Pos('$methattrs_TFoo = { l 1', IR) > 0);
  AssertTrue('entry is (method name, attr typeinfo, thunk) triple',
    Pos('l $__mn_TFoo_Run + 12, l $typeinfo_MyAttr, l $__attr_TFoo_m', IR) > 0);
  AssertTrue('typeinfo refs $methattrs_TFoo in slot 8',
    Pos(', l $methattrs_TFoo }', IR) > 0);
end;

procedure TCustomAttributeTests.TestCodegen_HasClassAttribute_EmitsRuntimeCall;
const
  Src =
    '''
    program P;
    type
      ThreadedAttribute = class(TCustomAttribute) end;
      [Threaded]
      TFoo = class(TObject) end;
    var B: Boolean;
    begin
      B := HasClassAttribute(TFoo, ThreadedAttribute)
    end.
    ''';
var IR: string;
begin
  IR := GenIR(Src);
  AssertTrue('HasClassAttribute emits call to $_HasClassAttribute',
    Pos('call $_HasClassAttribute', IR) > 0);
end;

procedure TCustomAttributeTests.TestCodegen_TCustomAttribute_StubsEmitted;
const
  Src =
    '''
    program P;
    begin end.
    ''';
var IR: string;
begin
  IR := GenIR(Src);
  AssertTrue('$typeinfo_TCustomAttribute emitted unconditionally',
    Pos('$typeinfo_TCustomAttribute', IR) > 0);
  AssertTrue('$vtable_TCustomAttribute emitted unconditionally',
    Pos('$vtable_TCustomAttribute', IR) > 0);
  AssertTrue('$_FieldCleanup_TCustomAttribute emitted unconditionally',
    Pos('$_FieldCleanup_TCustomAttribute', IR) > 0);
end;

{ ------------------------------------------------------------------ }
{ End-to-end tests                                                      }
{ ------------------------------------------------------------------ }

procedure TCustomAttributeTests.TestE2E_HasClassAttribute_True;
const
  Src =
    '''
    program P;
    type
      ThreadedAttribute = class(TCustomAttribute) end;
      [Threaded]
      TFoo = class(TObject) end;
    begin
      WriteLn(HasClassAttribute(TFoo, ThreadedAttribute))
    end.
    ''';
var Output: string;
begin
  Output := CompileAndRun(Src);
  if Output = '<toolchain-missing>' then begin Ignore('toolchain unavailable'); Exit end;
  AssertEquals('stdout', 'True' + #10, Output);
end;

procedure TCustomAttributeTests.TestE2E_HasClassAttribute_False;
const
  Src =
    '''
    program P;
    type
      ThreadedAttribute = class(TCustomAttribute) end;
      TBar = class(TObject) end;
    begin
      WriteLn(HasClassAttribute(TBar, ThreadedAttribute))
    end.
    ''';
var Output: string;
begin
  Output := CompileAndRun(Src);
  if Output = '<toolchain-missing>' then begin Ignore('toolchain unavailable'); Exit end;
  AssertEquals('stdout', 'False' + #10, Output);
end;

procedure TCustomAttributeTests.TestE2E_HasClassAttribute_InheritedFromParent;
const
  Src =
    '''
    program P;
    type
      ThreadedAttribute = class(TCustomAttribute) end;
      [Threaded]
      TBase = class(TObject) end;
      TChild = class(TBase) end;
    begin
      WriteLn(HasClassAttribute(TBase, ThreadedAttribute));
      WriteLn(HasClassAttribute(TChild, ThreadedAttribute))
    end.
    ''';
var Output: string;
begin
  Output := CompileAndRun(Src);
  if Output = '<toolchain-missing>' then begin Ignore('toolchain unavailable'); Exit end;
  AssertEquals('stdout', 'True' + #10 + 'True' + #10, Output);
end;

procedure TCustomAttributeTests.TestE2E_HasClassAttribute_MultipleAttributes;
const
  Src =
    '''
    program P;
    type
      AttrA = class(TCustomAttribute) end;
      AttrB = class(TCustomAttribute) end;
      [AttrA]
      [AttrB]
      TFoo = class(TObject) end;
    begin
      WriteLn(HasClassAttribute(TFoo, AttrA));
      WriteLn(HasClassAttribute(TFoo, AttrB))
    end.
    ''';
var Output: string;
begin
  Output := CompileAndRun(Src);
  if Output = '<toolchain-missing>' then begin Ignore('toolchain unavailable'); Exit end;
  AssertEquals('stdout', 'True' + #10 + 'True' + #10, Output);
end;

procedure TCustomAttributeTests.TestE2E_GetClassAttribute_ReifiesConstructorArgs;
const
  Src =
    '''
    program P;
    type
      TestCaseAttribute = class(TCustomAttribute)
      private
        FName: string;
        FArgs: string;
      public
        constructor Create(AName, AArgs: string);
        property Name: string read FName;
        property Args: string read FArgs;
      end;
      [TestCase('simple', '2,2,4')]
      TFoo = class(TObject) end;
    constructor TestCaseAttribute.Create(AName, AArgs: string);
    begin
      FName := AName;
      FArgs := AArgs;
    end;
    var
      A:  TObject;
      TC: TestCaseAttribute;
    begin
      A := GetClassAttribute(TFoo, TestCaseAttribute);
      if A = nil then
        WriteLn('nil')
      else
      begin
        TC := TestCaseAttribute(A);
        WriteLn(TC.Name + '|' + TC.Args)
      end
    end.
    ''';
var Output: string;
begin
  Output := CompileAndRun(Src);
  if Output = '<toolchain-missing>' then begin Ignore('toolchain unavailable'); Exit end;
  AssertEquals('stdout', 'simple|2,2,4' + #10, Output);
end;

procedure TCustomAttributeTests.TestE2E_GetClassAttribute_AbsentReturnsNil;
const
  Src =
    '''
    program P;
    type
      MarkAttribute = class(TCustomAttribute) end;
      TBar = class(TObject) end;
    var
      A: TObject;
    begin
      A := GetClassAttribute(TBar, MarkAttribute);
      if A = nil then
        WriteLn('nil')
      else
        WriteLn('instance')
    end.
    ''';
var Output: string;
begin
  Output := CompileAndRun(Src);
  if Output = '<toolchain-missing>' then begin Ignore('toolchain unavailable'); Exit end;
  AssertEquals('stdout', 'nil' + #10, Output);
end;

procedure TCustomAttributeTests.TestE2E_MethodAttributes_HasGetCountAt;
const
  Src =
    '''
    program P;
    type
      MarkAttribute = class(TCustomAttribute)
      private
        FTag: string;
      public
        constructor Create(ATag: string);
        property Tag: string read FTag;
      end;
      TFoo = class(TObject)
      published
        [Mark('alpha')]
        [Mark('beta')]
        procedure Run;
      end;
    constructor MarkAttribute.Create(ATag: string);
    begin
      FTag := ATag;
    end;
    procedure TFoo.Run;
    begin
    end;
    var
      A: TObject;
      M: MarkAttribute;
    begin
      WriteLn(MethodAttributeCount(TFoo, 'Run'));
      WriteLn(HasMethodAttribute(TFoo, 'Run', MarkAttribute));
      WriteLn(HasMethodAttribute(TFoo, 'Missing', MarkAttribute));
      A := GetMethodAttributeAt(TFoo, 'Run', 1);
      M := MarkAttribute(A);
      WriteLn(M.Tag);
      A := GetMethodAttribute(TFoo, 'Run', MarkAttribute);
      M := MarkAttribute(A);
      WriteLn(M.Tag)
    end.
    ''';
var Output: string;
begin
  Output := CompileAndRun(Src);
  if Output = '<toolchain-missing>' then begin Ignore('toolchain unavailable'); Exit end;
  AssertEquals('stdout',
    '2' + #10 + 'True' + #10 + 'False' + #10 + 'beta' + #10 + 'alpha' + #10,
    Output);
end;

initialization
  RegisterTest(TCustomAttributeTests);

end.
