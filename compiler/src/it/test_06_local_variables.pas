{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

program test_06_local_variables;


{ Test program for debugging local variables and function parameters }

function Calculate(A, B: Integer): Integer;
var
  Sum: Integer;
  Product: Integer;
begin
  Sum := A + B;
  Product := A * B;
  Result := Sum + Product;  { Breakpoint line for testing locals }
end;

var
  X, Y, ResultValue: Integer;
  Sentinel: Integer;
begin
  X := 5;
  Y := 10;
  ResultValue := Calculate(X, Y);
  Sentinel := 1;
end.
