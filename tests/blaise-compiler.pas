{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: BSD-3-Clause

  blaise-compiler.pas - Self-hosting source.
  Concatenated from all compiler units.
}

program BlaiseCompiler;

const
  CHR_QUOTE    = 39;    CHR_HASH     = 35;    CHR_DOLLAR   = 36;
  CHR_LF       = 10;    CHR_CR       = 13;    CHR_TAB      = 9;
  CHR_SPACE    = 32;    CHR_0        = 48;    CHR_9        = 57;
  CHR_A_UP     = 65;    CHR_F_UP     = 70;    CHR_Z_UP     = 90;
  CHR_a_LO     = 97;    CHR_f_LO     = 102;   CHR_z_LO     = 122;
  CHR_UNDER    = 95;    CHR_CARET    = 94;    CHR_DOT      = 46;
  CHR_AT       = 64;    CHR_LT       = 60;    CHR_GT       = 62;
  CHR_EQ       = 61;    CHR_PLUS     = 43;    CHR_MINUS    = 45;
  CHR_STAR     = 42;    CHR_SLASH    = 47;    CHR_LPAREN   = 40;
  CHR_RPAREN   = 41;    CHR_SEMI     = 59;    CHR_COLON    = 58;
  CHR_LBRACKET = 91;    CHR_RBRACKET = 93;    CHR_e_LO     = 101;
  CHR_E_UP     = 69;    CHR_DQUOTE   = 34;

type
  Exception = class
    FMessage: string;
    procedure Create(AMessage: string);
    procedure CreateFmt(const AFmt: string; AArg: Integer);
    property Message: string read FMessage;
  end;
  EParseError    = class(Exception);
  ESemanticError = class(Exception);
  ECodeGenError  = class(Exception);

procedure Exception.Create(AMessage: string);
begin
  Self.FMessage := AMessage
end;

procedure Exception.CreateFmt(const AFmt: string; AArg: Integer);
begin
  Self.FMessage := Format(AFmt, AArg)
end;


{ === RTL: Collections === }

{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: BSD-3-Clause
  See LICENSE file in the project root for full license terms.
}


// Blaise RTL — Classes unit.
//
// Provides TObjectList and TStringList with a method-based API compatible
// with the Blaise compiler source for self-hosting.
//
// Design notes:
//   - Indexed properties (Items[I], Objects[I]) are not supported in Blaise;
//     use Get(I)/Put(I,...) and GetObject(I)/SetObject(I,...) instead.
//   - TDuplicates is replaced by Integer constants: dupAccept=0, dupIgnore=1,
//     dupError=2 (enums are not yet supported in Blaise).
//   - TObjectList does not manage class instance lifetimes automatically;
//     in Blaise's ARC model, objects are freed when their last strong
//     reference drops. Use _ClassAddRef/_ClassRelease for manual management.
//   - TStringList stores strings as ^string; ARC is emitted by the compiler
//     for pointer-dereference writes (EmitPointerWrite). ZeroMem is used to
//     zero-initialise newly grown string slots so no garbage is ever released.


const
  dupAccept = 0;
  dupIgnore = 1;
  dupError  = 2;

type
  { ------------------------------------------------------------------ }
  { TObjectList                                                          }
  { ------------------------------------------------------------------ }

  TObjectList = class
    FData:        ^Pointer;
    FCount:       Integer;
    FCapacity:    Integer;
    FOwnsObjects: Boolean;
    procedure Grow;
    procedure Create(AOwnsObjects: Boolean);
    procedure   Destroy;
    function    Add(AObject: Pointer): Integer;
    function    Get(AIndex: Integer): Pointer;
    procedure   Put(AIndex: Integer; AObject: Pointer);
    function    IndexOf(AObject: Pointer): Integer;
    procedure   Delete(AIndex: Integer);
    procedure   Clear;
    property Count: Integer read FCount;
  end;

  { ------------------------------------------------------------------ }
  { TStringList                                                          }
  { ------------------------------------------------------------------ }

  TStringList = class
    FStrings:       ^string;
    FObjects:       ^Pointer;
    FCount:         Integer;
    FCapacity:      Integer;
    FCaseSensitive: Boolean;
    FSorted:        Boolean;
    FDuplicates:    Integer;
    procedure Grow;
    function  Compare(S1: string; S2: string): Integer;
    function  FindSorted(S: string; var Idx: Integer): Boolean;
    procedure Create;
    procedure   Destroy;
    function    Add(S: string): Integer;
    procedure   AddObject(S: string; AObject: Pointer);
    function    Find(S: string; var Index: Integer): Boolean;
    function    IndexOf(S: string): Integer;
    function    Get(AIndex: Integer): string;
    procedure   Put(AIndex: Integer; S: string);
    function    GetObject(AIndex: Integer): Pointer;
    procedure   SetObject(AIndex: Integer; AObject: Pointer);
    procedure   Delete(AIndex: Integer);
    procedure   Clear;
    procedure   Insert(AIndex: Integer; S: string);
    function    GetText: string;
    property Count:         Integer read FCount;
    property CaseSensitive: Boolean read FCaseSensitive write FCaseSensitive;
    property Sorted:        Boolean read FSorted        write FSorted;
    property Duplicates:    Integer read FDuplicates    write FDuplicates;
  end;


{ ================================================================== }
{ TObjectList                                                          }
{ ================================================================== }

procedure TObjectList.Grow;
var
  NewCap: Integer;
begin
  if Self.FCapacity = 0 then
    NewCap := 4
  else
    NewCap := Self.FCapacity * 2;
  Self.FData     := ReallocMem(Self.FData, NewCap * SizeOf(Pointer));
  Self.FCapacity := NewCap
end;

procedure TObjectList.Create(AOwnsObjects: Boolean);
begin
  Self.FOwnsObjects := AOwnsObjects
end;

procedure TObjectList.Destroy;
begin
  FreeMem(Self.FData);
  Self.FData     := nil;
  Self.FCount    := 0;
  Self.FCapacity := 0
end;

function TObjectList.Add(AObject: Pointer): Integer;
var
  Dest: ^Pointer;
begin
  if Self.FCount = Self.FCapacity then
    Self.Grow;
  Dest        := Self.FData + Self.FCount * SizeOf(Pointer);
  Dest^       := AObject;
  Self.FCount := Self.FCount + 1;
  Result      := Self.FCount - 1
end;

function TObjectList.Get(AIndex: Integer): Pointer;
var
  Src: ^Pointer;
begin
  Src    := Self.FData + AIndex * SizeOf(Pointer);
  Result := Src^
end;

procedure TObjectList.Put(AIndex: Integer; AObject: Pointer);
var
  Dest: ^Pointer;
begin
  Dest  := Self.FData + AIndex * SizeOf(Pointer);
  Dest^ := AObject
end;

function TObjectList.IndexOf(AObject: Pointer): Integer;
var
  I:   Integer;
  Src: ^Pointer;
begin
  I      := 0;
  Result := -1;
  while I < Self.FCount do
  begin
    Src := Self.FData + I * SizeOf(Pointer);
    if Src^ = AObject then
    begin
      Result := I;
      break
    end;
    I := I + 1
  end
end;

procedure TObjectList.Delete(AIndex: Integer);
var
  I:   Integer;
  Dst: ^Pointer;
  Src: ^Pointer;
begin
  I := AIndex;
  while I < Self.FCount - 1 do
  begin
    Dst  := Self.FData + I * SizeOf(Pointer);
    Src  := Self.FData + (I + 1) * SizeOf(Pointer);
    Dst^ := Src^;
    I    := I + 1
  end;
  Self.FCount := Self.FCount - 1
end;

procedure TObjectList.Clear;
begin
  Self.FCount := 0
end;

{ ================================================================== }
{ TStringList                                                          }
{ ================================================================== }

procedure TStringList.Grow;
var
  NewCap: Integer;
  OldCap: Integer;
begin
  OldCap := Self.FCapacity;
  if OldCap = 0 then
    NewCap := 4
  else
    NewCap := OldCap * 2;
  Self.FStrings  := ReallocMem(Self.FStrings, NewCap * SizeOf(string));
  Self.FObjects  := ReallocMem(Self.FObjects, NewCap * SizeOf(Pointer));
  { Zero-initialise new string slots so ARC release of "old" value is safe }
  ZeroMem(Self.FStrings + OldCap * SizeOf(string),
          (NewCap - OldCap) * SizeOf(string));
  Self.FCapacity := NewCap
end;

function TStringList.Compare(S1: string; S2: string): Integer;
begin
  if Self.FCaseSensitive then
    Result := CompareStr(S1, S2)
  else
    Result := CompareText(S1, S2)
end;

function TStringList.FindSorted(S: string; var Idx: Integer): Boolean;
var
  Lo:   Integer;
  Hi:   Integer;
  Mid:  Integer;
  Cmp:  Integer;
  Ptr:  ^string;
  MStr: string;
begin
  Lo := 0;
  Hi := Self.FCount - 1;
  while Lo <= Hi do
  begin
    Mid  := (Lo + Hi) div 2;
    Ptr  := Self.FStrings + Mid * SizeOf(string);
    MStr := Ptr^;
    Cmp  := Self.Compare(S, MStr);
    if Cmp = 0 then
    begin
      Idx    := Mid;
      Result := True;
      Exit
    end
    else if Cmp < 0 then
      Hi := Mid - 1
    else
      Lo := Mid + 1
  end;
  Idx    := Lo;
  Result := False
end;

procedure TStringList.Create;
begin
  Self.FCaseSensitive := True;
  Self.FSorted        := False;
  Self.FDuplicates    := dupAccept
end;

procedure TStringList.Destroy;
var
  I:   Integer;
  Ptr: ^string;
begin
  { Release all strings before freeing the backing store }
  I := 0;
  while I < Self.FCount do
  begin
    Ptr  := Self.FStrings + I * SizeOf(string);
    Ptr^ := nil;
    I    := I + 1
  end;
  FreeMem(Self.FStrings);
  FreeMem(Self.FObjects);
  Self.FStrings  := nil;
  Self.FObjects  := nil;
  Self.FCount    := 0;
  Self.FCapacity := 0
end;

function TStringList.Add(S: string): Integer;
var
  Idx:  Integer;
  StrP: ^string;
  ObjP: ^Pointer;
begin
  if Self.FSorted then
  begin
    Self.FindSorted(S, Idx);
    if (Self.FDuplicates = dupIgnore) and
       (Idx < Self.FCount) then
    begin
      { Check for exact match at Idx }
      StrP := Self.FStrings + Idx * SizeOf(string);
      if Self.Compare(S, StrP^) = 0 then
      begin
        Result := Idx;
        Exit
      end
    end;
    Self.Insert(Idx, S);
    Result := Idx
  end
  else
  begin
    if Self.FCount = Self.FCapacity then
      Self.Grow;
    StrP        := Self.FStrings + Self.FCount * SizeOf(string);
    ObjP        := Self.FObjects + Self.FCount * SizeOf(Pointer);
    StrP^       := S;
    ObjP^       := nil;
    Result      := Self.FCount;
    Self.FCount := Self.FCount + 1
  end
end;

procedure TStringList.AddObject(S: string; AObject: Pointer);
var
  Idx:  Integer;
  ObjP: ^Pointer;
begin
  Idx  := Self.Add(S);
  ObjP := Self.FObjects + Idx * SizeOf(Pointer);
  ObjP^ := AObject
end;

function TStringList.Find(S: string; var Index: Integer): Boolean;
var
  I:    Integer;
  Ptr:  ^string;
begin
  if Self.FSorted then
    Result := Self.FindSorted(S, Index)
  else
  begin
    { Linear search for unsorted list }
    I := 0;
    while I < Self.FCount do
    begin
      Ptr := Self.FStrings + I * SizeOf(string);
      if Self.Compare(S, Ptr^) = 0 then
      begin
        Index  := I;
        Result := True;
        Exit
      end;
      I := I + 1
    end;
    Index  := -1;
    Result := False
  end
end;

function TStringList.IndexOf(S: string): Integer;
var
  Idx: Integer;
begin
  if Self.Find(S, Idx) then
    Result := Idx
  else
    Result := -1
end;

function TStringList.Get(AIndex: Integer): string;
var
  Ptr: ^string;
begin
  Ptr    := Self.FStrings + AIndex * SizeOf(string);
  Result := Ptr^
end;

procedure TStringList.Put(AIndex: Integer; S: string);
var
  Ptr: ^string;
begin
  Ptr  := Self.FStrings + AIndex * SizeOf(string);
  Ptr^ := S
end;

function TStringList.GetObject(AIndex: Integer): Pointer;
var
  Ptr: ^Pointer;
begin
  Ptr    := Self.FObjects + AIndex * SizeOf(Pointer);
  Result := Ptr^
end;

procedure TStringList.SetObject(AIndex: Integer; AObject: Pointer);
var
  Ptr: ^Pointer;
begin
  Ptr  := Self.FObjects + AIndex * SizeOf(Pointer);
  Ptr^ := AObject
end;

procedure TStringList.Delete(AIndex: Integer);
var
  I:    Integer;
  SDst: ^string;
  SSrc: ^string;
  ODst: ^Pointer;
  OSrc: ^Pointer;
begin
  I := AIndex;
  while I < Self.FCount - 1 do
  begin
    SDst  := Self.FStrings + I * SizeOf(string);
    SSrc  := Self.FStrings + (I + 1) * SizeOf(string);
    ODst  := Self.FObjects + I * SizeOf(Pointer);
    OSrc  := Self.FObjects + (I + 1) * SizeOf(Pointer);
    SDst^ := SSrc^;
    ODst^ := OSrc^;
    I     := I + 1
  end;
  { Release the last (duplicate) string slot and clear the object slot }
  SDst  := Self.FStrings + (Self.FCount - 1) * SizeOf(string);
  SDst^ := nil;
  ODst  := Self.FObjects + (Self.FCount - 1) * SizeOf(Pointer);
  ODst^ := nil;
  Self.FCount := Self.FCount - 1
end;

procedure TStringList.Clear;
var
  I:   Integer;
  Ptr: ^string;
begin
  I := 0;
  while I < Self.FCount do
  begin
    Ptr  := Self.FStrings + I * SizeOf(string);
    Ptr^ := nil;
    I    := I + 1
  end;
  Self.FCount := 0
end;

procedure TStringList.Insert(AIndex: Integer; S: string);
var
  I:    Integer;
  SDst: ^string;
  SSrc: ^string;
  ODst: ^Pointer;
  OSrc: ^Pointer;
  Ptr:  ^string;
  OPtr: ^Pointer;
begin
  if Self.FCount = Self.FCapacity then
    Self.Grow;
  { Shift elements right from FCount-1 down to AIndex }
  I := Self.FCount;
  while I > AIndex do
  begin
    SDst  := Self.FStrings + I * SizeOf(string);
    SSrc  := Self.FStrings + (I - 1) * SizeOf(string);
    ODst  := Self.FObjects + I * SizeOf(Pointer);
    OSrc  := Self.FObjects + (I - 1) * SizeOf(Pointer);
    SDst^ := SSrc^;
    ODst^ := OSrc^;
    I     := I - 1
  end;
  { Zero the source slot that was shifted (now duplicated at AIndex+1) }
  SSrc  := Self.FStrings + AIndex * SizeOf(string);
  SSrc^ := nil;  { release the "old" value ARC wrote there during shift }
  { Write the new string at AIndex }
  Ptr   := Self.FStrings + AIndex * SizeOf(string);
  OPtr  := Self.FObjects + AIndex * SizeOf(Pointer);
  Ptr^  := S;
  OPtr^ := nil;
  Self.FCount := Self.FCount + 1
end;

function TStringList.GetText: string;
var
  I:   Integer;
  Ptr: ^string;
  Sep: string;
begin
  Result := '';
  Sep    := '';
  I := 0;
  while I < Self.FCount do
  begin
    Ptr    := Self.FStrings + I * SizeOf(string);
    Result := Result + Sep + Ptr^;
    Sep    := #13#10;
    I      := I + 1
  end
end;




{ === uPasTokeniser === }


var KwList: TStringList;

procedure InitKeywords;
begin
  KwList := TStringList.Create;
  KwList.Sorted := True;
  KwList.CaseSensitive := True;
  KwList.Add('ABSOLUTE');  KwList.Add('AND');       KwList.Add('ARRAY');
  KwList.Add('AS');        KwList.Add('ASM');        KwList.Add('BEGIN');
  KwList.Add('BITPACKED'); KwList.Add('CASE');       KwList.Add('CLASS');
  KwList.Add('CONST');     KwList.Add('CONSTREF');   KwList.Add('CONSTRUCTOR');
  KwList.Add('CONTAINS');  KwList.Add('DESTRUCTOR'); KwList.Add('DISPINTERFACE');
  KwList.Add('DIV');       KwList.Add('DO');         KwList.Add('DOWNTO');
  KwList.Add('ELSE');      KwList.Add('END');        KwList.Add('EXCEPT');
  KwList.Add('EXPORTS');   KwList.Add('FALSE');      KwList.Add('FILE');
  KwList.Add('FINALIZATION'); KwList.Add('FINALLY'); KwList.Add('FOR');
  KwList.Add('FUNCTION');  KwList.Add('GENERIC');    KwList.Add('GOTO');
  KwList.Add('IF');        KwList.Add('IMPLEMENTATION'); KwList.Add('IN');
  KwList.Add('INHERITED'); KwList.Add('INITIALIZATION'); KwList.Add('INLINE');
  KwList.Add('INTERFACE'); KwList.Add('IS');         KwList.Add('LABEL');
  KwList.Add('LIBRARY');   KwList.Add('MOD');        KwList.Add('NIL');
  KwList.Add('NOT');       KwList.Add('OBJCCATEGORY'); KwList.Add('OBJCCLASS');
  KwList.Add('OBJCPROTOCOL'); KwList.Add('OBJECT'); KwList.Add('OF');
  KwList.Add('OPERATOR');  KwList.Add('OR');         KwList.Add('OTHERWISE');
  KwList.Add('PACKAGE');   KwList.Add('PACKED');     KwList.Add('PROCEDURE');
  KwList.Add('PROGRAM');   KwList.Add('PROPERTY');   KwList.Add('RAISE');
  KwList.Add('RECORD');    KwList.Add('REPEAT');     KwList.Add('REQUIRES');
  KwList.Add('RESOURCESTRING'); KwList.Add('SELF'); KwList.Add('SET');
  KwList.Add('SHL');       KwList.Add('SHR');        KwList.Add('SPECIALIZE');
  KwList.Add('THEN');      KwList.Add('THREADVAR');  KwList.Add('TO');
  KwList.Add('TRUE');      KwList.Add('TRY');        KwList.Add('TYPE');
  KwList.Add('UNIT');      KwList.Add('UNTIL');      KwList.Add('USES');
  KwList.Add('VAR');       KwList.Add('WHILE');      KwList.Add('WITH');
  KwList.Add('XOR')
end;

function BinarySearchKeyword(const AText: string): Boolean;
var
  Idx: Integer;
begin
  Result := KwList.Find(AText, Idx)
end;

{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: BSD-3-Clause
  See LICENSE file in the project root for full license terms.
}

{
    Clean Pascal Compiler — General Pascal Tokeniser

    Lightweight Object Pascal tokeniser. Operates on a string buffer and
    yields tokens one at a time via NextToken. No exceptions on malformed
    source — unrecognised characters produce fptkSymbol tokens of length 1,
    and unterminated strings or comments consume to end-of-source.

    Does NOT evaluate compiler directives or IFDEF branches — everything
    is tokenised literally.

    Ported from the fpGUI IDE tokeniser (same author).
}




type
  TFpgPasTokenKind = (
    fptkEOF,
    fptkWhitespace,
    fptkLineEnding,
    fptkIdentifier,
    fptkKeyword,
    fptkNumber,
    fptkString,
    fptkComment,
    fptkDirective,
    fptkSymbol
  );

  TFpgPasToken = record
    Kind: TFpgPasTokenKind;
    Line: Integer;       { 1-based line number }
    Column: Integer;     { 1-based column }
    Len: Integer;        { character length in source }
    TextStart: Integer;  { 1-based index into source string }
  end;

  { TFpgPascalTokeniser }

  TFpgPascalTokeniser = class(TObject)

    FSource: string;
    FPos: Integer;
    FLine: Integer;
    FLineStart: Integer;  { FPos value at start of current line }
    FToken: TFpgPasToken;
    function Peek: Integer;
    function PeekAt(AOffset: Integer): Integer;
    procedure Advance;
    procedure AdvanceLine;
    procedure ReadWhitespace;
    procedure ReadLineEnding;
    procedure ReadIdentifierOrKeyword;
    procedure ReadNumber;
    procedure ReadString;
    procedure ReadBraceCommentOrDirective;
    procedure ReadParenStarCommentOrDirective;
    procedure ReadLineComment;
    procedure ReadSymbol;

    procedure Create;
    procedure SetSource(const ASource: string);
    function NextToken: TFpgPasToken;
    function TokenText: string;
    function TokenTextUpper: string;
    property Token: TFpgPasToken read FToken;
    property Source: string read FSource;
  end;

{ Returns True if AText is a Pascal keyword (case-insensitive). }
function PasIsKeyword(const AText: string): Boolean;




function PasIsKeyword(const AText: string): Boolean;
begin
  if AText = '' then
    begin Result := False; Exit end;
  Result := BinarySearchKeyword(UpperCase(AText));
end;

{ TFpgPascalTokeniser }

procedure TFpgPascalTokeniser.Create;
begin
  inherited Create;
  FSource := '';
  FPos := 1;
  FLine := 1;
  FLineStart := 1;
end;

procedure TFpgPascalTokeniser.SetSource(const ASource: string);
begin
  FSource := ASource;
  FPos := 1;
  FLine := 1;
  FLineStart := 1;
  FToken.Kind := fptkEOF;
  FToken.Line := 1;
  FToken.Column := 1;
  FToken.Len := 0;
  FToken.TextStart := 1;
end;

function TFpgPascalTokeniser.Peek: Integer;
begin
  if FPos <= Length(FSource) then
    Result := OrdAt(FSource, FPos)
  else
    Result := 0;
end;

function TFpgPascalTokeniser.PeekAt(AOffset: Integer): Integer;
var
  p: Integer;
begin
  p := FPos + AOffset;
  if (p >= 1) and (p <= Length(FSource)) then
    Result := OrdAt(FSource, p)
  else
    Result := 0;
end;

procedure TFpgPascalTokeniser.Advance;
begin
  FPos := FPos + 1;
end;

procedure TFpgPascalTokeniser.AdvanceLine;
begin
  FLine := FLine + 1;
  FLineStart := FPos;
end;

procedure TFpgPascalTokeniser.ReadWhitespace;
begin
  FToken.Kind := fptkWhitespace;
  while (FPos <= Length(FSource)) and (((OrdAt(FSource, FPos) = 32) or (OrdAt(FSource, FPos) = 9))) do
    Advance;
  FToken.Len := FPos - FToken.TextStart;
end;

procedure TFpgPascalTokeniser.ReadLineEnding;
begin
  FToken.Kind := fptkLineEnding;
  if (OrdAt(FSource, FPos) = 13) and (PeekAt(1) = #10) then
    Advance;  { consume CR of CRLF }
  Advance;    { consume LF (or lone CR) }
  FToken.Len := FPos - FToken.TextStart;
  AdvanceLine;
end;

procedure TFpgPascalTokeniser.ReadIdentifierOrKeyword;
begin
  while (FPos <= Length(FSource)) and
        ((((OrdAt(FSource, FPos) >= 65) and (OrdAt(FSource, FPos) <= 90)) or ((OrdAt(FSource, FPos) >= 97) and (OrdAt(FSource, FPos) <= 122)) or ((OrdAt(FSource, FPos) >= 48) and (OrdAt(FSource, FPos) <= 57)) or (OrdAt(FSource, FPos) = 95))) do
    Advance;
  FToken.Len := FPos - FToken.TextStart;
  if BinarySearchKeyword(UpperCase(TokenText)) then
    FToken.Kind := fptkKeyword
  else
    FToken.Kind := fptkIdentifier;
end;

procedure TFpgPascalTokeniser.ReadNumber;
var
  c: Integer;
begin
  FToken.Kind := fptkNumber;
  c := OrdAt(FSource, FPos);

  if c = 36 then
  begin
    { Hex: $[0-9A-Fa-f]+ }
    Advance;
    while (FPos <= Length(FSource)) and
          ((((OrdAt(FSource, FPos) >= 48) and (OrdAt(FSource, FPos) <= 57)) or ((OrdAt(FSource, FPos) >= 65) and (OrdAt(FSource, FPos) <= 70)) or ((OrdAt(FSource, FPos) >= 97) and (OrdAt(FSource, FPos) <= 102)))) do
      Advance;
    FToken.Len := FPos - FToken.TextStart;
    Exit;
  end;

  if c = 37 then
  begin
    { Binary: %[01]+ }
    Advance;
    while (FPos <= Length(FSource)) and (((OrdAt(FSource, FPos) = 48) or (OrdAt(FSource, FPos) = 49))) do
      Advance;
    FToken.Len := FPos - FToken.TextStart;
    Exit;
  end;

  if c = 38 then
  begin
    { Octal: &[0-7]+ }
    Advance;
    while (FPos <= Length(FSource)) and ((((OrdAt(FSource, FPos) >= 48) and (OrdAt(FSource, FPos) <= 55)))) do
      Advance;
    FToken.Len := FPos - FToken.TextStart;
    Exit;
  end;

  { Decimal integer or float }
  while (FPos <= Length(FSource)) and ((((OrdAt(FSource, FPos) >= 48) and (OrdAt(FSource, FPos) <= 57)))) do
    Advance;

  { Check for decimal point (but not '..') }
  if (FPos <= Length(FSource)) and (OrdAt(FSource, FPos) = 46) and
     (PeekAt(1) <> '.') then
  begin
    Advance;  { consume '.' }
    while (FPos <= Length(FSource)) and ((((OrdAt(FSource, FPos) >= 48) and (OrdAt(FSource, FPos) <= 57)))) do
      Advance;
  end;

  { Check for exponent }
  if (FPos <= Length(FSource)) and (((OrdAt(FSource, FPos) = 101) or (OrdAt(FSource, FPos) = 69))) then
  begin
    Advance;
    if (FPos <= Length(FSource)) and (((OrdAt(FSource, FPos) = 43) or (OrdAt(FSource, FPos) = 45))) then
      Advance;
    while (FPos <= Length(FSource)) and ((((OrdAt(FSource, FPos) >= 48) and (OrdAt(FSource, FPos) <= 57)))) do
      Advance;
  end;

  FToken.Len := FPos - FToken.TextStart;
end;

procedure TFpgPascalTokeniser.ReadString;
var
  c: Integer;
begin
  { Pascal string literals can be composed of:
    - 'quoted text' (with '' for embedded quotes)
    - #nn (decimal char code)
    - #$nn (hex char code)
    - ^A (control char)
    These can be concatenated without operators: 'abc'#13#10'def' }
  FToken.Kind := fptkString;

  while True do
begin
    c := Peek;
    if c = 39 then
    begin
      Advance;  { opening quote }
      while FPos <= Length(FSource) do
      begin
        if OrdAt(FSource, FPos) = 39 then
        begin
          Advance;
          { Embedded quote? '' }
          if (FPos <= Length(FSource)) and (OrdAt(FSource, FPos) = 39) then
            Advance
          else
            Break;  { closing quote }
        end
        else if ((OrdAt(FSource, FPos) = 10) or (OrdAt(FSource, FPos) = 13)) then
          Break  { unterminated string at line end }
        else
          Advance;
      end;
    end
    else if c = 35 then
    begin
      Advance;  { consume # }
      if (FPos <= Length(FSource)) and (OrdAt(FSource, FPos) = 36) then
      begin
        Advance;  { hex char code }
        while (FPos <= Length(FSource)) and
              ((((OrdAt(FSource, FPos) >= 48) and (OrdAt(FSource, FPos) <= 57)) or ((OrdAt(FSource, FPos) >= 65) and (OrdAt(FSource, FPos) <= 70)) or ((OrdAt(FSource, FPos) >= 97) and (OrdAt(FSource, FPos) <= 102)))) do
          Advance;
      end
      else
      begin
        while (FPos <= Length(FSource)) and ((((OrdAt(FSource, FPos) >= 48) and (OrdAt(FSource, FPos) <= 57)))) do
          Advance;
      end;
    end
    else if c = 94 then
    begin
      Advance;  { consume ^ }
      if (FPos <= Length(FSource)) and ((((OrdAt(FSource, FPos) >= 65) and (OrdAt(FSource, FPos) <= 90)) or ((OrdAt(FSource, FPos) >= 97) and (OrdAt(FSource, FPos) <= 122)))) then
        Advance;
    end
    else
      Break;  { not a string continuation }
  end;

  FToken.Len := FPos - FToken.TextStart;
end;

procedure TFpgPascalTokeniser.ReadBraceCommentOrDirective;
begin
  // Already at open-brace. Check next char for '$'.
  if PeekAt(1) = '$' then
    FToken.Kind := fptkDirective
  else
    FToken.Kind := fptkComment;

  Advance;  // consume open-brace
  while FPos <= Length(FSource) do
  begin
    if OrdAt(FSource, FPos) = 125 then
    begin
      Advance;
      Break;
    end
    else if OrdAt(FSource, FPos) = 13 then
    begin
      Advance;
      if (FPos <= Length(FSource)) and (OrdAt(FSource, FPos) = 10) then
        Advance;
      AdvanceLine;
    end
    else if OrdAt(FSource, FPos) = 10 then
    begin
      Advance;
      AdvanceLine;
    end
    else
      Advance;
  end;
  FToken.Len := FPos - FToken.TextStart;
end;

procedure TFpgPascalTokeniser.ReadParenStarCommentOrDirective;
begin
  { Already at '('. Next is '*'. Check char after '*' for '$'. }
  if PeekAt(2) = '$' then
    FToken.Kind := fptkDirective
  else
    FToken.Kind := fptkComment;

  Advance;  { consume '(' }
  Advance;  { consume '*' }
  while FPos <= Length(FSource) do
  begin
    if (OrdAt(FSource, FPos) = 42) and (PeekAt(1) = ')') then
    begin
      Advance;  { consume '*' }
      Advance;  { consume ')' }
      Break;
    end
    else if OrdAt(FSource, FPos) = 13 then
    begin
      Advance;
      if (FPos <= Length(FSource)) and (OrdAt(FSource, FPos) = 10) then
        Advance;
      AdvanceLine;
    end
    else if OrdAt(FSource, FPos) = 10 then
    begin
      Advance;
      AdvanceLine;
    end
    else
      Advance;
  end;
  FToken.Len := FPos - FToken.TextStart;
end;

procedure TFpgPascalTokeniser.ReadLineComment;
begin
  FToken.Kind := fptkComment;
  { Consume everything until end of line or end of source }
  while (FPos <= Length(FSource)) and
        not (((OrdAt(FSource, FPos) = 10) or (OrdAt(FSource, FPos) = 13))) do
    Advance;
  FToken.Len := FPos - FToken.TextStart;
end;

procedure TFpgPascalTokeniser.ReadSymbol;
var
  c, c2: Integer;
begin
  FToken.Kind := fptkSymbol;
  c := OrdAt(FSource, FPos);
  c2 := PeekAt(1);
  Advance;

  case c of
    ':': if c2 = 61 then Advance;           // :=
    '<': if ((c2 = 62) or (c2 = 61)) then Advance;   // <> or <=
    '>': if ((c2 = 60) or (c2 = 61)) then Advance;   // >< or >=
    '.': if c2 = 46 then Advance;           // ..
    '*': if c2 = 42 then Advance;           // **
    '@': if c2 = 64 then Advance;           // @@
    '+': if c2 = 61 then Advance;           // +=
    '-': if c2 = 61 then Advance;           // -=
    '/': if c2 = 61 then Advance;           // /= (// handled separately)
  end;

  // Special: *= (if * was not followed by *)
  if (c = 42) and (c2 <> 42) and (c2 = 61) then
    Advance;

  FToken.Len := FPos - FToken.TextStart;
end;

function TFpgPascalTokeniser.NextToken: TFpgPasToken;
var
  c, c2: Integer;
begin
  if FPos > Length(FSource) then
  begin
    FToken.Kind := fptkEOF;
    FToken.Line := FLine;
    FToken.Column := FPos - FLineStart + 1;
    FToken.Len := 0;
    FToken.TextStart := FPos;
    Result := FToken;
    Exit;
  end;

  { Record token start position }
  FToken.TextStart := FPos;
  FToken.Line := FLine;
  FToken.Column := FPos - FLineStart + 1;

  c := OrdAt(FSource, FPos);

  { Whitespace (not line endings) }
  if ((c = 32) or (c = 9)) then
  begin
    ReadWhitespace;
    Result := FToken;
    Exit;
  end;

  { Line endings }
  if ((c = 13) or (c = 10)) then
  begin
    ReadLineEnding;
    Result := FToken;
    Exit;
  end;

  { Identifiers and keywords }
  if (((c >= 65) and (c <= 90)) or ((c >= 97) and (c <= 122)) or (c = 95)) then
  begin
    ReadIdentifierOrKeyword;
    Result := FToken;
    Exit;
  end;

  { Numbers: digits or $ (hex) or % (binary) or & (octal) }
  if (((c >= 48) and (c <= 57))) then
  begin
    ReadNumber;
    Result := FToken;
    Exit;
  end;
  if (c = 36) and ((((PeekAt(1) >= 48) and (PeekAt(1) <= 57)) or ((PeekAt(1) >= 65) and (PeekAt(1) <= 70)) or ((PeekAt(1) >= 97) and (PeekAt(1) <= 102)))) then
  begin
    ReadNumber;
    Result := FToken;
    Exit;
  end;
  if (c = 37) and (((PeekAt(1) = 48) or (PeekAt(1) = 49))) then
  begin
    ReadNumber;
    Result := FToken;
    Exit;
  end;
  if (c = 38) and ((((PeekAt(1) >= 48) and (PeekAt(1) <= 55)))) then
  begin
    ReadNumber;
    Result := FToken;
    Exit;
  end;

  { Strings: ' or # — Clean Pascal does not support ^X control-char string escapes }
  if ((c = 39) or (c = 35)) then
  begin
    ReadString;
    Result := FToken;
    Exit;
  end;

  { Comments and directives }
  if c = 123 then
  begin
    ReadBraceCommentOrDirective;
    Result := FToken;
    Exit;
  end;

  c2 := PeekAt(1);

  if (c = 40) and (c2 = 42) then
  begin
    ReadParenStarCommentOrDirective;
    Result := FToken;
    Exit;
  end;

  if (c = 47) and (c2 = 47) then
  begin
    ReadLineComment;
    Result := FToken;
    Exit;
  end;

  { Symbols and operators }
  ReadSymbol;
  Result := FToken;
end;

function TFpgPascalTokeniser.TokenText: string;
begin
  if (FToken.TextStart >= 1) and (FToken.Len > 0) and
     (FToken.TextStart + FToken.Len - 1 <= Length(FSource)) then
    Result := Copy(FSource, FToken.TextStart, FToken.Len)
  else
    Result := '';
end;

function TFpgPascalTokeniser.TokenTextUpper: string;
begin
  Result := UpperCase(TokenText);
end;



