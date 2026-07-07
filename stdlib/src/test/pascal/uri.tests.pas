{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

{ Tests for Net.Uri (docs/async-networking-design.adoc, L5): the transport-
  agnostic URL/URI parser + builder that underpins Net.Http.Client.

  Covers: parse of a full URL, scheme-default ports (http=80, https=443),
  percent encode/decode round-trip, query parsing into key/value pairs, and
  edge cases (no path -> '/', no query, explicit port override, IPv4 literal
  host, userinfo, fragment).

  Pure Pascal, no sockets.  Self-registers via the initialization section. }

unit Uri.Tests;

interface

uses
  blaise.testing, SysUtils, Net.Uri;

type
  TUriTests = class(TTestCase)
  published
    procedure TestParseFullUrl;
    procedure TestDefaultPortHttp;
    procedure TestDefaultPortHttps;
    procedure TestPortOverride;
    procedure TestMissingPathBecomesSlash;
    procedure TestNoQuery;
    procedure TestQueryParse;
    procedure TestUserInfo;
    procedure TestFragment;
    procedure TestIPv4Host;
    procedure TestEncodeComponent;
    procedure TestDecodeComponent;
    procedure TestEncodeDecodeRoundTrip;
    procedure TestToStringRoundTrip;
    procedure TestQueryParam;
    procedure TestSchemeCaseInsensitive;
  end;

implementation

procedure TUriTests.TestParseFullUrl;
var
  U: TUri;
begin
  U := TUri.Parse('http://example.com:8080/path/to/page?a=1&b=2#frag');
  try
    AssertEquals('scheme', 'http', U.Scheme);
    AssertEquals('host', 'example.com', U.Host);
    AssertEquals('port', 8080, U.Port);
    AssertEquals('path', '/path/to/page', U.Path);
    AssertEquals('query', 'a=1&b=2', U.Query);
    AssertEquals('fragment', 'frag', U.Fragment);
  finally
    U.Free();
  end;
end;

procedure TUriTests.TestDefaultPortHttp;
var
  U: TUri;
begin
  U := TUri.Parse('http://example.com/');
  try
    AssertEquals('http default port', 80, U.Port);
  finally
    U.Free();
  end;
end;

procedure TUriTests.TestDefaultPortHttps;
var
  U: TUri;
begin
  U := TUri.Parse('https://example.com/');
  try
    AssertEquals('https default port', 443, U.Port);
    AssertEquals('scheme', 'https', U.Scheme);
  finally
    U.Free();
  end;
end;

procedure TUriTests.TestPortOverride;
var
  U: TUri;
begin
  U := TUri.Parse('https://example.com:9443/');
  try
    AssertEquals('explicit port overrides default', 9443, U.Port);
  finally
    U.Free();
  end;
end;

procedure TUriTests.TestMissingPathBecomesSlash;
var
  U: TUri;
begin
  U := TUri.Parse('http://example.com');
  try
    AssertEquals('missing path defaults to /', '/', U.Path);
    AssertEquals('host still parsed', 'example.com', U.Host);
    AssertEquals('port still defaulted', 80, U.Port);
  finally
    U.Free();
  end;
end;

procedure TUriTests.TestNoQuery;
var
  U: TUri;
begin
  U := TUri.Parse('http://example.com/x');
  try
    AssertEquals('empty query', '', U.Query);
    AssertEquals('empty fragment', '', U.Fragment);
  finally
    U.Free();
  end;
end;

procedure TUriTests.TestQueryParse;
var
  U: TUri;
begin
  U := TUri.Parse('http://h/p?name=Ada&city=London&flag');
  try
    AssertEquals('query param name', 'Ada', U.QueryParam('name'));
    AssertEquals('query param city', 'London', U.QueryParam('city'));
    AssertEquals('valueless key -> empty', '', U.QueryParam('flag'));
    AssertEquals('missing key -> empty', '', U.QueryParam('nope'));
  finally
    U.Free();
  end;
end;

procedure TUriTests.TestUserInfo;
var
  U: TUri;
begin
  U := TUri.Parse('http://user:pass@example.com:81/x');
  try
    AssertEquals('userinfo', 'user:pass', U.UserInfo);
    AssertEquals('host after userinfo', 'example.com', U.Host);
    AssertEquals('port after userinfo', 81, U.Port);
  finally
    U.Free();
  end;
end;

procedure TUriTests.TestFragment;
var
  U: TUri;
begin
  U := TUri.Parse('http://h/p#section-2');
  try
    AssertEquals('fragment without query', 'section-2', U.Fragment);
    AssertEquals('query empty', '', U.Query);
  finally
    U.Free();
  end;
end;

procedure TUriTests.TestIPv4Host;
var
  U: TUri;
begin
  U := TUri.Parse('http://127.0.0.1:29500/api');
  try
    AssertEquals('ipv4 host', '127.0.0.1', U.Host);
    AssertEquals('ipv4 port', 29500, U.Port);
    AssertEquals('ipv4 path', '/api', U.Path);
  finally
    U.Free();
  end;
end;

procedure TUriTests.TestEncodeComponent;
begin
  AssertEquals('space encodes', 'a%20b', EncodeComponent('a b'));
  AssertEquals('reserved encodes', 'a%2Fb%3Fc', EncodeComponent('a/b?c'));
  AssertEquals('unreserved untouched', 'AZaz09-_.~', EncodeComponent('AZaz09-_.~'));
end;

procedure TUriTests.TestDecodeComponent;
begin
  AssertEquals('percent decode', 'a b', DecodeComponent('a%20b'));
  AssertEquals('plus stays plus', 'a+b', DecodeComponent('a+b'));
  AssertEquals('slash decode', 'a/b', DecodeComponent('a%2Fb'));
  AssertEquals('lowercase hex', 'a b', DecodeComponent('a%20b'));
end;

procedure TUriTests.TestEncodeDecodeRoundTrip;
const
  Raw = 'hello world/ +&=?#%';
begin
  AssertEquals('round trip', Raw, DecodeComponent(EncodeComponent(Raw)));
end;

procedure TUriTests.TestToStringRoundTrip;
var
  U: TUri;
  S: string;
begin
  U := TUri.Parse('http://example.com:8080/path?a=1#f');
  try
    S := U.ToString();
    AssertEquals('ToString reconstructs the URL',
      'http://example.com:8080/path?a=1#f', S);
  finally
    U.Free();
  end;
end;

procedure TUriTests.TestQueryParam;
var
  U: TUri;
begin
  U := TUri.Parse('http://h/?q=a%20b');
  try
    AssertEquals('query param is percent-decoded', 'a b', U.QueryParam('q'));
  finally
    U.Free();
  end;
end;

procedure TUriTests.TestSchemeCaseInsensitive;
var
  U: TUri;
begin
  U := TUri.Parse('HTTPS://Example.COM/x');
  try
    AssertEquals('scheme lowercased', 'https', U.Scheme);
    AssertEquals('https default from uppercase scheme', 443, U.Port);
  finally
    U.Free();
  end;
end;

initialization
  RegisterTest(TUriTests);

end.
