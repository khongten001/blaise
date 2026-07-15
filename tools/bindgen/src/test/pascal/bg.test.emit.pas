{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit bg.test.emit;

{ Tests for Bindgen.Emit — C declaration model → Blaise unit source.

  Assertions are substring checks on the generated source; the
  compile-the-output check lives in the e2e layer, not here. }

interface

uses
  blaise.testing, strutils,
  Bindgen.Model, Bindgen.Emit;

type
  TEmitTests = class(TTestCase)
  private
    FModel: TCModel;
    function Emit: string;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestEmit_UnitSkeleton;
    procedure TestEmit_Function_ExternalWithLibAndName;
    procedure TestEmit_Function_PointerReturnSynthesisesAlias;
    procedure TestEmit_Procedure_ForVoidReturn;
    procedure TestEmit_Typedef_MappedType;
    procedure TestEmit_EnumAlias_AndMemberConsts;
    procedure TestEmit_Record_WithMappedFields;
    procedure TestEmit_OpaqueRecord_EmptyRecord;
    procedure TestEmit_Variadic_SkippedWithComment;
    procedure TestEmit_ReservedWordParam_Renamed;
    procedure TestEmit_UnnamedParam_Synthesised;
    procedure TestEmit_PtrAliases_PrecedeOtherTypes;
    procedure TestEmit_CDeclOrder_Preserved;
    procedure TestEmit_UnknownAliasTarget_DegradesToPointer;
    procedure TestEmit_UnknownTypedefRHS_DegradesToPointer;
    procedure TestEmit_Union_ExactSizeRawArray;
    procedure TestEmit_Union_Uncomputable_Placeholder;
    procedure TestEmit_FnPtrTypedef_ProceduralType;
    procedure TestEmit_InlineFnPtrParam_SynthesisedType;
    procedure TestEmit_VariadicFnPtrTypedef_DegradesToPointer;
  end;

implementation

procedure TEmitTests.SetUp;
var
  R: TCRecord;
  E: TCEnum;
  F: TCFunction;
begin
  { A miniature Xlib-flavoured model covering every emission shape. }
  FModel := TCModel.Create();

  FModel.AddTypedef(TCTypedef.Create('XID', 'unsigned long'));
  FModel.AddTypedef(TCTypedef.Create('Display', 'struct _XDisplay'));

  R := TCRecord.Create('_XDisplay');
  FModel.AddRecord(R);

  R := TCRecord.Create('XPoint');
  R.IsComplete := True;
  R.Fields.Add(TCField.Create('x', 'int'));
  R.Fields.Add(TCField.Create('serial', 'unsigned long'));
  R.Fields.Add(TCField.Create('name', 'const char *'));
  FModel.AddRecord(R);

  E := TCEnum.Create('XOrientation');
  E.Members.Add(TCEnumMember.Create('XOrientVertical', 0));
  E.Members.Add(TCEnumMember.Create('XOrientHorizontal', 5));
  FModel.AddEnum(E);

  F := TCFunction.Create('XOpenDisplay');
  F.ReturnCType := 'Display *';
  F.Params.Add(TCParam.Create('display_name', 'const char *'));
  FModel.AddFunction(F);

  F := TCFunction.Create('XFlushNothing');
  F.ReturnCType := 'void';
  FModel.AddFunction(F);

  F := TCFunction.Create('XVariadicThing');
  F.ReturnCType := 'int';
  F.Params.Add(TCParam.Create('mode', 'int'));
  F.IsVariadic := True;
  FModel.AddFunction(F);

  F := TCFunction.Create('XReserved');
  F.ReturnCType := 'int';
  F.Params.Add(TCParam.Create('type', 'int'));
  F.Params.Add(TCParam.Create('', 'double'));
  FModel.AddFunction(F);
end;

procedure TEmitTests.TearDown;
begin
  FModel := nil;
end;

function TEmitTests.Emit: string;
begin
  Result := EmitBinding(FModel, 'x11', 'X11');
end;

procedure TEmitTests.TestEmit_UnitSkeleton;
var
  Src: string;
begin
  Src := Self.Emit();
  AssertTrue('unit clause', ContainsStr(Src, 'unit x11;'));
  AssertTrue('interface', ContainsStr(Src, 'interface'));
  AssertTrue('implementation', ContainsStr(Src, 'implementation'));
  AssertTrue('do-not-edit marker', ContainsStr(Src, 'DO NOT EDIT'));
end;

procedure TEmitTests.TestEmit_Function_ExternalWithLibAndName;
begin
  AssertTrue(ContainsStr(Self.Emit(),
    'function XOpenDisplay(display_name: PChar): PDisplay; cdecl; ' +
    'external ''X11'' name ''XOpenDisplay'';'));
end;

procedure TEmitTests.TestEmit_Function_PointerReturnSynthesisesAlias;
begin
  AssertTrue(ContainsStr(Self.Emit(), 'PDisplay = ^Display;'));
end;

procedure TEmitTests.TestEmit_Procedure_ForVoidReturn;
begin
  AssertTrue(ContainsStr(Self.Emit(),
    'procedure XFlushNothing; cdecl; external ''X11'' name ''XFlushNothing'';'));
end;

procedure TEmitTests.TestEmit_Typedef_MappedType;
begin
  AssertTrue(ContainsStr(Self.Emit(), 'XID = UInt64;'));
end;

procedure TEmitTests.TestEmit_EnumAlias_AndMemberConsts;
var
  Src: string;
begin
  Src := Self.Emit();
  AssertTrue('alias', ContainsStr(Src, 'XOrientation = Integer;'));
  AssertTrue('implicit member', ContainsStr(Src, 'XOrientVertical = 0;'));
  AssertTrue('explicit member', ContainsStr(Src, 'XOrientHorizontal = 5;'));
end;

procedure TEmitTests.TestEmit_Record_WithMappedFields;
var
  Src: string;
begin
  Src := Self.Emit();
  AssertTrue('record open', ContainsStr(Src, 'XPoint = record'));
  AssertTrue('int field', ContainsStr(Src, 'x: Integer;'));
  AssertTrue('unsigned long field', ContainsStr(Src, 'serial: UInt64;'));
  AssertTrue('char* field', ContainsStr(Src, 'name: PChar;'));
end;

procedure TEmitTests.TestEmit_OpaqueRecord_EmptyRecord;
begin
  AssertTrue(ContainsStr(Self.Emit(), '_XDisplay = record end;'));
end;

procedure TEmitTests.TestEmit_Variadic_SkippedWithComment;
var
  Src: string;
begin
  Src := Self.Emit();
  AssertTrue('no declaration', not ContainsStr(Src, 'function XVariadicThing'));
  AssertTrue('skip note', ContainsStr(Src, 'XVariadicThing'));
  AssertTrue('reason stated', ContainsStr(Src, 'variadic'));
end;

procedure TEmitTests.TestEmit_ReservedWordParam_Renamed;
begin
  AssertTrue(ContainsStr(Self.Emit(), 'type_: Integer'));
end;

procedure TEmitTests.TestEmit_UnnamedParam_Synthesised;
begin
  AssertTrue(ContainsStr(Self.Emit(), 'a1: Double'));
end;

procedure TEmitTests.TestEmit_PtrAliases_PrecedeOtherTypes;
var
  Src: string;
begin
  { Forward pointer declarations are legal in Blaise, so the synthetic
    aliases go first — a record field may reference one. }
  Src := Self.Emit();
  AssertTrue('alias before typedefs',
    Pos('PDisplay = ^Display;', Src) < Pos('XID = UInt64;', Src));
end;

procedure TEmitTests.TestEmit_CDeclOrder_Preserved;
var
  Src: string;
begin
  { XID was declared before XPoint in C; a field of a later record may
    reference an earlier typedef, so C order must be preserved. }
  Src := Self.Emit();
  AssertTrue('typedef before record',
    Pos('XID = UInt64;', Src) < Pos('XPoint = record', Src));
end;

procedure TEmitTests.TestEmit_UnknownAliasTarget_DegradesToPointer;
var
  F: TCFunction;
  Src: string;
begin
  { A parameter typed 'struct __va_list_tag *' synthesises an alias to
    a struct declared in a FILTERED-OUT system header.  The alias must
    degrade to an untyped Pointer, not reference an undeclared name. }
  F := TCFunction.Create('XUsesHidden');
  F.ReturnCType := 'int';
  F.Params.Add(TCParam.Create('va', 'struct __va_list_tag *'));
  FModel.AddFunction(F);
  Src := Self.Emit();
  AssertTrue('degraded', ContainsStr(Src, 'P__va_list_tag = Pointer;'));
  AssertTrue('no dangling ref', not ContainsStr(Src, '^__va_list_tag'));
end;

procedure TEmitTests.TestEmit_UnknownTypedefRHS_DegradesToPointer;
var
  Src: string;
begin
  { A typedef whose RHS names a type from a filtered-out header cannot
    be emitted verbatim — the name does not exist in the unit. }
  FModel.AddTypedef(TCTypedef.Create('MysteryHandle', 'struct hidden_tag *'));
  Src := Self.Emit();
  AssertTrue(ContainsStr(Src, 'Phidden_tag = Pointer;'));
end;

procedure TEmitTests.TestEmit_Union_ExactSizeRawArray;
var
  R: TCRecord;
  Src: string;
begin
  { XEvent-style union of int + long[24] = 192 bytes; by-value use
    demands the exact size, so it becomes a 24-element UInt64 array
    (which also carries the C union's 8-byte alignment). }
  R := TCRecord.Create('_XSampleEvent');
  R.IsUnion := True;
  R.IsComplete := True;
  R.Fields.Add(TCField.Create('type', 'int'));
  R.Fields.Add(TCField.Create('pad', 'long[24]'));
  FModel.AddRecord(R);
  Src := Self.Emit();
  AssertTrue('record emitted', ContainsStr(Src, '_XSampleEvent = record'));
  AssertTrue('raw array', ContainsStr(Src, 'raw: array[0..23] of UInt64;'));
end;

procedure TEmitTests.TestEmit_Union_Uncomputable_Placeholder;
var
  R: TCRecord;
  Src: string;
begin
  R := TCRecord.Create('BadUnion');
  R.IsUnion := True;
  R.IsComplete := True;
  R.Fields.Add(TCField.Create('m', 'struct never_declared'));
  FModel.AddRecord(R);
  Src := Self.Emit();
  AssertTrue(ContainsStr(Src, 'BadUnion = record end;'));
end;

procedure TEmitTests.TestEmit_FnPtrTypedef_ProceduralType;
var
  Src: string;
begin
  FModel.AddTypedef(TCTypedef.Create('XErrorHandler',
    'int (*)(Display *, int)'));
  Src := Self.Emit();
  AssertTrue(ContainsStr(Src,
    'XErrorHandler = function(a0: PDisplay; a1: Integer): Integer;'));
end;

procedure TEmitTests.TestEmit_InlineFnPtrParam_SynthesisedType;
var
  F: TCFunction;
  Src: string;
begin
  F := TCFunction.Create('XIfThing');
  F.ReturnCType := 'int';
  F.Params.Add(TCParam.Create('predicate', 'int (*)(Display *, XID)'));
  FModel.AddFunction(F);
  Src := Self.Emit();
  AssertTrue('synth type declared', ContainsStr(Src,
    'TXIfThing_predicate = function(a0: PDisplay; a1: XID): Integer;'));
  AssertTrue('param uses it', ContainsStr(Src,
    'XIfThing(predicate: TXIfThing_predicate)'));
end;

procedure TEmitTests.TestEmit_VariadicFnPtrTypedef_DegradesToPointer;
var
  Src: string;
begin
  FModel.AddTypedef(TCTypedef.Create('XVaHandler', 'int (*)(Display *, ...)'));
  Src := Self.Emit();
  AssertTrue(ContainsStr(Src, 'XVaHandler = Pointer;'));
end;

initialization
  RegisterTest(TEmitTests);

end.
