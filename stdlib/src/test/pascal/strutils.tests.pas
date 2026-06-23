{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

{ Tests for the StrUtils split/join helpers (SplitChar / SplitLines /
  JoinList).  Self-registers via the initialization section. }

unit StrUtils.Tests;

interface

uses
  blaise.testing, StrUtils, Generics.Collections;

type
  TStrUtilsTests = class(TTestCase)
  published
    procedure TestSplitChar_Basic;
    procedure TestSplitChar_EmptyPieces;
    procedure TestSplitChar_NoDelim;
    procedure TestSplitChar_Empty;
    procedure TestSplitLines_LF;
    procedure TestSplitLines_CRLF;
    procedure TestSplitLines_TrailingNewline;
    procedure TestJoinList_Basic;
    procedure TestJoinList_Empty;
    procedure TestRoundTrip;
  end;

implementation

const
  CH_COMMA = 44;

procedure TStrUtilsTests.TestSplitChar_Basic;
var L: TList<String>;
begin
  L := SplitChar('a,b,c', CH_COMMA);
  AssertEquals('count', 3, Integer(L.Count));
  AssertEquals('0', 'a', L.Get(0));
  AssertEquals('1', 'b', L.Get(1));
  AssertEquals('2', 'c', L.Get(2));
end;

procedure TStrUtilsTests.TestSplitChar_EmptyPieces;
var L: TList<String>;
begin
  { leading, trailing and adjacent delimiters keep empty pieces }
  L := SplitChar(',a,,b,', CH_COMMA);
  AssertEquals('count', 5, Integer(L.Count));
  AssertEquals('0', '', L.Get(0));
  AssertEquals('1', 'a', L.Get(1));
  AssertEquals('2', '', L.Get(2));
  AssertEquals('3', 'b', L.Get(3));
  AssertEquals('4', '', L.Get(4));
end;

procedure TStrUtilsTests.TestSplitChar_NoDelim;
var L: TList<String>;
begin
  L := SplitChar('abc', CH_COMMA);
  AssertEquals('count', 1, Integer(L.Count));
  AssertEquals('0', 'abc', L.Get(0));
end;

procedure TStrUtilsTests.TestSplitChar_Empty;
var L: TList<String>;
begin
  L := SplitChar('', CH_COMMA);
  AssertEquals('count', 1, Integer(L.Count));
  AssertEquals('0', '', L.Get(0));
end;

procedure TStrUtilsTests.TestSplitLines_LF;
var L: TList<String>;
begin
  L := SplitLines('one'#10'two'#10'three');
  AssertEquals('count', 3, Integer(L.Count));
  AssertEquals('0', 'one', L.Get(0));
  AssertEquals('2', 'three', L.Get(2));
end;

procedure TStrUtilsTests.TestSplitLines_CRLF;
var L: TList<String>;
begin
  { CRLF lines: the trailing CR must be stripped }
  L := SplitLines('one'#13#10'two'#13#10'three');
  AssertEquals('count', 3, Integer(L.Count));
  AssertEquals('0', 'one', L.Get(0));
  AssertEquals('1', 'two', L.Get(1));
  AssertEquals('2', 'three', L.Get(2));
end;

procedure TStrUtilsTests.TestSplitLines_TrailingNewline;
var L: TList<String>;
begin
  { a trailing LF yields a final empty line }
  L := SplitLines('a'#10'b'#10);
  AssertEquals('count', 3, Integer(L.Count));
  AssertEquals('last', '', L.Get(2));
end;

procedure TStrUtilsTests.TestJoinList_Basic;
var L: TList<String>;
begin
  L := TList<String>.Create();
  L.Add('a'); L.Add('b'); L.Add('c');
  AssertEquals('joined', 'a-b-c', JoinList(L, '-'));
end;

procedure TStrUtilsTests.TestJoinList_Empty;
var L: TList<String>;
begin
  L := TList<String>.Create();
  AssertEquals('empty list', '', JoinList(L, '-'));
  AssertEquals('nil list', '', JoinList(nil, '-'));
end;

procedure TStrUtilsTests.TestRoundTrip;
var L: TList<String>;
begin
  { JoinList is the inverse of SplitChar on the same delimiter }
  L := SplitChar('x,y,z', CH_COMMA);
  AssertEquals('roundtrip', 'x,y,z', JoinList(L, ','));
end;

initialization
  RegisterTest(TStrUtilsTests);

end.
