{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

{
  Bootstrap compatibility shim — 0-based string helpers.

  Blaise strings are 0-based: S[0] is the first character, Pos returns
  a 0-based index (-1 = not found), Copy takes a 0-based From argument.

  When this unit is compiled by FPC (which uses 1-based strings), each
  wrapper converts between conventions so the compiler source can be
  written uniformly in Blaise style.  When compiled by Blaise itself the
  built-in intrinsics are already 0-based, so the wrappers are thin
  pass-throughs that the optimiser will inline away.

  Usage:
    - Replace s[1] with StrAt(s, 0)
    - Replace Pos(sub, s) > 0  with Pos(sub, s) >= 0
    - Replace Copy(s, n, len)  with Copy(s, n, len)  (already 0-based in Blaise)
    - Use StrAt(s, i) instead of s[i+1] style char access
}

unit uStrCompat;

{$mode objfpc}{$H+}

interface

{ StrAt: return ordinal of character at 0-based index I }
function StrAt(const S: string; I: Integer): Integer;

{ StrCopyFrom: copy from 0-based position From, Count chars }
function StrCopyFrom(const S: string; From, Count: Integer): string;

{ StrCopyTail: copy from 0-based position From to end of string }
function StrCopyTail(const S: string; From: Integer): string;

{ StrHead: copy the first N characters (equivalent to Copy(s, 0, N)) }
function StrHead(const S: string; N: Integer): string;

{ StrPos: find sub in s, return 0-based index; -1 if not found }
function StrPos(const Sub, S: string): Integer;

implementation

{$IFDEF FPC}

function StrAt(const S: string; I: Integer): Integer;
begin
  Result := Ord(S[I + 1]);
end;

function StrCopyFrom(const S: string; From, Count: Integer): string;
begin
  Result := Copy(S, From + 1, Count);
end;

function StrCopyTail(const S: string; From: Integer): string;
begin
  Result := Copy(S, From + 1, MaxInt);
end;

function StrHead(const S: string; N: Integer): string;
begin
  Result := Copy(S, 1, N);
end;

function StrPos(const Sub, S: string): Integer;
begin
  Result := Pos(Sub, S) - 1;  { FPC Pos is 1-based; 0 → -1 (not found) }
end;

{$ELSE}

function StrAt(const S: string; I: Integer): Integer;
begin
  Result := OrdAt(S, I);
end;

function StrCopyFrom(const S: string; From, Count: Integer): string;
begin
  Result := Copy(S, From, Count);
end;

function StrCopyTail(const S: string; From: Integer): string;
begin
  Result := Copy(S, From, MaxInt);
end;

function StrHead(const S: string; N: Integer): string;
begin
  Result := Copy(S, 0, N);
end;

function StrPos(const Sub, S: string): Integer;
begin
  Result := Pos(Sub, S);
end;

{$ENDIF}

end.
