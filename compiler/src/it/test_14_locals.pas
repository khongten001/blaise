program test_14_locals;


{ Test program for 'locals' command — lists all in-scope variables }

var
  GlobalCount: Integer;
  Sentinel: Integer;

function Compute(A, B: Integer): Integer;
var
  Sum: Integer;
  Product: Integer;
begin
  Sum := A + B;
  Product := A * B;
  Result := Sum + Product;  { breakpoint here — line 17 }
end;

begin
  WriteLn(Compute(3, 7));
  WriteLn(GlobalCount);
  Sentinel := 1;
end.
