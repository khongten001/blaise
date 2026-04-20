unit uSymbolTable;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, contnrs;

type
  { ------------------------------------------------------------------ }
  {  Type descriptors                                                   }
  { ------------------------------------------------------------------ }

  TTypeKind = (
    tyInteger,    { Int32  — QBE 'w' }
    tyInt64,      { Int64  — QBE 'l' }
    tyUInt32,     { UInt32 — QBE 'w' unsigned }
    tyByte,       { Byte   — QBE 'b' }
    tyBoolean,    { Boolean — stored as byte, 0/1 only }
    tyString,     { ARC-managed UTF-8 string }
    tyRecord,     { Stack-allocated aggregate (Phase 2) }
    tyClass,      { Heap-allocated, single-inheritance (Phase 2) }
    tyVoid,       { No value — used as procedure return type }
    tyNil         { Pseudo-type for the nil literal; compatible with tyClass }
  );

  TTypeDesc = class
  public
    Kind: TTypeKind;
    Name: string;
    function IsNumeric: Boolean;
    function IsString: Boolean;
    function IsOrdinal: Boolean;
    function IsRecord: Boolean;
    { Size in bytes for QBE allocation. }
    function ByteSize: Integer;
    { QBE alloc alignment: 4 for integer-only records, 8 for pointer/string. }
    function AllocAlign: Integer;
  end;

  { Field entry inside a record type descriptor. }
  TFieldInfo = class
  public
    Name:     string;
    TypeDesc: TTypeDesc;  { not owned }
    Offset:   Integer;    { byte offset from record base }
  end;

  { Extended type descriptor for record types. }
  TRecordTypeDesc = class(TTypeDesc)
  private
    FFields: TObjectList;  { owned TFieldInfo }
    FKeys:   TStringList;  { sorted, case-insensitive; Objects[] = TFieldInfo (not owned) }
    FParent: TRecordTypeDesc;  { not owned; nil for root classes }
  public
    constructor Create(const AName: string; AKind: TTypeKind = tyRecord);
    destructor Destroy; override;
    procedure AddField(const AName: string; AType: TTypeDesc);
    function  FindField(const AName: string): TFieldInfo;
    function  TotalSize: Integer;
    function  MaxAlign: Integer;
    property  Fields: TObjectList read FFields;
    property  Parent: TRecordTypeDesc read FParent write FParent;
  end;

  { ------------------------------------------------------------------ }
  {  Symbols                                                            }
  { ------------------------------------------------------------------ }

  TSymbolKind = (
    skVariable,
    skType,
    skProcedure,
    skFunction,
    skParameter,
    skVarParameter
  );

  TParamDesc = class
  public
    Name:     string;
    TypeDesc: TTypeDesc;  { not owned }
    IsConst:  Boolean;
    IsVar:    Boolean;
  end;

  TSymbol = class
  public
    Name:     string;
    Kind:     TSymbolKind;
    TypeDesc: TTypeDesc;    { not owned; nil for procedures }
    Params:   TObjectList;  { owned TParamDesc; populated for procedures/functions }
    constructor Create(const AName: string; AKind: TSymbolKind; AType: TTypeDesc);
    destructor Destroy; override;
  end;

  { ------------------------------------------------------------------ }
  {  Scope                                                              }
  { ------------------------------------------------------------------ }

  TScope = class
  private
    FParent:  TScope;
    FSymbols: TObjectList;  { owns all TSymbol in this scope }
    FKeys:    TStringList;  { sorted, case-insensitive; Objects[] = TSymbol (not owned) }
  public
    constructor Create(AParent: TScope);
    destructor Destroy; override;
    property Parent: TScope read FParent;
    { Returns False if name already defined in this scope; caller must free ASymbol. }
    function Define(ASymbol: TSymbol): Boolean;
    function LookupLocal(const AName: string): TSymbol;
    function Lookup(const AName: string): TSymbol;
  end;

  { ------------------------------------------------------------------ }
  {  Symbol table                                                       }
  { ------------------------------------------------------------------ }

  TSymbolTable = class
  private
    FScopeStack: TObjectList;   { owned TScope, index 0 = global }
    FAllTypes:   TObjectList;   { owned TTypeDesc }

    FTypeInteger: TTypeDesc;
    FTypeInt64:   TTypeDesc;
    FTypeUInt32:  TTypeDesc;
    FTypeByte:    TTypeDesc;
    FTypeBoolean: TTypeDesc;
    FTypeString:  TTypeDesc;
    FTypeVoid:    TTypeDesc;
    FTypeNil:     TTypeDesc;

    function GetCurrentScope: TScope;
    function GetScopeDepth: Integer;
    function NewType(AKind: TTypeKind; const AName: string): TTypeDesc;
    procedure RegisterBuiltins;
  public
    constructor Create;
    destructor Destroy; override;

    { Scope management }
    function  PushScope: TScope;
    procedure PopScope;
    property  CurrentScope: TScope read GetCurrentScope;
    property  ScopeDepth: Integer read GetScopeDepth;

    { Symbol management — owns ASymbol on success; caller must free on False }
    function Define(ASymbol: TSymbol): Boolean;
    function Lookup(const AName: string): TSymbol;

    { Type lookup — case-insensitive, returns nil if not found }
    function FindType(const AName: string): TTypeDesc;

    { Creates a new TRecordTypeDesc, registers it in FAllTypes, and returns it.
      Caller must then add fields and register it as a skType symbol. }
    function NewRecordType(const AName: string): TRecordTypeDesc;

    { Creates a new class type descriptor (tyClass, heap-allocated). }
    function NewClassType(const AName: string): TRecordTypeDesc;

    { Convenience type accessors }
    property TypeInteger: TTypeDesc read FTypeInteger;
    property TypeInt64:   TTypeDesc read FTypeInt64;
    property TypeUInt32:  TTypeDesc read FTypeUInt32;
    property TypeByte:    TTypeDesc read FTypeByte;
    property TypeBoolean: TTypeDesc read FTypeBoolean;
    property TypeString:  TTypeDesc read FTypeString;
    property TypeVoid:    TTypeDesc read FTypeVoid;
    property TypeNil:     TTypeDesc read FTypeNil;
  end;

implementation

{ ------------------------------------------------------------------ }
{ TTypeDesc                                                           }
{ ------------------------------------------------------------------ }

function TTypeDesc.IsNumeric: Boolean;
begin
  Result := Kind in [tyInteger, tyInt64, tyUInt32, tyByte];
end;

function TTypeDesc.IsString: Boolean;
begin
  Result := Kind = tyString;
end;

function TTypeDesc.IsOrdinal: Boolean;
begin
  Result := Kind in [tyInteger, tyInt64, tyUInt32, tyByte, tyBoolean];
end;

function TTypeDesc.IsRecord: Boolean;
begin
  Result := Kind = tyRecord;
end;

function TTypeDesc.ByteSize: Integer;
begin
  case Kind of
    tyInteger, tyUInt32: Result := 4;
    tyInt64:             Result := 8;
    tyByte, tyBoolean:   Result := 1;
    tyString:            Result := 8;  { pointer size on 64-bit }
    tyRecord:            Result := TRecordTypeDesc(Self).TotalSize;
    tyNil:               Result := 8;
  else
    Result := 8;
  end;
end;

function TTypeDesc.AllocAlign: Integer;
begin
  case Kind of
    tyInteger, tyUInt32: Result := 4;
    tyByte, tyBoolean:   Result := 4;  { round up to word boundary }
    tyInt64, tyString:   Result := 8;
    tyRecord:            Result := TRecordTypeDesc(Self).MaxAlign;
  else
    Result := 8;
  end;
end;

{ ------------------------------------------------------------------ }
{ TRecordTypeDesc                                                     }
{ ------------------------------------------------------------------ }

constructor TRecordTypeDesc.Create(const AName: string; AKind: TTypeKind = tyRecord);
begin
  inherited Create;
  Kind   := AKind;
  Name   := AName;
  FFields := TObjectList.Create(True);
  FKeys   := TStringList.Create;
  FKeys.Sorted        := True;
  FKeys.CaseSensitive := False;
  FKeys.Duplicates    := dupIgnore;
end;

destructor TRecordTypeDesc.Destroy;
begin
  FKeys.Free;
  FFields.Free;
  inherited Destroy;
end;

procedure TRecordTypeDesc.AddField(const AName: string; AType: TTypeDesc);
var
  Info:   TFieldInfo;
  Offset: Integer;
begin
  Offset := TotalSize;  { next available byte }
  Info          := TFieldInfo.Create;
  Info.Name     := AName;
  Info.TypeDesc := AType;
  Info.Offset   := Offset;
  FFields.Add(Info);
  FKeys.AddObject(AName, Info);
end;

function TRecordTypeDesc.FindField(const AName: string): TFieldInfo;
var
  Idx: Integer;
begin
  if FKeys.Find(AName, Idx) then
    Result := TFieldInfo(FKeys.Objects[Idx])
  else
    Result := nil;
end;

function TRecordTypeDesc.TotalSize: Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to FFields.Count - 1 do
    Inc(Result, TFieldInfo(FFields[I]).TypeDesc.ByteSize);
end;

function TRecordTypeDesc.MaxAlign: Integer;
var
  I, A: Integer;
begin
  Result := 4;
  for I := 0 to FFields.Count - 1 do
  begin
    A := TFieldInfo(FFields[I]).TypeDesc.AllocAlign;
    if A > Result then
      Result := A;
  end;
end;

{ ------------------------------------------------------------------ }
{ TSymbol                                                             }
{ ------------------------------------------------------------------ }

constructor TSymbol.Create(const AName: string; AKind: TSymbolKind; AType: TTypeDesc);
begin
  inherited Create;
  Name     := AName;
  Kind     := AKind;
  TypeDesc := AType;
  Params   := TObjectList.Create(True);
end;

destructor TSymbol.Destroy;
begin
  Params.Free;
  inherited Destroy;
end;

{ ------------------------------------------------------------------ }
{ TScope                                                              }
{ ------------------------------------------------------------------ }

constructor TScope.Create(AParent: TScope);
begin
  inherited Create;
  FParent  := AParent;
  FSymbols := TObjectList.Create(True);
  FKeys    := TStringList.Create;
  FKeys.Sorted        := True;
  FKeys.CaseSensitive := False;
  FKeys.Duplicates    := dupIgnore;  { we check manually before inserting }
end;

destructor TScope.Destroy;
begin
  FKeys.Free;
  FSymbols.Free;
  inherited Destroy;
end;

function TScope.Define(ASymbol: TSymbol): Boolean;
var
  Idx: Integer;
begin
  if FKeys.Find(ASymbol.Name, Idx) then
  begin
    Result := False;
    Exit;
  end;
  FSymbols.Add(ASymbol);
  { Store the TSymbol pointer directly in the string list's Objects slot. }
  FKeys.AddObject(ASymbol.Name, ASymbol);
  Result := True;
end;

function TScope.LookupLocal(const AName: string): TSymbol;
var
  Idx: Integer;
begin
  if FKeys.Find(AName, Idx) then
    Result := TSymbol(FKeys.Objects[Idx])
  else
    Result := nil;
end;

function TScope.Lookup(const AName: string): TSymbol;
var
  S: TScope;
begin
  S := Self;
  while S <> nil do
  begin
    Result := S.LookupLocal(AName);
    if Result <> nil then
      Exit;
    S := S.FParent;
  end;
  Result := nil;
end;

{ ------------------------------------------------------------------ }
{ TSymbolTable                                                        }
{ ------------------------------------------------------------------ }

constructor TSymbolTable.Create;
begin
  inherited Create;
  FScopeStack := TObjectList.Create(True);
  FAllTypes   := TObjectList.Create(True);
  { Global scope — parent = nil }
  FScopeStack.Add(TScope.Create(nil));
  RegisterBuiltins;
end;

destructor TSymbolTable.Destroy;
begin
  FScopeStack.Free;
  FAllTypes.Free;
  inherited Destroy;
end;

function TSymbolTable.NewType(AKind: TTypeKind; const AName: string): TTypeDesc;
begin
  Result      := TTypeDesc.Create;
  Result.Kind := AKind;
  Result.Name := AName;
  FAllTypes.Add(Result);
end;

function TSymbolTable.NewRecordType(const AName: string): TRecordTypeDesc;
begin
  Result := TRecordTypeDesc.Create(AName, tyRecord);
  FAllTypes.Add(Result);
end;

function TSymbolTable.NewClassType(const AName: string): TRecordTypeDesc;
begin
  Result := TRecordTypeDesc.Create(AName, tyClass);
  FAllTypes.Add(Result);
end;

procedure TSymbolTable.RegisterBuiltins;
var
  Sym: TSymbol;
begin
  { Primitive types }
  FTypeInteger := NewType(tyInteger, 'Integer');
  FTypeInt64   := NewType(tyInt64,   'Int64');
  FTypeUInt32  := NewType(tyUInt32,  'UInt32');
  FTypeByte    := NewType(tyByte,    'Byte');
  FTypeBoolean := NewType(tyBoolean, 'Boolean');
  FTypeString  := NewType(tyString,  'string');
  FTypeVoid    := NewType(tyVoid,    'void');
  FTypeNil     := NewType(tyNil,     'nil');

  { Register type names as skType symbols in global scope }
  Define(TSymbol.Create('Integer', skType, FTypeInteger));
  Define(TSymbol.Create('Int64',   skType, FTypeInt64));
  Define(TSymbol.Create('UInt32',  skType, FTypeUInt32));
  Define(TSymbol.Create('Byte',    skType, FTypeByte));
  Define(TSymbol.Create('Boolean', skType, FTypeBoolean));
  Define(TSymbol.Create('string',  skType, FTypeString));

  { Built-in I/O procedures }
  Sym := TSymbol.Create('Write',   skProcedure, nil);
  Define(Sym);
  Sym := TSymbol.Create('WriteLn', skProcedure, nil);
  Define(Sym);
end;

function TSymbolTable.GetCurrentScope: TScope;
begin
  Result := TScope(FScopeStack[FScopeStack.Count - 1]);
end;

function TSymbolTable.GetScopeDepth: Integer;
begin
  Result := FScopeStack.Count;
end;

function TSymbolTable.PushScope: TScope;
begin
  Result := TScope.Create(CurrentScope);
  FScopeStack.Add(Result);
end;

procedure TSymbolTable.PopScope;
begin
  if FScopeStack.Count > 1 then
    FScopeStack.Delete(FScopeStack.Count - 1);
end;

function TSymbolTable.Define(ASymbol: TSymbol): Boolean;
begin
  Result := CurrentScope.Define(ASymbol);
end;

function TSymbolTable.Lookup(const AName: string): TSymbol;
begin
  Result := CurrentScope.Lookup(AName);
end;

function TSymbolTable.FindType(const AName: string): TTypeDesc;
var
  Sym: TSymbol;
begin
  Sym := CurrentScope.Lookup(AName);
  if (Sym <> nil) and (Sym.Kind = skType) then
    Result := Sym.TypeDesc
  else
    Result := nil;
end;

end.
