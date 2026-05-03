{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit SysUtils;

// Blaise RTL — SysUtils unit.
//
// Provides the Exception base class.  All other SysUtils functionality
// (Format, IntToStr, StrToInt, etc.) is provided by compiler built-ins
// and does not require a runtime unit.
//
// Note: Exception.CreateFmt is intentionally absent.  All uses of
// CreateFmt in the compiler source are replaced with Create(Format(...))
// as part of the self-hosting source adaptation (Step 7).

interface

type
  Exception = class
    FMessage: string;
    constructor Create(AMessage: string);
    property Message: string read FMessage;
  end;

implementation

constructor Exception.Create(AMessage: string);
begin
  Self.FMessage := AMessage
end;

end.
