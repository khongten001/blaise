{
  Blaise stdlib - XML reader
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

{ Blaise stdlib - XML reader facade.

  GetXML parses an XML document string into the Xml.Types tree by driving the
  Xml.Parser engine.  The caller owns the returned document (parent-owns-
  child); releasing it frees the whole tree.  EXMLParseError is raised on
  malformed input.

      Doc := GetXML(S);
      Title := Doc.Root.ChildText('title');
      Doc.Free();
}

unit Xml.Reader;

interface

uses
  Xml.Types, Xml.Parser;

{ Parse AText into an XML document.  Raises EXMLParseError on malformed
  input.  Whitespace-only text nodes are dropped; use TXMLParser directly
  with PreserveWhitespace := True to keep them. }
function GetXML(const AText: string): TXMLDocument;

implementation

function GetXML(const AText: string): TXMLDocument;
var
  P: TXMLParser;
begin
  P := TXMLParser.Create(AText);
  Result := P.Parse();
  P.Free();
end;

end.
