{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

{ Basic smoke test for punit: a single always-failing test via RunTest. }

program testpunit1;

uses punit;

function DoTest : string;
begin
  Result := 'test failed';
end;

begin
  RunTest(@DoTest);
end.
