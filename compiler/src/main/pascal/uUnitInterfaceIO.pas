{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Andrew Haines
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

{ uUnitInterfaceIO — text-based serializer / deserializer for
  TUnitInterface.

  Phase 6c-E starter.  The on-disk story for separate compilation
  needs a stable, parser-free way to materialise a TUnitInterface
  from a byte sequence.  This unit owns that mapping.

  Format (v1):
    Magic + version on a single line, then length-prefixed string
    records.  Lengths are decimal ASCII followed by ':' and the
    raw bytes (no escaping needed since lengths drive consumption).

    BLAISE-IFACE 1\n
    <unit-name lpstr>
    CONST <count>\n
      <name lpstr><typeref lpstr><int64><strval lpstr><flags byte>
    END\n

  Where:
    <lpstr>     = "<decimal-len>:" followed by <len> raw bytes
    <int64>     = lpstr containing the decimal digits
    <flags byte>= '0' / '1' / '2' / '3'
                  bit 0 = IsString, bit 1 = IsFloat

  TypeRef is rendered as "UnitName.TypeName" — '$builtin.Integer',
  '<thisunit>.TFoo', or '.<empty>' for untyped consts.

  Scope of this commit: unit name + const records only.  Vars,
  types, routines, and class/generic bodies land in follow-up
  commits.  The plumbing — magic header, length-prefixed strings,
  cursor-based reader — is the load-bearing part; extending it to
  more record types is mechanical.

  Why text and not binary: easier to diff and inspect during
  development, no endianness concerns, no bit-twiddling.  Once the
  layout stabilises we can re-encode as a compact binary form
  without changing the surface API. }

unit uUnitInterfaceIO;

interface

uses
  Classes, SysUtils, uAST, uUnitInterface;

const
  IFACE_MAGIC   = 'BLAISE-IFACE';
  IFACE_VERSION = 1;

type
  EIfaceFormatError = class(Exception);

{ Render AIface into a string.  Caller owns the buffer. }
function WriteUnitInterface(AIface: TUnitInterface): string;

{ Parse AText into a freshly-allocated TUnitInterface.  Caller owns
  the returned interface.  Raises EIfaceFormatError on a malformed
  input or version mismatch. }
function ReadUnitInterface(const AText: string): TUnitInterface;

implementation

{ ----- Writer ----------------------------------------------------- }

{ Length-prefixed string: "<len>:bytes".  Lets the reader consume
  exactly <len> UTF-8 bytes without worrying about embedded ':',
  newlines, or quotes. }
function EncodeLpstr(const S: string): string;
begin
  Result := IntToStr(Length(S)) + ':' + S;
end;

function EncodeInt64(V: Int64): string;
begin
  Result := EncodeLpstr(IntToStr(V));
end;

function EncodeFlags(AIsString, AIsFloat: Boolean): string;
var
  B: Integer;
begin
  B := 0;
  if AIsString then B := B or 1;
  if AIsFloat  then B := B or 2;
  Result := IntToStr(B);
end;

{ Pass the ref as two strings to dodge the documented record-with-
  strings-as-const-param codegen bug (memory:
  project_record_const_param_crash.md). }
function EncodeQualRefParts(const AUnitName, ATypeName: string): string;
begin
  Result := EncodeLpstr(AUnitName + '.' + ATypeName);
end;

function WriteConsts(AIface: TUnitInterface): string;
var
  I:  Integer;
  C:  TConstEntry;
  SB: TStringList;
begin
  SB := TStringList.Create;
  try
    SB.Add('CONST ' + IntToStr(AIface.Consts.Count));
    for I := 0 to AIface.Consts.Count - 1 do
    begin
      C := TConstEntry(AIface.Consts.Items[I]);
      SB.Add(
        EncodeLpstr(C.Decl.Name) +
        EncodeQualRefParts(C.TypeRef.UnitName, C.TypeRef.TypeName) +
        EncodeInt64(C.Decl.IntVal) +
        EncodeLpstr(C.Decl.StrVal) +
        EncodeFlags(C.Decl.IsString, C.Decl.IsFloat));
    end;
    SB.Add('END');
    Result := SB.Text;
  finally
    SB.Free;
  end;
end;

function WriteUnitInterface(AIface: TUnitInterface): string;
begin
  Result :=
    IFACE_MAGIC + ' ' + IntToStr(IFACE_VERSION) + #10 +
    EncodeLpstr(AIface.Name) + #10 +
    WriteConsts(AIface);
end;

{ ----- Reader ----------------------------------------------------- }

{ Cursor state passed by var-ref into the per-record readers — keeps
  the API surface scalar-friendly so we avoid the const-record-param
  string-field crash documented in memory. }

{ Char-classification on integer ordinals — Blaise lacks a Char
  type and S[i] returns a 1-byte string, so route through Ord() to
  get scalar Integer comparisons. }
function IsWhitespaceOrd(C: Integer): Boolean;
begin
  Result := (C = 32) or (C = 9) or (C = 10) or (C = 13);
end;

function IsUpperOrd(C: Integer): Boolean;
begin
  Result := (C >= Ord('A')) and (C <= Ord('Z'));
end;

function IsDigitOrd(C: Integer): Boolean;
begin
  Result := (C >= Ord('0')) and (C <= Ord('9'));
end;

{ Indexing convention throughout this unit: Blaise strings are
  0-indexed.  S[0] is the first byte; valid positions are 0 ..
  Length(S)-1.  Copy(S, start, len) treats start as 0-based.  Pos
  returns 0-based offset or -1 for not found.  APos cursor is
  0-based. }

procedure SkipWhitespace(const AText: string; var APos: Integer);
begin
  while (APos < Length(AText)) and IsWhitespaceOrd(Ord(AText[APos])) do
    Inc(APos);
end;

function ReadLpstrAt(const AText: string; var APos: Integer): string;
var
  ColonPos: Integer;
  Len:      Integer;
  LenStr:   string;
begin
  SkipWhitespace(AText, APos);
  ColonPos := APos;
  while (ColonPos < Length(AText)) and (AText[ColonPos] <> ':') do
    Inc(ColonPos);
  if ColonPos >= Length(AText) then
    raise EIfaceFormatError.Create('lpstr: missing '':'' separator');
  LenStr := Copy(AText, APos, ColonPos - APos);
  Len    := StrToInt(LenStr);
  if ColonPos + 1 + Len > Length(AText) then
    raise EIfaceFormatError.Create(Format(
      'lpstr: %d bytes requested, only %d available', [Len, Length(AText) - ColonPos - 1]));
  Result := Copy(AText, ColonPos + 1, Len);
  APos   := ColonPos + 1 + Len;
end;

function ReadInt64At(const AText: string; var APos: Integer): Int64;
begin
  Result := StrToInt64(ReadLpstrAt(AText, APos));
end;

function ReadFlagsAt(const AText: string; var APos: Integer;
                     out AIsString, AIsFloat: Boolean): Integer;
var
  B: Integer;
begin
  SkipWhitespace(AText, APos);
  if APos >= Length(AText) then
    raise EIfaceFormatError.Create('flags: end-of-input');
  B := Ord(AText[APos]) - Ord('0');
  Inc(APos);
  AIsString := (B and 1) <> 0;
  AIsFloat  := (B and 2) <> 0;
  Result := B;
end;

{ Split 'Unit.Type' into two strings.  Avoids passing TQualTypeRef
  records — same record-with-strings codegen bug that bit
  uSemanticImport.ResolveRef. }
procedure DecodeQualRef(const ASrc: string; var AUnit, AType: string);
var
  Dot: Integer;
begin
  { Blaise Pos and Copy are 0-based. }
  Dot := Pos('.', ASrc);
  if Dot < 0 then
  begin
    AUnit := '';
    AType := ASrc;
  end
  else
  begin
    AUnit := Copy(ASrc, 0, Dot);
    AType := Copy(ASrc, Dot + 1, Length(ASrc) - Dot - 1);
  end;
end;

{ Read an unterminated keyword (letters only) at the current cursor;
  consume it and advance past trailing whitespace.  Used for record
  tags ('CONST', 'END', etc.). }
function ReadTag(const AText: string; var APos: Integer): string;
var
  Start: Integer;
begin
  SkipWhitespace(AText, APos);
  Start := APos;
  while (APos < Length(AText)) and IsUpperOrd(Ord(AText[APos])) do
    Inc(APos);
  Result := Copy(AText, Start, APos - Start);
end;

function ReadDecimalAt(const AText: string; var APos: Integer): Integer;
var
  Start: Integer;
begin
  SkipWhitespace(AText, APos);
  Start := APos;
  while (APos < Length(AText)) and IsDigitOrd(Ord(AText[APos])) do
    Inc(APos);
  if APos = Start then
    raise EIfaceFormatError.Create('expected decimal digits');
  Result := StrToInt(Copy(AText, Start, APos - Start));
end;

procedure ReadHeader(const AText: string; var APos: Integer);
var
  MagicPos: Integer;
  Ver:      Integer;
begin
  SkipWhitespace(AText, APos);
  { Blaise Pos: 0-based result, -1 = not found.  Match at the
    cursor's current position means MagicPos = APos. }
  MagicPos := Pos(IFACE_MAGIC, AText);
  if MagicPos < 0 then
    raise EIfaceFormatError.Create('missing magic header');
  if MagicPos <> APos then
    raise EIfaceFormatError.Create(Format(
      'magic ''%s'' not at expected position %d (found at %d)',
      [IFACE_MAGIC, APos, MagicPos]));
  Inc(APos, Length(IFACE_MAGIC));
  SkipWhitespace(AText, APos);
  Ver := ReadDecimalAt(AText, APos);
  if Ver <> IFACE_VERSION then
    raise EIfaceFormatError.Create(Format(
      'unsupported version %d (this build understands %d)',
      [Ver, IFACE_VERSION]));
end;

procedure ReadConsts(const AText: string; var APos: Integer;
                     AIface: TUnitInterface);
var
  Count:    Integer;
  I:        Integer;
  Entry:    TConstEntry;
  Name:     string;
  RefStr:   string;
  IntVal:   Int64;
  StrVal:   string;
  IsString: Boolean;
  IsFloat:  Boolean;
  RefUnit:  string;
  RefType:  string;
begin
  Count := ReadDecimalAt(AText, APos);
  for I := 1 to Count do
  begin
    Name     := ReadLpstrAt(AText, APos);
    RefStr   := ReadLpstrAt(AText, APos);
    IntVal   := ReadInt64At(AText, APos);
    StrVal   := ReadLpstrAt(AText, APos);
    ReadFlagsAt(AText, APos, IsString, IsFloat);
    DecodeQualRef(RefStr, RefUnit, RefType);

    Entry := TConstEntry.Create;
    Entry.Decl := TConstDecl.Create;
    Entry.Decl.Name     := Name;
    Entry.Decl.IntVal   := IntVal;
    Entry.Decl.StrVal   := StrVal;
    Entry.Decl.IsString := IsString;
    Entry.Decl.IsFloat  := IsFloat;
    Entry.TypeRef       := MakeQualRef(RefUnit, RefType);
    AIface.AddConst(Entry);
  end;
  { Trailing 'END' marker — keeps the format extensible: future
    record types follow the same tag/payload/END pattern. }
  if ReadTag(AText, APos) <> 'END' then
    raise EIfaceFormatError.Create('CONST block: missing END marker');
end;

function ReadUnitInterface(const AText: string): TUnitInterface;
var
  Cur:    Integer;
  UName:  string;
  Tag:    string;
begin
  Cur := 0;  { 0-based cursor }
  ReadHeader(AText, Cur);
  UName := ReadLpstrAt(AText, Cur);
  Result := TUnitInterface.Create(UName);
  try
    while Cur < Length(AText) do
    begin
      SkipWhitespace(AText, Cur);
      if Cur >= Length(AText) then Break;
      Tag := ReadTag(AText, Cur);
      if      Tag = 'CONST' then ReadConsts(AText, Cur, Result)
      else if Tag = ''      then Break
      else
        raise EIfaceFormatError.Create(Format(
          'unknown record tag ''%s'' at position %d', [Tag, Cur]));
    end;
  except
    Result.Free;
    raise;
  end;
end;

end.
