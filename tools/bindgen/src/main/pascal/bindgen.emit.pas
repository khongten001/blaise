{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

{ bindgen — C declaration model → Blaise binding unit source.

  Emission order: a mapping pre-pass walks the whole model so the type
  mapper discovers every synthetic pointer alias, then the type section
  is emitted with those aliases FIRST (Blaise allows forward pointer
  declarations — verified) followed by the type declarations in their
  original C order, which C's declare-before-use rule makes valid
  Pascal order too.  Enum members become consts; each C function
  becomes a cdecl external routine that names both the library and the
  C symbol.

  Deliberate slice-1 gaps (marked in the output):
    - variadic functions are skipped (not callable from Blaise)
    - unions get a placeholder record usable only through pointers
    - function-pointer typedefs degrade to untyped Pointer }

unit Bindgen.Emit;

interface

uses
  SysUtils, StrUtils, generics.collections, classes,
  Bindgen.Model, Bindgen.TypeMap, Bindgen.Layout;

{ Render AModel as a complete Blaise unit named AUnitName whose external
  declarations link against ALibName. }
function EmitBinding(AModel: TCModel; const AUnitName, ALibName: string): string;

{ Make a C identifier safe as a Blaise identifier: reserved words get a
  trailing underscore; an empty name becomes 'a<index>'. }
function SanitiseIdent(const AName: string; AIndex: Integer): string;

implementation

const
  { The Blaise lexer's keyword set (uLexer.MapKeyword), plus 'string'
    and 'result' which collide with the builtin type / function-result
    variable.  Space-delimited for a simple membership test. }
  ReservedWords =
    ' PROGRAM USES VAR THREADVAR BEGIN END ASM TYPE RECORD PACKED CLASS' +
    ' PROCEDURE FUNCTION DIV MOD IF THEN ELSE WHILE DO FOR TO DOWNTO' +
    ' REPEAT UNTIL TRY FINALLY EXCEPT RAISE NIL UNIT INTERFACE' +
    ' IMPLEMENTATION VIRTUAL OVERRIDE IS AS AND OR NOT EXIT BREAK CONTINUE' +
    ' CASE OF ARRAY SET IN SHL SHR SAR XOR CONST OUT CONSTRUCTOR' +
    ' DESTRUCTOR INHERITED INITIALIZATION FINALIZATION STRING RESULT ';

function IsReservedWord(const AName: string): Boolean;
begin
  Result := Pos(' ' + UpperCase(AName) + ' ', ReservedWords) >= 0;
end;

function SanitiseIdent(const AName: string; AIndex: Integer): string;
begin
  if AName = '' then
  begin
    Result := 'a' + IntToStr(AIndex);
    Exit;
  end;
  Result := AName;
  if IsReservedWord(Result) then
    Result := Result + '_';
end;

procedure PreMapModel(AModel: TCModel; AMapper: TTypeMapper);
var
  I, J: Integer;
  R: TCRecord;
  F: TCFunction;
begin
  { Walk everything once so the mapper registers every pointer alias
    before any line is emitted. }
  for I := 0 to AModel.Typedefs.Count - 1 do
    AMapper.Map(AModel.Typedefs[I].CType);
  for I := 0 to AModel.Records.Count - 1 do
  begin
    R := AModel.Records[I];
    for J := 0 to R.Fields.Count - 1 do
      AMapper.Map(R.Fields[J].CType);
  end;
  for I := 0 to AModel.Functions.Count - 1 do
  begin
    F := AModel.Functions[I];
    if F.IsVariadic then Continue;
    AMapper.Map(F.ReturnCType);
    for J := 0 to F.Params.Count - 1 do
      AMapper.Map(F.Params[J].CType);
  end;
end;

{ A C union becomes a record with a single 'raw' array of its exact
  byte size, so by-value use (XEvent!) reserves the right amount of
  stack.  UInt64 elements when the size allows carry the union's usual
  8-byte alignment; member access is by pointer cast until proper
  variant emission lands. }
procedure EmitUnion(R: TCRecord; AModel: TCModel; ATypeLines: TStringList);
var
  Size, Align: Integer;
  J: Integer;
  Members: string;
begin
  if not RecordSizeAlign(AModel, R, Size, Align) then
  begin
    ATypeLines.Add('  ' + R.Name + ' = record end; { TODO: C union of ' +
      'unknown size — placeholder, only valid through pointers }');
    Exit;
  end;
  Members := '';
  for J := 0 to R.Fields.Count - 1 do
  begin
    if J > 0 then Members := Members + ', ';
    Members := Members + R.Fields[J].Name;
  end;
  ATypeLines.Add('  ' + R.Name + ' = record { C union (' +
    IntToStr(Size) + ' bytes): ' + Members + ' }');
  if (Size mod 8) = 0 then
    ATypeLines.Add('    raw: array[0..' + IntToStr((Size div 8) - 1) +
      '] of UInt64;')
  else
    ATypeLines.Add('    raw: array[0..' + IntToStr(Size - 1) + '] of Byte;');
  ATypeLines.Add('  end;');
end;

procedure EmitRecord(R: TCRecord; AModel: TCModel; AMapper: TTypeMapper;
  ATypeLines: TStringList);
var
  J: Integer;
begin
  if R.Name = '' then Exit;  { anonymous and never typedef-named }
  if not R.IsComplete then
  begin
    ATypeLines.Add('  ' + R.Name + ' = record end; { opaque }');
    Exit;
  end;
  if R.IsUnion then
  begin
    EmitUnion(R, AModel, ATypeLines);
    Exit;
  end;
  ATypeLines.Add('  ' + R.Name + ' = record');
  for J := 0 to R.Fields.Count - 1 do
    ATypeLines.Add('    ' + SanitiseIdent(R.Fields[J].Name, J) + ': ' +
      AMapper.Map(R.Fields[J].CType) + ';');
  ATypeLines.Add('  end;');
end;

const
  { Blaise builtin type names (uSymbolTable.RegisterBuiltins) — valid
    type references even though the unit does not declare them. }
  BuiltinTypeNames =
    ' INTEGER INT64 UINT32 CARDINAL UINT64 QWORD PTRUINT SMALLINT INT16' +
    ' WORD UINT16 BYTE BOOLEAN POINTER PCHAR DOUBLE SINGLE ';

function KnownTypeName(ADeclared: TSet<string>; const AName: string): Boolean;
begin
  Result := ADeclared.Contains(UpperCase(AName)) or
    (Pos(' ' + UpperCase(AName) + ' ', BuiltinTypeNames) >= 0);
end;

{ True when AMapped is a bare identifier (not an array/pointer form)
  that no declaration in this unit will satisfy. }
function IsUnresolvedName(ADeclared: TSet<string>; const AMapped: string): Boolean;
begin
  Result := (AMapped <> '') and (Pos(' ', AMapped) < 0) and
    (Pos('^', AMapped) < 0) and (not KnownTypeName(ADeclared, AMapped));
end;

procedure EmitTypedef(T: TCTypedef; AMapper: TTypeMapper;
  ATypeLines: TStringList; ADeclared: TSet<string>);
var
  Mapped: string;
begin
  Mapped := AMapper.Map(T.CType);
  if Mapped = '' then Exit;          { typedef of void — meaningless }
  if Mapped = T.Name then Exit;      { self-alias — record carries it }
  if IsUnresolvedName(ADeclared, Mapped) then
    ATypeLines.Add('  ' + T.Name + ' = Pointer; { unresolved C type ''' +
      T.CType + ''' — declared in a filtered-out header }')
  else if Pos('(*', T.CType) >= 0 then
    ATypeLines.Add('  ' + T.Name + ' = ' + Mapped +
      '; { TODO: C function pointer ' + T.CType + ' }')
  else
    ATypeLines.Add('  ' + T.Name + ' = ' + Mapped + ';');
end;

procedure EmitEnum(E: TCEnum; ATypeLines, AConstLines: TStringList);
var
  J: Integer;
begin
  if E.Name <> '' then
    ATypeLines.Add('  ' + E.Name + ' = Integer;');
  for J := 0 to E.Members.Count - 1 do
    AConstLines.Add('  ' + E.Members[J].Name + ' = ' +
      IntToStr(E.Members[J].Value) + ';');
end;

procedure EmitFunction(F: TCFunction; const ALibName: string;
  AMapper: TTypeMapper; AFuncLines: TStringList);
var
  J: Integer;
  ParamStr: string;
  Ret: string;
  Sig: string;
begin
  if F.IsVariadic then
  begin
    AFuncLines.Add('{ ' + F.Name +
      ': skipped — variadic C functions are not callable from Blaise }');
    Exit;
  end;
  ParamStr := '';
  for J := 0 to F.Params.Count - 1 do
  begin
    if J > 0 then
      ParamStr := ParamStr + '; ';
    ParamStr := ParamStr + SanitiseIdent(F.Params[J].Name, J) + ': ' +
      AMapper.Map(F.Params[J].CType);
  end;
  Ret := AMapper.Map(F.ReturnCType);
  if ParamStr <> '' then
    ParamStr := '(' + ParamStr + ')';
  if Ret = '' then
    Sig := 'procedure ' + F.Name + ParamStr
  else
    Sig := 'function ' + F.Name + ParamStr + ': ' + Ret;
  AFuncLines.Add(Sig + '; cdecl; external ''' + ALibName + ''' name ''' +
    F.Name + ''';');
end;

function EmitBinding(AModel: TCModel; const AUnitName, ALibName: string): string;
var
  Mapper: TTypeMapper;
  Lines: TStringList;
  TypeLines: TStringList;
  ConstLines: TStringList;
  FuncLines: TStringList;
  I: Integer;
  D: TCDecl;
  Declared: TSet<string>;
  Target: string;
begin
  Mapper := TTypeMapper.Create();
  Lines := TStringList.Create();
  TypeLines := TStringList.Create();
  ConstLines := TStringList.Create();
  FuncLines := TStringList.Create();

  PreMapModel(AModel, Mapper);

  { Every name this unit will declare (Pascal is case-insensitive). }
  Declared := TSet<string>.Create();
  for I := 0 to AModel.Records.Count - 1 do
    if AModel.Records[I].Name <> '' then
      Declared.Include(UpperCase(AModel.Records[I].Name));
  for I := 0 to AModel.Typedefs.Count - 1 do
    Declared.Include(UpperCase(AModel.Typedefs[I].Name));
  for I := 0 to AModel.Enums.Count - 1 do
    if AModel.Enums[I].Name <> '' then
      Declared.Include(UpperCase(AModel.Enums[I].Name));
  for I := 0 to Mapper.PtrAliases.Count - 1 do
    Declared.Include(UpperCase(Mapper.PtrAliases[I].Name));

  { Pointer aliases first: forward pointer declarations are legal, so
    this order is always safe regardless of where the targets sit.
    An alias whose target lives in a filtered-out header (e.g. a system
    struct) degrades to an untyped Pointer. }
  for I := 0 to Mapper.PtrAliases.Count - 1 do
  begin
    Target := Mapper.PtrAliases[I].Target;
    if KnownTypeName(Declared, Target) then
      TypeLines.Add('  ' + Mapper.PtrAliases[I].Name + ' = ^' + Target + ';')
    else
      TypeLines.Add('  ' + Mapper.PtrAliases[I].Name +
        ' = Pointer; { unresolved pointee ''' + Target + ''' }');
  end;

  { Remaining declarations in original C order (declare-before-use). }
  for I := 0 to AModel.Decls.Count - 1 do
  begin
    D := AModel.Decls[I];
    if D is TCRecord then
      EmitRecord(TCRecord(D), AModel, Mapper, TypeLines)
    else if D is TCTypedef then
      EmitTypedef(TCTypedef(D), Mapper, TypeLines, Declared)
    else if D is TCEnum then
      EmitEnum(TCEnum(D), TypeLines, ConstLines)
    else if D is TCFunction then
      EmitFunction(TCFunction(D), ALibName, Mapper, FuncLines);
  end;

  { -------- assemble -------- }
  Lines.Add('{ Unit ' + AUnitName + ' — Blaise binding for library ''' +
    ALibName + '''.');
  Lines.Add('  Generated by blaise-bindgen — DO NOT EDIT.');
  Lines.Add('  Regenerate with:  bindgen --header <header.h> --unit ' +
    AUnitName + ' --lib ' + ALibName + ' }');
  Lines.Add('');
  Lines.Add('unit ' + AUnitName + ';');
  Lines.Add('');
  Lines.Add('interface');
  Lines.Add('');
  if TypeLines.Count > 0 then
  begin
    Lines.Add('type');
    for I := 0 to TypeLines.Count - 1 do
      Lines.Add(TypeLines[I]);
    Lines.Add('');
  end;
  if ConstLines.Count > 0 then
  begin
    Lines.Add('const');
    for I := 0 to ConstLines.Count - 1 do
      Lines.Add(ConstLines[I]);
    Lines.Add('');
  end;
  for I := 0 to FuncLines.Count - 1 do
    Lines.Add(FuncLines[I]);
  Lines.Add('');
  Lines.Add('implementation');
  Lines.Add('');
  Lines.Add('end.');

  Result := Lines.Text;
end;

end.
