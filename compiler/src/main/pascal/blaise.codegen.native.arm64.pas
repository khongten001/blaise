{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.
}

unit blaise.codegen.native.arm64;

{ AArch64 (Apple Silicon macOS) native backend — the second Template-Method
  leaf of TNativeBackend (macos-arm64 Phase 2,
  docs/macos-arm64-backend-design.adoc).

  Emits AArch64 GNU-syntax assembly text into the inherited FAsm buffer;
  blaise.assembler.arm64 encodes that text into a Mach-O MH_OBJECT.  All
  target-independent walks (the ARC field-kind walk, ClassifyRecordReturn)
  come from the base class; this leaf supplies only registers and mnemonics.

  DELIBERATELY INCREMENTAL: this backend currently lowers a well-defined
  subset (program entry, integer arithmetic/comparisons, integer and string
  locals/globals, WriteLn/Write, if/while).  Every unsupported construct
  raises ENativeCodeGenError with an 'arm64:' prefix naming the node — an
  honest hole, never silent wrong code.  The subset grows commit by commit
  against the Phase 2 checklist.

  Conventions in this leaf (AAPCS64 + Apple):
    x0-x7 / d0-d7   argument + result registers
    x8               sret pointer (indirect record result)
    x9-x15           scratch
    x16/x17          IP0/IP1 (linker veneers) — not used by codegen
    x18              RESERVED by Apple — never touched
    x19-x28          callee-saved (x19 = ARC base anchor, x20/x21 = the
                     ARC walk scratch pair — the %rbx/%r14/%r15 analogues)
    x29/x30          frame pointer / link register — the fp chain is ALWAYS
                     maintained (Darwin unwind requirement)
    sp               16-byte aligned at every call

  Frame model: `stp x29, x30, [sp, #-16]!` + `mov x29, sp` +
  `sub sp, sp, #FrameSize`.  Locals live at NEGATIVE x29 offsets and are
  addressed with ldur/stur (unscaled ±256) or a materialised address for
  larger frames.  Expression evaluation uses full-width stack brackets
  (`str x0, [sp, #-16]!` / `ldr x9, [sp], #16`) so sp stays 16-aligned. }

interface

uses
  SysUtils, Classes, contnrs, Generics.Collections, uAST, uSymbolTable,
  uStrCompat, blaise.codegen, blaise.codegen.native.backend,
  blaise.codegen.target;

const
  VIRT_NONE = -1;   { EmitCall: no virtual dispatch — direct bl }

type
  TArm64Backend = class(TNativeBackend)
  private
    FFrame:       TDictionary<string, Integer>;  { local -> POSITIVE byte
                                                   distance below x29 }
    FFrameSize:   Integer;
    FGlobalNames: TStringList;                   { program-level int globals }
    FStrLits:     TStringList;
    FLabelN:      Integer;
    FProgramName: string;
    FIsFunction:  Boolean;       { current routine returns a value }
    FResultFloat: Boolean;       { ...and that value is a Double (d0) }
    FResultSingle: Boolean;      { ...or a Single (returned in s0) }
    FExitLabel:   string;        { current routine's epilogue label }
    FBreakLbls:   TStringList;   { innermost-last loop end labels }
    FContLbls:    TStringList;   { innermost-last loop continue labels }
    FForN:        Integer;       { hidden for-loop end-slot counter }
    FFloatLits:   TStringList;   { .rodata double-literal texts }
    FStrLocals:   TStringList;   { string locals of the current routine —
                                   released at the shared exit label }
    FCurrentUnitName: string;    { '' = program context; else the unit being emitted }
    FModuleVarNames: TStringList; { unit-level var names (both sections) — these
                                    take the owning-unit symbol prefix }
    FUnitInits:   TStringList;   { emitted <unit>_init symbols, called by _main }
    FGlobalInits: TDictionary<string, string>;  { prefixed symbol -> .data
                                    directive for initialised globals }
    FClassDecls:  TObjectList;   { not owned — program-level class TTypeDecls }
    FObjLocals:   TStringList;   { class-typed locals — released at scope exit }
    FObjGlobals:  TStringList;   { class-typed globals — released at program exit }
    FStrGlobals:  TStringList;   { string program globals — released at
                                   the program exit }
    FRecLocals:   TStringList;   { record locals; Objects = TRecordTypeDesc }
    FRecGlobals:  TStringList;   { record program globals; Objects = desc }
    FGlobalSize:  TDictionary<string, Integer>;  { bss size per global }
    FFloatNames:  TStringList;   { program-level float globals (parallel
                                   subset of FGlobalNames' world) }

    function  NewLabel(const APrefix: string): string;
    procedure NotYet(const AWhat: string; ANode: TASTNode);

    { ---- frame + operands ---- }
    procedure AddLocal(const AName: string; ASize: Integer);
    function  IsLocal(const AName: string): Boolean;
    { Load/store x-register <-> local slot / global (int-family only). }
    procedure EmitLoadSlot(const AReg, AName: string);
    procedure EmitStoreSlot(const AReg, AName: string);
    { Address of a variable's storage (record base / slot address). }
    procedure EmitSlotAddr(const AReg, AName: string);
    procedure EmitFieldAssign(AStmt: TFieldAssignment);

    { ---- expression lowering (result in x0) ---- }
    procedure EmitExprToX0(AExpr: TASTExpr);
    procedure EmitPushX0;
    procedure EmitPopTo(const AReg: string);
    procedure EmitIntLiteral(const AReg: string; AValue: Int64);
    { Float expression lowering (result in d0). }
    procedure EmitExprToD0(AExpr: TASTExpr);
    { Float-context operand: floats via EmitExprToD0, integers via
      EmitExprToX0 + scvtf widening. }
    procedure EmitExprToD0OrConvert(AExpr: TASTExpr);
    function  IsFloatExpr(AExpr: TASTExpr): Boolean;
    { Ownership of a string value in x0: ArcExprOwnsRef plus concat — this
      backend consumes concat's +1 directly instead of the deferred
      transient-release machinery the mature backends use (a concat result
      here is always consumed exactly once by its statement). }
    function  OwnsStringRef(AExpr: TASTExpr): Boolean;
    procedure EmitFloatLitSection;
    procedure EmitStrLitAddr(AValue: string);
    function  AsmEscape(const AValue: string): string;

    { ---- statements ---- }
    procedure EmitStmt(AStmt: TASTStmt);
    procedure EmitStmtList(AStmts: TObjectList);
    procedure EmitAssignment(AAsgn: TAssignment);
    procedure EmitProcCallStmt(ACall: TProcCall);
    procedure EmitWrite(ACall: TProcCall; ANewline: Boolean);
    procedure EmitIf(AStmt: TIfStmt);
    procedure EmitWhile(AStmt: TWhileStmt);
    procedure EmitFor(AStmt: TForStmt);
    procedure EmitExit(AStmt: TExitStmt);
    procedure EmitFunctionDef(ADecl: TMethodDecl);
    procedure EmitCall(ADecl: TMethodDecl; const AName: string;
      AArgs: TObjectList; const ASretDest: string = '';
      ASelfPushed: Boolean = False; AVirtSlot: Integer = VIRT_NONE);
    { Pre-pass: register every local/param/hidden slot a routine body needs
      so the frame size is final before the prologue's sub sp. }
    procedure RegisterFrameSlots(ADecl: TMethodDecl; ABody: TBlock);
    procedure RegisterForSlots(AStmt: TASTStmt);
    function  RoutineSym(ADecl: TMethodDecl; const AName: string): string;
    function  GlobalSym(const AName: string): string;
    procedure RegisterGlobalInit(const ASym: string; AVD: TVarDecl);
    { AAPCS64 record-return shape for ARec: 0 = sret via x8, 1 = x0,
      2 = x0:x1 memory image, 3/4 = HFA of N Doubles in d0..d(N-1)
      (encoded as 100+N).  Derived from the shared classifier; the
      register choice is this leaf's per-CPU step. }
    function  RecReturnShape(ARec: TRecordTypeDesc): Integer;

    procedure EmitStrLitSection;
    procedure EmitGlobalsSection;
  protected
    procedure EmitProgram(AProg: TProgram); override;
    procedure EmitUnit(AUnit: TUnit); override;
    procedure EmitUnitInit(AUnit: TUnit);
    function  ClassPrefixOwner(const AOwner: string): string;
    function  ClassSym(ATD: TTypeDecl): string;
    function  ClassDescOf(ATD: TTypeDecl): TRecordTypeDesc;
    procedure EmitClassCleanupFns;
    procedure EmitClassMetaSections;
    procedure EmitMethodCallCommon(AMethod: TMethodDecl; const AName: string;
      AArgs: TObjectList);
    procedure EmitMethodCallStmt(AStmt: TMethodCallStmt);
    procedure EmitMethodCallExpr(AExpr: TMethodCallExpr);
    procedure EmitInstanceFieldStore(AFld: TFieldInfo;
      AValueExpr: TASTExpr; const AInstSlot: string);
    procedure EmitImplicitSelfStore(AAsgn: TAssignment);
    procedure RegisterUnitVars(ABlock: TBlock);
    procedure FinalizeEmit; override;

    { ---- ARC walk primitives (TNativeBackend contract) ----
      x21 anchors an array walk (x86 %r15), x20 is the derived-base /
      element scratch (x86 %r14); both callee-saved, saved as a 16-byte
      pair so sp alignment holds across the per-element runtime calls. }
    function  ArcNestedBaseReg: string; override;
    procedure ArcPushNestedBase(AOffset: Integer;
                                const ABaseReg: string); override;
    procedure ArcPopNestedBase; override;
    procedure EmitWeakClearAt(AOffset: Integer;
                              const ABaseReg: string); override;
    procedure EmitReleaseSlotAt(AType: TTypeDesc; AOffset: Integer;
                                const ABaseReg: string;
                                AZero: Boolean); override;
    procedure EmitRetainSlotAt(AType: TTypeDesc; AOffset: Integer;
                               const ABaseReg: string); override;
    procedure ArcEnterArrayWalk(const ABaseReg: string); override;
    procedure ArcArrayElemAddr(AByteOffset: Integer); override;
    function  ArcArrayElemReg: string; override;
    procedure ArcLeaveArrayWalk; override;
  public
    constructor Create(const ATarget: TTargetDesc); override;
    destructor Destroy; override;
  end;

implementation

{ Integer-family predicate (local twin of the x86-64 unit's free function;
  candidate for a shared home in blaise.codegen once the leaf grows). }
function IsIntFam(AType: TTypeDesc): Boolean;
begin
  Result := (AType <> nil) and
    (AType.Kind in [tyInteger, tyInt64, tyUInt64, tyUInt32, tyByte,
                    tySmallInt, tyWord, tyBoolean, tyEnum]);
end;

constructor TArm64Backend.Create(const ATarget: TTargetDesc);
begin
  inherited Create(ATarget);
  FFrame       := TDictionary<string, Integer>.Create();
  FGlobalNames := TStringList.Create();
  FStrLits     := TStringList.Create();
  FBreakLbls   := TStringList.Create();
  FContLbls    := TStringList.Create();
  FFloatLits   := TStringList.Create();
  FFloatNames  := TStringList.Create();
  FStrLocals   := TStringList.Create();
  FStrGlobals  := TStringList.Create();
  FModuleVarNames := TStringList.Create();
  FUnitInits   := TStringList.Create();
  FGlobalInits := TDictionary<string, string>.Create();
  FClassDecls  := TObjectList.Create(False);
  FObjLocals   := TStringList.Create();
  FObjGlobals  := TStringList.Create();
  FRecLocals   := TStringList.Create();
  FRecGlobals  := TStringList.Create();
  FGlobalSize  := TDictionary<string, Integer>.Create();
  FFrameSize   := 0;
  FLabelN      := 0;
  FForN        := 0;
end;

destructor TArm64Backend.Destroy;
begin
  FGlobalSize.Free();
  FRecGlobals.Free();
  FRecLocals.Free();
  FStrGlobals.Free();
  FModuleVarNames.Free();
  FUnitInits.Free();
  FGlobalInits.Free();
  FClassDecls.Free();
  FObjLocals.Free();
  FObjGlobals.Free();
  FStrLocals.Free();
  FFloatNames.Free();
  FFloatLits.Free();
  FContLbls.Free();
  FBreakLbls.Free();
  FStrLits.Free();
  FGlobalNames.Free();
  FFrame.Free();
  inherited Destroy();
end;

function TArm64Backend.NewLabel(const APrefix: string): string;
begin
  Result := 'L' + APrefix + IntToStr(FLabelN);
  FLabelN := FLabelN + 1;
end;

procedure TArm64Backend.NotYet(const AWhat: string; ANode: TASTNode);
var
  Pos: string;
begin
  Pos := '';
  if ANode <> nil then
    Pos := Format(' at line %d col %d', [ANode.Line, ANode.Col]);
  raise ENativeCodeGenError.Create(
    'arm64: not yet lowered: ' + AWhat + Pos
    + ' (the AArch64 backend subset grows incrementally — Phase 2)');
end;

{ ---- frame + operands --------------------------------------------------- }

procedure TArm64Backend.AddLocal(const AName: string; ASize: Integer);
var
  Sz: Integer;
begin
  Sz := ASize;
  if Sz < 8 then Sz := 8;
  { keep every slot 8-aligned; the frame total is 16-aligned at prologue }
  Sz := (Sz + 7) and (not 7);
  FFrameSize := FFrameSize + Sz;
  FFrame.Add(AName, FFrameSize);   { distance below x29 }
end;

function TArm64Backend.IsLocal(const AName: string): Boolean;
var
  Off: Integer;
begin
  Result := FFrame.TryGetValue(AName, Off);
end;

procedure TArm64Backend.EmitLoadSlot(const AReg, AName: string);
var
  Off: Integer;
  Sym: string;
begin
  if FFrame.TryGetValue(AName, Off) then
  begin
    if Off <= 256 then
      Self.Emit(Format(#9'ldur %s, [x29, #-%d]', [AReg, Off]))
    else
    begin
      Self.Emit(Format(#9'sub x9, x29, #%d', [Off]));
      Self.Emit(Format(#9'ldr %s, [x9]', [AReg]));
    end;
    Exit;
  end;
  Sym := GlobalSym(AName);
  if FGlobalNames.IndexOf(Sym) >= 0 then
  begin
    Self.Emit(Format(#9'adrp x9, _g_%s@PAGE', [Sym]));
    Self.Emit(Format(#9'ldr %s, [x9, _g_%s@PAGEOFF]', [AReg, Sym]));
    Exit;
  end;
  NotYet('load of variable ''' + AName + '''', nil);
end;

procedure TArm64Backend.EmitStoreSlot(const AReg, AName: string);
var
  Off: Integer;
  Sym: string;
begin
  if FFrame.TryGetValue(AName, Off) then
  begin
    if Off <= 256 then
      Self.Emit(Format(#9'stur %s, [x29, #-%d]', [AReg, Off]))
    else
    begin
      Self.Emit(Format(#9'sub x9, x29, #%d', [Off]));
      Self.Emit(Format(#9'str %s, [x9]', [AReg]));
    end;
    Exit;
  end;
  Sym := GlobalSym(AName);
  if FGlobalNames.IndexOf(Sym) >= 0 then
  begin
    Self.Emit(Format(#9'adrp x9, _g_%s@PAGE', [Sym]));
    Self.Emit(Format(#9'str %s, [x9, _g_%s@PAGEOFF]', [AReg, Sym]));
    Exit;
  end;
  NotYet('store to variable ''' + AName + '''', nil);
end;

procedure TArm64Backend.EmitSlotAddr(const AReg, AName: string);
var
  Off: Integer;
  Sym: string;
begin
  if FFrame.TryGetValue(AName, Off) then
  begin
    Self.Emit(Format(#9'sub %s, x29, #%d', [AReg, Off]));
    Exit;
  end;
  Sym := GlobalSym(AName);
  if FGlobalNames.IndexOf(Sym) >= 0 then
  begin
    Self.Emit(Format(#9'adrp %s, _g_%s@PAGE', [AReg, Sym]));
    Self.Emit(Format(#9'add %s, %s, _g_%s@PAGEOFF', [AReg, AReg, Sym]));
    Exit;
  end;
  NotYet('address of variable ''' + AName + '''', nil);
end;

procedure TArm64Backend.EmitInstanceFieldStore(AFld: TFieldInfo;
  AValueExpr: TASTExpr; const AInstSlot: string);
begin
  { store AValueExpr into AFld of the instance whose POINTER lives in the
    frame slot AInstSlot ('Self' or a class-typed variable).  Managed
    fields run the retain/release discipline; the instance pointer is
    re-loaded after any release call (it clobbers scratch regs). }
  if AFld.TypeDesc.IsString() or (AFld.TypeDesc.Kind = tyClass) then
  begin
    Self.EmitExprToX0(AValueExpr);
    if (AFld.TypeDesc.IsString() and not OwnsStringRef(AValueExpr)) or
       ((AFld.TypeDesc.Kind = tyClass) and
        not ArcExprOwnsRef(AValueExpr)) then
    begin
      EmitPushX0();
      if AFld.TypeDesc.IsString() then
        Self.Emit(#9'bl _StringAddRef')
      else
        Self.Emit(#9'bl _ClassAddRef');
      EmitPopTo('x0');
    end;
    EmitPushX0();
    EmitLoadSlot('x9', AInstSlot);
    Self.Emit(Format(#9'ldr x0, [x9, #%d]', [AFld.Offset]));
    if AFld.TypeDesc.IsString() then
      Self.Emit(#9'bl _StringRelease')
    else
      Self.Emit(#9'bl _ClassRelease');
    EmitLoadSlot('x9', AInstSlot);
    EmitPopTo('x0');
    Self.Emit(Format(#9'str x0, [x9, #%d]', [AFld.Offset]));
    Exit;
  end;
  if AFld.TypeDesc.Kind = tyDouble then
  begin
    Self.EmitExprToD0OrConvert(AValueExpr);
    Self.Emit(#9'fmov x0, d0');
  end
  else if IsIntFam(AFld.TypeDesc) then
    Self.EmitExprToX0(AValueExpr)
  else
    NotYet('store to a field of this type', AValueExpr);
  EmitPushX0();
  EmitLoadSlot('x9', AInstSlot);
  EmitPopTo('x0');
  Self.Emit(Format(#9'str x0, [x9, #%d]', [AFld.Offset]));
end;

procedure TArm64Backend.EmitImplicitSelfStore(AAsgn: TAssignment);
begin
  EmitInstanceFieldStore(TFieldInfo(AAsgn.ImplicitSelfField), AAsgn.Expr,
    'Self');
end;

procedure TArm64Backend.EmitFieldAssign(AStmt: TFieldAssignment);
begin
  if (AStmt.ObjExpr <> nil) or AStmt.IsVarParam or
     (AStmt.PropIndexExpr <> nil) then
    NotYet('this field-assignment form', AStmt);
  if AStmt.FieldInfo = nil then
    NotYet('unresolved field assignment', AStmt);
  if AStmt.IsImplicitSelf then
  begin
    EmitInstanceFieldStore(AStmt.FieldInfo, AStmt.Expr, 'Self');
    Exit;
  end;
  if AStmt.IsClassAccess then
  begin
    { Obj.Field := value — the instance pointer lives in Obj's slot }
    EmitInstanceFieldStore(AStmt.FieldInfo, AStmt.Expr, AStmt.RecordName);
    Exit;
  end;
  if not (IsIntFam(AStmt.FieldInfo.TypeDesc) or
          (AStmt.FieldInfo.TypeDesc.Kind in [tyDouble, tyClass]) or
          AStmt.FieldInfo.TypeDesc.IsString()) then
    NotYet('field of this type', AStmt);
  if AStmt.FieldInfo.TypeDesc.IsString() or
     (AStmt.FieldInfo.TypeDesc.Kind = tyClass) then
  begin
    { managed field store: retain the value unless the expression owns a
      +1 already, release the field's old value, then store.  The slot
      address is re-derived after the release call (it clobbers x9). }
    Self.EmitExprToX0(AStmt.Expr);
    if (AStmt.FieldInfo.TypeDesc.IsString() and
        not OwnsStringRef(AStmt.Expr)) or
       ((AStmt.FieldInfo.TypeDesc.Kind = tyClass) and
        not ArcExprOwnsRef(AStmt.Expr)) then
    begin
      EmitPushX0();
      if AStmt.FieldInfo.TypeDesc.IsString() then
        Self.Emit(#9'bl _StringAddRef')
      else
        Self.Emit(#9'bl _ClassAddRef');
      EmitPopTo('x0');
    end;
    EmitPushX0();
    EmitSlotAddr('x9', AStmt.RecordName);
    Self.Emit(Format(#9'ldr x0, [x9, #%d]', [AStmt.FieldInfo.Offset]));
    if AStmt.FieldInfo.TypeDesc.IsString() then
      Self.Emit(#9'bl _StringRelease')
    else
      Self.Emit(#9'bl _ClassRelease');
    EmitSlotAddr('x9', AStmt.RecordName);
    EmitPopTo('x0');
    Self.Emit(Format(#9'str x0, [x9, #%d]', [AStmt.FieldInfo.Offset]));
    Exit;
  end;
  if AStmt.FieldInfo.TypeDesc.Kind = tyDouble then
  begin
    Self.EmitExprToD0OrConvert(AStmt.Expr);
    Self.Emit(#9'fmov x0, d0');
  end
  else
    Self.EmitExprToX0(AStmt.Expr);
  EmitPushX0();
  EmitSlotAddr('x9', AStmt.RecordName);
  EmitPopTo('x0');
  Self.Emit(Format(#9'str x0, [x9, #%d]', [AStmt.FieldInfo.Offset]));
end;

{ ---- expressions --------------------------------------------------------- }

procedure TArm64Backend.EmitPushX0;
begin
  { full 16-byte slot so sp stays aligned for any call inside the bracket }
  Self.Emit(#9'str x0, [sp, #-16]!');
end;

procedure TArm64Backend.EmitPopTo(const AReg: string);
begin
  Self.Emit(Format(#9'ldr %s, [sp], #16', [AReg]));
end;

procedure TArm64Backend.EmitIntLiteral(const AReg: string; AValue: Int64);
var
  U: Int64;
  Shift: Integer;
  Chunk: Integer;
  First: Boolean;
begin
  if (AValue >= 0) and (AValue <= $FFFF) then
  begin
    Self.Emit(Format(#9'movz %s, #%d', [AReg, AValue]));
    Exit;
  end;
  if (AValue < 0) and (AValue >= -65536) then
  begin
    Self.Emit(Format(#9'movn %s, #%d', [AReg, (not AValue) and $FFFF]));
    Exit;
  end;
  { general 64-bit: movz + movk chain over the non-zero 16-bit chunks }
  U := AValue;
  First := True;
  for Shift := 0 to 3 do
  begin
    Chunk := Integer((U shr (Shift * 16)) and $FFFF);
    if (Chunk = 0) and (not First or (Shift < 3)) and not (First and (Shift = 3)) then
      Continue;
    if First then
    begin
      Self.Emit(Format(#9'movz %s, #%d, lsl #%d', [AReg, Chunk, Shift * 16]));
      First := False;
    end
    else
      Self.Emit(Format(#9'movk %s, #%d, lsl #%d', [AReg, Chunk, Shift * 16]));
  end;
  if First then
    Self.Emit(Format(#9'movz %s, #0', [AReg]));
end;

function TArm64Backend.AsmEscape(const AValue: string): string;
var
  I, C: Integer;
begin
  Result := '';
  for I := 0 to Length(AValue) - 1 do
  begin
    C := StrAt(AValue, I);
    if C = 10 then Result := Result + '\n'
    else if C = 9 then Result := Result + '\t'
    else if C = 0 then Result := Result + '\0'
    else if C = Ord('\') then Result := Result + '\\'
    else if C = Ord('"') then Result := Result + '\"'
    else Result := Result + Chr(C);
  end;
end;

procedure TArm64Backend.EmitStrLitAddr(AValue: string);
var
  Idx: Integer;
begin
  Idx := FStrLits.IndexOf(AValue);
  if Idx < 0 then
    Idx := FStrLits.Add(AValue);
  { pointer = blob + 12 (past the refcnt/len/cap header — same immutable
    string layout the x86-64 backend emits) }
  Self.Emit(Format(#9'adrp x0, __s%d@PAGE', [Idx]));
  Self.Emit(Format(#9'add x0, x0, __s%d@PAGEOFF', [Idx]));
  Self.Emit(#9'add x0, x0, #12');
end;

procedure TArm64Backend.EmitExprToX0(AExpr: TASTExpr);
var
  BE: TBinaryExpr;
  DivGuardOk: string;
  CondName: string;
  Idx: Integer;
begin
  if AExpr is TIntLiteral then
  begin
    EmitIntLiteral('x0', TIntLiteral(AExpr).Value);
    Exit;
  end;
  if AExpr is TStringLiteral then
  begin
    EmitStrLitAddr(TStringLiteral(AExpr).Value);
    Exit;
  end;
  if (AExpr is TIdentExpr) and TIdentExpr(AExpr).IsImplicitSelf and
     (TIdentExpr(AExpr).ImplicitFieldInfo <> nil) then
  begin
    { bare field name inside a method: load through Self }
    EmitLoadSlot('x0', 'Self');
    Self.Emit(Format(#9'ldr x0, [x0, #%d]',
      [TFieldInfo(TIdentExpr(AExpr).ImplicitFieldInfo).Offset]));
    Exit;
  end;
  if AExpr is TIdentExpr then
  begin
    EmitLoadSlot('x0', TIdentExpr(AExpr).Name);
    if TIdentExpr(AExpr).ParamMode = pmVar then
      Self.Emit(#9'ldr x0, [x0]');   { var param: slot holds the address }
    Exit;
  end;
  if AExpr is TFuncCallExpr then
  begin
    if TFuncCallExpr(AExpr).IsIndirectCall or
       TFuncCallExpr(AExpr).IsImplicitSelfMethod or
       (TFuncCallExpr(AExpr).ResolvedDecl = nil) then
      NotYet('this call form (''' + TFuncCallExpr(AExpr).Name + ''')', AExpr);
    if IsFloatExpr(AExpr) then
      NotYet('float-returning call in integer context', AExpr);
    if (AExpr.ResolvedType <> nil) and
       (AExpr.ResolvedType.Kind = tyRecord) then
      NotYet('record-returning call outside direct assignment', AExpr);
    EmitCall(TMethodDecl(TFuncCallExpr(AExpr).ResolvedDecl),
      TFuncCallExpr(AExpr).Name, TFuncCallExpr(AExpr).Args);
    Exit;
  end;
  if AExpr is TBinaryExpr then
  begin
    BE := TBinaryExpr(AExpr);
    { string concatenation: _StringConcat returns an owned +1 string }
    if (BE.Op = boAdd) and (AExpr.ResolvedType <> nil) and
       (AExpr.ResolvedType.Kind = tyString) then
    begin
      Self.EmitExprToX0(BE.Left);
      EmitPushX0();
      Self.EmitExprToX0(BE.Right);
      Self.Emit(#9'mov x1, x0');
      EmitPopTo('x0');
      Self.Emit(#9'bl _StringConcat');
      Exit;
    end;
    { string comparisons: content comparison via the RTL helpers — an int
      cmp on the pointers would be silently wrong.  Owned operands (concat/
      call transients) are released after the compare (this backend has no
      deferred transient-release list). }
    if (BE.Op in [boEQ, boNE, boLT, boGT, boLE, boGE]) and
       (BE.Left.ResolvedType <> nil) and
       BE.Left.ResolvedType.IsString() then
    begin
      Self.EmitExprToX0(BE.Left);
      EmitPushX0();
      Self.EmitExprToX0(BE.Right);
      EmitPushX0();
      Self.Emit(#9'ldur x0, [sp, #16]');   { left  (peek) }
      Self.Emit(#9'ldur x1, [sp]');        { right (peek) }
      if BE.Op in [boEQ, boNE] then
        Self.Emit(#9'bl _StringEquals')
      else
        Self.Emit(#9'bl _StringCompare');
      EmitPushX0();                        { result bracket }
      if OwnsStringRef(BE.Right) then
      begin
        Self.Emit(#9'ldur x0, [sp, #16]');
        Self.Emit(#9'bl _StringRelease');
      end;
      if OwnsStringRef(BE.Left) then
      begin
        Self.Emit(#9'ldur x0, [sp, #32]');
        Self.Emit(#9'bl _StringRelease');
      end;
      EmitPopTo('x0');
      Self.Emit(#9'add sp, sp, #32');      { drop the operand brackets }
      case BE.Op of
        boEQ: ;                            { 0/1 already }
        boNE:
        begin
          Self.Emit(#9'cmp x0, #0');
          Self.Emit(#9'cset x0, eq');
        end;
      else
        begin
          { _StringCompare is strcmp-like: signed compare against 0 }
          Self.Emit(#9'sxtw x0, w0');
          Self.Emit(#9'cmp x0, #0');
          case BE.Op of
            boLT: Self.Emit(#9'cset x0, lt');
            boGT: Self.Emit(#9'cset x0, gt');
            boLE: Self.Emit(#9'cset x0, le');
          else
            Self.Emit(#9'cset x0, ge');
          end;
        end;
      end;
      Exit;
    end;
    { any other operator on strings stays a named hole }
    if ((BE.Left.ResolvedType <> nil) and BE.Left.ResolvedType.IsString())
       or ((BE.Right.ResolvedType <> nil) and
           BE.Right.ResolvedType.IsString()) then
      NotYet('string operator', AExpr);
    { float COMPARISON in integer/boolean context: fcmp + cset }
    if (BE.Op in [boEQ, boNE, boLT, boGT, boLE, boGE]) and
       (IsFloatExpr(BE.Left) or IsFloatExpr(BE.Right)) then
    begin
      Self.EmitExprToD0OrConvert(BE.Left);
      Self.Emit(#9'str d0, [sp, #-16]!');
      Self.EmitExprToD0OrConvert(BE.Right);
      Self.Emit(#9'fmov d1, d0');
      Self.Emit(#9'ldr d0, [sp], #16');
      Self.Emit(#9'fcmp d0, d1');
      case BE.Op of
        boEQ: CondName := 'eq';
        boNE: CondName := 'ne';
        boLT: CondName := 'mi';   { ordered less: N set }
        boGT: CondName := 'gt';
        boLE: CondName := 'ls';   { ordered less-or-equal }
      else
        CondName := 'ge';
      end;
      Self.Emit(Format(#9'cset x0, %s', [CondName]));
      Exit;
    end;
    Self.EmitExprToX0(BE.Left);
    EmitPushX0();
    Self.EmitExprToX0(BE.Right);
    Self.Emit(#9'mov x1, x0');
    EmitPopTo('x0');
    case BE.Op of
      boAdd: Self.Emit(#9'add x0, x0, x1');
      boSub: Self.Emit(#9'sub x0, x0, x1');
      boMul: Self.Emit(#9'mul x0, x0, x1');
      boDiv, boMod:
      begin
        { AArch64 sdiv does NOT trap on a zero divisor (it yields 0), so the
          guard is ALWAYS emitted — the x86-64 backend can lean on the CPU
          trap, this leaf cannot (design doc, Phase 2 risks). }
        DivGuardOk := NewLabel('divok');
        Self.Emit(Format(#9'cbnz x1, %s', [DivGuardOk]));
        Self.Emit(#9'brk #1');                { deliberate trap: div by zero }
        Self.Emit(DivGuardOk + ':');
        if BE.Op = boDiv then
          Self.Emit(#9'sdiv x0, x0, x1')
        else
        begin
          Self.Emit(#9'sdiv x9, x0, x1');
          Self.Emit(#9'msub x0, x9, x1, x0'); { x0 - (x0 div x1)*x1 }
        end;
      end;
      boAnd: Self.Emit(#9'and x0, x0, x1');
      boOr:  Self.Emit(#9'orr x0, x0, x1');
      boXor: Self.Emit(#9'eor x0, x0, x1');
      boShl: Self.Emit(#9'lsl x0, x0, x1');
      boShr: Self.Emit(#9'lsr x0, x0, x1');
      boSar: Self.Emit(#9'asr x0, x0, x1');
      boEQ, boNE, boLT, boGT, boLE, boGE:
      begin
        case BE.Op of
          boEQ: CondName := 'eq';
          boNE: CondName := 'ne';
          boLT: CondName := 'lt';
          boGT: CondName := 'gt';
          boLE: CondName := 'le';
        else
          CondName := 'ge';
        end;
        Self.Emit(#9'cmp x0, x1');
        Self.Emit(Format(#9'cset x0, %s', [CondName]));
      end;
    else
      NotYet('binary operator ' + IntToStr(Ord(BE.Op)), AExpr);
    end;
    Exit;
  end;
  if AExpr is TInheritedCallExpr then
  begin
    if TInheritedCallExpr(AExpr).ResolvedMethod = nil then
      NotYet('unresolved inherited call', AExpr);
    if IsFloatExpr(AExpr) then
      NotYet('float-returning inherited call in integer context', AExpr);
    EmitLoadSlot('x0', 'Self');
    EmitPushX0();
    EmitCall(TMethodDecl(TInheritedCallExpr(AExpr).ResolvedMethod),
      TInheritedCallExpr(AExpr).Name, TInheritedCallExpr(AExpr).Args,
      '', True, VIRT_NONE);
    Exit;
  end;
  if AExpr is TMethodCallExpr then
  begin
    if IsFloatExpr(AExpr) then
      NotYet('float-returning method call in integer context', AExpr);
    if (AExpr.ResolvedType <> nil) and
       (AExpr.ResolvedType.Kind = tyRecord) then
      NotYet('record-returning method call', AExpr);
    EmitMethodCallExpr(TMethodCallExpr(AExpr));
    Exit;
  end;
  if (AExpr is TFieldAccessExpr) and TFieldAccessExpr(AExpr).IsConstant then
  begin
    { TypeName.ConstName — folded by the semantic pass }
    if (AExpr.ResolvedType <> nil) and
       (AExpr.ResolvedType.Kind = tyString) then
    begin
      Idx := FStrLits.IndexOf(TFieldAccessExpr(AExpr).ConstString);
      if Idx < 0 then
        Idx := FStrLits.Add(TFieldAccessExpr(AExpr).ConstString);
      Self.Emit(Format(#9'adrp x0, __s%d@PAGE', [Idx]));
      Self.Emit(Format(#9'add x0, x0, __s%d@PAGEOFF', [Idx]));
      Self.Emit(#9'add x0, x0, #12');
      Exit;
    end;
    EmitIntLiteral('x0', TFieldAccessExpr(AExpr).ConstValue);
    Exit;
  end;
  if (AExpr is TFieldAccessExpr) and
     (TFieldAccessExpr(AExpr).Base = nil) and
     (TFieldAccessExpr(AExpr).FieldInfo <> nil) and
     (TFieldAccessExpr(AExpr).IsClassAccess or
      TFieldAccessExpr(AExpr).IsImplicitSelf) and
     (not TFieldAccessExpr(AExpr).IsConstant) then
  begin
    { instance field read: the base is a POINTER — Obj's slot value, or
      Self for a bare field name inside a method }
    if not (IsIntFam(TFieldAccessExpr(AExpr).FieldInfo.TypeDesc) or
            (TFieldAccessExpr(AExpr).FieldInfo.TypeDesc.Kind in
              [tyDouble, tyClass]) or
            TFieldAccessExpr(AExpr).FieldInfo.TypeDesc.IsString()) then
      NotYet('read of a field of this type', AExpr);
    if TFieldAccessExpr(AExpr).IsImplicitSelf then
      EmitLoadSlot('x0', 'Self')
    else
      EmitLoadSlot('x0', TFieldAccessExpr(AExpr).RecordName);
    Self.Emit(Format(#9'ldr x0, [x0, #%d]',
      [TFieldAccessExpr(AExpr).FieldInfo.Offset]));
    Exit;
  end;
  if (AExpr is TFieldAccessExpr) and
     (TFieldAccessExpr(AExpr).Base = nil) and
     (TFieldAccessExpr(AExpr).FieldInfo <> nil) and
     (not TFieldAccessExpr(AExpr).IsImplicitSelf) and
     (not TFieldAccessExpr(AExpr).IsClassAccess) and
     (not TFieldAccessExpr(AExpr).IsConstant) then
  begin
    { plain Rec.Field read of a local/global record }
    if not (IsIntFam(TFieldAccessExpr(AExpr).FieldInfo.TypeDesc) or
            (TFieldAccessExpr(AExpr).FieldInfo.TypeDesc.Kind in
              [tyDouble, tyClass]) or
            TFieldAccessExpr(AExpr).FieldInfo.TypeDesc.IsString()) then
      NotYet('read of a field of this type', AExpr);
    EmitSlotAddr('x9', TFieldAccessExpr(AExpr).RecordName);
    Self.Emit(Format(#9'ldr x0, [x9, #%d]',
      [TFieldAccessExpr(AExpr).FieldInfo.Offset]));
    Exit;
  end;
  NotYet('expression ' + AExpr.ClassName, AExpr);
end;

function TArm64Backend.OwnsStringRef(AExpr: TASTExpr): Boolean;
begin
  Result := ArcExprOwnsRef(AExpr)
    or ((AExpr is TBinaryExpr) and (TBinaryExpr(AExpr).Op = boAdd) and
        (AExpr.ResolvedType <> nil) and (AExpr.ResolvedType.Kind = tyString));
end;

function TArm64Backend.IsFloatExpr(AExpr: TASTExpr): Boolean;
begin
  Result := ((AExpr.ResolvedType <> nil) and AExpr.ResolvedType.IsFloat())
    or (AExpr is TFloatLiteral);
end;

procedure TArm64Backend.EmitExprToD0(AExpr: TASTExpr);
var
  BE: TBinaryExpr;
  Idx: Integer;
  Lit: string;
  CondName: string;
begin
  if AExpr is TFloatLiteral then
  begin
    { .rodata double constant addressed via an adrp/PAGEOFF pair — the
      AArch64 analogue of the x86-64 .LF label + movsd(%rip) }
    Lit := TFloatLiteral(AExpr).Value;
    Idx := FFloatLits.IndexOf(Lit);
    if Idx < 0 then
      Idx := FFloatLits.Add(Lit);
    Self.Emit(Format(#9'adrp x9, __d%d@PAGE', [Idx]));
    Self.Emit(Format(#9'ldr d0, [x9, __d%d@PAGEOFF]', [Idx]));
    Exit;
  end;
  if (AExpr is TIdentExpr) and IsFloatExpr(AExpr) then
  begin
    if (AExpr.ResolvedType <> nil) and
       (AExpr.ResolvedType.Kind = tySingle) then
    begin
      { Single lives as a 4-byte value: load through s0 and widen }
      if TIdentExpr(AExpr).ParamMode = pmVar then
        NotYet('var Single parameter', AExpr);
      EmitSlotAddr('x9', TIdentExpr(AExpr).Name);
      Self.Emit(#9'ldr s0, [x9]');
      Self.Emit(#9'fcvt d0, s0');
      Exit;
    end;
    { reuse the slot machinery: load the 8-byte pattern into x0, move to d0 }
    EmitLoadSlot('x0', TIdentExpr(AExpr).Name);
    if TIdentExpr(AExpr).ParamMode = pmVar then
      Self.Emit(#9'ldr x0, [x0]');   { var param: slot holds the address }
    Self.Emit(#9'fmov d0, x0');
    Exit;
  end;
  if (AExpr is TFieldAccessExpr) and IsFloatExpr(AExpr) then
  begin
    { Double field: load the bit pattern via the integer path, fmov to d0 }
    Self.EmitExprToX0(AExpr);
    Self.Emit(#9'fmov d0, x0');
    Exit;
  end;
  if AExpr is TFuncCallExpr then
  begin
    if TFuncCallExpr(AExpr).IsIndirectCall or
       TFuncCallExpr(AExpr).IsImplicitSelfMethod or
       (TFuncCallExpr(AExpr).ResolvedDecl = nil) then
      NotYet('this call form in float context', AExpr);
    EmitCall(TMethodDecl(TFuncCallExpr(AExpr).ResolvedDecl),
      TFuncCallExpr(AExpr).Name, TFuncCallExpr(AExpr).Args);
    if (AExpr.ResolvedType <> nil) and
       (AExpr.ResolvedType.Kind = tySingle) then
      Self.Emit(#9'fcvt d0, s0');   { Single returns in s0 — widen }
    { a Double-returning call leaves its result in d0 already }
    Exit;
  end;
  if AExpr is TBinaryExpr then
  begin
    BE := TBinaryExpr(AExpr);
    { int operands convert on the way in (scvtf) — mixed int/float exprs }
    Self.EmitExprToD0OrConvert(BE.Left);
    Self.Emit(#9'str d0, [sp, #-16]!');
    Self.EmitExprToD0OrConvert(BE.Right);
    Self.Emit(#9'fmov d1, d0');
    Self.Emit(#9'ldr d0, [sp], #16');
    case BE.Op of
      boAdd:   Self.Emit(#9'fadd d0, d0, d1');
      boSub:   Self.Emit(#9'fsub d0, d0, d1');
      boMul:   Self.Emit(#9'fmul d0, d0, d1');
      boSlash: Self.Emit(#9'fdiv d0, d0, d1');
    else
      NotYet('float binary operator', AExpr);
    end;
    Exit;
  end;
  NotYet('float expression ' + AExpr.ClassName, AExpr);
end;

procedure TArm64Backend.EmitExprToD0OrConvert(AExpr: TASTExpr);
begin
  if IsFloatExpr(AExpr) then
    EmitExprToD0(AExpr)
  else
  begin
    Self.EmitExprToX0(AExpr);
    Self.Emit(#9'scvtf d0, x0');
  end;
end;

{ ---- statements ---------------------------------------------------------- }

procedure TArm64Backend.EmitStmtList(AStmts: TObjectList);
var
  I: Integer;
begin
  for I := 0 to AStmts.Count - 1 do
    Self.EmitStmt(TASTStmt(AStmts.Items[I]));
end;

procedure TArm64Backend.EmitStmt(AStmt: TASTStmt);
begin
  if AStmt is TCompoundStmt then
  begin
    EmitStmtList(TCompoundStmt(AStmt).Stmts);
    Exit;
  end;
  if AStmt is TAssignment then
  begin
    EmitAssignment(TAssignment(AStmt));
    Exit;
  end;
  if AStmt is TFieldAssignment then
  begin
    EmitFieldAssign(TFieldAssignment(AStmt));
    Exit;
  end;
  if AStmt is TProcCall then
  begin
    EmitProcCallStmt(TProcCall(AStmt));
    Exit;
  end;
  if AStmt is TMethodCallStmt then
  begin
    EmitMethodCallStmt(TMethodCallStmt(AStmt));
    Exit;
  end;
  if AStmt is TInheritedCallStmt then
  begin
    { static dispatch to the parent implementation with the current Self }
    if TInheritedCallStmt(AStmt).ResolvedMethod = nil then
      NotYet('unresolved inherited call', AStmt);
    EmitLoadSlot('x0', 'Self');
    EmitPushX0();
    EmitCall(TMethodDecl(TInheritedCallStmt(AStmt).ResolvedMethod),
      TInheritedCallStmt(AStmt).Name, TInheritedCallStmt(AStmt).Args,
      '', True, VIRT_NONE);
    Exit;
  end;
  if AStmt is TIfStmt then
  begin
    EmitIf(TIfStmt(AStmt));
    Exit;
  end;
  if AStmt is TWhileStmt then
  begin
    EmitWhile(TWhileStmt(AStmt));
    Exit;
  end;
  if AStmt is TForStmt then
  begin
    EmitFor(TForStmt(AStmt));
    Exit;
  end;
  if AStmt is TExitStmt then
  begin
    EmitExit(TExitStmt(AStmt));
    Exit;
  end;
  if AStmt is TBreakStmt then
  begin
    if FBreakLbls.Count = 0 then
      NotYet('break outside a loop', AStmt);
    Self.Emit(Format(#9'b %s', [FBreakLbls.Strings[FBreakLbls.Count - 1]]));
    Exit;
  end;
  if AStmt is TContinueStmt then
  begin
    if FContLbls.Count = 0 then
      NotYet('continue outside a loop', AStmt);
    Self.Emit(Format(#9'b %s', [FContLbls.Strings[FContLbls.Count - 1]]));
    Exit;
  end;
  NotYet('statement ' + AStmt.ClassName, AStmt);
end;

procedure TArm64Backend.EmitAssignment(AAsgn: TAssignment);
var
  I, Shape: Integer;
  RD: TMethodDecl;
begin
  if (AAsgn.ResolvedLhsType <> nil) and
     (AAsgn.ResolvedLhsType.Kind = tyString) then
  begin
    { ARC discipline (mirrors x86-64): retain the incoming value unless the
      expression already OWNS a +1 reference (concat/call results), release
      the slot's previous string, then store.  A var-param target holds the
      caller's ADDRESS — the old-value load and the store deref it (the
      address is re-loaded after the release call clobbers x9). }
    Self.EmitExprToX0(AAsgn.Expr);
    if not OwnsStringRef(AAsgn.Expr) then
    begin
      EmitPushX0();
      Self.Emit(#9'bl _StringAddRef');
      EmitPopTo('x0');
    end;
    EmitPushX0();
    if AAsgn.IsVarParam then
    begin
      EmitLoadSlot('x9', AAsgn.Name);
      Self.Emit(#9'ldr x0, [x9]');
      Self.Emit(#9'bl _StringRelease');
      EmitLoadSlot('x9', AAsgn.Name);
      EmitPopTo('x0');
      Self.Emit(#9'str x0, [x9]');
      Exit;
    end;
    EmitLoadSlot('x0', AAsgn.Name);
    Self.Emit(#9'bl _StringRelease');
    EmitPopTo('x0');
    EmitStoreSlot('x0', AAsgn.Name);
    Exit;
  end;
  if (AAsgn.ResolvedLhsType <> nil) and
     (AAsgn.ResolvedLhsType.Kind = tyClass) then
  begin
    if AAsgn.IsWeakLhs then
      NotYet('[Weak] assignment', AAsgn);
    if AAsgn.ImplicitSelfField <> nil then
      NotYet('implicit-Self class-field assignment via TAssignment', AAsgn);
    { same ARC discipline as strings, through _Class* }
    Self.EmitExprToX0(AAsgn.Expr);
    if not ArcExprOwnsRef(AAsgn.Expr) then
    begin
      EmitPushX0();
      Self.Emit(#9'bl _ClassAddRef');
      EmitPopTo('x0');
    end;
    EmitPushX0();
    if AAsgn.IsVarParam then
      NotYet('var class parameter', AAsgn);
    EmitLoadSlot('x0', AAsgn.Name);
    Self.Emit(#9'bl _ClassRelease');
    EmitPopTo('x0');
    EmitStoreSlot('x0', AAsgn.Name);
    Exit;
  end;
  if (AAsgn.ResolvedLhsType <> nil) and (AAsgn.ImplicitSelfField <> nil) then
  begin
    { bare field := value inside a method — route through the field-store
      machinery with Self as the instance }
    EmitImplicitSelfStore(AAsgn);
    Exit;
  end;
  if (AAsgn.ResolvedLhsType <> nil) and
     (AAsgn.ResolvedLhsType.Kind = tyRecord) then
  begin
    { record-returning call: classify the callee's return shape }
    if (AAsgn.Expr is TFuncCallExpr) and
       (TFuncCallExpr(AAsgn.Expr).ResolvedDecl <> nil) then
    begin
      RD := TMethodDecl(TFuncCallExpr(AAsgn.Expr).ResolvedDecl);
      if RD.IsExternal then
        { a C-side small-struct return needs full AAPCS64 marshalling
          validation on real hardware first — keep the hole honest }
        NotYet('external record-returning call', AAsgn);
      Shape := RecReturnShape(TRecordTypeDesc(AAsgn.ResolvedLhsType));
      if Shape = 0 then
      begin
        EmitCall(RD, TFuncCallExpr(AAsgn.Expr).Name,
          TFuncCallExpr(AAsgn.Expr).Args, AAsgn.Name);
        Exit;
      end;
      EmitCall(RD, TFuncCallExpr(AAsgn.Expr).Name,
        TFuncCallExpr(AAsgn.Expr).Args);
      EmitSlotAddr('x9', AAsgn.Name);
      case Shape of
        1: Self.Emit(#9'str x0, [x9]');
        2:
        begin
          Self.Emit(#9'str x0, [x9]');
          Self.Emit(#9'str x1, [x9, #8]');
        end;
      else
        for I := 0 to (Shape - 100) - 1 do
          Self.Emit(Format(#9'str d%d, [x9, #%d]', [I, I * 8]));
      end;
      Exit;
    end;
    { whole-record copy.  With managed fields the ARC discipline mirrors
      x86-64's record-var assignment: retain the SOURCE's managed fields
      first, release the destination's old ones, then memcpy the raw
      bytes — retain-before-release keeps self-assignment (R := R) exact.
      The walk calls clobber the scratch regs, so the two base addresses
      live in callee-saved x19/x22 for the duration. }
    if not (AAsgn.Expr is TIdentExpr) then
      NotYet('record assignment from this expression', AAsgn);
    if not RecretManagedClean(TRecordTypeDesc(AAsgn.ResolvedLhsType)) then
    begin
      Self.Emit(#9'stp x19, x22, [sp, #-16]!');
      EmitSlotAddr('x19', TIdentExpr(AAsgn.Expr).Name);
      EmitSlotAddr('x22', AAsgn.Name);
      Self.EmitRecordFieldRetains(
        TRecordTypeDesc(AAsgn.ResolvedLhsType), 'x19');
      Self.EmitRecordFieldReleases(
        TRecordTypeDesc(AAsgn.ResolvedLhsType), 'x22');
      Self.Emit(#9'mov x0, x22');
      Self.Emit(#9'mov x1, x19');
      EmitIntLiteral('x2', AAsgn.ResolvedLhsType.RawSize());
      Self.Emit(#9'bl memcpy');
      Self.Emit(#9'ldp x19, x22, [sp], #16');
      Exit;
    end;
    EmitSlotAddr('x0', AAsgn.Name);
    EmitPushX0();
    EmitSlotAddr('x0', TIdentExpr(AAsgn.Expr).Name);
    Self.Emit(#9'mov x1, x0');
    EmitPopTo('x0');
    EmitIntLiteral('x2', AAsgn.ResolvedLhsType.RawSize());
    Self.Emit(#9'bl memcpy');
    Exit;
  end;
  if (AAsgn.ResolvedLhsType <> nil) and AAsgn.ResolvedLhsType.IsFloat() then
  begin
    if AAsgn.ResolvedLhsType.Kind = tySingle then
    begin
      if AAsgn.IsVarParam then
        NotYet('var Single parameter', AAsgn);
      Self.EmitExprToD0OrConvert(AAsgn.Expr);
      Self.Emit(#9'fcvt s0, d0');
      EmitSlotAddr('x9', AAsgn.Name);
      Self.Emit(#9'str s0, [x9]');
      Exit;
    end;
    Self.EmitExprToD0OrConvert(AAsgn.Expr);
    Self.Emit(#9'fmov x0, d0');
    if AAsgn.IsVarParam then
    begin
      EmitLoadSlot('x9', AAsgn.Name);
      Self.Emit(#9'str x0, [x9]');
    end
    else
      EmitStoreSlot('x0', AAsgn.Name);
    Exit;
  end;
  if (AAsgn.ResolvedLhsType <> nil) and
     not IsIntFam(AAsgn.ResolvedLhsType) and
     not (AAsgn.ResolvedLhsType.Kind = tyBoolean) then
    NotYet('assignment to non-integer variable', AAsgn);
  Self.EmitExprToX0(AAsgn.Expr);
  if AAsgn.IsVarParam then
  begin
    EmitLoadSlot('x9', AAsgn.Name);
    Self.Emit(#9'str x0, [x9]');
  end
  else
    EmitStoreSlot('x0', AAsgn.Name);
end;

procedure TArm64Backend.EmitProcCallStmt(ACall: TProcCall);
begin
  if SameText(ACall.Name, 'WriteLn') then
  begin
    EmitWrite(ACall, True);
    Exit;
  end;
  if SameText(ACall.Name, 'Write') then
  begin
    EmitWrite(ACall, False);
    Exit;
  end;
  if (ACall.ResolvedDecl <> nil) and (ACall.ResolvedDecl is TMethodDecl) and
     (TMethodDecl(ACall.ResolvedDecl).OwnerTypeName = '') then
  begin
    EmitCall(TMethodDecl(ACall.ResolvedDecl), ACall.Name, ACall.Args);
    Exit;
  end;
  NotYet('call to ''' + ACall.Name + '''', ACall);
end;

procedure TArm64Backend.EmitWrite(ACall: TProcCall; ANewline: Boolean);
var
  I: Integer;
  Arg: TASTExpr;
  K: TTypeKind;
begin
  for I := 0 to ACall.Args.Count - 1 do
  begin
    Arg := TASTExpr(ACall.Args.Items[I]);
    if Arg.ResolvedType <> nil then
      K := Arg.ResolvedType.Kind
    else
      K := tyInteger;
    if (K in [tyString, tyPChar]) or (Arg is TStringLiteral) then
    begin
      Self.EmitExprToX0(Arg);
      if (K = tyString) and OwnsStringRef(Arg) then
      begin
        { an owned +1 transient (concat/call result) is borrowed by
          _SysWriteStr — release it after the write or it leaks }
        EmitPushX0();
        Self.Emit(#9'mov x1, x0');
        Self.Emit(#9'movz w0, #1');
        Self.Emit(#9'bl _SysWriteStr');
        EmitPopTo('x0');
        Self.Emit(#9'bl _StringRelease');
      end
      else
      begin
        Self.Emit(#9'mov x1, x0');
        Self.Emit(#9'movz w0, #1');           { fd = stdout }
        Self.Emit(#9'bl _SysWriteStr');
      end;
    end
    else if K in [tyDouble, tySingle] then
    begin
      Self.EmitExprToD0OrConvert(Arg);
      Self.Emit(#9'movz w0, #1');
      Self.Emit(#9'bl _SysWriteDouble');
    end
    else if K = tyBoolean then
    begin
      Self.EmitExprToX0(Arg);
      Self.Emit(#9'mov w1, w0');
      Self.Emit(#9'movz w0, #1');
      Self.Emit(#9'bl _SysWriteBool');
    end
    else if K = tyInt64 then
    begin
      Self.EmitExprToX0(Arg);
      Self.Emit(#9'mov x1, x0');
      Self.Emit(#9'movz w0, #1');
      Self.Emit(#9'bl _SysWriteInt64');
    end
    else if IsIntFam(Arg.ResolvedType) or (Arg is TIntLiteral) then
    begin
      Self.EmitExprToX0(Arg);
      Self.Emit(#9'mov w1, w0');
      Self.Emit(#9'movz w0, #1');
      Self.Emit(#9'bl _SysWriteInt');
    end
    else
      NotYet('Write/WriteLn argument of this type', Arg);
  end;
  if ANewline then
  begin
    Self.Emit(#9'movz w0, #1');
    Self.Emit(#9'bl _SysWriteNewline');
  end;
end;

procedure TArm64Backend.EmitIf(AStmt: TIfStmt);
var
  ElseL, EndL: string;
begin
  ElseL := NewLabel('else');
  EndL  := NewLabel('endif');
  Self.EmitExprToX0(AStmt.Condition);
  Self.Emit(Format(#9'cbz x0, %s', [ElseL]));
  Self.EmitStmt(AStmt.ThenStmt);
  Self.Emit(Format(#9'b %s', [EndL]));
  Self.Emit(ElseL + ':');
  if AStmt.ElseStmt <> nil then
    Self.EmitStmt(AStmt.ElseStmt);
  Self.Emit(EndL + ':');
end;

procedure TArm64Backend.EmitWhile(AStmt: TWhileStmt);
var
  TopL, EndL: string;
begin
  TopL := NewLabel('while');
  EndL := NewLabel('wend');
  Self.Emit(TopL + ':');
  Self.EmitExprToX0(AStmt.Condition);
  Self.Emit(Format(#9'cbz x0, %s', [EndL]));
  Self.EmitStmt(AStmt.Body);
  Self.Emit(Format(#9'b %s', [TopL]));
  Self.Emit(EndL + ':');
end;

procedure TArm64Backend.EmitFor(AStmt: TForStmt);
var
  TopL, EndL, ContL: string;
  EndSlot: string;
begin
  { the pre-pass registered one hidden end slot per for statement, consumed
    here in the same walk order }
  EndSlot := '__for_end_' + IntToStr(FForN);
  FForN := FForN + 1;
  TopL  := NewLabel('for');
  EndL  := NewLabel('fend');
  ContL := NewLabel('fcont');
  Self.EmitExprToX0(AStmt.StartExpr);
  EmitStoreSlot('x0', AStmt.VarName);
  Self.EmitExprToX0(AStmt.EndExpr);      { bound evaluated ONCE }
  EmitStoreSlot('x0', EndSlot);
  Self.Emit(TopL + ':');
  EmitLoadSlot('x0', AStmt.VarName);
  EmitLoadSlot('x1', EndSlot);
  Self.Emit(#9'cmp x0, x1');
  if AStmt.IsDownTo then
    Self.Emit(Format(#9'b.lt %s', [EndL]))
  else
    Self.Emit(Format(#9'b.gt %s', [EndL]));
  FBreakLbls.Add(EndL);
  FContLbls.Add(ContL);
  Self.EmitStmt(AStmt.Body);
  FContLbls.Delete(FContLbls.Count - 1);
  FBreakLbls.Delete(FBreakLbls.Count - 1);
  Self.Emit(ContL + ':');
  EmitLoadSlot('x0', AStmt.VarName);
  if AStmt.IsDownTo then
    Self.Emit(#9'sub x0, x0, #1')
  else
    Self.Emit(#9'add x0, x0, #1');
  EmitStoreSlot('x0', AStmt.VarName);
  Self.Emit(Format(#9'b %s', [TopL]));
  Self.Emit(EndL + ':');
end;

procedure TArm64Backend.EmitExit(AStmt: TExitStmt);
begin
  if AStmt.ResultAssign <> nil then
    Self.EmitStmt(AStmt.ResultAssign)
  else if AStmt.Value <> nil then
    NotYet('exit with a value in this position', AStmt);
  Self.Emit(Format(#9'b %s', [FExitLabel]));
end;

{ ---- routines ------------------------------------------------------------ }

function TArm64Backend.RoutineSym(ADecl: TMethodDecl;
  const AName: string): string;
begin
  if (ADecl <> nil) and ADecl.IsExternal and (ADecl.ExternalName <> '') then
    Result := ADecl.ExternalName
  else if (ADecl <> nil) and (ADecl.ResolvedQbeName <> '') then
    Result := CodegenMangle(ADecl.ResolvedQbeName)
  else if ADecl <> nil then
    Result := CodegenMangle(ADecl.Name)
  else
    Result := CodegenMangle(AName);
end;

function TArm64Backend.GlobalSym(const AName: string): string;
var
  Sym: TSymbol;
  Owner: string;
begin
  { Owner resolution mirrors TX86_64Backend.GlobalSymName: an exported
    unit var carries its OwningUnit in the symbol table; an implementation-
    private one is invisible to Lookup and only ever referenced from its
    own unit, so the emitting unit is the owner.  The program name (and
    unmangled RTL units, via MangleUnitPrefix) map to a bare name. }
  Result := AName;
  Owner := '';
  if FSymTable <> nil then
  begin
    Sym := FSymTable.Lookup(AName);
    if (Sym <> nil) and (Sym.Kind = skVariable) and (Sym.OwningUnit <> '') then
      Owner := Sym.OwningUnit;
  end;
  if (Owner = '') and (FModuleVarNames.IndexOf(AName) >= 0) then
    Owner := FCurrentUnitName;
  if Owner = '' then Exit;
  if (FProgramName <> '') and SameText(Owner, FProgramName) then Exit;
  Result := MangleUnitPrefix(Owner) + AName;
end;

procedure TArm64Backend.RegisterGlobalInit(const ASym: string; AVD: TVarDecl);
begin
  { Integer and float literal initialisers become .data directives; string,
    aggregate, and const-expression initialisers stay honest holes. }
  if AVD.InitConst.IsString or AVD.InitConst.IsArrayConst or
     (AVD.InitConst.ConstParts <> nil) then
    NotYet('initialised global of this form', AVD);
  if AVD.InitConst.IsFloat then
    FGlobalInits.Add(ASym, #9'.double ' + AVD.InitConst.StrVal)
  else
    FGlobalInits.Add(ASym, Format(#9'.quad %d', [AVD.InitConst.IntVal]));
end;

function TArm64Backend.RecReturnShape(ARec: TRecordTypeDesc): Integer;
var
  I, NDoubles: Integer;
  F: TFieldInfo;
  AllDouble: Boolean;
begin
  { HFA check first: up to four Double fields return in d0..d(N-1) —
    AAPCS64's homogeneous float aggregate rule.  (Single-member HFAs are
    rejected with the rest of Single support.) }
  AllDouble := ARec.Fields.Count > 0;
  NDoubles := 0;
  for I := 0 to ARec.Fields.Count - 1 do
  begin
    F := TFieldInfo(ARec.Fields.Items[I]);
    if (F.TypeDesc = nil) or (F.TypeDesc.Kind <> tyDouble) then
      AllDouble := False
    else
      NDoubles := NDoubles + 1;
  end;
  if AllDouble and (NDoubles <= 4) then
  begin
    Result := 100 + NDoubles;
    Exit;
  end;
  case Self.ClassifyRecordReturn(ARec) of
    rcSret: Result := 0;
    rcInt1: Result := 1;
  else
    { rcInt2 / rcIntSSE / rcSSEInt / rcSSE2: any non-HFA composite of at
      most 16 bytes returns as a MEMORY IMAGE in x0:x1 on AAPCS64 (no
      per-eightbyte class split like System V). }
    Result := 2;
  end;
end;

procedure TArm64Backend.RegisterForSlots(AStmt: TASTStmt);
var
  I: Integer;
begin
  if AStmt = nil then Exit;
  if AStmt is TCompoundStmt then
  begin
    for I := 0 to TCompoundStmt(AStmt).Stmts.Count - 1 do
      RegisterForSlots(TASTStmt(TCompoundStmt(AStmt).Stmts.Items[I]));
    Exit;
  end;
  if AStmt is TForStmt then
  begin
    AddLocal('__for_end_' + IntToStr(FForN), 8);
    FForN := FForN + 1;
    RegisterForSlots(TForStmt(AStmt).Body);
    Exit;
  end;
  if AStmt is TIfStmt then
  begin
    RegisterForSlots(TIfStmt(AStmt).ThenStmt);
    RegisterForSlots(TIfStmt(AStmt).ElseStmt);
    Exit;
  end;
  if AStmt is TWhileStmt then
    RegisterForSlots(TWhileStmt(AStmt).Body);
end;

procedure TArm64Backend.RegisterFrameSlots(ADecl: TMethodDecl; ABody: TBlock);
var
  I, J: Integer;
  VD: TVarDecl;
  Par: TMethodParam;
begin
  FFrame.Clear();
  FFrameSize := 0;
  FStrLocals.Clear();
  FRecLocals.Clear();
  FObjLocals.Clear();
  if ADecl <> nil then
  begin
    if (ADecl.OwnerTypeName <> '') and not ADecl.IsStatic then
      AddLocal('Self', 8);
    for I := 0 to ADecl.Params.Count - 1 do
    begin
      Par := TMethodParam(ADecl.Params.Items[I]);
      if Par.IsOpenArray then
        NotYet('open-array parameters', ADecl);
      if Par.IsVarParam then
      begin
        { var/out param: the 8-byte slot holds the caller's ADDRESS.  The
          pointee is int-family, Double or string for now — records need
          base-pointer plumbing at every field-access site. }
        if not (IsIntFam(Par.ResolvedType) or
                ((Par.ResolvedType <> nil) and
                 (Par.ResolvedType.Kind in [tyDouble, tyString]))) then
          NotYet('var parameter ''' + Par.ParamName + ''' of this type', ADecl);
        AddLocal(Par.ParamName, 8);
        Continue;
      end;
      if (Par.ResolvedType <> nil) and (Par.ResolvedType.Kind = tyRecord) then
      begin
        if not RecretManagedClean(TRecordTypeDesc(Par.ResolvedType)) then
          NotYet('managed-record parameter', ADecl);
        AddLocal(Par.ParamName, Par.ResolvedType.RawSize());
        FRecLocals.AddObject(Par.ParamName, Par.ResolvedType);
        if RecReturnShape(TRecordTypeDesc(Par.ResolvedType)) = 0 then
          { >16B records arrive as a pointer; park it until the
            prologue memcpy pass copies the bytes into our own slot }
          AddLocal('__pptr_' + Par.ParamName, 8);
      end
      else
      begin
        if not (IsIntFam(Par.ResolvedType) or
                ((Par.ResolvedType <> nil) and
                 (Par.ResolvedType.Kind in [tyDouble, tySingle,
                                            tyString]))) then
          NotYet('parameter ''' + Par.ParamName + ''' of this type', ADecl);
        AddLocal(Par.ParamName, 8);
        { a BY-VALUE string param is the callee's own copy: retained in the
          prologue, released with the string locals at scope exit.  A const
          string param is a borrow — no retain, no release. }
        if (Par.ResolvedType <> nil) and (Par.ResolvedType.Kind = tyString)
           and not Par.IsConstParam then
          FStrLocals.Add(Par.ParamName);
      end;
    end;
    if ADecl.ResolvedReturnType <> nil then
    begin
      if ADecl.ResolvedReturnType.Kind = tyRecord then
      begin
        if not RecretManagedClean(TRecordTypeDesc(ADecl.ResolvedReturnType)) then
          NotYet('managed-record function result', ADecl);
        AddLocal('Result', ADecl.ResolvedReturnType.RawSize());
        if RecReturnShape(TRecordTypeDesc(ADecl.ResolvedReturnType)) = 0 then
          AddLocal('__sret', 8);   { the incoming x8 destination pointer }
      end
      else if not (IsIntFam(ADecl.ResolvedReturnType) or
                   (ADecl.ResolvedReturnType.Kind in [tyDouble, tySingle]) or
                   (ADecl.ResolvedReturnType.Kind = tyString)) then
        NotYet('function result of this type', ADecl)
      else
        { a string Result is a plain pointer slot.  It is deliberately NOT
          in FStrLocals: the +1 it holds transfers to the caller at return
          (ArcExprOwnsRef treats call results as owned), so the scope-exit
          release must skip it. }
        AddLocal('Result', 8);
    end;
  end;
  for I := 0 to ABody.Decls.Count - 1 do
  begin
    VD := TVarDecl(ABody.Decls.Items[I]);
    if not (IsIntFam(VD.ResolvedType) or
            ((VD.ResolvedType <> nil) and
             (VD.ResolvedType.Kind in [tyDouble, tySingle, tyString,
                                       tyRecord, tyClass]))) then
      NotYet('local variable of this type', VD);
    for J := 0 to VD.Names.Count - 1 do
    begin
      if VD.ResolvedType.Kind = tyRecord then
      begin
        { managed fields are fine: zero-init nils them, the base-class ARC
          walks handle copies and the scope-exit release }
        AddLocal(VD.Names.Strings[J], VD.ResolvedType.RawSize());
        FRecLocals.AddObject(VD.Names.Strings[J], VD.ResolvedType);
      end
      else
        AddLocal(VD.Names.Strings[J], 8);
      if VD.ResolvedType.Kind = tyString then
        FStrLocals.Add(VD.Names.Strings[J]);
      if VD.ResolvedType.Kind = tyClass then
        FObjLocals.Add(VD.Names.Strings[J]);
    end;
  end;
  for I := 0 to ABody.Stmts.Count - 1 do
    RegisterForSlots(TASTStmt(ABody.Stmts.Items[I]));
end;

procedure TArm64Backend.EmitFunctionDef(ADecl: TMethodDecl);
var
  I, J, K, FIdx: Integer;
  FrameAligned: Integer;
  Sym: string;
  RecShape, ParShape: Integer;
  Par: TMethodParam;
begin
  if ADecl.Body.ProcDecls.Count > 0 then
    NotYet('nested routines', ADecl);
  Sym := RoutineSym(ADecl, ADecl.Name);
  FIsFunction := ADecl.ResolvedReturnType <> nil;
  FResultFloat := FIsFunction and
    (ADecl.ResolvedReturnType.Kind = tyDouble);
  FResultSingle := FIsFunction and
    (ADecl.ResolvedReturnType.Kind = tySingle);
  RecShape := -1;
  if FIsFunction and (ADecl.ResolvedReturnType.Kind = tyRecord) then
    RecShape := RecReturnShape(TRecordTypeDesc(ADecl.ResolvedReturnType));
  FExitLabel := NewLabel('rexit');
  FForN := 0;
  RegisterFrameSlots(ADecl, ADecl.Body);
  FForN := 0;   { reset so EmitFor consumes slots in registration order }
  FrameAligned := (FFrameSize + 15) and (not 15);

  Self.Emit('');
  Self.Emit(Format('.globl %s', [Sym]));
  Self.Emit(Sym + ':');
  Self.Emit(#9'stp x29, x30, [sp, #-16]!');
  Self.Emit(#9'mov x29, sp');
  if FrameAligned > 0 then
    Self.Emit(Format(#9'sub sp, sp, #%d', [FrameAligned]));
  { spill register args to their slots.  Integer and float parameters
    consume INDEPENDENT register sequences (x0.. / d0..) per AAPCS64;
    floats hop through x9 so the slot store machinery stays uniform. }
  if ADecl.Params.Count > 8 then
    NotYet('more than 8 parameters', ADecl);
  J := 0;      { int register index }
  FIdx := 0;   { float register index }
  if (ADecl.OwnerTypeName <> '') and not ADecl.IsStatic then
  begin
    { method: Self arrives first in x0 }
    EmitStoreSlot('x0', 'Self');
    J := 1;
  end;
  for I := 0 to ADecl.Params.Count - 1 do
  begin
    Par := TMethodParam(ADecl.Params.Items[I]);
    if Par.IsVarParam then
    begin
      { var/out param: one x register carrying the caller's address }
      if J >= 8 then NotYet('parameters spilling to the stack', ADecl);
      EmitStoreSlot('x' + IntToStr(J), Par.ParamName);
      J := J + 1;
    end
    else if (Par.ResolvedType <> nil) and (Par.ResolvedType.Kind = tyRecord) then
    begin
      ParShape := RecReturnShape(TRecordTypeDesc(Par.ResolvedType));
      case ParShape of
        0:
        begin
          { >16B: pointer in one x reg — park it, copy bytes in pass 2 }
          if J >= 8 then NotYet('parameters spilling to the stack', ADecl);
          EmitStoreSlot('x' + IntToStr(J), '__pptr_' + Par.ParamName);
          J := J + 1;
        end;
        1:
        begin
          if J >= 8 then NotYet('parameters spilling to the stack', ADecl);
          EmitStoreSlot('x' + IntToStr(J), Par.ParamName);
          J := J + 1;
        end;
        2:
        begin
          if J >= 7 then NotYet('parameters spilling to the stack', ADecl);
          EmitStoreSlot('x' + IntToStr(J), Par.ParamName);
          EmitSlotAddr('x9', Par.ParamName);
          Self.Emit(Format(#9'str x%d, [x9, #8]', [J + 1]));
          J := J + 2;
        end;
      else
        { HFA of (ParShape - 100) Doubles in d(FIdx).. }
        if FIdx + (ParShape - 100) > 8 then
          NotYet('parameters spilling to the stack', ADecl);
        EmitSlotAddr('x9', Par.ParamName);
        for K := 0 to (ParShape - 100) - 1 do
          Self.Emit(Format(#9'str d%d, [x9, #%d]', [FIdx + K, K * 8]));
        FIdx := FIdx + (ParShape - 100);
      end;
    end
    else if (Par.ResolvedType <> nil) and
            (Par.ResolvedType.Kind = tyDouble) then
    begin
      if FIdx >= 8 then NotYet('parameters spilling to the stack', ADecl);
      Self.Emit(Format(#9'fmov x9, d%d', [FIdx]));
      EmitStoreSlot('x9', Par.ParamName);
      FIdx := FIdx + 1;
    end
    else if (Par.ResolvedType <> nil) and
            (Par.ResolvedType.Kind = tySingle) then
    begin
      { Single arrives in s(FIdx); its slot holds the 4-byte value }
      if FIdx >= 8 then NotYet('parameters spilling to the stack', ADecl);
      EmitSlotAddr('x9', Par.ParamName);
      Self.Emit(Format(#9'str s%d, [x9]', [FIdx]));
      FIdx := FIdx + 1;
    end
    else
    begin
      if J >= 8 then NotYet('parameters spilling to the stack', ADecl);
      EmitStoreSlot('x' + IntToStr(J), Par.ParamName);
      J := J + 1;
    end;
  end;
  { sret: park the incoming x8 destination pointer in its hidden slot }
  if RecShape = 0 then
    EmitStoreSlot('x8', '__sret');
  { by-value string params: retain the callee's copy (the caller keeps its
    own reference).  Runs after every register is parked — _StringAddRef
    clobbers the caller-saved argument registers. }
  for I := 0 to ADecl.Params.Count - 1 do
  begin
    Par := TMethodParam(ADecl.Params.Items[I]);
    if (Par.ResolvedType <> nil) and (Par.ResolvedType.Kind = tyString) and
       not Par.IsConstParam then
    begin
      EmitLoadSlot('x0', Par.ParamName);
      Self.Emit(#9'bl _StringAddRef');
    end;
  end;
  { pass 2: copy the bytes of every pointer-passed record param into its
    own slot.  This runs only after every register is parked, because the
    memcpy call clobbers the caller-saved argument registers. }
  for I := 0 to ADecl.Params.Count - 1 do
  begin
    Par := TMethodParam(ADecl.Params.Items[I]);
    if (Par.ResolvedType <> nil) and (Par.ResolvedType.Kind = tyRecord) and
       (RecReturnShape(TRecordTypeDesc(Par.ResolvedType)) = 0) then
    begin
      EmitSlotAddr('x0', Par.ParamName);
      EmitLoadSlot('x1', '__pptr_' + Par.ParamName);
      EmitIntLiteral('x2', Par.ResolvedType.RawSize());
      Self.Emit(#9'bl memcpy');
    end;
  end;
  { zero-initialise Result and every declared local (language rule: ALL
    variables are zero-initialised) }
  if FIsFunction and (RecShape >= 0) then
  begin
    EmitSlotAddr('x0', 'Result');
    Self.Emit(#9'movz w1, #0');
    EmitIntLiteral('x2', ADecl.ResolvedReturnType.RawSize());
    Self.Emit(#9'bl memset');
  end
  else if FIsFunction then
    EmitStoreSlot('xzr', 'Result');
  for I := 0 to ADecl.Body.Decls.Count - 1 do
    for J := 0 to TVarDecl(ADecl.Body.Decls.Items[I]).Names.Count - 1 do
    begin
      if TVarDecl(ADecl.Body.Decls.Items[I]).ResolvedType.Kind = tyRecord then
      begin
        { records zero-initialise their whole storage }
        EmitSlotAddr('x0',
          TVarDecl(ADecl.Body.Decls.Items[I]).Names.Strings[J]);
        Self.Emit(#9'movz w1, #0');
        EmitIntLiteral('x2',
          TVarDecl(ADecl.Body.Decls.Items[I]).ResolvedType.RawSize());
        Self.Emit(#9'bl memset');
      end
      else
        EmitStoreSlot('xzr',
          TVarDecl(ADecl.Body.Decls.Items[I]).Names.Strings[J]);
    end;

  EmitStmtList(ADecl.Body.Stmts);

  Self.Emit(FExitLabel + ':');
  { release string locals at scope exit (Exit statements land here too) }
  for I := 0 to FStrLocals.Count - 1 do
  begin
    EmitLoadSlot('x0', FStrLocals.Strings[I]);
    Self.Emit(#9'bl _StringRelease');
  end;
  { release class-typed locals (borrowed Self is NOT in FObjLocals) }
  for I := 0 to FObjLocals.Count - 1 do
  begin
    EmitLoadSlot('x0', FObjLocals.Strings[I]);
    Self.Emit(#9'bl _ClassRelease');
  end;
  { release the managed fields of record locals — the base-class walk needs
    a callee-saved base register across its release calls }
  for I := 0 to FRecLocals.Count - 1 do
    if not RecretManagedClean(TRecordTypeDesc(FRecLocals.Objects[I])) then
    begin
      Self.Emit(#9'str x19, [sp, #-16]!');
      EmitSlotAddr('x19', FRecLocals.Strings[I]);
      Self.EmitRecordFieldReleases(
        TRecordTypeDesc(FRecLocals.Objects[I]), 'x19');
      Self.Emit(#9'ldr x19, [sp], #16');
    end;
  if FIsFunction and (RecShape >= 0) then
  begin
    case RecShape of
      0:
      begin
        { sret: copy Result into the caller's x8 buffer }
        EmitLoadSlot('x0', '__sret');
        EmitPushX0();
        EmitSlotAddr('x0', 'Result');
        Self.Emit(#9'mov x1, x0');
        EmitPopTo('x0');
        EmitIntLiteral('x2', ADecl.ResolvedReturnType.RawSize());
        Self.Emit(#9'bl memcpy');
      end;
      1:
      begin
        EmitSlotAddr('x9', 'Result');
        Self.Emit(#9'ldr x0, [x9]');
      end;
      2:
      begin
        EmitSlotAddr('x9', 'Result');
        Self.Emit(#9'ldr x0, [x9]');
        Self.Emit(#9'ldr x1, [x9, #8]');
      end;
    else
      begin
        { HFA: N doubles in d0..d(N-1) }
        EmitSlotAddr('x9', 'Result');
        for I := 0 to (RecShape - 100) - 1 do
          Self.Emit(Format(#9'ldr d%d, [x9, #%d]', [I, I * 8]));
      end;
    end;
  end
  else if FIsFunction and FResultSingle then
  begin
    { Single results return in s0 — the slot holds the 4-byte value }
    EmitSlotAddr('x9', 'Result');
    Self.Emit(#9'ldr s0, [x9]');
  end
  else if FIsFunction then
  begin
    EmitLoadSlot('x0', 'Result');
    if FResultFloat then
      Self.Emit(#9'fmov d0, x0');   { Double results return in d0 }
  end;
  Self.Emit(#9'mov sp, x29');
  Self.Emit(#9'ldp x29, x30, [sp], #16');
  Self.Emit(#9'ret');
  FFrame.Clear();
  FFrameSize := 0;
end;

procedure TArm64Backend.EmitCall(ADecl: TMethodDecl; const AName: string;
  AArgs: TObjectList; const ASretDest: string;
  ASelfPushed: Boolean; AVirtSlot: Integer);
var
  I, K, Shape: Integer;
  Arg: TASTExpr;
  NInt, NFloat: Integer;
  PopRegs: TStringList;
  Reg: string;
begin
  NInt := 0;
  NFloat := 0;
  if ADecl = nil then
    NotYet('call to unresolved routine ''' + AName + '''', nil);
  { a method receiver was pushed by the caller BEFORE this call: it is the
    first int-class value, popped last into x0 }
  if ASelfPushed then
    NInt := 1;
  { Apple's AArch64 ABI passes ALL variadic arguments on the stack
    (unlike Linux AAPCS64, where anonymous args continue the register
    sequence).  Until that is implemented, reject rather than emit a
    silently wrong call. }
  if ADecl.IsVarArgs and (AArgs.Count > ADecl.Params.Count) then
    NotYet('varargs call (Apple AArch64 passes variadic args on the stack)',
      ADecl);
  if ADecl.IsExternal and (ADecl.ExternalName = '') then
    NotYet('external routine without a link name', nil);
  if AArgs.Count > 8 then
    NotYet('call with more than 8 arguments', nil);
  { Evaluate args left-to-right onto the stack (calls inside an argument
    cannot clobber earlier args), floats as their 8-byte bit pattern.
    Integer and float args consume INDEPENDENT register sequences
    (x0.. / d0..) per AAPCS64.  Each pushed 8-byte value records its
    final register up front; the pop walk restores in reverse order. }
  PopRegs := TStringList.Create();
  try
    if ASelfPushed then
      PopRegs.Add('x0');
    for I := 0 to AArgs.Count - 1 do
    begin
      Arg := TASTExpr(AArgs.Items[I]);
      if (I < ADecl.Params.Count) and
         TMethodParam(ADecl.Params.Items[I]).IsVarParam then
      begin
        { var/out param: pass the lvalue's address.  A var param handed
          straight through to another var param forwards the address it
          already holds. }
        if not (Arg is TIdentExpr) then
          NotYet('var argument from this expression', Arg);
        if NInt >= 8 then NotYet('arguments spilling to the stack', Arg);
        if TIdentExpr(Arg).ParamMode = pmVar then
          EmitLoadSlot('x0', TIdentExpr(Arg).Name)
        else
          EmitSlotAddr('x0', TIdentExpr(Arg).Name);
        EmitPushX0();
        PopRegs.Add('x' + IntToStr(NInt));
        Inc(NInt);
      end
      else if (Arg.ResolvedType <> nil) and
         (Arg.ResolvedType.Kind = tyRecord) then
      begin
        if ADecl.IsExternal then
          { C-side small-struct marshalling needs hardware validation
            first — same honest hole as external record returns }
          NotYet('record argument to an external routine', Arg);
        if not (Arg is TIdentExpr) then
          NotYet('record argument from this expression', Arg);
        Shape := RecReturnShape(TRecordTypeDesc(Arg.ResolvedType));
        case Shape of
          0:
          begin
            { >16B: pass the lvalue address.  AAPCS64 wants a caller-side
              copy, but our callees memcpy the bytes into their own slot
              at entry (before any user code runs), which yields identical
              by-value semantics — and external callees are rejected above }
            if NInt >= 8 then NotYet('arguments spilling to the stack', Arg);
            EmitSlotAddr('x0', TIdentExpr(Arg).Name);
            EmitPushX0();
            PopRegs.Add('x' + IntToStr(NInt));
            Inc(NInt);
          end;
          1:
          begin
            if NInt >= 8 then NotYet('arguments spilling to the stack', Arg);
            EmitSlotAddr('x0', TIdentExpr(Arg).Name);
            Self.Emit(#9'ldr x0, [x0]');
            EmitPushX0();
            PopRegs.Add('x' + IntToStr(NInt));
            Inc(NInt);
          end;
          2:
          begin
            if NInt >= 7 then NotYet('arguments spilling to the stack', Arg);
            EmitSlotAddr('x9', TIdentExpr(Arg).Name);
            Self.Emit(#9'ldr x0, [x9]');
            EmitPushX0();
            PopRegs.Add('x' + IntToStr(NInt));
            EmitSlotAddr('x9', TIdentExpr(Arg).Name);
            Self.Emit(#9'ldr x0, [x9, #8]');
            EmitPushX0();
            PopRegs.Add('x' + IntToStr(NInt + 1));
            NInt := NInt + 2;
          end;
        else
          { HFA of (Shape - 100) Doubles in d(NFloat).. }
          if NFloat + (Shape - 100) > 8 then
            NotYet('arguments spilling to the stack', Arg);
          for K := 0 to (Shape - 100) - 1 do
          begin
            EmitSlotAddr('x9', TIdentExpr(Arg).Name);
            Self.Emit(Format(#9'ldr x0, [x9, #%d]', [K * 8]));
            EmitPushX0();
            PopRegs.Add('d' + IntToStr(NFloat + K));
          end;
          NFloat := NFloat + (Shape - 100);
        end;
      end
      else if (Arg.ResolvedType <> nil) and
              (Arg.ResolvedType.Kind = tyString) then
      begin
        { the callee owns its copy (by-value params retain in the callee
          prologue; const params borrow), so the caller passes a BORROWED
          pointer.  Owned +1 transients (concat/call results) would need a
          post-call release slot — honest hole until then. }
        if OwnsStringRef(Arg) then
          NotYet('owned string transient as argument', Arg);
        if not ((Arg is TIdentExpr) or (Arg is TStringLiteral)) then
          NotYet('string argument from this expression', Arg);
        if NInt >= 8 then NotYet('arguments spilling to the stack', Arg);
        Self.EmitExprToX0(Arg);
        EmitPushX0();
        PopRegs.Add('x' + IntToStr(NInt));
        Inc(NInt);
      end
      else if IsFloatExpr(Arg) then
      begin
        if NFloat >= 8 then NotYet('arguments spilling to the stack', Arg);
        Self.EmitExprToD0(Arg);
        Self.Emit(#9'fmov x0, d0');
        EmitPushX0();
        { a Single param wants the value in s(N) — the pop walk narrows }
        if (Arg.ResolvedType <> nil) and
           (Arg.ResolvedType.Kind = tySingle) then
          PopRegs.Add('s' + IntToStr(NFloat))
        else
          PopRegs.Add('d' + IntToStr(NFloat));
        Inc(NFloat);
      end
      else if IsIntFam(Arg.ResolvedType) or (Arg is TIntLiteral) then
      begin
        if NInt >= 8 then NotYet('arguments spilling to the stack', Arg);
        Self.EmitExprToX0(Arg);
        EmitPushX0();
        PopRegs.Add('x' + IntToStr(NInt));
        Inc(NInt);
      end
      else
        NotYet('call argument of this type', Arg);
    end;
    { pop last-pushed-first into each value's pre-assigned register }
    for I := PopRegs.Count - 1 downto 0 do
    begin
      Reg := PopRegs.Strings[I];
      if Copy(Reg, 0, 1) = 'd' then
      begin
        EmitPopTo('x9');
        Self.Emit(Format(#9'fmov %s, x9', [Reg]));
      end
      else if Copy(Reg, 0, 1) = 's' then
      begin
        { Single arg: the stacked value is the DOUBLE bit pattern —
          rebuild d(N) and narrow into s(N) (same register, legal) }
        EmitPopTo('x9');
        Self.Emit(Format(#9'fmov d%s, x9', [Copy(Reg, 1, Length(Reg) - 1)]));
        Self.Emit(Format(#9'fcvt %s, d%s',
          [Reg, Copy(Reg, 1, Length(Reg) - 1)]));
      end
      else
        EmitPopTo(Reg);
    end;
  finally
    PopRegs.Free();
  end;
  if ASretDest <> '' then
    { record sret: the callee writes through x8 (set AFTER the arg pops —
      nothing below clobbers it before the call) }
    EmitSlotAddr('x8', ASretDest);
  if AVirtSlot >= 0 then
  begin
    { virtual dispatch: vtable at instance[0]; slot 0 is the typeinfo
      back-pointer, so method slots start at +8 }
    Self.Emit(#9'ldr x9, [x0]');
    Self.Emit(Format(#9'ldr x9, [x9, #%d]', [(AVirtSlot + 1) * 8]));
    Self.Emit(#9'blr x9');
  end
  else
    Self.Emit(Format(#9'bl %s', [RoutineSym(ADecl, AName)]));
end;

{ ---- data sections ------------------------------------------------------- }

procedure TArm64Backend.EmitStrLitSection;
var
  I, Len: Integer;
begin
  if FStrLits.Count = 0 then Exit;
  Self.Emit('.section .rodata');
  for I := 0 to FStrLits.Count - 1 do
  begin
    Len := Length(FStrLits.Strings[I]);
    Self.Emit('.balign 4');
    Self.Emit(Format('__s%d:', [I]));
    Self.Emit(#9'.word -1');                    { refcnt = immortal }
    Self.Emit(Format(#9'.word %d', [Len]));     { length }
    Self.Emit(Format(#9'.word %d', [Len]));     { capacity }
    if Len > 0 then
      Self.Emit(Format(#9'.ascii "%s"', [AsmEscape(FStrLits.Strings[I])]));
    Self.Emit(#9'.byte 0');
  end;
end;

procedure TArm64Backend.EmitFloatLitSection;
var
  I: Integer;
begin
  if FFloatLits.Count = 0 then Exit;
  Self.Emit('.section .rodata');
  for I := 0 to FFloatLits.Count - 1 do
  begin
    Self.Emit('.balign 8');
    Self.Emit(Format('__d%d:', [I]));
    Self.Emit(Format(#9'.double %s', [FFloatLits.Strings[I]]));
  end;
end;

procedure TArm64Backend.EmitGlobalsSection;
var
  I, J: Integer;
  Directive: string;
  AnyBss, AnyData: Boolean;
begin
  if FGlobalNames.Count = 0 then Exit;
  AnyBss := False;
  AnyData := False;
  for I := 0 to FGlobalNames.Count - 1 do
    if FGlobalInits.ContainsKey(FGlobalNames.Strings[I]) then
      AnyData := True
    else
      AnyBss := True;
  if AnyBss then
  begin
    Self.Emit('.section .bss');
    for I := 0 to FGlobalNames.Count - 1 do
    begin
      if FGlobalInits.ContainsKey(FGlobalNames.Strings[I]) then Continue;
      Self.Emit('.balign 8');
      Self.Emit(Format('_g_%s:', [FGlobalNames.Strings[I]]));
      if FGlobalSize.TryGetValue(FGlobalNames.Strings[I], J) then
        Self.Emit(Format(#9'.zero %d', [J]))
      else
        Self.Emit(#9'.zero 8');
    end;
  end;
  if AnyData then
  begin
    Self.Emit('.section .data');
    for I := 0 to FGlobalNames.Count - 1 do
    begin
      if not FGlobalInits.TryGetValue(FGlobalNames.Strings[I], Directive) then
        Continue;
      Self.Emit('.balign 8');
      Self.Emit(Format('_g_%s:', [FGlobalNames.Strings[I]]));
      Self.Emit(Directive);
    end;
  end;
end;

{ ---- classes ------------------------------------------------------------- }

function TArm64Backend.ClassPrefixOwner(const AOwner: string): string;
begin
  { mirror of TCodeGenQBE.ClassUnitPrefixOwner: the program name and the
    unmangled RTL units keep bare class symbols }
  Result := '';
  if AOwner = '' then Exit;
  if (FProgramName <> '') and SameText(AOwner, FProgramName) then Exit;
  if SameText(AOwner, 'System') then Exit;
  if (Length(AOwner) >= 4) and SameText(Copy(AOwner, 0, 4), 'rtl.') then Exit;
  if (Length(AOwner) >= 7) and SameText(Copy(AOwner, 0, 7), 'blaise_') then Exit;
  Result := CodegenMangle(AOwner) + '_';
end;

function TArm64Backend.ClassSym(ATD: TTypeDecl): string;
var
  D: TRecordTypeDesc;
begin
  D := ClassDescOf(ATD);
  Result := ClassPrefixOwner(D.OwningUnit) + CodegenMangle(ATD.Name);
end;

function TArm64Backend.ClassDescOf(ATD: TTypeDecl): TRecordTypeDesc;
var
  D: TTypeDesc;
begin
  D := TTypeDesc(ATD.ResolvedDesc);
  if (D = nil) and (FSymTable <> nil) then
    D := FSymTable.FindType(ATD.Name);
  if (D = nil) or not (D is TRecordTypeDesc) then
    NotYet('unresolved class ''' + ATD.Name + '''', nil);
  Result := TRecordTypeDesc(D);
end;

procedure TArm64Backend.EmitClassCleanupFns;
var
  I: Integer;
  TD: TTypeDecl;
  RT, Walk: TRecordTypeDesc;
  Sym: string;
begin
  { _FieldCleanup_<T>(self): invoked by _ClassRelease at refcount zero.
    Calls the nearest user Destroy in the chain once, then releases the
    managed fields (inherited fields are merged into this class's list
    by the semantic pass, so one walk covers everything). }
  Self.Emit('');
  Self.Emit('.globl _FieldCleanup_TObject');
  Self.Emit('_FieldCleanup_TObject:');
  Self.Emit(#9'ret');
  for I := 0 to FClassDecls.Count - 1 do
  begin
    TD := TTypeDecl(FClassDecls.Items[I]);
    RT := ClassDescOf(TD);
    Sym := '_FieldCleanup_' + ClassSym(TD);
    Self.Emit('');
    Self.Emit(Format('.globl %s', [Sym]));
    Self.Emit(Sym + ':');
    Self.Emit(#9'stp x29, x30, [sp, #-16]!');
    Self.Emit(#9'mov x29, sp');
    Self.Emit(#9'str x19, [sp, #-16]!');
    Self.Emit(#9'mov x19, x0');
    Walk := RT;
    while Walk <> nil do
    begin
      if Walk.HasDestroyMethod then
      begin
        if Walk.DestroyResolvedQbeName <> '' then
          Self.Emit(Format(#9'bl %s',
            [CodegenMangle(Walk.DestroyResolvedQbeName)]))
        else
          Self.Emit(Format(#9'bl %s_Destroy', [CodegenMangle(Walk.Name)]));
        Break;
      end;
      Walk := Walk.Parent;
    end;
    Self.EmitRecordFieldReleases(RT, 'x19');
    Self.Emit(#9'ldr x19, [sp], #16');
    Self.Emit(#9'ldp x29, x30, [sp], #16');
    Self.Emit(#9'ret');
  end;
end;

procedure TArm64Backend.EmitClassMetaSections;
var
  I, S: Integer;
  TD: TTypeDecl;
  RT: TRecordTypeDesc;
  E: TVTableEntry;
  Sym, ParentRef: string;
begin
  { TObject stubs once per program: root typeinfo, a vtable carrying the
    built-in virtuals, and the class-name blob.  TObject_Destroy /
    TObject_ToString resolve from the RTL at link time. }
  Self.Emit('');
  Self.Emit('.section .rodata');
  Self.Emit('.balign 4');
  Self.Emit('__cn_TObject_h:');
  Self.Emit(#9'.word -1');
  Self.Emit(#9'.word 7');
  Self.Emit(#9'.word 7');
  Self.Emit('__cn_TObject:');
  Self.Emit(#9'.ascii "TObject"');
  Self.Emit(#9'.byte 0');
  Self.Emit('.section .data');
  Self.Emit('.balign 8');
  Self.Emit('.globl typeinfo_TObject');
  Self.Emit('typeinfo_TObject:');
  Self.Emit(#9'.quad 0');                       { parent }
  Self.Emit(#9'.quad 0');                       { impllist }
  Self.Emit(#9'.quad __cn_TObject');            { class name }
  Self.Emit(#9'.quad 0');                       { published methods }
  Self.Emit(#9'.quad 8');                       { instance size: vptr }
  Self.Emit(#9'.quad _FieldCleanup_TObject');
  Self.Emit(#9'.quad vtable_TObject');
  Self.Emit(#9'.quad 0');                       { class attrs }
  Self.Emit(#9'.quad 0');                       { method attrs }
  Self.Emit('.globl vtable_TObject');
  Self.Emit('vtable_TObject:');
  Self.Emit(#9'.quad typeinfo_TObject');
  Self.Emit(#9'.quad TObject_Destroy');
  Self.Emit(#9'.quad TObject_ToString');

  for I := 0 to FClassDecls.Count - 1 do
  begin
    TD := TTypeDecl(FClassDecls.Items[I]);
    RT := ClassDescOf(TD);
    Sym := ClassSym(TD);
    Self.Emit('.section .rodata');
    Self.Emit('.balign 4');
    Self.Emit(Format('__cn_%s_h:', [Sym]));
    Self.Emit(#9'.word -1');
    Self.Emit(Format(#9'.word %d', [Length(TD.Name)]));
    Self.Emit(Format(#9'.word %d', [Length(TD.Name)]));
    Self.Emit(Format('__cn_%s:', [Sym]));
    Self.Emit(Format(#9'.ascii "%s"', [TD.Name]));
    Self.Emit(#9'.byte 0');
    if (RT.Parent <> nil) and (RT.Parent.Name <> 'TObject') then
      ParentRef := 'typeinfo_' + ClassPrefixOwner(RT.Parent.OwningUnit) +
        CodegenMangle(RT.Parent.Name)
    else
      ParentRef := 'typeinfo_TObject';
    Self.Emit('.section .data');
    Self.Emit('.balign 8');
    Self.Emit(Format('.globl typeinfo_%s', [Sym]));
    Self.Emit(Format('typeinfo_%s:', [Sym]));
    Self.Emit(Format(#9'.quad %s', [ParentRef]));
    Self.Emit(#9'.quad 0');
    Self.Emit(Format(#9'.quad __cn_%s', [Sym]));
    Self.Emit(#9'.quad 0');
    Self.Emit(Format(#9'.quad %d', [RT.RawSize()]));
    Self.Emit(Format(#9'.quad _FieldCleanup_%s', [Sym]));
    Self.Emit(Format(#9'.quad vtable_%s', [Sym]));
    Self.Emit(#9'.quad 0');
    Self.Emit(#9'.quad 0');
    Self.Emit(Format('.globl vtable_%s', [Sym]));
    Self.Emit(Format('vtable_%s:', [Sym]));
    Self.Emit(Format(#9'.quad typeinfo_%s', [Sym]));
    for S := 0 to RT.VTableCount() - 1 do
    begin
      E := RT.VTableEntryAt(S);
      if E.IsAbstract then
        Self.Emit(#9'.quad _AbstractMethodError')
      else if (Length(E.ImplName) > 0) and
              (StrAt(E.ImplName, 0) = Ord('$')) then
        { ImplName is a QBE label and may carry the $ sigil }
        Self.Emit(Format(#9'.quad %s',
          [CodegenMangle(StrCopyTail(E.ImplName, 1))]))
      else
        Self.Emit(Format(#9'.quad %s', [CodegenMangle(E.ImplName)]));
    end;
  end;
end;

procedure TArm64Backend.EmitMethodCallCommon(AMethod: TMethodDecl;
  const AName: string; AArgs: TObjectList);
begin
  { receiver is in x0 — push it (EmitCall pops it back into x0 last) }
  EmitPushX0();
  EmitCall(AMethod, AName, AArgs, '', True, AMethod.VTableSlot);
end;

procedure TArm64Backend.EmitMethodCallStmt(AStmt: TMethodCallStmt);
var
  MD: TMethodDecl;
begin
  if AStmt.IsConstructorCall or AStmt.IsImplicitSelf or
     (AStmt.ObjExpr <> nil) or
     ((AStmt.ObjectName = '') and not AStmt.IsStaticCall) then
    NotYet('this method-call form', AStmt);
  MD := TMethodDecl(AStmt.ResolvedMethod);
  if MD = nil then
    NotYet('unresolved method ''' + AStmt.Name + '''', AStmt);
  if AStmt.IsStaticCall or MD.IsStatic then
  begin
    EmitCall(MD, AStmt.Name, AStmt.Args);
    Exit;
  end;
  if (AStmt.ResolvedReturnTypeDesc <> nil) and
     (AStmt.ResolvedReturnTypeDesc.Kind in [tyRecord, tyInterface]) then
    NotYet('discarded aggregate-returning method call', AStmt);
  EmitLoadSlot('x0', AStmt.ObjectName);
  if AStmt.IsVarParam then
    Self.Emit(#9'ldr x0, [x0]');
  EmitMethodCallCommon(MD, AStmt.Name, AStmt.Args);
  { a discarded owned result (class-typed) must be released }
  if (AStmt.ResolvedReturnTypeDesc <> nil) and
     (AStmt.ResolvedReturnTypeDesc.Kind = tyClass) then
    Self.Emit(#9'bl _ClassRelease');
  if (AStmt.ResolvedReturnTypeDesc <> nil) and
     (AStmt.ResolvedReturnTypeDesc.Kind = tyString) then
    Self.Emit(#9'bl _StringRelease');
end;

procedure TArm64Backend.EmitMethodCallExpr(AExpr: TMethodCallExpr);
var
  MD: TMethodDecl;
  TD: TTypeDecl;
  I: Integer;
  Sym: string;
begin
  if AExpr.IsConstructorCall then
  begin
    { TFoo.Create(args): _ClassCreate(typeinfo) allocates, installs the
      vtable and takes the +1; a declared constructor body then runs as a
      plain method on the new instance. }
    if AExpr.IsMetaclassDispatch then
      NotYet('metaclass constructor dispatch', AExpr);
    Sym := '';
    for I := 0 to FClassDecls.Count - 1 do
    begin
      TD := TTypeDecl(FClassDecls.Items[I]);
      if SameText(TD.Name, AExpr.ObjectName) then
      begin
        Sym := ClassSym(TD);
        Break;
      end;
    end;
    if Sym = '' then
      NotYet('constructor for class ''' + AExpr.ObjectName + '''', AExpr);
    Self.Emit(Format(#9'adrp x0, typeinfo_%s@PAGE', [Sym]));
    Self.Emit(Format(#9'add x0, x0, typeinfo_%s@PAGEOFF', [Sym]));
    Self.Emit(#9'bl _ClassCreate');
    MD := TMethodDecl(AExpr.ResolvedMethod);
    if (MD <> nil) and (MD.Body <> nil) then
    begin
      EmitPushX0();               { keep the result across the ctor call }
      EmitMethodCallCommon(MD, 'Create', AExpr.Args);
      EmitPopTo('x0');
    end
    else if AExpr.Args.Count > 0 then
      NotYet('constructor arguments without a declared constructor', AExpr);
    Exit;
  end;
  if AExpr.IsBuiltinToString then
  begin
    { built-in TObject.ToString: always-virtual through vtable slot 1
      (offset 16 past the typeinfo back-pointer).  Returns an owned +1
      string. }
    if (AExpr.ObjExpr <> nil) or (AExpr.ObjectName = '') then
      NotYet('ToString on this receiver form', AExpr);
    EmitLoadSlot('x0', AExpr.ObjectName);
    if AExpr.IsVarParam then
      Self.Emit(#9'ldr x0, [x0]');
    Self.Emit(#9'ldr x9, [x0]');
    Self.Emit(#9'ldr x9, [x9, #16]');
    Self.Emit(#9'blr x9');
    Exit;
  end;
  if AExpr.IsMetaclassDispatch or AExpr.IsBuiltinInheritsFrom or
     AExpr.IsProcFieldCall or (AExpr.ObjExpr <> nil) or
     ((AExpr.ObjectName = '') and not AExpr.IsStaticCall) then
    NotYet('this method-call form', AExpr);
  MD := TMethodDecl(AExpr.ResolvedMethod);
  if MD = nil then
    NotYet('unresolved method ''' + AExpr.Name + '''', AExpr);
  if AExpr.IsStaticCall or MD.IsStatic then
  begin
    { static (class-level) call: no Self, plain call to the mangled name }
    EmitCall(MD, AExpr.Name, AExpr.Args);
    Exit;
  end;
  EmitLoadSlot('x0', AExpr.ObjectName);
  if AExpr.IsVarParam then
    Self.Emit(#9'ldr x0, [x0]');
  EmitMethodCallCommon(MD, AExpr.Name, AExpr.Args);
end;

{ ---- program / unit ------------------------------------------------------ }

procedure TArm64Backend.EmitProgram(AProg: TProgram);
var
  I, J: Integer;
  VD:   TVarDecl;
  Decl: TMethodDecl;
  FrameAligned: Integer;
  TDcl: TTypeDecl;
  CDef: TClassTypeDef;
begin
  FProgramName := AProg.Name;
  FCurrentUnitName := '';
  for I := 0 to AProg.Block.TypeDecls.Count - 1 do
  begin
    TDcl := TTypeDecl(AProg.Block.TypeDecls.Items[I]);
    if TDcl.Def is TClassTypeDef then
    begin
      CDef := TClassTypeDef(TDcl.Def);
      if CDef.ImplementsNames.Count > 0 then
        NotYet('classes implementing interfaces', nil);
      if CDef.Properties.Count > 0 then
        NotYet('class properties', nil);
      if CDef.Attributes.Count > 0 then
        NotYet('class attributes', nil);
      FClassDecls.Add(TDcl);
    end
    else if not (TDcl.Def is TRecordTypeDef) then
      NotYet('non-record type declarations', nil)
    else if TRecordTypeDef(TDcl.Def).Methods.Count > 0 then
      NotYet('record methods', nil);
  end;

  { Program-level variables become globals (int-family only for now). }
  for I := 0 to AProg.Block.Decls.Count - 1 do
  begin
    VD := TVarDecl(AProg.Block.Decls.Items[I]);
    if not (IsIntFam(VD.ResolvedType) or
            ((VD.ResolvedType <> nil) and
             (VD.ResolvedType.Kind in [tyDouble, tySingle, tyString,
                                       tyRecord, tyClass]))) then
      NotYet('program variable of this type', VD);
    for J := 0 to VD.Names.Count - 1 do
    begin
      FGlobalNames.Add(VD.Names.Strings[J]);
      if VD.InitConst <> nil then
        RegisterGlobalInit(VD.Names.Strings[J], VD);
      if VD.ResolvedType.Kind = tyString then
        FStrGlobals.Add(VD.Names.Strings[J]);
      if VD.ResolvedType.Kind = tyClass then
        FObjGlobals.Add(VD.Names.Strings[J]);
      if VD.ResolvedType.Kind = tyRecord then
      begin
        FRecGlobals.AddObject(VD.Names.Strings[J], VD.ResolvedType);
        FGlobalSize.Add(VD.Names.Strings[J], VD.ResolvedType.RawSize());
      end
      else
        FGlobalSize.Add(VD.Names.Strings[J], 8);
    end;
  end;

  Self.Emit('.text');

  { Standalone procedures/functions before $main. }
  for I := 0 to AProg.Block.ProcDecls.Count - 1 do
  begin
    Decl := TMethodDecl(AProg.Block.ProcDecls.Items[I]);
    if Decl.OwnerTypeName <> '' then Continue;   { method stubs: bodies below }
    if Decl.TypeParams <> nil then Continue;     { generic templates }
    if Decl.Body = nil then Continue;            { forward decls }
    if Decl.IsExternal then Continue;            { externals: call-site only }
    EmitFunctionDef(Decl);
  end;

  { Class method bodies (LinkClassMethodImpls placed them on the class
    defs), then the ARC field-cleanup functions. }
  for I := 0 to FClassDecls.Count - 1 do
  begin
    CDef := TClassTypeDef(TTypeDecl(FClassDecls.Items[I]).Def);
    for J := 0 to CDef.Methods.Count - 1 do
    begin
      Decl := TMethodDecl(CDef.Methods.Items[J]);
      if Decl.Body = nil then Continue;
      if Decl.TypeParams <> nil then
        NotYet('generic methods', Decl);
      EmitFunctionDef(Decl);
    end;
  end;
  EmitClassCleanupFns();

  { _main's frame holds only the hidden for-loop bound slots (program vars
    are globals). }
  FIsFunction := False;
  FExitLabel := NewLabel('mainexit');
  FFrame.Clear();
  FFrameSize := 0;
  FForN := 0;
  for I := 0 to AProg.Block.Stmts.Count - 1 do
    RegisterForSlots(TASTStmt(AProg.Block.Stmts.Items[I]));
  FForN := 0;
  FrameAligned := (FFrameSize + 15) and (not 15);

  Self.Emit('');
  Self.Emit('.globl _main');
  Self.Emit('_main:');
  { Prologue: fp/lr pair + frame chain — ALWAYS (Darwin unwind).  argc/argv
    arrive in x0/x1 and pass straight through to _SetArgs, which must run
    before _BlaiseInit (that clobbers the argument registers). }
  Self.Emit(#9'stp x29, x30, [sp, #-16]!');
  Self.Emit(#9'mov x29, sp');
  if FrameAligned > 0 then
    Self.Emit(Format(#9'sub sp, sp, #%d', [FrameAligned]));
  Self.Emit(#9'bl _SetArgs');
  Self.Emit(#9'bl _BlaiseInit');
  { unit initialization sections, in dependency (append) order }
  for I := 0 to FUnitInits.Count - 1 do
    Self.Emit(Format(#9'bl %s', [FUnitInits.Strings[I]]));

  EmitStmtList(AProg.Block.Stmts);

  Self.Emit(FExitLabel + ':');
  { release string globals before returning (ARC parity with x86-64's
    program-exit global release) }
  for I := 0 to FStrGlobals.Count - 1 do
  begin
    EmitLoadSlot('x0', FStrGlobals.Strings[I]);
    Self.Emit(#9'bl _StringRelease');
  end;
  for I := 0 to FRecGlobals.Count - 1 do
    if not RecretManagedClean(TRecordTypeDesc(FRecGlobals.Objects[I])) then
    begin
      Self.Emit(#9'str x19, [sp, #-16]!');
      EmitSlotAddr('x19', FRecGlobals.Strings[I]);
      Self.EmitRecordFieldReleases(
        TRecordTypeDesc(FRecGlobals.Objects[I]), 'x19');
      Self.Emit(#9'ldr x19, [sp], #16');
    end;
  for I := 0 to FObjGlobals.Count - 1 do
  begin
    EmitLoadSlot('x0', FObjGlobals.Strings[I]);
    Self.Emit(#9'bl _ClassRelease');
  end;
  Self.Emit(#9'movz w0, #0');
  Self.Emit(#9'mov sp, x29');
  Self.Emit(#9'ldp x29, x30, [sp], #16');
  Self.Emit(#9'ret');

  EmitStrLitSection();
  EmitFloatLitSection();
  EmitGlobalsSection();
  if FClassDecls.Count > 0 then
    EmitClassMetaSections();
end;

procedure TArm64Backend.EmitUnit(AUnit: TUnit);
var
  I: Integer;
  Decl: TMethodDecl;

  procedure CheckTypeSubset(ATypeDecls: TObjectList);
  var
    K, M: Integer;
    UDcl: TTypeDecl;
    UDef: TClassTypeDef;
    MDcl: TMethodDecl;
  begin
    for K := 0 to ATypeDecls.Count - 1 do
    begin
      UDcl := TTypeDecl(ATypeDecls.Items[K]);
      if UDcl.Def is TClassTypeDef then
      begin
        UDef := TClassTypeDef(UDcl.Def);
        if UDef.ImplementsNames.Count > 0 then
          NotYet('classes implementing interfaces', nil);
        if UDef.Properties.Count > 0 then
          NotYet('class properties', nil);
        if UDef.Attributes.Count > 0 then
          NotYet('class attributes', nil);
        FClassDecls.Add(UDcl);
        for M := 0 to UDef.Methods.Count - 1 do
        begin
          MDcl := TMethodDecl(UDef.Methods.Items[M]);
          if MDcl.Body = nil then Continue;
          if MDcl.TypeParams <> nil then
            NotYet('generic methods', MDcl);
          EmitFunctionDef(MDcl);
        end;
        Continue;
      end;
      if not (UDcl.Def is TRecordTypeDef) then
        NotYet('non-record type declarations in unit ' + AUnit.Name, nil)
      else if TRecordTypeDef(UDcl.Def).Methods.Count > 0 then
        NotYet('record methods in unit ' + AUnit.Name, nil);
    end;
  end;

begin
  { Same deliberately-incremental subset as EmitProgram: routines and
    record types lower; everything else stays an honest hole.  Cross-unit
    call sites need nothing here — RoutineSym mangles through the
    semantic pass's ResolvedQbeName on both the definition and the call. }
  FCurrentUnitName := AUnit.Name;
  RegisterUnitVars(AUnit.IntfBlock);
  RegisterUnitVars(AUnit.ImplBlock);
  Self.Emit('.text');
  CheckTypeSubset(AUnit.IntfBlock.TypeDecls);
  CheckTypeSubset(AUnit.ImplBlock.TypeDecls);
  if (AUnit.GenericInstances.Count > 0) or
     (AUnit.GenericRecordInstances.Count > 0) or
     (AUnit.GenericMethodInstances.Count > 0) or
     (AUnit.GenericFuncInstances.Count > 0) then
    NotYet('generic instances in unit ' + AUnit.Name, nil);
  if (AUnit.FinalStmts <> nil) and (AUnit.FinalStmts.Count > 0) then
    NotYet('unit finalization section (' + AUnit.Name + ')', nil);

  Self.Emit('.text');
  for I := 0 to AUnit.ImplBlock.ProcDecls.Count - 1 do
  begin
    Decl := TMethodDecl(AUnit.ImplBlock.ProcDecls.Items[I]);
    if Decl.OwnerTypeName <> '' then Continue;   { method stubs — types NotYet above }
    if Decl.TypeParams <> nil then Continue;     { generic templates }
    if Decl.Body = nil then Continue;            { forward decls }
    if Decl.IsExternal then Continue;            { externals: call-site only }
    EmitFunctionDef(Decl);
  end;

  { Initialization section: a parameterless <unit>_init routine that _main
    calls (in dependency order) right after _BlaiseInit.  Finalization is a
    NotYet above rather than the x86 emit-but-never-call shape. }
  if (AUnit.InitStmts <> nil) and (AUnit.InitStmts.Count > 0) then
    EmitUnitInit(AUnit);
  FCurrentUnitName := '';
end;

procedure TArm64Backend.EmitUnitInit(AUnit: TUnit);
var
  I: Integer;
  Sym: string;
  FrameAligned: Integer;
begin
  Sym := CodegenMangle(AUnit.Name) + '_init';
  FUnitInits.Add(Sym);
  FIsFunction := False;
  FResultFloat := False;
  FExitLabel := NewLabel('uinitexit');
  FFrame.Clear();
  FFrameSize := 0;
  FStrLocals.Clear();
  FRecLocals.Clear();
  FForN := 0;
  for I := 0 to AUnit.InitStmts.Count - 1 do
    RegisterForSlots(TASTStmt(AUnit.InitStmts.Items[I]));
  FForN := 0;
  FrameAligned := (FFrameSize + 15) and (not 15);
  Self.Emit('');
  Self.Emit(Format('.globl %s', [Sym]));
  Self.Emit(Sym + ':');
  Self.Emit(#9'stp x29, x30, [sp, #-16]!');
  Self.Emit(#9'mov x29, sp');
  if FrameAligned > 0 then
    Self.Emit(Format(#9'sub sp, sp, #%d', [FrameAligned]));
  EmitStmtList(AUnit.InitStmts);
  Self.Emit(FExitLabel + ':');
  Self.Emit(#9'mov sp, x29');
  Self.Emit(#9'ldp x29, x30, [sp], #16');
  Self.Emit(#9'ret');
  FFrame.Clear();
  FFrameSize := 0;
end;

procedure TArm64Backend.RegisterUnitVars(ABlock: TBlock);
var
  I, J: Integer;
  VD: TVarDecl;
  N: string;
begin
  for I := 0 to ABlock.Decls.Count - 1 do
  begin
    VD := TVarDecl(ABlock.Decls.Items[I]);
    if not (IsIntFam(VD.ResolvedType) or
            ((VD.ResolvedType <> nil) and
             (VD.ResolvedType.Kind in [tyDouble, tySingle, tyString,
                                       tyRecord]))) then
      NotYet('unit variable of this type', VD);
    if VD.IsThreadVar then
      NotYet('unit threadvars', VD);
    for J := 0 to VD.Names.Count - 1 do
    begin
      FModuleVarNames.Add(VD.Names.Strings[J]);
      { register under the owning-unit-prefixed symbol so same-named vars
        in different units (or the program) cannot collide }
      N := GlobalSym(VD.Names.Strings[J]);
      FGlobalNames.Add(N);
      if VD.InitConst <> nil then
        RegisterGlobalInit(N, VD);
      if VD.ResolvedType.Kind = tyString then
        FStrGlobals.Add(N);
      if VD.ResolvedType.Kind = tyRecord then
      begin
        FRecGlobals.AddObject(N, VD.ResolvedType);
        FGlobalSize.Add(N, VD.ResolvedType.RawSize());
      end
      else
        FGlobalSize.Add(N, 8);
    end;
  end;
end;

procedure TArm64Backend.FinalizeEmit;
begin
  { data sections are emitted at the end of EmitProgram in this subset }
end;

{ ---- ARC walk primitives ------------------------------------------------- }

function TArm64Backend.ArcNestedBaseReg: string;
begin
  Result := 'x20';
end;

procedure TArm64Backend.ArcPushNestedBase(AOffset: Integer;
  const ABaseReg: string);
begin
  { Save the nested-base scratch as a full 16-byte slot (sp alignment holds
    across the recursion's runtime calls), then derive parent+offset. }
  Self.Emit(#9'str x20, [sp, #-16]!');
  if AOffset > 0 then
    Self.Emit(Format(#9'add x20, %s, #%d', [ABaseReg, AOffset]))
  else
    Self.Emit(Format(#9'mov x20, %s', [ABaseReg]));
end;

procedure TArm64Backend.ArcPopNestedBase;
begin
  Self.Emit(#9'ldr x20, [sp], #16');
end;

procedure TArm64Backend.EmitWeakClearAt(AOffset: Integer;
  const ABaseReg: string);
begin
  if AOffset > 0 then
    Self.Emit(Format(#9'add x0, %s, #%d', [ABaseReg, AOffset]))
  else
    Self.Emit(Format(#9'mov x0, %s', [ABaseReg]));
  Self.Emit(#9'bl _WeakClear');
end;

procedure TArm64Backend.EmitReleaseSlotAt(AType: TTypeDesc; AOffset: Integer;
  const ABaseReg: string; AZero: Boolean);
begin
  Self.Emit(Format(#9'ldr x0, [%s, #%d]', [ABaseReg, AOffset]));
  if AType.IsString() then
    Self.Emit(#9'bl _StringRelease')
  else if AType.Kind = tyDynArray then
    Self.Emit(#9'bl _DynArrayRelease')
  else
    { tyClass and tyInterface release the obj slot via _ClassRelease }
    Self.Emit(#9'bl _ClassRelease');
  if AZero then
    Self.Emit(Format(#9'str xzr, [%s, #%d]', [ABaseReg, AOffset]));
end;

procedure TArm64Backend.EmitRetainSlotAt(AType: TTypeDesc; AOffset: Integer;
  const ABaseReg: string);
begin
  Self.Emit(Format(#9'ldr x0, [%s, #%d]', [ABaseReg, AOffset]));
  if AType.IsString() then
    Self.Emit(#9'bl _StringAddRef')
  else if AType.Kind = tyDynArray then
    Self.Emit(#9'bl _DynArrayAddRef')
  else
    Self.Emit(#9'bl _ClassAddRef');
end;

procedure TArm64Backend.ArcEnterArrayWalk(const ABaseReg: string);
begin
  { x21 anchors the array base, x20 derives each element — saved as a PAIR
    so sp stays 16-aligned at the per-element release/retain calls. }
  Self.Emit(#9'stp x21, x20, [sp, #-16]!');
  Self.Emit(Format(#9'mov x21, %s', [ABaseReg]));
end;

procedure TArm64Backend.ArcArrayElemAddr(AByteOffset: Integer);
begin
  if AByteOffset > 0 then
    Self.Emit(Format(#9'add x20, x21, #%d', [AByteOffset]))
  else
    Self.Emit(#9'mov x20, x21');
end;

function TArm64Backend.ArcArrayElemReg: string;
begin
  Result := 'x20';
end;

procedure TArm64Backend.ArcLeaveArrayWalk;
begin
  Self.Emit(#9'ldp x21, x20, [sp], #16');
end;

end.
