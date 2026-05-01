{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: BSD-3-Clause
  See LICENSE file in the project root for full license terms.
}

{
  Blaise RTL — string operation functions (Pascal port of blaise_str.c)

  String memory layout (shared with blaise_arc.pas):
    +--[4 bytes]--+--[4 bytes]--+--[4 bytes]--+--[N bytes]--+--[1 byte]--+
    | RefCount    | Length      | Capacity    | UTF-8 data  | NUL        |
    +-------------+-------------+-------------+-------------+------------+
    ^--- string pointer (header ptr)

  nil represents an empty / unassigned string.
  RefCount = -1 marks immortal (statically-allocated) strings.

  Header field byte offsets:
    0  RefCount  (Integer, 4 bytes)
    4  Length    (Integer, 4 bytes)
    8  Capacity  (Integer, 4 bytes)
   12  char data begins (HDR_SIZE)
}

unit blaise_str;

{$mode objfpc}{$H+}

interface

{ ------------------------------------------------------------------ }
{ Libc bindings (malloc/free only — all other libc calls replaced)    }
{ ------------------------------------------------------------------ }
function  _libc_malloc(Size: Int64): Pointer; external name 'malloc';
procedure _libc_free(Ptr: Pointer);           external name 'free';

{ ------------------------------------------------------------------ }
{ String RTL public interface                                          }
{ ------------------------------------------------------------------ }
function  _StringLength(S: Pointer): Integer;
function  _StringPos(Sub, S: Pointer): Integer;
function  _StringCopy(S: Pointer; From, Count: Integer): Pointer;
function  _StringUpperCase(S: Pointer): Pointer;
function  _StringLowerCase(S: Pointer): Pointer;
function  _StringTrim(S: Pointer): Pointer;
function  _StringSameText(S1, S2: Pointer): Integer;
function  _IntToStr(N: Integer): Pointer;
function  _Int64ToStr(N: Int64): Pointer;
function  _StrToInt(S: Pointer): Integer;
function  _StrToInt64(S: Pointer): Int64;
function  _OrdAt(S: Pointer; I: Integer): Integer;
function  _Chr(N: Integer): Pointer;
function  _UpCase(N: Integer): Pointer;
function  _StringCompare(S1, S2: Pointer): Integer;
function  _StringCompareText(S1, S2: Pointer): Integer;
function  _StringFromPChar(P: PChar): Pointer;

{ _StringFormat is variadic and remains implemented in blaise_str.c }

implementation

const
  HDR_SIZE = 12;  { 3 x 4-byte integers: RefCount, Length, Capacity }

{ ------------------------------------------------------------------ }
{ Pure-Pascal memory helpers (no libc)                                 }
{ ------------------------------------------------------------------ }

procedure MemCopy(Dst, Src: Pointer; N: Integer);
var
  D, S: PChar;
  I:    Integer;
begin
  D := PChar(Dst);
  S := PChar(Src);
  for I := 0 to N - 1 do
    D[I] := S[I];
end;

{ ------------------------------------------------------------------ }
{ Internal helpers                                                     }
{ ------------------------------------------------------------------ }

function StrLen(Ptr: Pointer): Integer;
var
  P: ^Integer;
begin
  if Ptr = nil then
    Result := 0
  else
  begin
    P := Ptr + 4;  { Length field at offset 4 }
    Result := P^;
  end;
end;

function StrData(Ptr: Pointer): PChar;
begin
  Result := PChar(Ptr + HDR_SIZE);
end;

{ Allocate a new Blaise string of exactly Len bytes plus NUL.
  RefCount = 0 (unowned); caller must call _StringAddRef. }
function StrAlloc(Len: Integer): Pointer;
var
  TotalL: Int64;
  RC, LN, CP: ^Integer;
  NulPtr: PChar;
begin
  TotalL := Int64(HDR_SIZE) + Int64(Len) + 1;
  Result := _libc_malloc(TotalL);
  if Result = nil then Exit;
  RC  := Result;
  RC^ := 0;
  LN  := Result + 4;
  LN^ := Len;
  CP  := Result + 8;
  CP^ := Len;
  NulPtr      := PChar(Result + HDR_SIZE);
  NulPtr[Len] := 0;
end;

{ ------------------------------------------------------------------ }
{ _StringLength                                                        }
{ ------------------------------------------------------------------ }

function _StringLength(S: Pointer): Integer;
begin
  Result := StrLen(S);
end;

{ ------------------------------------------------------------------ }
{ _StringPos(Sub, S) : Integer  — 1-based; 0 if not found            }
{ ------------------------------------------------------------------ }

function _StringPos(Sub, S: Pointer): Integer;
var
  SLen, SubLen: Integer;
  SData, SubData: PChar;
  I, J: Integer;
  Match: Boolean;
begin
  SLen   := StrLen(S);
  SubLen := StrLen(Sub);
  if SubLen = 0 then
  begin
    Result := 1;
    Exit;
  end;
  if SubLen > SLen then
  begin
    Result := 0;
    Exit;
  end;
  SData   := StrData(S);
  SubData := StrData(Sub);
  I := 0;
  while I <= SLen - SubLen do
  begin
    Match := True;
    J := 0;
    while J < SubLen do
    begin
      if SData[I + J] <> SubData[J] then
      begin
        Match := False;
        Break;
      end;
      Inc(J);
    end;
    if Match then
    begin
      Result := I + 1;
      Exit;
    end;
    Inc(I);
  end;
  Result := 0;
end;

{ ------------------------------------------------------------------ }
{ _StringCopy(S, From, Count) : string  — 1-based From               }
{ ------------------------------------------------------------------ }

function _StringCopy(S: Pointer; From, Count: Integer): Pointer;
var
  SLen:  Integer;
  Data:  PChar;
  Start: Integer;
begin
  SLen := StrLen(S);
  if From < 1 then From := 1;
  Start := From - 1;
  if Start >= SLen then
  begin
    Result := StrAlloc(0);
    Exit;
  end;
  if (Count < 0) or (Start + Count > SLen) then
    Count := SLen - Start;
  Result := StrAlloc(Count);
  if (Result <> nil) and (Count > 0) then
  begin
    Data := StrData(S);
    MemCopy(Result + HDR_SIZE, Data + Start, Count);
  end;
end;

{ ------------------------------------------------------------------ }
{ _StringUpperCase                                                     }
{ ------------------------------------------------------------------ }

function _StringUpperCase(S: Pointer): Pointer;
var
  Len:     Integer;
  SrcData: PChar;
  DstData: PChar;
  I, C:    Integer;
begin
  Len    := StrLen(S);
  Result := StrAlloc(Len);
  if Result = nil then Exit;
  SrcData := StrData(S);
  DstData := PChar(Result + HDR_SIZE);
  for I := 0 to Len - 1 do
  begin
    C := SrcData[I];
    if (C >= 97) and (C <= 122) then
      DstData[I] := C - 32
    else
      DstData[I] := C;
  end;
end;

{ ------------------------------------------------------------------ }
{ _StringLowerCase                                                     }
{ ------------------------------------------------------------------ }

function _StringLowerCase(S: Pointer): Pointer;
var
  Len:     Integer;
  SrcData: PChar;
  DstData: PChar;
  I, C:    Integer;
begin
  Len    := StrLen(S);
  Result := StrAlloc(Len);
  if Result = nil then Exit;
  SrcData := StrData(S);
  DstData := PChar(Result + HDR_SIZE);
  for I := 0 to Len - 1 do
  begin
    C := SrcData[I];
    if (C >= 65) and (C <= 90) then
      DstData[I] := C + 32
    else
      DstData[I] := C;
  end;
end;

{ ------------------------------------------------------------------ }
{ _StringTrim                                                          }
{ ------------------------------------------------------------------ }

function _StringTrim(S: Pointer): Pointer;
var
  Len:    Integer;
  Data:   PChar;
  Lo, Hi: Integer;
  NewLen: Integer;
begin
  Len  := StrLen(S);
  Data := StrData(S);
  Lo := 0;
  while Lo < Len do
  begin
    if Data[Lo] > 32 then Break;
    Inc(Lo);
  end;
  Hi := Len - 1;
  while Hi >= Lo do
  begin
    if Data[Hi] > 32 then Break;
    Dec(Hi);
  end;
  if Hi >= Lo then
    NewLen := Hi - Lo + 1
  else
    NewLen := 0;
  Result := StrAlloc(NewLen);
  if (Result = nil) or (NewLen = 0) then Exit;
  MemCopy(Result + HDR_SIZE, Data + Lo, NewLen);
end;

{ ------------------------------------------------------------------ }
{ _StringSameText                                                      }
{ ------------------------------------------------------------------ }

function _StringSameText(S1, S2: Pointer): Integer;
var
  Len1, Len2, I: Integer;
  D1, D2:        PChar;
  C1, C2:        Integer;
begin
  Len1 := StrLen(S1);
  Len2 := StrLen(S2);
  if Len1 <> Len2 then
  begin
    Result := 0;
    Exit;
  end;
  D1 := StrData(S1);
  D2 := StrData(S2);
  for I := 0 to Len1 - 1 do
  begin
    C1 := D1[I];
    C2 := D2[I];
    if (C1 >= 65) and (C1 <= 90) then C1 := C1 + 32;
    if (C2 >= 65) and (C2 <= 90) then C2 := C2 + 32;
    if C1 <> C2 then
    begin
      Result := 0;
      Exit;
    end;
  end;
  Result := 1;
end;

{ ------------------------------------------------------------------ }
{ WriteDecimal — write N as decimal digits into Buf (no NUL).        }
{ Buf must have at least 21 bytes.  Returns character count.         }
{ ------------------------------------------------------------------ }

function WriteDecimal(N: Int64; Buf: PChar): Integer;
var
  IsNeg: Boolean;
  AbsN:  Int64;
  Pos:   Integer;
  Tmp:   Pointer;
  TP:    PChar;
  I, J:  Integer;
  Digit: Integer;
begin
  Tmp := _libc_malloc(22);
  TP  := PChar(Tmp);
  IsNeg := N < 0;
  if IsNeg then
    AbsN := -N
  else
    AbsN := N;
  if AbsN = 0 then
  begin
    TP[0] := 48;  { '0' }
    Pos   := 1;
  end
  else
  begin
    Pos := 0;
    while AbsN > 0 do
    begin
      Digit  := Integer(AbsN mod 10);
      TP[Pos] := 48 + Digit;
      AbsN   := AbsN div 10;
      Inc(Pos);
    end;
  end;
  I := 0;
  if IsNeg then
  begin
    Buf[0] := 45;  { '-' }
    I := 1;
  end;
  J := Pos - 1;
  while J >= 0 do
  begin
    Buf[I] := TP[J];
    Inc(I);
    Dec(J);
  end;
  _libc_free(Tmp);
  Result := I;
end;

{ ------------------------------------------------------------------ }
{ _IntToStr                                                            }
{ ------------------------------------------------------------------ }

function _IntToStr(N: Integer): Pointer;
var
  Buf:     Pointer;
  BP:      PChar;
  Written: Integer;
begin
  Buf     := _libc_malloc(22);
  BP      := PChar(Buf);
  Written := WriteDecimal(Int64(N), BP);
  Result  := StrAlloc(Written);
  if (Result <> nil) and (Written > 0) then
    MemCopy(Result + HDR_SIZE, Buf, Written);
  _libc_free(Buf);
end;

{ ------------------------------------------------------------------ }
{ _Int64ToStr                                                          }
{ ------------------------------------------------------------------ }

function _Int64ToStr(N: Int64): Pointer;
var
  Buf:     Pointer;
  BP:      PChar;
  Written: Integer;
begin
  Buf     := _libc_malloc(22);
  BP      := PChar(Buf);
  Written := WriteDecimal(N, BP);
  Result  := StrAlloc(Written);
  if (Result <> nil) and (Written > 0) then
    MemCopy(Result + HDR_SIZE, Buf, Written);
  _libc_free(Buf);
end;

{ ------------------------------------------------------------------ }
{ _StrToInt / _StrToInt64                                             }
{ ------------------------------------------------------------------ }

function _StrToInt(S: Pointer): Integer;
var
  Data:  PChar;
  Neg:   Boolean;
  I, C:  Integer;
  Value: Int64;
begin
  Data  := StrData(S);
  I     := 0;
  Neg   := False;
  if Data[0] = 45 then  { '-' }
  begin
    Neg := True;
    I   := 1;
  end
  else if Data[0] = 43 then  { '+' }
    I := 1;
  Value := 0;
  C := Data[I];
  while (C >= 48) and (C <= 57) do
  begin
    Value := Value * 10 + Int64(C - 48);
    Inc(I);
    C := Data[I];
  end;
  if Neg then
    Result := Integer(-Value)
  else
    Result := Integer(Value);
end;

function _StrToInt64(S: Pointer): Int64;
var
  Data:  PChar;
  Neg:   Boolean;
  I, C:  Integer;
begin
  Data  := StrData(S);
  I     := 0;
  Neg   := False;
  if Data[0] = 45 then
  begin
    Neg := True;
    I   := 1;
  end
  else if Data[0] = 43 then
    I := 1;
  Result := 0;
  C := Data[I];
  while (C >= 48) and (C <= 57) do
  begin
    Result := Result * 10 + Int64(C - 48);
    Inc(I);
    C := Data[I];
  end;
  if Neg then
    Result := -Result;
end;

{ ------------------------------------------------------------------ }
{ _OrdAt                                                               }
{ ------------------------------------------------------------------ }

function _OrdAt(S: Pointer; I: Integer): Integer;
var
  Len:  Integer;
  Data: PChar;
begin
  Len  := StrLen(S);
  if (I < 1) or (I > Len) then
  begin
    Result := 0;
    Exit;
  end;
  Data   := StrData(S);
  Result := Data[I - 1];
end;

{ ------------------------------------------------------------------ }
{ _Chr                                                                 }
{ ------------------------------------------------------------------ }

function _Chr(N: Integer): Pointer;
var
  DP: PChar;
begin
  Result := StrAlloc(1);
  if Result = nil then Exit;
  DP    := PChar(Result + HDR_SIZE);
  DP[0] := N;
end;

{ ------------------------------------------------------------------ }
{ _UpCase                                                              }
{ ------------------------------------------------------------------ }

function _UpCase(N: Integer): Pointer;
var
  C: Integer;
begin
  C := N;
  if (C >= 97) and (C <= 122) then
    C := C - 32;
  Result := _Chr(C);
end;

{ ------------------------------------------------------------------ }
{ _StringCompare                                                       }
{ ------------------------------------------------------------------ }

function _StringCompare(S1, S2: Pointer): Integer;
var
  Len1, Len2, Len: Integer;
  D1, D2:          PChar;
  I, C1, C2:       Integer;
begin
  Len1 := StrLen(S1);
  Len2 := StrLen(S2);
  if Len1 < Len2 then Len := Len1 else Len := Len2;
  D1 := StrData(S1);
  D2 := StrData(S2);
  for I := 0 to Len - 1 do
  begin
    C1 := D1[I];
    C2 := D2[I];
    if C1 <> C2 then
    begin
      Result := C1 - C2;
      Exit;
    end;
  end;
  Result := Len1 - Len2;
end;

{ ------------------------------------------------------------------ }
{ _StringCompareText                                                   }
{ ------------------------------------------------------------------ }

function _StringCompareText(S1, S2: Pointer): Integer;
var
  Len1, Len2, Len: Integer;
  D1, D2:          PChar;
  I, C1, C2:       Integer;
begin
  Len1 := StrLen(S1);
  Len2 := StrLen(S2);
  if Len1 < Len2 then Len := Len1 else Len := Len2;
  D1 := StrData(S1);
  D2 := StrData(S2);
  for I := 0 to Len - 1 do
  begin
    C1 := D1[I];
    C2 := D2[I];
    if (C1 >= 65) and (C1 <= 90) then C1 := C1 + 32;
    if (C2 >= 65) and (C2 <= 90) then C2 := C2 + 32;
    if C1 <> C2 then
    begin
      Result := C1 - C2;
      Exit;
    end;
  end;
  Result := Len1 - Len2;
end;

{ ------------------------------------------------------------------ }
{ _StringFromPChar                                                     }
{ ------------------------------------------------------------------ }

function _StringFromPChar(P: PChar): Pointer;
var
  Len: Integer;
begin
  if P = nil then
  begin
    Result := StrAlloc(0);
    Exit;
  end;
  Len := 0;
  while P[Len] <> 0 do
    Inc(Len);
  Result := StrAlloc(Len);
  if (Result <> nil) and (Len > 0) then
    MemCopy(Result + HDR_SIZE, P, Len);
end;

end.
