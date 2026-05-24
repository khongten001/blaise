{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Andrew Haines
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

{ uSemanticImport — registers a previously-exported TUnitInterface into
  a TSymbolTable, mirroring the interface-section side-effects of
  uSemantic.AnalyseUnitForExport without re-running semantic on the
  source unit.

  Pipeline position:
    uSemantic.AnalyseUnitForExport(DepUnit, FTable)   ← legacy path
    uSemanticImport.ImportUnitInterface(Iface, FTable) ← new path

  Both end with the same TSymbolTable state for downstream consumers
  (semantic of the main unit, then codegen).

  Scope of this commit (6c-A):
    * Constants — IntVal/StrVal already evaluated, just register.
    * Variables — interface-section global vars (IsGlobal=True).
    * Enumeration types — and their members as skConstant.
    * Set types over enum bases.
    * Type aliases (simple name → existing type).
    * Free routines — skFunction/skProcedure with resolved params/return.

  Out of scope (deferred to 6c-B/C):
    * Class & record types — vtable, parent, fields, interface impls.
    * Procedural types.
    * Generics.
    * Inline-body wiring (codegen still walks bodies). }

unit uSemanticImport;

interface

uses
  Classes, Contnrs, SysUtils, uAST, uSymbolTable, uUnitInterface;

type
  EImportError = class(Exception);

{ Register everything in AIface into ATable.  ATable must already have
  the dependencies of AIface (the units in AIface.UsedUnits) imported,
  so cross-unit type references can be resolved by simple name lookup
  against ATable.  Builtin types must also be present (RegisterBuiltins). }
procedure ImportUnitInterface(AIface: TUnitInterface; ATable: TSymbolTable);

implementation

{ ----- Type-ref resolution -------------------------------------- }

{ Resolve a TQualTypeRef to a TTypeDesc by name lookup.  After topo-
  order import, every referenced symbol is already in ATable. }
function ResolveTypeName(const ATypeName: string; ATable: TSymbolTable): TTypeDesc;
begin
  if ATypeName = '' then begin Result := nil; Exit; end;
  Result := ATable.FindType(ATypeName);
end;

{ ----- Type-entry registration ---------------------------------- }

procedure RegisterEnum(AEntry: TTypeEntry; ATable: TSymbolTable);
var
  EnumDef:  TEnumTypeDef;
  EnumDesc: TEnumTypeDesc;
  Sym, MSym: TSymbol;
  K: Integer;
  MName: string;
begin
  EnumDef  := TEnumTypeDef(AEntry.Def);
  EnumDesc := ATable.NewEnumType(AEntry.Name);
  for K := 0 to EnumDef.Members.Count - 1 do
  begin
    MName := EnumDef.Members.Strings[K];
    EnumDesc.Members.Add(MName);
    MSym  := TSymbol.Create(MName, skConstant, EnumDesc);
    MSym.ConstValue := EnumDef.OrdinalAt(K);
    if not ATable.Define(MSym) then MSym.Free;
  end;
  Sym := TSymbol.Create(AEntry.Name, skType, EnumDesc);
  if not ATable.Define(Sym) then Sym.Free;
end;

procedure RegisterSet(AEntry: TTypeEntry; ATable: TSymbolTable);
var
  SetDef:   TSetTypeDef;
  BaseSym:  TSymbol;
  SetDesc:  TSetTypeDesc;
  Sym:      TSymbol;
begin
  SetDef := TSetTypeDef(AEntry.Def);
  BaseSym := ATable.Lookup(SetDef.BaseTypeName);
  if (BaseSym = nil) or (BaseSym.Kind <> skType) or
     not (BaseSym.TypeDesc is TEnumTypeDesc) then
    raise EImportError.CreateFmt(
      'Set %s base ''%s'' is not an enum (import order?)',
      [AEntry.Name, SetDef.BaseTypeName]);
  SetDesc := ATable.NewSetType(AEntry.Name, TEnumTypeDesc(BaseSym.TypeDesc));
  Sym := TSymbol.Create(AEntry.Name, skType, SetDesc);
  if not ATable.Define(Sym) then Sym.Free;
end;

procedure RegisterAlias(AEntry: TTypeEntry; ATable: TSymbolTable);
var
  AliasDef:   TTypeAliasDef;
  AliasName:  string;
  BaseSym:    TSymbol;
  BaseType:   TTypeDesc;
  AliasDesc:  TTypeDesc;
  Sym:        TSymbol;
begin
  AliasDef  := TTypeAliasDef(AEntry.Def);
  AliasName := AliasDef.TypeName;
  if (Length(AliasName) > 0) and (AliasName[1] = '^') then
  begin
    BaseSym  := ATable.Lookup(Copy(AliasName, 2, Length(AliasName) - 1));
    BaseType := nil;
    if (BaseSym <> nil) and (BaseSym.Kind = skType) then
      BaseType := BaseSym.TypeDesc;
    AliasDesc := ATable.NewPointerType(AEntry.Name, BaseType);
  end
  else
  begin
    BaseSym := ATable.Lookup(AliasName);
    if (BaseSym = nil) or (BaseSym.Kind <> skType) then
      raise EImportError.CreateFmt(
        'Type alias %s = %s: base not found', [AEntry.Name, AliasName]);
    AliasDesc := BaseSym.TypeDesc;
  end;
  Sym := TSymbol.Create(AEntry.Name, skType, AliasDesc);
  if not ATable.Define(Sym) then Sym.Free;
end;

procedure RegisterTypes(AIface: TUnitInterface; ATable: TSymbolTable);
var
  I: Integer;
  Entry: TTypeEntry;
begin
  for I := 0 to AIface.Types.Count - 1 do
  begin
    Entry := TTypeEntry(AIface.Types.Items[I]);
    if Entry.IsClass or Entry.IsGeneric then
      raise EImportError.CreateFmt(
        'Class/generic import not implemented yet (6c-B/C): %s.%s',
        [AIface.Name, Entry.Name]);

    if Entry.Def is TEnumTypeDef then
      RegisterEnum(Entry, ATable)
    else if Entry.Def is TSetTypeDef then
      RegisterSet(Entry, ATable)
    else if Entry.Def is TTypeAliasDef then
      RegisterAlias(Entry, ATable)
    else
      raise EImportError.CreateFmt(
        'Type %s.%s: import of %s not yet implemented',
        [AIface.Name, Entry.Name, Entry.Def.ClassName]);
  end;
end;

{ ----- Const registration --------------------------------------- }

procedure RegisterConsts(AIface: TUnitInterface; ATable: TSymbolTable);
var
  I: Integer;
  Entry: TConstEntry;
  Sym: TSymbol;
  TypeDesc: TTypeDesc;
begin
  for I := 0 to AIface.Consts.Count - 1 do
  begin
    Entry := TConstEntry(AIface.Consts.Items[I]);
    TypeDesc := ResolveTypeName(Entry.TypeRef.TypeName, ATable);

    { Untyped const: derive a builtin TTypeDesc from the literal kind.
      Matches the shape AnalyseConstDecls registers — see uSemantic. }
    if TypeDesc = nil then
    begin
      if Entry.Decl.IsString then
        TypeDesc := ATable.FindType('string')
      else if Entry.Decl.IsFloat then
        TypeDesc := ATable.FindType('Double')
      else
        TypeDesc := ATable.FindType('Integer');
    end;

    Sym := TSymbol.Create(Entry.Decl.Name, skConstant, TypeDesc);
    Sym.ConstValue  := Entry.Decl.IntVal;
    Sym.ConstString := Entry.Decl.StrVal;
    if not ATable.Define(Sym) then
      Sym.Free;  { duplicate — silently skip }
  end;
end;

{ ----- Var registration ----------------------------------------- }

procedure RegisterVars(AIface: TUnitInterface; ATable: TSymbolTable);
var
  I: Integer;
  Entry: TVarEntry;
  Sym: TSymbol;
  TypeDesc: TTypeDesc;
begin
  for I := 0 to AIface.Vars.Count - 1 do
  begin
    Entry := TVarEntry(AIface.Vars.Items[I]);
    TypeDesc := ResolveTypeName(Entry.TypeRef.TypeName, ATable);
    if TypeDesc = nil then
      raise EImportError.CreateFmt(
        'Var %s.%s: type %s unresolved',
        [AIface.Name, Entry.Name, Entry.TypeRef.TypeName]);
    Sym := TSymbol.Create(Entry.Name, skVariable, TypeDesc);
    Sym.IsGlobal := True;
    if not ATable.Define(Sym) then
      Sym.Free;
  end;
end;

{ ----- Routine registration ------------------------------------- }

{ Build a TParamDesc for the symbol table from a cloned TMethodParam.
  Param types must already be registered in ATable (caller imported
  the dep, or it's a builtin). }
function BuildParamDesc(AParam: TMethodParam; ATable: TSymbolTable): TParamDesc;
var
  Sym: TSymbol;
begin
  Result := TParamDesc.Create;
  Result.Name     := AParam.ParamName;
  Result.IsConst  := AParam.IsConstParam;
  Result.IsVar    := AParam.IsVarParam;
  Sym := ATable.Lookup(AParam.TypeName);
  if (Sym <> nil) and (Sym.Kind = skType) then
    Result.TypeDesc := Sym.TypeDesc;
  { Unresolved param type leaves TypeDesc nil; downstream call-site
    resolution would catch this — but for the cases in 6c-A scope we
    expect all param types to resolve. }
end;

procedure RegisterRoutines(AIface: TUnitInterface; ATable: TSymbolTable);
var
  I, J: Integer;
  Sig: TRoutineSig;
  Sym: TSymbol;
  RetType: TTypeDesc;
  Param: TMethodParam;
  PDesc: TParamDesc;
begin
  for I := 0 to AIface.Routines.Count - 1 do
  begin
    Sig := TRoutineSig(AIface.Routines.Items[I]);

    if Sig.IsFunction then
    begin
      RetType := ResolveTypeName(Sig.ReturnType.TypeName, ATable);
      Sym := TSymbol.Create(Sig.Name, skFunction, RetType);
    end
    else
      Sym := TSymbol.Create(Sig.Name, skProcedure, nil);

    Sym.IsOverload := False;  { overload chains rebuilt by 6c-B once
                                we carry IsOverload through TRoutineSig }

    for J := 0 to Sig.Params.Count - 1 do
    begin
      Param := TMethodParam(Sig.Params.Items[J]);
      PDesc := BuildParamDesc(Param, ATable);
      Sym.Params.Add(PDesc);
    end;

    if not ATable.Define(Sym) then
      Sym.Free;
  end;
end;

{ ----- Top-level ------------------------------------------------ }

procedure ImportUnitInterface(AIface: TUnitInterface; ATable: TSymbolTable);
begin
  { Types FIRST — consts, vars, and routine params look up against
    the symbol table by name. }
  RegisterTypes  (AIface, ATable);
  RegisterConsts (AIface, ATable);
  RegisterVars   (AIface, ATable);
  RegisterRoutines(AIface, ATable);
end;

end.
