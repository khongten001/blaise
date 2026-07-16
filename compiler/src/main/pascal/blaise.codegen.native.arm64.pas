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
  uStrCompat, blaise.codegen, blaise.codegen.native.backend, strutils,
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
    FUnitFinals:  TStringList;   { emitted <unit>_final symbols — called at
                                    program exit in REVERSE dependency order }
    FGlobalInits: TDictionary<string, string>;  { prefixed symbol -> .data
                                    directive for initialised globals }
    FGlobalStrInits: TStringList; { symbols of string-initialised globals }
    FGlobalStrVals:  TStringList; { parallel: the literal values }
    FClassDecls:  TObjectList;   { not owned — program-level class TTypeDecls }
    FObjLocals:   TStringList;   { class-typed locals — released at scope exit }
    FObjGlobals:  TStringList;   { class-typed globals — released at program exit }
    FTlvGlobals:  TStringList;   { threadvar globals — Mach-O TLV descriptors }
    FIntfDecls:   TObjectList;   { not owned — program-level interface TTypeDecls }
    FIntfLocals:  TStringList;   { interface locals (base name) — obj released at exit }
    FIntfGlobals: TStringList;   { interface globals (prefixed base name) }
    FExcDepth:    Integer;       { active exception frames at emission point }
    FExcSlotN:    Integer;       { next _excf_N frame slot ordinal }
    FFinallyBodies: TObjectList; { not owned — TCompoundStmt per frame (nil =
                                   except frame); mirrors the runtime stack }
    FLoopExcDepth: TStringList;  { FExcDepth at each enclosing loop's entry —
                                   break/continue unwind to it }
    FDynLocals:   TStringList;   { dyn-array locals — released at scope exit }
    FDynGlobals:  TStringList;   { dyn-array globals — released at exit }
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
    procedure EmitStrDisposeX0(AExpr: TASTExpr);
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
    function  NewExcFrameSlot: string;
    procedure EmitExcPrologue(const AFrameSlot, AExcLbl, ATryLbl: string);
    procedure EmitExcUnwindTo(ATargetDepth: Integer);
    procedure EmitTryFinally(AStmt: TTryFinallyStmt);
    procedure EmitTryExcept(AStmt: TTryExceptStmt);
    procedure EmitStaticElemAssign(AStmt: TStaticSubscriptAssign);
    procedure EmitRaise(AStmt: TRaiseStmt);
    procedure EmitRepeat(AStmt: TRepeatStmt);
    procedure EmitCase(AStmt: TCaseStmt);
    procedure EmitExprToX0Aux(AExpr: TASTExpr);
    procedure EmitFor(AStmt: TForStmt);
    procedure EmitExit(AStmt: TExitStmt);
    procedure EmitFunctionDef(ADecl: TMethodDecl);
    function  StackArgSize(AArg: TASTExpr): Integer;
    function  StackParamSize(APar: TMethodParam): Integer;
    function  AlignTo(AValue, AAlign: Integer): Integer;
    function  ComputeStackArgArea(ADecl: TMethodDecl; AArgs: TObjectList;
      ASelfPushed: Boolean): Integer;
    function  ComputeStackArgAreaEx(ADecl: TMethodDecl; AArgs: TObjectList;
      ASelfPushed: Boolean; out ATransBase: Integer): Integer;
    procedure DecodeMemArg(const AEntry: string; out AOff, ASize: Integer);
    procedure EmitCall(ADecl: TMethodDecl; const AName: string;
      AArgs: TObjectList; const ASretDest: string = '';
      ASelfPushed: Boolean = False; AVirtSlot: Integer = VIRT_NONE);
    { Pre-pass: register every local/param/hidden slot a routine body needs
      so the frame size is final before the prologue's sub sp. }
    function  MaxManagedRecRet(AStmt: TASTStmt): Integer;
    procedure RegisterFrameSlots(ADecl: TMethodDecl; ABody: TBlock);
    procedure RegisterForSlots(AStmt: TASTStmt);
    function  RoutineSym(ADecl: TMethodDecl; const AName: string): string;
    function  GlobalSym(const AName: string): string;
    procedure RegisterGlobalInit(const ASym: string; AVD: TVarDecl);
    { AAPCS64 record-return shape for ARec: 0 = sret via x8, 1 = x0,
      2 = x0:x1 memory image, 3/4 = HFA of N Doubles in d0..d(N-1)
      (encoded as 100+N).  Derived from the shared classifier; the
      register choice is this leaf's per-CPU step. }
    procedure EmitSmallSetLiteral(AExpr: TArrayLiteralExpr);
    procedure EmitStaticElemAddr(ASub: TStringSubscriptExpr);
    procedure EmitDynElemAddr(ASub: TStringSubscriptExpr);
    procedure EmitElemLoad(AElem: TTypeDesc);
    function  AggHasManaged(AType: TTypeDesc): Boolean;
    function  RecReturnShape(ARec: TRecordTypeDesc): Integer;

    procedure EmitStrLitSection;
    procedure EmitGlobalsSection;
  protected
    procedure EmitProgram(AProg: TProgram); override;
    procedure EmitUnit(AUnit: TUnit); override;
    procedure EmitUnitInit(AUnit: TUnit);
    procedure EmitUnitSection(AUnit: TUnit; AStmts: TObjectList;
      const ASym: string; ARegistry: TStringList);
    function  ClassPrefixOwner(const AOwner: string): string;
    function  PropAccessorSym(const AOwnerType, AMethod: string): string;
    function  ClassSym(ATD: TTypeDecl): string;
    function  ClassDescOf(ATD: TTypeDecl): TRecordTypeDesc;
    procedure EmitClassCleanupFns;
    procedure EmitClassMetaSections;
    procedure EmitTlvAddr(const ASym: string);
    procedure EmitTlvSections;
    procedure EmitMethodCallCommon(AMethod: TMethodDecl; const AName: string;
      AArgs: TObjectList);
    procedure EmitMethodCallOnExpr(AMethod: TMethodDecl; const AName: string;
      AArgs: TObjectList; AObjExpr: TASTExpr);
    procedure EmitMethodCallStmt(AStmt: TMethodCallStmt);
    procedure EmitMethodCallExpr(AExpr: TMethodCallExpr);
    procedure EmitInstanceFieldStore(AFld: TFieldInfo;
      AValueExpr: TASTExpr; const AInstSlot: string);
    procedure EmitImplicitSelfStore(AAsgn: TAssignment);
    procedure EmitInterfaceAssign(AAsgn: TAssignment);
    procedure EmitPropReadCall(AFld: TFieldAccessExpr);
    procedure EmitInterfaceAsCast(AAsgn: TAssignment);
    function  IntfItabSym(const AClassName, AIntfName: string): string;
    procedure EmitTypeinfoAddr(const AReg, ATypeName: string);
    procedure EmitIntfDispatch(const AVarName: string; AIdx: Integer;
      AArgs: TObjectList);
    procedure EmitIntfMetaSections;
    function  FindClassMethodImpl(ATD: TTypeDecl;
      const AName: string): TMethodDecl;
    function  ClassImplementsAny(ATD: TTypeDecl): Boolean;
    procedure EmitInstanceFieldStoreStacked(AFld: TFieldInfo;
      AValueExpr: TASTExpr);
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
  FUnitFinals  := TStringList.Create();
  FGlobalInits := TDictionary<string, string>.Create();
  FGlobalStrInits := TStringList.Create();
  FGlobalStrVals  := TStringList.Create();
  FClassDecls  := TObjectList.Create(False);
  FObjLocals   := TStringList.Create();
  FObjGlobals  := TStringList.Create();
  FTlvGlobals  := TStringList.Create();
  FIntfDecls   := TObjectList.Create(False);
  FIntfLocals  := TStringList.Create();
  FIntfGlobals := TStringList.Create();
  FFinallyBodies := TObjectList.Create(False);
  FLoopExcDepth := TStringList.Create();
  FDynLocals := TStringList.Create();
  FDynGlobals := TStringList.Create();
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
  FUnitFinals.Free();
  FGlobalInits.Free();
  FGlobalStrInits.Free();
  FGlobalStrVals.Free();
  FClassDecls.Free();
  FObjLocals.Free();
  FObjGlobals.Free();
  FTlvGlobals.Free();
  FIntfDecls.Free();
  FIntfLocals.Free();
  FIntfGlobals.Free();
  FFinallyBodies.Free();
  FLoopExcDepth.Free();
  FDynLocals.Free();
  FDynGlobals.Free();
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

procedure TArm64Backend.EmitTlvAddr(const ASym: string);
begin
  { Mach-O TLV access: materialise the descriptor address (the linker may
    relax the ldr to an add for a same-image variable), call its thunk
    with x0 = descriptor — the thunk returns the per-thread address in
    x0.  Clobbers caller-saved registers, like any call. }
  Self.Emit(Format(#9'adrp x0, _tv_%s@TLVPPAGE', [ASym]));
  Self.Emit(Format(#9'ldr x0, [x0, _tv_%s@TLVPPAGEOFF]', [ASym]));
  Self.Emit(#9'ldr x9, [x0]');
  Self.Emit(#9'blr x9');
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
  if FTlvGlobals.IndexOf(Sym) >= 0 then
  begin
    EmitTlvAddr(Sym);
    Self.Emit(Format(#9'ldr %s, [x0]', [AReg]));
    Exit;
  end;
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
  if FTlvGlobals.IndexOf(Sym) >= 0 then
  begin
    { park the value across the thunk call }
    Self.Emit(Format(#9'str %s, [sp, #-16]!', [AReg]));
    EmitTlvAddr(Sym);
    Self.Emit(#9'mov x9, x0');
    Self.Emit(#9'ldr x0, [sp], #16');
    Self.Emit(#9'str x0, [x9]');
    Exit;
  end;
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
  if FTlvGlobals.IndexOf(Sym) >= 0 then
  begin
    EmitTlvAddr(Sym);
    if AReg <> 'x0' then
      Self.Emit(Format(#9'mov %s, x0', [AReg]));
    Exit;
  end;
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
    if (AFld.TypeDesc.IsString() and not ArcExprOwnsRef(AValueExpr)) or
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
  if AFld.TypeDesc.Kind = tySingle then
  begin
    Self.EmitExprToD0OrConvert(AValueExpr);
    Self.Emit(#9'fcvt s0, d0');
    EmitLoadSlot('x9', AInstSlot);
    Self.Emit(Format(#9'str s0, [x9, #%d]', [AFld.Offset]));
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

procedure TArm64Backend.EmitInstanceFieldStoreStacked(AFld: TFieldInfo;
  AValueExpr: TASTExpr);
begin
  { like EmitInstanceFieldStore, but the instance pointer is on TOP of the
    stack (pushed by the caller); consumed on exit.  Needed for chained
    bases (A.B.C := v), which have no frame slot to re-derive from. }
  if AFld.TypeDesc.IsString() or (AFld.TypeDesc.Kind = tyClass) then
  begin
    Self.EmitExprToX0(AValueExpr);
    if (AFld.TypeDesc.IsString() and not ArcExprOwnsRef(AValueExpr)) or
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
    EmitPushX0();                       { [base][value] }
    Self.Emit(#9'ldr x9, [sp, #16]');
    Self.Emit(Format(#9'ldr x0, [x9, #%d]', [AFld.Offset]));
    if AFld.TypeDesc.IsString() then
      Self.Emit(#9'bl _StringRelease')
    else
      Self.Emit(#9'bl _ClassRelease');
    Self.Emit(#9'ldr x9, [sp, #16]');
    EmitPopTo('x0');
    Self.Emit(Format(#9'str x0, [x9, #%d]', [AFld.Offset]));
    Self.Emit(#9'add sp, sp, #16');     { drop the base }
    Exit;
  end;
  if AFld.TypeDesc.Kind = tySingle then
  begin
    Self.EmitExprToD0OrConvert(AValueExpr);
    Self.Emit(#9'fcvt s0, d0');
    Self.Emit(#9'ldr x9, [sp], #16');   { pop the base }
    Self.Emit(Format(#9'str s0, [x9, #%d]', [AFld.Offset]));
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
  Self.Emit(#9'ldr x9, [sp], #16');     { pop the base }
  Self.Emit(Format(#9'str x0, [x9, #%d]', [AFld.Offset]));
end;

procedure TArm64Backend.EmitImplicitSelfStore(AAsgn: TAssignment);
begin
  EmitInstanceFieldStore(TFieldInfo(AAsgn.ImplicitSelfField), AAsgn.Expr,
    'Self');
end;

procedure TArm64Backend.EmitFieldAssign(AStmt: TFieldAssignment);
begin
  if AStmt.PropWriteInfo <> nil then
  begin
    { method-backed property write: setter(self, value) — or
      setter(self, index, value) for the indexed form }
    if (AStmt.ObjExpr <> nil) or AStmt.IsImplicitSelf then
      NotYet('property write on this receiver form', AStmt);
    if AStmt.PropIndexExpr <> nil then
    begin
      if AStmt.IsElemWrite then
        NotYet('array-field element write via subscript', AStmt);
      if TPropertyInfo(AStmt.PropWriteInfo).IsStatic then
        NotYet('static indexed property write', AStmt);
      if TPropertyInfo(AStmt.PropWriteInfo).TypeDesc.IsFloat() then
        NotYet('float indexed property write', AStmt);
      if not (IsIntFam(AStmt.PropIndexExpr.ResolvedType) or
              (AStmt.PropIndexExpr is TIntLiteral)) then
        NotYet('indexed property with a non-integer index', AStmt);
      Self.EmitExprToX0(AStmt.PropIndexExpr);
      EmitPushX0();
      Self.EmitExprToX0(AStmt.Expr);
      EmitPushX0();
      EmitLoadSlot('x0', AStmt.RecordName);
      if AStmt.IsVarParam then
        Self.Emit(#9'ldr x0, [x0]');
      EmitPopTo('x2');
      EmitPopTo('x1');
      if AStmt.PropAccessorVSlot >= 0 then
      begin
        Self.Emit(#9'ldr x9, [x0]');
        Self.Emit(Format(#9'ldr x9, [x9, #%d]',
          [(AStmt.PropAccessorVSlot + 1) * 8]));
        Self.Emit(#9'blr x9');
      end
      else
        Self.Emit(Format(#9'bl %s',
          [PropAccessorSym(AStmt.PropOwnerType,
            TPropertyInfo(AStmt.PropWriteInfo).WriteMethod)]));
      Exit;
    end;
    if TPropertyInfo(AStmt.PropWriteInfo).IsStatic then
    begin
      { static setter: the value is the FIRST argument (no Self) }
      if TPropertyInfo(AStmt.PropWriteInfo).TypeDesc.IsFloat() then
        Self.EmitExprToD0OrConvert(AStmt.Expr)
      else
        Self.EmitExprToX0(AStmt.Expr);
      Self.Emit(Format(#9'bl %s',
        [PropAccessorSym(AStmt.PropOwnerType,
          TPropertyInfo(AStmt.PropWriteInfo).WriteMethod)]));
      Exit;
    end;
    if TPropertyInfo(AStmt.PropWriteInfo).TypeDesc.IsFloat() then
    begin
      Self.EmitExprToD0OrConvert(AStmt.Expr);
      EmitLoadSlot('x0', AStmt.RecordName);
      if AStmt.IsVarParam then
        Self.Emit(#9'ldr x0, [x0]');
    end
    else
    begin
      if (TPropertyInfo(AStmt.PropWriteInfo).TypeDesc.IsString() and
          ArcBuiltinStrArgOwnsRef(AStmt.Expr)) or
         ((TPropertyInfo(AStmt.PropWriteInfo).TypeDesc.Kind = tyClass) and
          ArcExprOwnsRef(AStmt.Expr)) then
        NotYet('owned transient as property value', AStmt);
      Self.EmitExprToX0(AStmt.Expr);
      EmitPushX0();
      EmitLoadSlot('x0', AStmt.RecordName);
      if AStmt.IsVarParam then
        Self.Emit(#9'ldr x0, [x0]');
      EmitPopTo('x1');
    end;
    if AStmt.PropAccessorVSlot >= 0 then
    begin
      Self.Emit(#9'ldr x9, [x0]');
      Self.Emit(Format(#9'ldr x9, [x9, #%d]',
        [(AStmt.PropAccessorVSlot + 1) * 8]));
      Self.Emit(#9'blr x9');
    end
    else
      Self.Emit(Format(#9'bl %s',
        [PropAccessorSym(AStmt.PropOwnerType,
          TPropertyInfo(AStmt.PropWriteInfo).WriteMethod)]));
    Exit;
  end;
  if AStmt.ObjExpr <> nil then
  begin
    { chained base: A.B.C := v — the base expression yields the instance }
    if AStmt.FieldInfo = nil then
      NotYet('unresolved field assignment', AStmt);
    if ArcExprOwnsRef(AStmt.ObjExpr) then
      NotYet('field store on an owned transient base', AStmt);
    Self.EmitExprToX0(AStmt.ObjExpr);
    EmitPushX0();
    EmitInstanceFieldStoreStacked(AStmt.FieldInfo, AStmt.Expr);
    Exit;
  end;
  if AStmt.IsVarParam or (AStmt.PropIndexExpr <> nil) then
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
          (AStmt.FieldInfo.TypeDesc.Kind in [tyDouble, tySingle,
                                             tyClass]) or
          AStmt.FieldInfo.TypeDesc.IsString()) then
    NotYet('field of this type', AStmt);
  if AStmt.FieldInfo.TypeDesc.Kind = tySingle then
  begin
    Self.EmitExprToD0OrConvert(AStmt.Expr);
    Self.Emit(#9'fcvt s0, d0');
    EmitSlotAddr('x9', AStmt.RecordName);
    Self.Emit(Format(#9'str s0, [x9, #%d]', [AStmt.FieldInfo.Offset]));
    Exit;
  end;
  if AStmt.FieldInfo.TypeDesc.IsString() or
     (AStmt.FieldInfo.TypeDesc.Kind = tyClass) then
  begin
    { managed field store: retain the value unless the expression owns a
      +1 already, release the field's old value, then store.  The slot
      address is re-derived after the release call (it clobbers x9). }
    Self.EmitExprToX0(AStmt.Expr);
    if (AStmt.FieldInfo.TypeDesc.IsString() and
        not ArcExprOwnsRef(AStmt.Expr)) or
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
  Lit: string;
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
  if (AExpr is TIdentExpr) and TIdentExpr(AExpr).IsMetaclassRef then
  begin
    { bare class name as a value: the typeinfo address IS the metaclass }
    EmitTypeinfoAddr('x0', TIdentExpr(AExpr).Name);
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
  if (AExpr is TIdentExpr) and TIdentExpr(AExpr).IsConstant then
  begin
    { named constant / enum member — folded by the semantic pass }
    if (AExpr.ResolvedType <> nil) and
       (AExpr.ResolvedType.Kind = tyString) then
    begin
      Idx := FStrLits.IndexOf(TIdentExpr(AExpr).ConstString);
      if Idx < 0 then
        Idx := FStrLits.Add(TIdentExpr(AExpr).ConstString);
      Self.Emit(Format(#9'adrp x0, __s%d@PAGE', [Idx]));
      Self.Emit(Format(#9'add x0, x0, __s%d@PAGEOFF', [Idx]));
      Self.Emit(#9'add x0, x0, #12');
      Exit;
    end;
    EmitIntLiteral('x0', TIdentExpr(AExpr).ConstValue);
    Exit;
  end;
  if AExpr is TIdentExpr then
  begin
    EmitLoadSlot('x0', TIdentExpr(AExpr).Name);
    if TIdentExpr(AExpr).ParamMode = pmVar then
      Self.Emit(#9'ldr x0, [x0]');   { var param: slot holds the address }
    Exit;
  end;
  if (AExpr is TFuncCallExpr) and
     SameText(TFuncCallExpr(AExpr).Name, 'Length') and
     (TFuncCallExpr(AExpr).Args.Count = 1) and
     (TASTExpr(TFuncCallExpr(AExpr).Args.Items[0]).ResolvedType <> nil) and
     (TASTExpr(TFuncCallExpr(AExpr).Args.Items[0]).ResolvedType.Kind =
       tyDynArray) then
  begin
    Self.EmitExprToX0(TASTExpr(TFuncCallExpr(AExpr).Args.Items[0]));
    Self.Emit(#9'bl _DynArrayLength');
    Exit;
  end;
  if (AExpr is TFuncCallExpr) and
     (TFuncCallExpr(AExpr).ResolvedDecl = nil) and
     (TFuncCallExpr(AExpr).Args.Count = 1) and
     (SameText(TFuncCallExpr(AExpr).Name, 'PChar') or
      SameText(TFuncCallExpr(AExpr).Name, 'Pointer')) then
  begin
    { PChar(x)/Pointer(x): bit-level reinterpret — a Blaise string data
      pointer is already NUL-terminated, so it IS the PChar value }
    Self.EmitExprToX0(TASTExpr(TFuncCallExpr(AExpr).Args.Items[0]));
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
    { X in SmallSet: ((set shr ord) and 1) and (ord < BitCount) — the
      range guard forces 0 for ordinals past the set width (a shift past
      the register width is undefined) }
    if (BE.Op = boIn) and (BE.Right.ResolvedType <> nil) and
       (BE.Right.ResolvedType.Kind = tySet) then
    begin
      if TSetTypeDesc(BE.Right.ResolvedType).IsJumbo() then
        NotYet('jumbo set membership', AExpr);
      Self.EmitExprToX0(BE.Right);
      EmitPushX0();
      Self.EmitExprToX0(BE.Left);
      Self.Emit(#9'mov x1, x0');
      EmitPopTo('x0');
      Self.Emit(#9'lsr x0, x0, x1');
      Self.Emit(#9'movz x2, #1');
      Self.Emit(#9'and x0, x0, x2');
      EmitIntLiteral('x2',
        TSetTypeDesc(BE.Right.ResolvedType).BitCount);
      Self.Emit(#9'cmp x1, x2');
      Self.Emit(#9'cset x2, lt');
      Self.Emit(#9'and x0, x0, x2');
      Exit;
    end;
    { small-set arithmetic: union/intersection/difference are plain bit
      ops on the mask; equality compares the masks }
    if (BE.Left.ResolvedType <> nil) and
       (BE.Left.ResolvedType.Kind = tySet) then
    begin
      if TSetTypeDesc(BE.Left.ResolvedType).IsJumbo() then
        NotYet('jumbo set operations', AExpr);
      Self.EmitExprToX0(BE.Left);
      EmitPushX0();
      Self.EmitExprToX0(BE.Right);
      Self.Emit(#9'mov x1, x0');
      EmitPopTo('x0');
      case BE.Op of
        boAdd: Self.Emit(#9'orr x0, x0, x1');
        boMul: Self.Emit(#9'and x0, x0, x1');
        boSub:
        begin
          { A - B = A and (not B): complement via eor with all-ones }
          Self.Emit(#9'movn x2, #0');
          Self.Emit(#9'eor x1, x1, x2');
          Self.Emit(#9'and x0, x0, x1');
        end;
        boEQ:
        begin
          Self.Emit(#9'cmp x0, x1');
          Self.Emit(#9'cset x0, eq');
        end;
        boNE:
        begin
          Self.Emit(#9'cmp x0, x1');
          Self.Emit(#9'cset x0, ne');
        end;
      else
        NotYet('this set operation', AExpr);
      end;
      Exit;
    end;
    { string concatenation: _StringConcat returns an owned +1 string }
    if (BE.Op = boAdd) and (AExpr.ResolvedType <> nil) and
       (AExpr.ResolvedType.Kind = tyString) then
    begin
      Self.EmitExprToX0(BE.Left);
      EmitPushX0();
      Self.EmitExprToX0(BE.Right);
      EmitPushX0();
      Self.Emit(#9'ldur x1, [sp]');        { right }
      Self.Emit(#9'ldur x0, [sp, #16]');   { left  }
      Self.Emit(#9'bl _StringConcat');
      { dispose operand transients by shape — nested concats produce rc=0
        intermediates that would otherwise leak permanently }
      if ArcBuiltinStrArgOwnsRef(BE.Left) or
         ArcBuiltinStrArgOwnsRef(BE.Right) then
      begin
        EmitPushX0();                      { park the result }
        if ArcBuiltinStrArgOwnsRef(BE.Right) then
        begin
          Self.Emit(#9'ldur x0, [sp, #16]');
          EmitStrDisposeX0(BE.Right);
        end;
        if ArcBuiltinStrArgOwnsRef(BE.Left) then
        begin
          Self.Emit(#9'ldur x0, [sp, #32]');
          EmitStrDisposeX0(BE.Left);
        end;
        EmitPopTo('x0');
      end;
      Self.Emit(#9'add sp, sp, #32');      { drop the operand brackets }
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
      if ArcBuiltinStrArgOwnsRef(BE.Right) then
      begin
        Self.Emit(#9'ldur x0, [sp, #16]');
        EmitStrDisposeX0(BE.Right);
      end;
      if ArcBuiltinStrArgOwnsRef(BE.Left) then
      begin
        Self.Emit(#9'ldur x0, [sp, #32]');
        EmitStrDisposeX0(BE.Left);
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
  if (AExpr is TStringSubscriptExpr) and
     (TStringSubscriptExpr(AExpr).StrExpr.ResolvedType <> nil) and
     (TStringSubscriptExpr(AExpr).StrExpr.ResolvedType.Kind =
       tyStaticArray) then
  begin
    EmitStaticElemAddr(TStringSubscriptExpr(AExpr));
    EmitElemLoad(TStaticArrayTypeDesc(
      TStringSubscriptExpr(AExpr).StrExpr.ResolvedType).ElementType);
    Exit;
  end;
  if (AExpr is TStringSubscriptExpr) and
     (TStringSubscriptExpr(AExpr).StrExpr.ResolvedType <> nil) and
     (TStringSubscriptExpr(AExpr).StrExpr.ResolvedType.Kind =
       tyDynArray) then
  begin
    EmitDynElemAddr(TStringSubscriptExpr(AExpr));
    EmitElemLoad(TDynArrayTypeDesc(
      TStringSubscriptExpr(AExpr).StrExpr.ResolvedType).ElementType);
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
  if (AExpr is TFieldAccessExpr) and
     (TFieldAccessExpr(AExpr).PropRead <> nil) then
  begin
    EmitPropReadCall(TFieldAccessExpr(AExpr));
    Exit;
  end;
  if AExpr is TSupportsExpr then
  begin
    { Supports(Obj, IFoo): non-nil itab in the impllist chain.  The
      3-arg form populates the out-var's fat pointer on success and
      leaves it UNTOUCHED on failure (QBE parity). }
    if ArcExprOwnsRef(TSupportsExpr(AExpr).Obj) then
      NotYet('Supports on an owned transient', AExpr);
    if TSupportsExpr(AExpr).OutVarName = '' then
    begin
      Self.EmitExprToX0(TSupportsExpr(AExpr).Obj);
      EmitTypeinfoAddr('x1', TSupportsExpr(AExpr).IntfTypeName);
      Self.Emit(#9'bl _GetItab');
      Self.Emit(#9'cmp x0, #0');
      Self.Emit(#9'cset x0, ne');
      Exit;
    end;
    Self.EmitExprToX0(TSupportsExpr(AExpr).Obj);
    EmitPushX0();                                    { [obj] }
    EmitTypeinfoAddr('x1', TSupportsExpr(AExpr).IntfTypeName);
    Self.Emit(#9'bl _GetItab');
    EmitPushX0();                                    { [obj][itab] }
    CondName := NewLabel('supno');
    Lit := NewLabel('supend');
    Self.Emit(Format(#9'cbz x0, %s', [CondName]));
    EmitPopTo('x0');
    EmitStoreSlot('x0', TSupportsExpr(AExpr).OutVarName + '_itab');
    Self.Emit(#9'ldr x0, [sp]');
    Self.Emit(#9'bl _ClassAddRef');
    EmitLoadSlot('x0', TSupportsExpr(AExpr).OutVarName);
    Self.Emit(#9'bl _ClassRelease');
    EmitPopTo('x0');
    EmitStoreSlot('x0', TSupportsExpr(AExpr).OutVarName);
    Self.Emit(#9'movz x0, #1');
    Self.Emit(Format(#9'b %s', [Lit]));
    Self.Emit(CondName + ':');
    Self.Emit(#9'add sp, sp, #32');
    Self.Emit(#9'movz x0, #0');
    Self.Emit(Lit + ':');
    Exit;
  end;
  if (AExpr is TArrayLiteralExpr) and (AExpr.ResolvedType <> nil) and
     (AExpr.ResolvedType.Kind = tySet) then
  begin
    if TSetTypeDesc(AExpr.ResolvedType).IsJumbo() then
      NotYet('jumbo set literals', AExpr);
    EmitSmallSetLiteral(TArrayLiteralExpr(AExpr));
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
     (TFieldAccessExpr(AExpr).Base <> nil) and
     (TFieldAccessExpr(AExpr).FieldInfo <> nil) and
     TFieldAccessExpr(AExpr).IsClassAccess and
     (not TFieldAccessExpr(AExpr).IsConstant) then
  begin
    { chained field read A.B.C: the base expression yields the instance
      pointer.  Owned transient bases stay NotYet — releasing them here
      would free the object before the field value is consumed. }
    if ArcExprOwnsRef(TFieldAccessExpr(AExpr).Base) then
      NotYet('field read on an owned transient base', AExpr);
    if not (IsIntFam(TFieldAccessExpr(AExpr).FieldInfo.TypeDesc) or
            (TFieldAccessExpr(AExpr).FieldInfo.TypeDesc.Kind in
              [tyDouble, tySingle, tyClass]) or
            TFieldAccessExpr(AExpr).FieldInfo.TypeDesc.IsString()) then
      NotYet('read of a field of this type', AExpr);
    Self.EmitExprToX0(TFieldAccessExpr(AExpr).Base);
    if TFieldAccessExpr(AExpr).FieldInfo.TypeDesc.Kind = tySingle then
      Self.Emit(Format(#9'ldr w0, [x0, #%d]',
        [TFieldAccessExpr(AExpr).FieldInfo.Offset]))
    else
      Self.Emit(Format(#9'ldr x0, [x0, #%d]',
        [TFieldAccessExpr(AExpr).FieldInfo.Offset]));
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
              [tyDouble, tySingle, tyClass]) or
            TFieldAccessExpr(AExpr).FieldInfo.TypeDesc.IsString()) then
      NotYet('read of a field of this type', AExpr);
    if TFieldAccessExpr(AExpr).IsImplicitSelf then
      EmitLoadSlot('x0', 'Self')
    else
      EmitLoadSlot('x0', TFieldAccessExpr(AExpr).RecordName);
    if TFieldAccessExpr(AExpr).FieldInfo.TypeDesc.Kind = tySingle then
      Self.Emit(Format(#9'ldr w0, [x0, #%d]',
        [TFieldAccessExpr(AExpr).FieldInfo.Offset]))
    else
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
              [tyDouble, tySingle, tyClass]) or
            TFieldAccessExpr(AExpr).FieldInfo.TypeDesc.IsString()) then
      NotYet('read of a field of this type', AExpr);
    EmitSlotAddr('x9', TFieldAccessExpr(AExpr).RecordName);
    if TFieldAccessExpr(AExpr).FieldInfo.TypeDesc.Kind = tySingle then
      Self.Emit(Format(#9'ldr w0, [x9, #%d]',
        [TFieldAccessExpr(AExpr).FieldInfo.Offset]))
    else
      Self.Emit(Format(#9'ldr x0, [x9, #%d]',
        [TFieldAccessExpr(AExpr).FieldInfo.Offset]));
    Exit;
  end;
  NotYet('expression ' + AExpr.ClassName, AExpr);
end;

procedure TArm64Backend.EmitStrDisposeX0(AExpr: TASTExpr);
begin
  { dispose the string transient whose value is in x0, by refcount shape
    (docs/arc-string-transient-handover.adoc):
      rc = 1 (ArcExprOwnsRef, user routine results)  -> one Release
      rc = 0 (concat/built-in results)               -> AddRef THEN Release
    A bare release on an rc = 0 buffer drives it to -1 = IMMORTAL — a
    permanent leak the --debug tracker cannot see. }
  if ArcExprOwnsRef(AExpr) then
    Self.Emit(#9'bl _StringRelease')
  else if ArcExprIsUnownedStrTransient(AExpr) then
  begin
    EmitPushX0();
    Self.Emit(#9'bl _StringAddRef');
    EmitPopTo('x0');
    Self.Emit(#9'bl _StringRelease');
  end;
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
  if (AExpr is TIdentExpr) and TIdentExpr(AExpr).IsImplicitSelf and
     (TIdentExpr(AExpr).ImplicitFieldInfo <> nil) and IsFloatExpr(AExpr) then
  begin
    { bare float field inside a method — the X0 path loads the bit
      pattern through Self (symmetry rule: every TIdentExpr branch needs
      its implicit-Self twin) }
    Self.EmitExprToX0(AExpr);
    Self.Emit(#9'fmov d0, x0');
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
  if (AExpr is TStringSubscriptExpr) and IsFloatExpr(AExpr) and
     (TStringSubscriptExpr(AExpr).StrExpr.ResolvedType <> nil) and
     (TStringSubscriptExpr(AExpr).StrExpr.ResolvedType.Kind =
       tyStaticArray) then
  begin
    { float array element: the integer path loads the bit pattern }
    Self.EmitExprToX0(AExpr);
    if (AExpr.ResolvedType <> nil) and
       (AExpr.ResolvedType.Kind = tySingle) then
    begin
      Self.Emit(#9'str w0, [sp, #-16]!');
      Self.Emit(#9'ldr s0, [sp]');
      Self.Emit(#9'add sp, sp, #16');
      Self.Emit(#9'fcvt d0, s0');
    end
    else
      Self.Emit(#9'fmov d0, x0');
    Exit;
  end;
  if (AExpr is TFieldAccessExpr) and
     (TFieldAccessExpr(AExpr).PropRead <> nil) and IsFloatExpr(AExpr) then
  begin
    { float property read: the getter leaves the value in d0 (or s0 for
      Single — widen) }
    EmitPropReadCall(TFieldAccessExpr(AExpr));
    if (AExpr.ResolvedType <> nil) and
       (AExpr.ResolvedType.Kind = tySingle) then
      Self.Emit(#9'fcvt d0, s0');
    Exit;
  end;
  if (AExpr is TFieldAccessExpr) and IsFloatExpr(AExpr) then
  begin
    { float field: load the bit pattern via the integer path.  A Single
      field arrives as 4 bytes in w0 — bounce it through the stack into
      s0 and widen (no fmov s,w encoding in the assembler yet). }
    Self.EmitExprToX0(AExpr);
    if (AExpr.ResolvedType <> nil) and
       (AExpr.ResolvedType.Kind = tySingle) then
    begin
      Self.Emit(#9'str w0, [sp, #-16]!');
      Self.Emit(#9'ldr s0, [sp]');
      Self.Emit(#9'add sp, sp, #16');
      Self.Emit(#9'fcvt d0, s0');
    end
    else
      Self.Emit(#9'fmov d0, x0');
    Exit;
  end;
  if AExpr is TMethodCallExpr then
  begin
    { float-returning method call: the integer emitter's method paths end
      at the call, and the value is already in d0 }
    if TMethodCallExpr(AExpr).IsConstructorCall then
      NotYet('constructor in float context', AExpr);
    EmitMethodCallExpr(TMethodCallExpr(AExpr));
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
  if AStmt is TRepeatStmt then
  begin
    EmitRepeat(TRepeatStmt(AStmt));
    Exit;
  end;
  if AStmt is TCaseStmt then
  begin
    EmitCase(TCaseStmt(AStmt));
    Exit;
  end;
  if AStmt is TTryFinallyStmt then
  begin
    EmitTryFinally(TTryFinallyStmt(AStmt));
    Exit;
  end;
  if AStmt is TTryExceptStmt then
  begin
    EmitTryExcept(TTryExceptStmt(AStmt));
    Exit;
  end;
  if AStmt is TRaiseStmt then
  begin
    EmitRaise(TRaiseStmt(AStmt));
    Exit;
  end;
  if AStmt is TStaticSubscriptAssign then
  begin
    EmitStaticElemAssign(TStaticSubscriptAssign(AStmt));
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
    if FLoopExcDepth.Count > 0 then
      EmitExcUnwindTo(StrToInt(
        FLoopExcDepth.Strings[FLoopExcDepth.Count - 1]));
    Self.Emit(Format(#9'b %s', [FBreakLbls.Strings[FBreakLbls.Count - 1]]));
    Exit;
  end;
  if AStmt is TContinueStmt then
  begin
    if FContLbls.Count = 0 then
      NotYet('continue outside a loop', AStmt);
    if FLoopExcDepth.Count > 0 then
      EmitExcUnwindTo(StrToInt(
        FLoopExcDepth.Strings[FLoopExcDepth.Count - 1]));
    Self.Emit(Format(#9'b %s', [FContLbls.Strings[FContLbls.Count - 1]]));
    Exit;
  end;
  NotYet('statement ' + AStmt.ClassName, AStmt);
end;

procedure TArm64Backend.EmitPropReadCall(AFld: TFieldAccessExpr);
begin
  { method-backed property read: a getter call on the receiver.  The value
    lands wherever the getter's return convention puts it (x0 for scalars,
    d0 for floats) — callers pick the register that matches the context.
    An indexed read calls getter(self, index). }
  if (AFld.PropRead.IndexParamName <> '') and (AFld.PropIndexExpr = nil) then
    NotYet('indexed property read without an index', AFld);
  if AFld.Base <> nil then
    NotYet('chained property read', AFld);
  if AFld.PropRead.IsStatic then
  begin
    { static property: the getter is a class-level routine — no receiver }
    Self.Emit(Format(#9'bl %s',
      [PropAccessorSym(AFld.PropOwnerType, AFld.PropRead.ReadMethod)]));
    Exit;
  end;
  if AFld.PropIndexExpr <> nil then
  begin
    if not (IsIntFam(AFld.PropIndexExpr.ResolvedType) or
            (AFld.PropIndexExpr is TIntLiteral)) then
      NotYet('indexed property with a non-integer index', AFld);
    Self.EmitExprToX0(AFld.PropIndexExpr);
    EmitPushX0();
  end;
  if AFld.IsImplicitSelf then
    EmitLoadSlot('x0', 'Self')
  else
    EmitLoadSlot('x0', AFld.RecordName);
  if AFld.IsVarParam then
    Self.Emit(#9'ldr x0, [x0]');
  if AFld.PropIndexExpr <> nil then
    EmitPopTo('x1');
  if AFld.PropAccessorVSlot >= 0 then
  begin
    Self.Emit(#9'ldr x9, [x0]');
    Self.Emit(Format(#9'ldr x9, [x9, #%d]',
      [(AFld.PropAccessorVSlot + 1) * 8]));
    Self.Emit(#9'blr x9');
  end
  else
    Self.Emit(Format(#9'bl %s',
      [PropAccessorSym(AFld.PropOwnerType, AFld.PropRead.ReadMethod)]));
end;

procedure TArm64Backend.EmitInterfaceAssign(AAsgn: TAssignment);
var
  ItabSym: string;
begin
  { fat-pointer stores: the obj half co-owns the backing instance (retain
    on store unless the source owns a +1, release the old); the itab half
    is static rodata — never refcounted. }
  if AAsgn.IsVarParam or (AAsgn.ImplicitSelfField <> nil) then
    NotYet('interface assignment to this target', AAsgn);
  if AAsgn.IsWeakLhs then
  begin
    { weak interface: the obj half goes through the weak table; the itab
      half is plain data }
    if ArcExprOwnsRef(AAsgn.Expr) then
      NotYet('owned transient into a [Weak] interface', AAsgn);
    if (AAsgn.Expr.ResolvedType <> nil) and
       (AAsgn.Expr.ResolvedType.Kind = tyClass) then
    begin
      Self.EmitExprToX0(AAsgn.Expr);
      Self.Emit(#9'mov x1, x0');
      EmitSlotAddr('x0', AAsgn.Name);
      Self.Emit(#9'bl _WeakAssign');
      ItabSym := IntfItabSym(TRecordTypeDesc(AAsgn.Expr.ResolvedType).Name,
        AAsgn.ResolvedLhsType.Name);
      Self.Emit(Format(#9'adrp x0, %s@PAGE', [ItabSym]));
      Self.Emit(Format(#9'add x0, x0, %s@PAGEOFF', [ItabSym]));
      EmitStoreSlot('x0', AAsgn.Name + '_itab');
      Exit;
    end;
    NotYet('[Weak] interface assignment from this expression', AAsgn);
  end;
  if (AAsgn.Expr.ResolvedType <> nil) and
     (AAsgn.Expr.ResolvedType.Kind = tyClass) then
  begin
    { narrowing a class value: the itab is known statically }
    ItabSym := IntfItabSym(TRecordTypeDesc(AAsgn.Expr.ResolvedType).Name,
      AAsgn.ResolvedLhsType.Name);
    Self.EmitExprToX0(AAsgn.Expr);
    if not ArcExprOwnsRef(AAsgn.Expr) then
    begin
      EmitPushX0();
      Self.Emit(#9'bl _ClassAddRef');
      EmitPopTo('x0');
    end;
    EmitPushX0();
    EmitLoadSlot('x0', AAsgn.Name);
    Self.Emit(#9'bl _ClassRelease');
    EmitPopTo('x0');
    EmitStoreSlot('x0', AAsgn.Name);
    Self.Emit(Format(#9'adrp x0, %s@PAGE', [ItabSym]));
    Self.Emit(Format(#9'add x0, x0, %s@PAGEOFF', [ItabSym]));
    EmitStoreSlot('x0', AAsgn.Name + '_itab');
    Exit;
  end;
  if (AAsgn.Expr is TIdentExpr) and (AAsgn.Expr.ResolvedType <> nil) and
     (AAsgn.Expr.ResolvedType.Kind = tyInterface) then
  begin
    { interface-to-interface copy of both halves }
    if TIdentExpr(AAsgn.Expr).ParamMode = pmVar then
      NotYet('var interface parameter', AAsgn);
    EmitLoadSlot('x0', TIdentExpr(AAsgn.Expr).Name);
    EmitPushX0();
    Self.Emit(#9'bl _ClassAddRef');
    EmitLoadSlot('x0', AAsgn.Name);
    Self.Emit(#9'bl _ClassRelease');
    EmitPopTo('x0');
    EmitStoreSlot('x0', AAsgn.Name);
    EmitLoadSlot('x0', TIdentExpr(AAsgn.Expr).Name + '_itab');
    EmitStoreSlot('x0', AAsgn.Name + '_itab');
    Exit;
  end;
  if AAsgn.Expr is TNilLiteral then
  begin
    EmitLoadSlot('x0', AAsgn.Name);
    Self.Emit(#9'bl _ClassRelease');
    EmitStoreSlot('xzr', AAsgn.Name);
    EmitStoreSlot('xzr', AAsgn.Name + '_itab');
    Exit;
  end;
  if (AAsgn.Expr is TAsExpr) and (AAsgn.Expr.ResolvedType <> nil) and
     (AAsgn.Expr.ResolvedType.Kind = tyInterface) then
  begin
    { I := Obj as IFoo — runtime itab lookup through the impllist chain;
      a nil result is an invalid cast }
    EmitInterfaceAsCast(AAsgn);
    Exit;
  end;
  if (AAsgn.Expr is TFuncCallExpr) and
     (TFuncCallExpr(AAsgn.Expr).ResolvedDecl <> nil) then
  begin
    { interface-returning call: the callee fills the 16-byte __iret
      scratch through x8; the returned obj is OWNED (+1) — release the
      old value, store both halves, no caller retain }
    if TMethodDecl(TFuncCallExpr(AAsgn.Expr).ResolvedDecl).IsExternal then
      NotYet('external interface-returning call', AAsgn);
    EmitCall(TMethodDecl(TFuncCallExpr(AAsgn.Expr).ResolvedDecl),
      TFuncCallExpr(AAsgn.Expr).Name, TFuncCallExpr(AAsgn.Expr).Args,
      '__iret');
    EmitLoadSlot('x0', AAsgn.Name);
    Self.Emit(#9'bl _ClassRelease');
    EmitSlotAddr('x9', '__iret');
    Self.Emit(#9'ldr x0, [x9]');
    EmitStoreSlot('x0', AAsgn.Name);
    Self.Emit(#9'ldr x0, [x9, #8]');
    EmitStoreSlot('x0', AAsgn.Name + '_itab');
    Exit;
  end;
  NotYet('interface assignment from this expression', AAsgn);
end;

procedure TArm64Backend.EmitInterfaceAsCast(AAsgn: TAssignment);
var
  AE: TAsExpr;
  OkL: string;
begin
  AE := TAsExpr(AAsgn.Expr);
  if ArcExprOwnsRef(AE.Obj) then
    NotYet('as-cast of an owned transient', AAsgn);
  Self.EmitExprToX0(AE.Obj);
  EmitPushX0();                     { the obj value }
  Self.Emit(Format(#9'adrp x1, typeinfo_%s@PAGE', [CodegenMangle(AE.TypeName)]));
  Self.Emit(Format(#9'add x1, x1, typeinfo_%s@PAGEOFF',
    [CodegenMangle(AE.TypeName)]));
  Self.Emit(#9'bl _GetItab');       { x0 = itab or nil }
  OkL := NewLabel('asok');
  Self.Emit(Format(#9'cbnz x0, %s', [OkL]));
  Self.Emit(#9'bl _Raise_InvalidCast');
  Self.Emit(OkL + ':');
  EmitStoreSlot('x0', AAsgn.Name + '_itab');
  { obj half with the usual ARC: retain new (borrowed source), release old }
  Self.Emit(#9'ldr x0, [sp]');      { peek the obj }
  Self.Emit(#9'bl _ClassAddRef');
  EmitLoadSlot('x0', AAsgn.Name);
  Self.Emit(#9'bl _ClassRelease');
  EmitPopTo('x0');
  EmitStoreSlot('x0', AAsgn.Name);
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
    if not ArcExprOwnsRef(AAsgn.Expr) then
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
     (AAsgn.ResolvedLhsType.Kind = tyInterface) then
  begin
    EmitInterfaceAssign(AAsgn);
    Exit;
  end;
  if (AAsgn.ResolvedLhsType <> nil) and
     (AAsgn.ResolvedLhsType.Kind = tyDynArray) then
  begin
    { data-pointer ARC, mirroring the string discipline }
    if AAsgn.IsWeakLhs or AAsgn.IsVarParam or
       (AAsgn.ImplicitSelfField <> nil) then
      NotYet('dyn-array assignment to this target', AAsgn);
    Self.EmitExprToX0(AAsgn.Expr);
    if not ArcExprOwnsRef(AAsgn.Expr) then
    begin
      EmitPushX0();
      Self.Emit(#9'bl _DynArrayAddRef');
      EmitPopTo('x0');
    end;
    EmitPushX0();
    EmitLoadSlot('x0', AAsgn.Name);
    Self.Emit(#9'bl _DynArrayRelease');
    EmitPopTo('x0');
    EmitStoreSlot('x0', AAsgn.Name);
    Exit;
  end;
  if (AAsgn.ResolvedLhsType <> nil) and
     (AAsgn.ResolvedLhsType.Kind = tyClass) then
  begin
    if AAsgn.ImplicitSelfField <> nil then
      NotYet('implicit-Self class-field assignment via TAssignment', AAsgn);
    if AAsgn.IsWeakLhs then
    begin
      { weak slot: registered in the weak table, no refcount held.  An
        owned +1 RHS would leak into a non-owning slot — keep it honest }
      if ArcExprOwnsRef(AAsgn.Expr) then
        NotYet('owned transient into a [Weak] variable', AAsgn);
      Self.EmitExprToX0(AAsgn.Expr);
      Self.Emit(#9'mov x1, x0');
      EmitSlotAddr('x0', AAsgn.Name);
      Self.Emit(#9'bl _WeakAssign');
      Exit;
    end;
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
      if not RecretManagedClean(TRecordTypeDesc(AAsgn.ResolvedLhsType)) then
      begin
        { managed LHS: the callee's fresh value lands in the __rret
          scratch first — the LHS may alias an argument, so its old field
          refs are released only AFTER the call — then moves in with the
          +1 field refs transferring (no retain). }
        if Shape = 0 then
          EmitCall(RD, TFuncCallExpr(AAsgn.Expr).Name,
            TFuncCallExpr(AAsgn.Expr).Args, '__rret')
        else
        begin
          EmitCall(RD, TFuncCallExpr(AAsgn.Expr).Name,
            TFuncCallExpr(AAsgn.Expr).Args);
          EmitSlotAddr('x9', '__rret');
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
        end;
        Self.Emit(#9'str x19, [sp, #-16]!');
        EmitSlotAddr('x19', AAsgn.Name);
        Self.EmitRecordFieldReleases(
          TRecordTypeDesc(AAsgn.ResolvedLhsType), 'x19');
        Self.Emit(#9'ldr x19, [sp], #16');
        EmitSlotAddr('x0', AAsgn.Name);
        EmitSlotAddr('x1', '__rret');
        EmitIntLiteral('x2', AAsgn.ResolvedLhsType.RawSize());
        Self.Emit(#9'bl memcpy');
        Exit;
      end;
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
     not (AAsgn.ResolvedLhsType.Kind in [tyBoolean, tyMetaClass,
                                         tyPointer, tyPChar, tySet]) then
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
  if SameText(ACall.Name, 'SetLength') and (ACall.Args.Count = 2) and
     (TASTExpr(ACall.Args.Items[0]).ResolvedType <> nil) and
     (TASTExpr(ACall.Args.Items[0]).ResolvedType.Kind = tyDynArray) then
  begin
    { arr := _DynArraySetLength(arr, n, elemsize) — plain ident lvalue }
    if not (TASTExpr(ACall.Args.Items[0]) is TIdentExpr) then
      NotYet('SetLength on this lvalue form', ACall);
    if TIdentExpr(TASTExpr(ACall.Args.Items[0])).ParamMode = pmVar then
      NotYet('SetLength on a var parameter', ACall);
    Self.EmitExprToX0(TASTExpr(ACall.Args.Items[1]));
    EmitPushX0();
    EmitLoadSlot('x0', TIdentExpr(TASTExpr(ACall.Args.Items[0])).Name);
    EmitPopTo('x1');
    EmitIntLiteral('x2', TDynArrayTypeDesc(
      TASTExpr(ACall.Args.Items[0]).ResolvedType).ElementType.RawSize());
    Self.Emit(#9'bl _DynArraySetLength');
    EmitStoreSlot('x0',
      TIdentExpr(TASTExpr(ACall.Args.Items[0])).Name);
    Exit;
  end;
  if (ACall.ResolvedDecl <> nil) and (ACall.ResolvedDecl is TMethodDecl) and
     (TMethodDecl(ACall.ResolvedDecl).OwnerTypeName = '') then
  begin
    EmitCall(TMethodDecl(ACall.ResolvedDecl), ACall.Name, ACall.Args);
    { a DISCARDED owned result must be disposed (user routine results are
      rc=1 — one release) }
    if TMethodDecl(ACall.ResolvedDecl).ResolvedReturnType <> nil then
    begin
      if TMethodDecl(ACall.ResolvedDecl).ResolvedReturnType.IsString() then
        Self.Emit(#9'bl _StringRelease')
      else if TMethodDecl(ACall.ResolvedDecl).ResolvedReturnType.Kind =
              tyClass then
        Self.Emit(#9'bl _ClassRelease')
      else if TMethodDecl(ACall.ResolvedDecl).ResolvedReturnType.Kind =
              tyDynArray then
        Self.Emit(#9'bl _DynArrayRelease');
    end;
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
      if (K = tyString) and ArcBuiltinStrArgOwnsRef(Arg) then
      begin
        { a transient is borrowed by _SysWriteStr — dispose it by shape
          after the write (rc=1 releases; rc=0 AddRef-then-Release) }
        EmitPushX0();
        Self.Emit(#9'mov x1, x0');
        Self.Emit(#9'movz w0, #1');
        Self.Emit(#9'bl _SysWriteStr');
        EmitPopTo('x0');
        EmitStrDisposeX0(Arg);
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

function TArm64Backend.NewExcFrameSlot: string;
begin
  { one static 512-byte, 16-aligned frame slot per emitted try — the body
    is buffered, so lazily growing the frame here is exact (BUG-045). }
  if (FFrameSize and 15) <> 0 then
    AddLocal('__excpad_' + IntToStr(FExcSlotN), 8);
  Result := '__excf_' + IntToStr(FExcSlotN);
  FExcSlotN := FExcSlotN + 1;
  if not FFrame.ContainsKey(Result) then
    AddLocal(Result, 512);
end;

procedure TArm64Backend.EmitExcPrologue(const AFrameSlot, AExcLbl,
  ATryLbl: string);
begin
  EmitSlotAddr('x0', AFrameSlot);
  Self.Emit(#9'bl _PushExcFrame');
  EmitSlotAddr('x0', AFrameSlot);
  Self.Emit(#9'bl _blaise_setjmp');
  Self.Emit(Format(#9'cbnz w0, %s', [AExcLbl]));
  Self.Emit(ATryLbl + ':');
end;

procedure TArm64Backend.EmitExcUnwindTo(ATargetDepth: Integer);
var
  I, J: Integer;
  FinBody: TCompoundStmt;
begin
  { non-local exit (Exit/Break/Continue) crossing try regions: pop each
    frame and run try/finally bodies inline on the way out }
  for I := FExcDepth downto ATargetDepth + 1 do
  begin
    Self.Emit(#9'bl _PopExcFrame');
    if I - 1 < FFinallyBodies.Count then
    begin
      FinBody := TCompoundStmt(FFinallyBodies.Items[I - 1]);
      if FinBody <> nil then
        for J := 0 to FinBody.Stmts.Count - 1 do
          EmitStmt(TASTStmt(FinBody.Stmts.Items[J]));
    end;
  end;
end;

procedure TArm64Backend.EmitTryFinally(AStmt: TTryFinallyStmt);
var
  I: Integer;
  FrameSlot, ExcL, TryL, EndL: string;
begin
  FrameSlot := NewExcFrameSlot();
  ExcL := NewLabel('finexc');
  TryL := NewLabel('trybody');
  EndL := NewLabel('finend');
  EmitExcPrologue(FrameSlot, ExcL, TryL);
  FExcDepth := FExcDepth + 1;
  FFinallyBodies.Add(AStmt.FinallyBody);
  for I := 0 to AStmt.TryBody.Stmts.Count - 1 do
    EmitStmt(TASTStmt(AStmt.TryBody.Stmts.Items[I]));
  Self.Emit(#9'bl _PopExcFrame');
  FExcDepth := FExcDepth - 1;
  FFinallyBodies.Delete(FFinallyBodies.Count - 1);
  for I := 0 to AStmt.FinallyBody.Stmts.Count - 1 do
    EmitStmt(TASTStmt(AStmt.FinallyBody.Stmts.Items[I]));
  Self.Emit(Format(#9'b %s', [EndL]));
  { exception path: capture, pop, run the finally, re-raise.  Codegen-time
    depth bookkeeping balances independently per path. }
  FExcDepth := FExcDepth + 1;
  FFinallyBodies.Add(AStmt.FinallyBody);
  Self.Emit(ExcL + ':');
  Self.Emit(#9'bl _CurrentException');
  Self.Emit(#9'str x0, [sp, #-16]!');
  Self.Emit(#9'bl _PopExcFrame');
  FExcDepth := FExcDepth - 1;
  FFinallyBodies.Delete(FFinallyBodies.Count - 1);
  for I := 0 to AStmt.FinallyBody.Stmts.Count - 1 do
    EmitStmt(TASTStmt(AStmt.FinallyBody.Stmts.Items[I]));
  Self.Emit(#9'ldr x0, [sp], #16');
  Self.Emit(#9'bl _Reraise');
  Self.Emit(EndL + ':');
end;

procedure TArm64Backend.EmitTryExcept(AStmt: TTryExceptStmt);
var
  I, J: Integer;
  H: TExceptHandlerClause;
  FrameSlot, ExcL, TryL, EndL, BodyL, NextL: string;
begin
  FrameSlot := NewExcFrameSlot();
  ExcL := NewLabel('exch');
  TryL := NewLabel('trybody');
  EndL := NewLabel('excend');
  EmitExcPrologue(FrameSlot, ExcL, TryL);
  FExcDepth := FExcDepth + 1;
  FFinallyBodies.Add(nil);
  for I := 0 to AStmt.TryBody.Stmts.Count - 1 do
    EmitStmt(TASTStmt(AStmt.TryBody.Stmts.Items[I]));
  Self.Emit(#9'bl _PopExcFrame');
  FExcDepth := FExcDepth - 1;
  FFinallyBodies.Delete(FFinallyBodies.Count - 1);
  Self.Emit(Format(#9'b %s', [EndL]));
  Self.Emit(ExcL + ':');
  if AStmt.Handlers.Count > 0 then
  begin
    { capture while our frame is still the top, then pop }
    Self.Emit(#9'bl _CurrentException');
    Self.Emit(#9'str x0, [sp, #-16]!');
    Self.Emit(#9'bl _PopExcFrame');
    for I := 0 to AStmt.Handlers.Count - 1 do
    begin
      H := TExceptHandlerClause(AStmt.Handlers.Items[I]);
      BodyL := NewLabel('hbody');
      NextL := NewLabel('hnext');
      Self.Emit(#9'ldr x0, [sp]');
      EmitTypeinfoAddr('x1', H.TypeName);
      Self.Emit(#9'bl _IsInstance');
      Self.Emit(Format(#9'cbz w0, %s', [NextL]));
      Self.Emit(BodyL + ':');
      if H.VarName <> '' then
      begin
        { bind: retain the exception (balances the scope-exit release of
          the handler var), release any prior binding, store }
        Self.Emit(#9'ldr x0, [sp]');
        Self.Emit(#9'bl _ClassAddRef');
        EmitLoadSlot('x0', H.VarName);
        Self.Emit(#9'bl _ClassRelease');
        Self.Emit(#9'ldr x0, [sp]');
        EmitStoreSlot('x0', H.VarName);
      end;
      for J := 0 to H.Body.Stmts.Count - 1 do
        EmitStmt(TASTStmt(H.Body.Stmts.Items[J]));
      Self.Emit(#9'add sp, sp, #16');
      Self.Emit(Format(#9'b %s', [EndL]));
      Self.Emit(NextL + ':');
    end;
    if AStmt.ElseBody <> nil then
    begin
      for J := 0 to AStmt.ElseBody.Stmts.Count - 1 do
        EmitStmt(TASTStmt(AStmt.ElseBody.Stmts.Items[J]));
      Self.Emit(#9'add sp, sp, #16');
      Self.Emit(Format(#9'b %s', [EndL]));
    end
    else
    begin
      Self.Emit(#9'ldr x0, [sp], #16');
      Self.Emit(#9'bl _Reraise');
    end;
  end
  else
  begin
    { bare except: catch-all body }
    Self.Emit(#9'bl _PopExcFrame');
    for I := 0 to AStmt.ExceptBody.Stmts.Count - 1 do
      EmitStmt(TASTStmt(AStmt.ExceptBody.Stmts.Items[I]));
  end;
  Self.Emit(EndL + ':');
end;

procedure TArm64Backend.EmitStaticElemAssign(AStmt: TStaticSubscriptAssign);
var
  Elem: TTypeDesc;
begin
  { Arr[I] := V for a plain local/global static array.  The element
    ADDRESS is computed first and parked on the stack so the value
    expression (and any ARC release call) cannot invalidate it. }
  if (AStmt.BaseExpr <> nil) or AStmt.IsVarParam or AStmt.IsImplicitSelf then
    NotYet('subscript write on this array form', AStmt);
  if (AStmt.ResolvedArrayType = nil) or
     not (AStmt.ResolvedArrayType.Kind in [tyStaticArray, tyDynArray]) then
    NotYet('subscript write on this base type', AStmt);
  if AStmt.ResolvedArrayType.Kind = tyDynArray then
    Elem := TDynArrayTypeDesc(AStmt.ResolvedArrayType).ElementType
  else
    Elem := TStaticArrayTypeDesc(AStmt.ResolvedArrayType).ElementType;
  Self.EmitExprToX0(AStmt.IndexExpr);
  EmitPushX0();
  if AStmt.ResolvedArrayType.Kind = tyDynArray then
    EmitLoadSlot('x0', AStmt.ArrayName)   { data pointer value }
  else
    EmitSlotAddr('x0', AStmt.ArrayName);
  EmitPopTo('x1');
  EmitIntLiteral('x2', Elem.RawSize());
  Self.Emit(#9'mul x1, x1, x2');
  Self.Emit(#9'add x0, x0, x1');
  EmitPushX0();                                { [elemaddr] }
  if Elem.IsString() or (Elem.Kind = tyClass) then
  begin
    Self.EmitExprToX0(AStmt.ValueExpr);
    if (Elem.IsString() and not ArcExprOwnsRef(AStmt.ValueExpr)) or
       ((Elem.Kind = tyClass) and not ArcExprOwnsRef(AStmt.ValueExpr)) then
    begin
      EmitPushX0();
      if Elem.IsString() then
        Self.Emit(#9'bl _StringAddRef')
      else
        Self.Emit(#9'bl _ClassAddRef');
      EmitPopTo('x0');
    end;
    EmitPushX0();                              { [addr][val] }
    Self.Emit(#9'ldr x9, [sp, #16]');
    Self.Emit(#9'ldr x0, [x9]');
    if Elem.IsString() then
      Self.Emit(#9'bl _StringRelease')
    else
      Self.Emit(#9'bl _ClassRelease');
    Self.Emit(#9'ldr x9, [sp, #16]');
    EmitPopTo('x0');
    Self.Emit(#9'str x0, [x9]');
    Self.Emit(#9'add sp, sp, #16');
    Exit;
  end;
  if Elem.Kind = tyDouble then
  begin
    Self.EmitExprToD0OrConvert(AStmt.ValueExpr);
    Self.Emit(#9'fmov x0, d0');
  end
  else if Elem.Kind = tySingle then
  begin
    Self.EmitExprToD0OrConvert(AStmt.ValueExpr);
    Self.Emit(#9'fcvt s0, d0');
    Self.Emit(#9'ldr x9, [sp], #16');
    Self.Emit(#9'str s0, [x9]');
    Exit;
  end
  else if IsIntFam(Elem) or (Elem.Kind = tyBoolean) then
    Self.EmitExprToX0(AStmt.ValueExpr)
  else
    NotYet('array element of this type', AStmt);
  Self.Emit(#9'ldr x9, [sp], #16');
  case Elem.RawSize() of
    1: Self.Emit(#9'strb w0, [x9]');
    4: Self.Emit(#9'str w0, [x9]');
    8: Self.Emit(#9'str x0, [x9]');
  else
    NotYet('array element of this width', AStmt);
  end;
end;

procedure TArm64Backend.EmitRaise(AStmt: TRaiseStmt);
begin
  if AStmt.Expr = nil then
  begin
    { bare re-raise: the in-flight exception }
    Self.Emit(#9'bl _CurrentException');
    Self.Emit(#9'bl _Reraise');
    Exit;
  end;
  Self.EmitExprToX0(AStmt.Expr);
  Self.Emit(#9'bl _Raise');
end;

procedure TArm64Backend.EmitRepeat(AStmt: TRepeatStmt);
var
  TopL, EndL: string;
begin
  { repeat..until: body always runs once; break/continue target the
    loop's exit / condition re-test }
  TopL := NewLabel('rep');
  EndL := NewLabel('rend');
  FBreakLbls.Add(EndL);
  FLoopExcDepth.Add(IntToStr(FExcDepth));
  FContLbls.Add(TopL);
  Self.Emit(TopL + ':');
  EmitStmtList(AStmt.Body.Stmts);
  Self.EmitExprToX0(AStmt.Condition);
  Self.Emit(Format(#9'cbz x0, %s', [TopL]));
  Self.Emit(EndL + ':');
  FBreakLbls.Delete(FBreakLbls.Count - 1);
  FLoopExcDepth.Delete(FLoopExcDepth.Count - 1);
  FContLbls.Delete(FContLbls.Count - 1);
end;

procedure TArm64Backend.EmitCase(AStmt: TCaseStmt);
var
  I, J: Integer;
  Br: TCaseBranch;
  EndL, NextL, BodyL: string;
begin
  { ordinal case: chained compares — selector evaluated ONCE and kept on
    the stack across the branch tests (a value expression can be a call).
    String cases need _StringEquals chains — NotYet. }
  if AStmt.IsStringCase then
    NotYet('string case statements', AStmt);
  EndL := NewLabel('cend');
  Self.EmitExprToX0(AStmt.Selector);
  EmitPushX0();
  for I := 0 to AStmt.Branches.Count - 1 do
  begin
    Br := TCaseBranch(AStmt.Branches.Items[I]);
    NextL := NewLabel('cnxt');
    BodyL := NewLabel('cbody');
    for J := 0 to Br.Values.Count - 1 do
    begin
      Self.Emit(#9'ldr x0, [sp]');
      Self.EmitExprToX0Aux(TASTExpr(Br.Values.Items[J]));
      Self.Emit(#9'cmp x0, x1');
      Self.Emit(Format(#9'b.eq %s', [BodyL]));
    end;
    Self.Emit(Format(#9'b %s', [NextL]));
    Self.Emit(BodyL + ':');
    EmitStmt(Br.Stmt);
    Self.Emit(Format(#9'b %s', [EndL]));
    Self.Emit(NextL + ':');
  end;
  if AStmt.ElseStmt <> nil then
    EmitStmt(AStmt.ElseStmt);
  Self.Emit(EndL + ':');
  Self.Emit(#9'add sp, sp, #16');   { drop the selector }
end;

procedure TArm64Backend.EmitExprToX0Aux(AExpr: TASTExpr);
begin
  { evaluate AExpr into x1 while [sp] holds a live value: literal/const
    values only (case branch values are literals by grammar) }
  if AExpr is TIntLiteral then
  begin
    EmitIntLiteral('x1', TIntLiteral(AExpr).Value);
    Exit;
  end;
  if (AExpr is TIdentExpr) and TIdentExpr(AExpr).IsConstant then
  begin
    EmitIntLiteral('x1', TIdentExpr(AExpr).ConstValue);
    Exit;
  end;
  NotYet('case value of this form', AExpr);
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
  FLoopExcDepth.Add(IntToStr(FExcDepth));
  FContLbls.Add(ContL);
  Self.EmitStmt(AStmt.Body);
  FContLbls.Delete(FContLbls.Count - 1);
  FBreakLbls.Delete(FBreakLbls.Count - 1);
  FLoopExcDepth.Delete(FLoopExcDepth.Count - 1);
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
  { leaving through try regions runs their finally bodies on the way out }
  EmitExcUnwindTo(0);
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
  { Integer, float and string literal initialisers become .data entries;
    aggregate and const-expression initialisers stay honest holes. }
  if AVD.InitConst.IsArrayConst or (AVD.InitConst.ConstParts <> nil) then
    NotYet('initialised global of this form', AVD);
  if AVD.InitConst.IsString then
  begin
    { the global points at an immortal blob emitted beside the .data
      entry; program-exit _StringRelease is a no-op on refcnt -1 }
    FGlobalStrInits.Add(ASym);
    FGlobalStrVals.Add(AVD.InitConst.StrVal);
    FGlobalInits.Add(ASym, Format(#9'.quad __gi_%s_d', [ASym]));
    Exit;
  end;
  if AVD.InitConst.IsFloat then
    FGlobalInits.Add(ASym, #9'.double ' + AVD.InitConst.StrVal)
  else
    FGlobalInits.Add(ASym, Format(#9'.quad %d', [AVD.InitConst.IntVal]));
end;

procedure TArm64Backend.EmitSmallSetLiteral(AExpr: TArrayLiteralExpr);
var
  Mask: Int64;
  I: Integer;
  Elem: TASTExpr;
  HasRuntime: Boolean;
begin
  { small set (<= 64 members): compile-time members fold into an
    immediate mask; runtime members OR their bit in afterwards }
  Mask := 0;
  HasRuntime := False;
  for I := 0 to AExpr.Elements.Count - 1 do
  begin
    Elem := TASTExpr(AExpr.Elements.Items[I]);
    if Elem is TIntLiteral then
      Mask := Mask or (Int64(1) shl TIntLiteral(Elem).Value)
    else if (Elem is TIdentExpr) and TIdentExpr(Elem).IsConstant then
      Mask := Mask or (Int64(1) shl TIdentExpr(Elem).ConstValue)
    else
      HasRuntime := True;
  end;
  EmitIntLiteral('x0', Mask);
  if not HasRuntime then Exit;
  for I := 0 to AExpr.Elements.Count - 1 do
  begin
    Elem := TASTExpr(AExpr.Elements.Items[I]);
    if (Elem is TIntLiteral) or
       ((Elem is TIdentExpr) and TIdentExpr(Elem).IsConstant) then
      Continue;
    EmitPushX0();
    Self.EmitExprToX0(Elem);
    Self.Emit(#9'mov x1, x0');
    EmitPopTo('x0');
    Self.Emit(#9'movz x2, #1');
    Self.Emit(#9'lsl x2, x2, x1');
    Self.Emit(#9'orr x0, x0, x2');
  end;
end;

procedure TArm64Backend.EmitStaticElemAddr(ASub: TStringSubscriptExpr);
var
  ESz: Integer;
begin
  { x0 := &base[index].  The base must be a plain local/global array
    identifier; chained/field bases stay NotYet. }
  if not (ASub.StrExpr is TIdentExpr) then
    NotYet('subscript on this array expression', ASub);
  if TIdentExpr(ASub.StrExpr).ParamMode = pmVar then
    NotYet('subscript on a var array parameter', ASub);
  ESz := TStaticArrayTypeDesc(
    ASub.StrExpr.ResolvedType).ElementType.RawSize();
  Self.EmitExprToX0(ASub.IndexExpr);
  EmitPushX0();
  EmitSlotAddr('x0', TIdentExpr(ASub.StrExpr).Name);
  EmitPopTo('x1');
  EmitIntLiteral('x2', ESz);
  Self.Emit(#9'mul x1, x1, x2');
  Self.Emit(#9'add x0, x0, x1');
end;

procedure TArm64Backend.EmitDynElemAddr(ASub: TStringSubscriptExpr);
var
  ESz: Integer;
begin
  { x0 := dataptr + index*elemsize — the base VALUE is the element-0
    pointer (dyn-array header sits below it) }
  if not (ASub.StrExpr is TIdentExpr) then
    NotYet('subscript on this dyn-array expression', ASub);
  if TIdentExpr(ASub.StrExpr).ParamMode = pmVar then
    NotYet('subscript on a var dyn-array parameter', ASub);
  ESz := TDynArrayTypeDesc(
    ASub.StrExpr.ResolvedType).ElementType.RawSize();
  Self.EmitExprToX0(ASub.IndexExpr);
  EmitPushX0();
  EmitLoadSlot('x0', TIdentExpr(ASub.StrExpr).Name);
  EmitPopTo('x1');
  EmitIntLiteral('x2', ESz);
  Self.Emit(#9'mul x1, x1, x2');
  Self.Emit(#9'add x0, x0, x1');
end;

procedure TArm64Backend.EmitElemLoad(AElem: TTypeDesc);
begin
  { load the element at [x0] into x0, width by element kind.  2-byte
    integers need ldrsh/ldrh (no assembler encodings yet) — NotYet. }
  if AElem = nil then NotYet('unresolved element type', nil);
  case AElem.RawSize() of
    1: Self.Emit(#9'ldrb w0, [x0]');
    4:
      if AElem.Kind = tyUInt32 then
        Self.Emit(#9'ldr w0, [x0]')
      else if AElem.Kind = tySingle then
        Self.Emit(#9'ldr w0, [x0]')
      else
        Self.Emit(#9'ldrsw x0, [x0]');
    8: Self.Emit(#9'ldr x0, [x0]');
  else
    NotYet('array element of this width', nil);
  end;
end;

function TArm64Backend.AggHasManaged(AType: TTypeDesc): Boolean;
begin
  { records: any managed field; static arrays: managed element kind }
  Result := False;
  if AType = nil then Exit;
  if AType.Kind = tyRecord then
    Result := not RecretManagedClean(TRecordTypeDesc(AType))
  else if AType.Kind = tyStaticArray then
  begin
    if TStaticArrayTypeDesc(AType).ElementType = nil then Exit;
    case TStaticArrayTypeDesc(AType).ElementType.Kind of
      tyString, tyClass, tyInterface, tyDynArray: Result := True;
      tyRecord: Result := not RecretManagedClean(
        TRecordTypeDesc(TStaticArrayTypeDesc(AType).ElementType));
      tyStaticArray: Result := AggHasManaged(
        TStaticArrayTypeDesc(AType).ElementType);
    end;
  end;
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
  begin
    RegisterForSlots(TWhileStmt(AStmt).Body);
    Exit;
  end;
  if AStmt is TRepeatStmt then
  begin
    for I := 0 to TRepeatStmt(AStmt).Body.Stmts.Count - 1 do
      RegisterForSlots(TASTStmt(TRepeatStmt(AStmt).Body.Stmts.Items[I]));
    Exit;
  end;
  if AStmt is TCaseStmt then
  begin
    for I := 0 to TCaseStmt(AStmt).Branches.Count - 1 do
      RegisterForSlots(TCaseBranch(TCaseStmt(AStmt).Branches.Items[I]).Stmt);
    RegisterForSlots(TCaseStmt(AStmt).ElseStmt);
  end;
end;

function TArm64Backend.MaxManagedRecRet(AStmt: TASTStmt): Integer;
var
  I, N: Integer;
begin
  { largest RawSize among managed-record-returning call assignments — the
    caller routes those through a __rret scratch so the LHS's old field
    refs can be released AFTER the callee produced the fresh value }
  Result := 0;
  if AStmt = nil then Exit;
  if AStmt is TAssignment then
  begin
    if (TAssignment(AStmt).ResolvedLhsType <> nil) and
       (TAssignment(AStmt).ResolvedLhsType.Kind = tyRecord) and
       (TAssignment(AStmt).Expr is TFuncCallExpr) and
       not RecretManagedClean(
         TRecordTypeDesc(TAssignment(AStmt).ResolvedLhsType)) then
      Result := TAssignment(AStmt).ResolvedLhsType.RawSize();
    Exit;
  end;
  if AStmt is TCompoundStmt then
  begin
    for I := 0 to TCompoundStmt(AStmt).Stmts.Count - 1 do
    begin
      N := MaxManagedRecRet(TASTStmt(TCompoundStmt(AStmt).Stmts.Items[I]));
      if N > Result then Result := N;
    end;
    Exit;
  end;
  if AStmt is TIfStmt then
  begin
    Result := MaxManagedRecRet(TIfStmt(AStmt).ThenStmt);
    N := MaxManagedRecRet(TIfStmt(AStmt).ElseStmt);
    if N > Result then Result := N;
    Exit;
  end;
  if AStmt is TWhileStmt then
    Result := MaxManagedRecRet(TWhileStmt(AStmt).Body)
  else if AStmt is TForStmt then
    Result := MaxManagedRecRet(TForStmt(AStmt).Body)
  else if AStmt is TRepeatStmt then
  begin
    for I := 0 to TRepeatStmt(AStmt).Body.Stmts.Count - 1 do
    begin
      N := MaxManagedRecRet(TASTStmt(TRepeatStmt(AStmt).Body.Stmts.Items[I]));
      if N > Result then Result := N;
    end;
  end
  else if AStmt is TCaseStmt then
  begin
    for I := 0 to TCaseStmt(AStmt).Branches.Count - 1 do
    begin
      N := MaxManagedRecRet(
        TCaseBranch(TCaseStmt(AStmt).Branches.Items[I]).Stmt);
      if N > Result then Result := N;
    end;
    N := MaxManagedRecRet(TCaseStmt(AStmt).ElseStmt);
    if N > Result then Result := N;
  end;
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
  FIntfLocals.Clear();
  FDynLocals.Clear();
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
      if (Par.ResolvedType <> nil) and
         (Par.ResolvedType.Kind = tyInterface) then
      begin
        { fat pointer: two int-class registers (obj, itab).  A BY-VALUE
          interface param is the callee's co-owning copy — retained in the
          prologue, obj half released at exit; const params borrow. }
        AddLocal(Par.ParamName, 8);
        AddLocal(Par.ParamName + '_itab', 8);
        if not Par.IsConstParam then
          FIntfLocals.Add(Par.ParamName);
        Continue;
      end;
      if (Par.ResolvedType <> nil) and (Par.ResolvedType.Kind = tyRecord) then
      begin
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
        { the field refs a record Result holds TRANSFER to the caller —
          Result deliberately stays out of the FRecLocals release walk }
        AddLocal('Result', ADecl.ResolvedReturnType.RawSize());
        if RecReturnShape(TRecordTypeDesc(ADecl.ResolvedReturnType)) = 0 then
          AddLocal('__sret', 8);   { the incoming x8 destination pointer }
      end
      else if ADecl.ResolvedReturnType.Kind = tyInterface then
      begin
        { fat-pointer result: written to the caller's 16-byte x8 buffer
          at return; the +1 on the obj half transfers to the caller }
        AddLocal('Result', 8);
        AddLocal('Result_itab', 8);
        AddLocal('__sret', 8);
      end
      else if not (IsIntFam(ADecl.ResolvedReturnType) or
                   (ADecl.ResolvedReturnType.Kind in [tyDouble, tySingle]) or
                   (ADecl.ResolvedReturnType.Kind in [tyString, tyClass])) then
        NotYet('function result of this type', ADecl)
      else
        { a string/class Result is a plain pointer slot.  It is deliberately
          NOT in FStrLocals/FObjLocals: the +1 it holds transfers to the
          caller at return (ArcExprOwnsRef treats call results as owned),
          so the scope-exit release must skip it. }
        AddLocal('Result', 8);
    end;
  end;
  for I := 0 to ABody.Decls.Count - 1 do
  begin
    VD := TVarDecl(ABody.Decls.Items[I]);
    if not (IsIntFam(VD.ResolvedType) or
            ((VD.ResolvedType <> nil) and
             (VD.ResolvedType.Kind in [tyDouble, tySingle, tyString,
                                       tyRecord, tyClass, tyInterface,
                                       tyMetaClass, tyStaticArray,
                                       tyDynArray, tySet]))) then
      NotYet('local variable of this type', VD);
    if (VD.ResolvedType.Kind = tySet) and
       TSetTypeDesc(VD.ResolvedType).IsJumbo() then
      NotYet('jumbo sets (more than 64 members)', VD);
    for J := 0 to VD.Names.Count - 1 do
    begin
      if VD.ResolvedType.Kind in [tyRecord, tyStaticArray] then
      begin
        { managed fields/elements are fine: zero-init nils them, the
          base-class ARC walks handle the scope-exit release }
        AddLocal(VD.Names.Strings[J], VD.ResolvedType.RawSize());
        FRecLocals.AddObject(VD.Names.Strings[J], VD.ResolvedType);
      end
      else
        AddLocal(VD.Names.Strings[J], 8);
      if VD.ResolvedType.Kind = tyString then
        FStrLocals.Add(VD.Names.Strings[J]);
      if (VD.ResolvedType.Kind = tyClass) and not VD.IsWeak then
        FObjLocals.Add(VD.Names.Strings[J]);
      if VD.ResolvedType.Kind = tyDynArray then
        FDynLocals.Add(VD.Names.Strings[J]);
      if VD.ResolvedType.Kind = tyInterface then
      begin
        { fat pointer: split obj/itab slots; the obj half co-owns the
          backing instance (weak slots hold no ref — not released) }
        AddLocal(VD.Names.Strings[J] + '_itab', 8);
        if not VD.IsWeak then
          FIntfLocals.Add(VD.Names.Strings[J]);
      end;
    end;
  end;
  { 16-byte scratch for interface-returning calls (sret target).  Always
    reserved — cheap, and avoids a body pre-scan. }
  AddLocal('__iret', 16);
  J := 0;
  for I := 0 to ABody.Stmts.Count - 1 do
    if MaxManagedRecRet(TASTStmt(ABody.Stmts.Items[I])) > J then
      J := MaxManagedRecRet(TASTStmt(ABody.Stmts.Items[I]));
  if J > 0 then
    AddLocal('__rret', J);
  for I := 0 to ABody.Stmts.Count - 1 do
    RegisterForSlots(TASTStmt(ABody.Stmts.Items[I]));
end;

procedure TArm64Backend.EmitFunctionDef(ADecl: TMethodDecl);
var
  I, J, K, FIdx: Integer;
  SPOff, SPSz: Integer;
  SavedAsm, BodyBuf: TStringBuilder;
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
  if FIsFunction and (ADecl.ResolvedReturnType.Kind = tyInterface) then
    RecShape := 0;   { interface results use the x8 sret path }
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
  { the rest is buffered so try statements can lazily grow the frame —
    the frame-reserve sub is written with the FINAL size (BUG-045 lesson:
    never pre-count exception frames from source) }
  SavedAsm := FAsm;
  BodyBuf := TStringBuilder.Create();
  FAsm := BodyBuf;
  FExcDepth := 0;
  FExcSlotN := 0;
  FFinallyBodies.Clear();
  FLoopExcDepth.Clear();
  { spill register args to their slots.  Integer and float parameters
    consume INDEPENDENT register sequences (x0.. / d0..) per AAPCS64;
    floats hop through x9 so the slot store machinery stays uniform. }
  J := 0;      { int register index }
  FIdx := 0;   { float register index }
  SPOff := 0;  { caller outgoing-area offset for stack params }
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
      if J >= 8 then
      begin
        SPOff := AlignTo(SPOff, 8);
        Self.Emit(Format(#9'ldr x9, [x29, #%d]', [16 + SPOff]));
        EmitStoreSlot('x9', Par.ParamName);
        SPOff := SPOff + 8;
      end
      else
      begin
        EmitStoreSlot('x' + IntToStr(J), Par.ParamName);
        J := J + 1;
      end;
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
            (Par.ResolvedType.Kind = tyInterface) then
    begin
      { fat pointer in two consecutive x registers }
      if J >= 7 then NotYet('interface parameters spilling to the stack', ADecl);
      EmitStoreSlot('x' + IntToStr(J), Par.ParamName);
      EmitStoreSlot('x' + IntToStr(J + 1), Par.ParamName + '_itab');
      J := J + 2;
    end
    else if (Par.ResolvedType <> nil) and
            (Par.ResolvedType.Kind = tyDouble) then
    begin
      if FIdx >= 8 then
      begin
        SPOff := AlignTo(SPOff, 8);
        Self.Emit(Format(#9'ldr x9, [x29, #%d]', [16 + SPOff]));
        EmitStoreSlot('x9', Par.ParamName);
        SPOff := SPOff + 8;
      end
      else
      begin
        Self.Emit(Format(#9'fmov x9, d%d', [FIdx]));
        EmitStoreSlot('x9', Par.ParamName);
        FIdx := FIdx + 1;
      end;
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
      if J >= 8 then
      begin
        SPSz := StackParamSize(Par);
        SPOff := AlignTo(SPOff, SPSz);
        if SPSz = 4 then
          Self.Emit(Format(#9'ldr w9, [x29, #%d]', [16 + SPOff]))
        else
          Self.Emit(Format(#9'ldr x9, [x29, #%d]', [16 + SPOff]));
        EmitStoreSlot('x9', Par.ParamName);
        SPOff := SPOff + SPSz;
      end
      else
      begin
        EmitStoreSlot('x' + IntToStr(J), Par.ParamName);
        J := J + 1;
      end;
    end;
  end;
  { sret: park the incoming x8 destination pointer in its hidden slot }
  if RecShape = 0 then
    EmitStoreSlot('x8', '__sret');
  { by-value record params with managed fields: the callee owns its copy,
    so retain every managed field (walk anchored on callee-saved x19). }
  for I := 0 to ADecl.Params.Count - 1 do
  begin
    Par := TMethodParam(ADecl.Params.Items[I]);
    if (Par.ResolvedType <> nil) and (Par.ResolvedType.Kind = tyRecord) and
       not Par.IsVarParam and
       not RecretManagedClean(TRecordTypeDesc(Par.ResolvedType)) then
    begin
      Self.Emit(#9'str x19, [sp, #-16]!');
      EmitSlotAddr('x19', Par.ParamName);
      Self.EmitRecordFieldRetains(TRecordTypeDesc(Par.ResolvedType), 'x19');
      Self.Emit(#9'ldr x19, [sp], #16');
    end;
  end;
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
    if (Par.ResolvedType <> nil) and
       (Par.ResolvedType.Kind = tyInterface) and not Par.IsConstParam then
    begin
      EmitLoadSlot('x0', Par.ParamName);
      Self.Emit(#9'bl _ClassAddRef');
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
  if FIsFunction and (ADecl.ResolvedReturnType.Kind = tyInterface) then
  begin
    EmitStoreSlot('xzr', 'Result');
    EmitStoreSlot('xzr', 'Result_itab');
  end
  else if FIsFunction and (RecShape >= 0) then
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
      if TVarDecl(ADecl.Body.Decls.Items[I]).ResolvedType.Kind in
         [tyRecord, tyStaticArray] then
      begin
        { aggregates zero-initialise their whole storage }
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
  { release the obj half of interface locals }
  for I := 0 to FIntfLocals.Count - 1 do
  begin
    EmitLoadSlot('x0', FIntfLocals.Strings[I]);
    Self.Emit(#9'bl _ClassRelease');
  end;
  for I := 0 to FDynLocals.Count - 1 do
  begin
    EmitLoadSlot('x0', FDynLocals.Strings[I]);
    Self.Emit(#9'bl _DynArrayRelease');
  end;
  { release the managed fields of record locals — the base-class walk needs
    a callee-saved base register across its release calls }
  for I := 0 to FRecLocals.Count - 1 do
    if AggHasManaged(TTypeDesc(FRecLocals.Objects[I])) then
    begin
      Self.Emit(#9'str x19, [sp, #-16]!');
      EmitSlotAddr('x19', FRecLocals.Strings[I]);
      Self.EmitManagedReleaseAt(TTypeDesc(FRecLocals.Objects[I]),
        'x19', False);
      Self.Emit(#9'ldr x19, [sp], #16');
    end;
  if FIsFunction and (RecShape >= 0) and
     (ADecl.ResolvedReturnType.Kind = tyRecord) then
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
  else if FIsFunction and
          (ADecl.ResolvedReturnType.Kind = tyInterface) then
  begin
    EmitLoadSlot('x9', '__sret');
    EmitLoadSlot('x0', 'Result');
    Self.Emit(#9'str x0, [x9]');
    EmitLoadSlot('x0', 'Result_itab');
    Self.Emit(#9'str x0, [x9, #8]');
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
  FAsm := SavedAsm;
  FrameAligned := (FFrameSize + 15) and (not 15);
  if FrameAligned > 0 then
    Self.Emit(Format(#9'sub sp, sp, #%d', [FrameAligned]));
  FAsm.Append(BodyBuf.ToString());
  BodyBuf.Free();
  FFrame.Clear();
  FFrameSize := 0;
end;

function TArm64Backend.StackArgSize(AArg: TASTExpr): Integer;
begin
  { Apple packs stack args to natural size, with the C default promotions
    for variadic args: sub-int widths promote to 4, floats to 8. }
  Result := 8;
  if (AArg.ResolvedType <> nil) and IsIntFam(AArg.ResolvedType) then
  begin
    Result := AArg.ResolvedType.RawSize();
    if Result < 4 then Result := 4;
    if Result > 8 then Result := 8;
  end;
end;

function TArm64Backend.StackParamSize(APar: TMethodParam): Integer;
begin
  { natural size for a FIXED param passed on the stack.  Floats stay 8
    (a deliberate simplification also applied on the callee side —
    a fixed Single stack param occupies 8 bytes here, matching both
    ends of every Blaise-internal call). }
  Result := 8;
  if APar.IsVarParam then Exit;
  if IsIntFam(APar.ResolvedType) then
  begin
    Result := APar.ResolvedType.RawSize();
    if Result < 4 then Result := 4;
    if Result > 8 then Result := 8;
  end;
end;

function TArm64Backend.AlignTo(AValue, AAlign: Integer): Integer;
begin
  Result := (AValue + AAlign - 1) and (not (AAlign - 1));
end;

function TArm64Backend.ComputeStackArgArea(ADecl: TMethodDecl;
  AArgs: TObjectList; ASelfPushed: Boolean): Integer;
var
  TB: Integer;
begin
  Result := ComputeStackArgAreaEx(ADecl, AArgs, ASelfPushed, TB);
end;

function TArm64Backend.ComputeStackArgAreaEx(ADecl: TMethodDecl;
  AArgs: TObjectList; ASelfPushed: Boolean; out ATransBase: Integer): Integer;
var
  I, NInt, NFloat, Off, Sz, Trans: Integer;
  Arg: TASTExpr;
begin
  { dry-run of the classification walk in EmitCall — must stay in
    lockstep with it }
  NInt := 0;
  NFloat := 0;
  Trans := 0;
  if ASelfPushed then NInt := 1;
  Off := 0;
  for I := 0 to AArgs.Count - 1 do
  begin
    Arg := TASTExpr(AArgs.Items[I]);
    { string transients get a release slot after the call when the CALLER
      must dispose them: rc=1 always (the callee pair nets to zero); rc=0
      only for const params (no callee pair — the caller pins).  A by-value
      rc=0 arg is freed by the callee's entry-retain/exit-release pair; a
      caller-side dispose would double-free. }
    if (Arg.ResolvedType <> nil) and (Arg.ResolvedType.Kind = tyString) then
    begin
      if ArcExprOwnsRef(Arg) then
        Inc(Trans)
      else if ArcExprIsUnownedStrTransient(Arg) and
              (I < ADecl.Params.Count) and
              TMethodParam(ADecl.Params.Items[I]).IsConstParam then
        Inc(Trans);
    end;
    if (I < ADecl.Params.Count) and
       TMethodParam(ADecl.Params.Items[I]).IsVarParam then
    begin
      Inc(NInt);
      Continue;
    end;
    if (Arg.ResolvedType <> nil) and (Arg.ResolvedType.Kind = tyRecord) then
    begin
      { record args never go to the stack in this subset (guarded in
        EmitCall); the register consumption mirrors its classification }
      case RecReturnShape(TRecordTypeDesc(Arg.ResolvedType)) of
        0, 1: Inc(NInt);
        2: NInt := NInt + 2;
      else
        NFloat := NFloat +
          (RecReturnShape(TRecordTypeDesc(Arg.ResolvedType)) - 100);
      end;
      Continue;
    end;
    if (Arg.ResolvedType <> nil) and
       (Arg.ResolvedType.Kind = tyInterface) then
    begin
      NInt := NInt + 2;
      Continue;
    end;
    if IsFloatExpr(Arg) then
    begin
      if (ADecl.IsVarArgs and (I >= ADecl.Params.Count)) or (NFloat >= 8) then
      begin
        Off := AlignTo(Off, 8) + 8;
      end
      else
        Inc(NFloat);
      Continue;
    end;
    { everything else travels int-class }
    if (ADecl.IsVarArgs and (I >= ADecl.Params.Count)) or (NInt >= 8) then
    begin
      if I < ADecl.Params.Count then
        Sz := StackParamSize(TMethodParam(ADecl.Params.Items[I]))
      else
        Sz := StackArgSize(Arg);
      Off := AlignTo(Off, Sz) + Sz;
    end
    else
      Inc(NInt);
  end;
  ATransBase := AlignTo(Off, 8);
  Result := AlignTo(ATransBase + Trans * 8, 16);
end;

procedure TArm64Backend.DecodeMemArg(const AEntry: string;
  out AOff, ASize: Integer);
var
  P: Integer;
begin
  { entry shape: m<offset>_<size> }
  P := Pos('_', AEntry);
  AOff := StrToInt(Copy(AEntry, 1, P - 1));
  ASize := StrToInt(Copy(AEntry, P + 1, Length(AEntry) - P - 1));
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
  StackOff, StackArea, ASz: Integer;
  TransBase, TransN: Integer;
  TransShapes: string;
  IsVariadicArg: Boolean;
begin
  NInt := 0;
  NFloat := 0;
  StackOff := 0;
  if ADecl = nil then
    NotYet('call to unresolved routine ''' + AName + '''', nil);
  { a method receiver was pushed by the caller BEFORE this call: it is the
    first int-class value, popped last into x0 }
  if ASelfPushed then
    NInt := 1;
  if ADecl.IsExternal and (ADecl.ExternalName = '') then
    NotYet('external routine without a link name', nil);
  { Outgoing stack-arg area: args past the register files, and ALL
    variadic anonymous args (Apple divergence — Linux AAPCS64 would
    continue the register sequence).  Apple packs stack args to natural
    size with the C default promotions; the area is allocated BEFORE the
    argument pushes so its offsets stay fixed during the pop walk. }
  StackArea := ComputeStackArgAreaEx(ADecl, AArgs, ASelfPushed, TransBase);
  TransN := 0;
  TransShapes := '';
  if StackArea > 0 then
    Self.Emit(Format(#9'sub sp, sp, #%d', [StackArea]));
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
              (Arg.ResolvedType.Kind = tyInterface) then
      begin
        { fat pointer: obj + itab in two consecutive int registers.
          The callee makes its own co-owning copy (by-value retains in
          the prologue), so the caller passes a borrow. }
        if not (Arg is TIdentExpr) then
          NotYet('interface argument from this expression', Arg);
        if TIdentExpr(Arg).ParamMode = pmVar then
          NotYet('var interface parameter', Arg);
        if NInt >= 7 then NotYet('interface arguments spilling to the stack', Arg);
        EmitLoadSlot('x0', TIdentExpr(Arg).Name);
        EmitPushX0();
        PopRegs.Add('x' + IntToStr(NInt));
        EmitLoadSlot('x0', TIdentExpr(Arg).Name + '_itab');
        EmitPushX0();
        PopRegs.Add('x' + IntToStr(NInt + 1));
        NInt := NInt + 2;
      end
      else if (Arg.ResolvedType <> nil) and
              (Arg.ResolvedType.Kind = tyString) then
      begin
        { the callee owns its copy (by-value params retain in the callee
          prologue; const params borrow), so the caller passes a BORROWED
          pointer.  Caller-side disposal by shape: rc=1 parks for ONE
          post-call release (also for const params); rc=0 parks only for
          const params (pin: AddRef+Release) — a by-value rc=0 arg is
          freed by the callee pair and must NOT be touched again. }
        Self.EmitExprToX0(Arg);
        EmitPushX0();
        if ArcExprOwnsRef(Arg) then
        begin
          Self.Emit(Format(#9'str x0, [sp, #%d]',
            [(PopRegs.Count + 1) * 16 + TransBase + TransN * 8]));
          TransShapes := TransShapes + '1';
          Inc(TransN);
        end
        else if ArcExprIsUnownedStrTransient(Arg) and
                (I < ADecl.Params.Count) and
                TMethodParam(ADecl.Params.Items[I]).IsConstParam then
        begin
          Self.Emit(Format(#9'str x0, [sp, #%d]',
            [(PopRegs.Count + 1) * 16 + TransBase + TransN * 8]));
          TransShapes := TransShapes + '0';
          Inc(TransN);
        end;
        if (ADecl.IsVarArgs and (I >= ADecl.Params.Count)) or (NInt >= 8) then
        begin
          StackOff := AlignTo(StackOff, 8);
          PopRegs.Add(Format('m%d_%d', [StackOff, 8]));
          StackOff := StackOff + 8;
        end
        else
        begin
          PopRegs.Add('x' + IntToStr(NInt));
          Inc(NInt);
        end;
      end
      else if IsFloatExpr(Arg) then
      begin
        IsVariadicArg := ADecl.IsVarArgs and (I >= ADecl.Params.Count);
        Self.EmitExprToD0(Arg);
        Self.Emit(#9'fmov x0, d0');
        EmitPushX0();
        if IsVariadicArg or (NFloat >= 8) then
        begin
          { variadic floats promote to double (8 bytes) }
          StackOff := AlignTo(StackOff, 8);
          PopRegs.Add(Format('m%d_%d', [StackOff, 8]));
          StackOff := StackOff + 8;
        end
        else if (Arg.ResolvedType <> nil) and
           (Arg.ResolvedType.Kind = tySingle) then
        begin
          PopRegs.Add('s' + IntToStr(NFloat));
          Inc(NFloat);
        end
        else
        begin
          PopRegs.Add('d' + IntToStr(NFloat));
          Inc(NFloat);
        end;
      end
      else if IsIntFam(Arg.ResolvedType) or (Arg is TIntLiteral) or
              ((Arg.ResolvedType <> nil) and
               (Arg.ResolvedType.Kind in [tyPChar, tyPointer])) then
      begin
        IsVariadicArg := ADecl.IsVarArgs and (I >= ADecl.Params.Count);
        Self.EmitExprToX0(Arg);
        EmitPushX0();
        if IsVariadicArg or (NInt >= 8) then
        begin
          if I < ADecl.Params.Count then
            ASz := StackParamSize(TMethodParam(ADecl.Params.Items[I]))
          else
            ASz := StackArgSize(Arg);
          StackOff := AlignTo(StackOff, ASz);
          PopRegs.Add(Format('m%d_%d', [StackOff, ASz]));
          StackOff := StackOff + ASz;
        end
        else
        begin
          PopRegs.Add('x' + IntToStr(NInt));
          Inc(NInt);
        end;
      end
      else
        NotYet('call argument of this type', Arg);
    end;
    { pop last-pushed-first into each value's pre-assigned register }
    for I := PopRegs.Count - 1 downto 0 do
    begin
      Reg := PopRegs.Strings[I];
      if Copy(Reg, 0, 1) = 'm' then
      begin
        { memory-class arg: the outgoing area sits ABOVE the still-pushed
          eval slots — I of them remain (16 bytes each) at pop time }
        EmitPopTo('x9');
        DecodeMemArg(Reg, StackOff, ASz);
        if ASz = 4 then
          Self.Emit(Format(#9'str w9, [sp, #%d]', [I * 16 + StackOff]))
        else
          Self.Emit(Format(#9'str x9, [sp, #%d]', [I * 16 + StackOff]));
      end
      else if Copy(Reg, 0, 1) = 'd' then
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
  if TransN > 0 then
  begin
    { the call result (x0/d0) must survive the releases }
    EmitPushX0();
    Self.Emit(#9'fmov x9, d0');
    Self.Emit(#9'str x9, [sp, #-16]!');
    for I := 0 to TransN - 1 do
    begin
      Self.Emit(Format(#9'ldr x0, [sp, #%d]', [32 + TransBase + I * 8]));
      if Copy(TransShapes, I, 1) = '0' then
      begin
        { rc=0 pin: 0 -> 1 -> 0 frees exactly once }
        EmitPushX0();
        Self.Emit(#9'bl _StringAddRef');
        EmitPopTo('x0');
      end;
      Self.Emit(#9'bl _StringRelease');
    end;
    Self.Emit(#9'ldr x9, [sp], #16');
    Self.Emit(#9'fmov d0, x9');
    EmitPopTo('x0');
  end;
  if StackArea > 0 then
    Self.Emit(Format(#9'add sp, sp, #%d', [StackArea]));
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
  if FGlobalStrInits.Count > 0 then
  begin
    { immortal blobs for string-initialised globals: refcnt -1, length,
      capacity, bytes, NUL — the __gi_<sym>_d label sits AT the data so
      the .data pointer needs no symbol arithmetic }
    Self.Emit('.section .rodata');
    for I := 0 to FGlobalStrInits.Count - 1 do
    begin
      Self.Emit('.balign 4');
      Self.Emit(Format('__gi_%s_h:', [FGlobalStrInits.Strings[I]]));
      Self.Emit(#9'.word -1');
      Self.Emit(Format(#9'.word %d', [Length(FGlobalStrVals.Strings[I])]));
      Self.Emit(Format(#9'.word %d', [Length(FGlobalStrVals.Strings[I])]));
      Self.Emit(Format('__gi_%s_d:', [FGlobalStrInits.Strings[I]]));
      if Length(FGlobalStrVals.Strings[I]) > 0 then
        Self.Emit(Format(#9'.ascii "%s"',
          [AsmEscape(FGlobalStrVals.Strings[I])]));
      Self.Emit(#9'.byte 0');
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

function TArm64Backend.PropAccessorSym(const AOwnerType,
  AMethod: string): string;
var
  D: TTypeDesc;
  Pfx: string;
begin
  { mirror of TCodeGenQBE.PropAccessorTarget's direct-call arm }
  Pfx := '';
  if FSymTable <> nil then
  begin
    D := FSymTable.FindType(AOwnerType);
    if D <> nil then
      Pfx := ClassPrefixOwner(D.OwningUnit);
  end;
  Result := Pfx + CodegenMangle(AOwnerType) + '_' + CodegenMangle(AMethod);
end;

procedure TArm64Backend.EmitTypeinfoAddr(const AReg, ATypeName: string);
var
  D: TTypeDesc;
  Pfx: string;
begin
  Pfx := '';
  if FSymTable <> nil then
  begin
    D := FSymTable.FindType(ATypeName);
    if D <> nil then
      Pfx := ClassPrefixOwner(D.OwningUnit);
  end;
  Self.Emit(Format(#9'adrp %s, typeinfo_%s@PAGE',
    [AReg, Pfx + CodegenMangle(ATypeName)]));
  Self.Emit(Format(#9'add %s, %s, typeinfo_%s@PAGEOFF',
    [AReg, AReg, Pfx + CodegenMangle(ATypeName)]));
end;

function TArm64Backend.IntfItabSym(const AClassName,
  AIntfName: string): string;
var
  D: TTypeDesc;
  Pfx: string;
begin
  Pfx := '';
  if FSymTable <> nil then
  begin
    D := FSymTable.FindType(AClassName);
    if D <> nil then
      Pfx := ClassPrefixOwner(D.OwningUnit);
  end;
  Result := 'itab_' + Pfx + CodegenMangle(AClassName) + '_' +
    CodegenMangle(AIntfName);
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
    if ClassImplementsAny(TD) then
      Self.Emit(Format(#9'.quad impllist_%s', [Sym]))
    else
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

procedure TArm64Backend.EmitIntfDispatch(const AVarName: string;
  AIdx: Integer; AArgs: TObjectList);
var
  I: Integer;
  Arg: TASTExpr;
begin
  { itab dispatch: obj in x0, args in x1.., fptr = itab[AIdx*8].  Only
    int-class scalar args in this slice — a dedicated emitter because the
    interface has no TMethodDecl to drive EmitCall's classification. }
  if AArgs.Count > 7 then
    NotYet('interface call with more than 7 arguments', nil);
  for I := 0 to AArgs.Count - 1 do
  begin
    Arg := TASTExpr(AArgs.Items[I]);
    if not (IsIntFam(Arg.ResolvedType) or (Arg is TIntLiteral) or
            ((Arg.ResolvedType <> nil) and
             (Arg.ResolvedType.Kind in [tyClass, tyPChar, tyPointer]))) then
      NotYet('interface-call argument of this type', Arg);
    Self.EmitExprToX0(Arg);
    EmitPushX0();
  end;
  for I := AArgs.Count - 1 downto 0 do
    EmitPopTo('x' + IntToStr(I + 1));
  EmitLoadSlot('x0', AVarName);
  EmitLoadSlot('x9', AVarName + '_itab');
  Self.Emit(Format(#9'ldr x9, [x9, #%d]', [AIdx * 8]));
  Self.Emit(#9'blr x9');
end;

procedure TArm64Backend.EmitIntfMetaSections;
var
  I, J, K: Integer;
  ITD, TD: TTypeDecl;
  CDef, Walk: TClassTypeDef;
  ID: TInterfaceTypeDesc;
  MD, Impl: TMethodDecl;
  Names: TStringList;
  Sym, ISym, WalkName: string;
begin
  if (FIntfDecls.Count = 0) and (FClassDecls.Count = 0) then Exit;
  Self.Emit('.section .data');
  { interface typeinfo: the address IS the identity token }
  for I := 0 to FIntfDecls.Count - 1 do
  begin
    ITD := TTypeDecl(FIntfDecls.Items[I]);
    Self.Emit('.balign 8');
    Self.Emit(Format('.globl typeinfo_%s', [CodegenMangle(ITD.Name)]));
    Self.Emit(Format('typeinfo_%s:', [CodegenMangle(ITD.Name)]));
    Self.Emit(#9'.quad 0');
  end;
  { itab + impllist per implementing class.  Interface names are collected
    across the class's ancestor chain — a descendant inherits its parent's
    interfaces and still needs its own itab (method lookup starts at the
    most-derived class). }
  for I := 0 to FClassDecls.Count - 1 do
  begin
    TD := TTypeDecl(FClassDecls.Items[I]);
    CDef := TClassTypeDef(TD.Def);
    Names := TStringList.Create();
    try
      Walk := CDef;
      WalkName := TD.Name;
      while Walk <> nil do
      begin
        for J := 0 to Walk.ImplementsNames.Count - 1 do
          if Names.IndexOf(Walk.ImplementsNames.Strings[J]) < 0 then
            Names.Add(Walk.ImplementsNames.Strings[J]);
        WalkName := Walk.ParentName;
        Walk := nil;
        for J := 0 to FClassDecls.Count - 1 do
          if SameText(TTypeDecl(FClassDecls.Items[J]).Name, WalkName) then
          begin
            Walk := TClassTypeDef(TTypeDecl(FClassDecls.Items[J]).Def);
            Break;
          end;
      end;
      if Names.Count = 0 then Continue;
      Sym := ClassSym(TD);
      for J := 0 to Names.Count - 1 do
      begin
        ID := TInterfaceTypeDesc(FSymTable.FindType(Names.Strings[J]));
        if (ID = nil) or not (ID is TInterfaceTypeDesc) then
          NotYet('unresolved interface ''' + Names.Strings[J] + '''', nil);
        ISym := IntfItabSym(TD.Name, Names.Strings[J]);
        Self.Emit('.balign 8');
        Self.Emit(Format('%s:', [ISym]));
        for K := 0 to ID.MethodCount() - 1 do
        begin
          Impl := FindClassMethodImpl(TD, ID.MethodName(K));
          if Impl = nil then
            NotYet('implementation of interface method ''' +
              ID.MethodName(K) + '''', nil);
          Self.Emit(Format(#9'.quad %s',
            [RoutineSym(Impl, ID.MethodName(K))]));
        end;
      end;
      Self.Emit('.balign 8');
      Self.Emit(Format('impllist_%s:', [Sym]));
      for J := 0 to Names.Count - 1 do
      begin
        Self.Emit(Format(#9'.quad typeinfo_%s',
          [CodegenMangle(Names.Strings[J])]));
        Self.Emit(Format(#9'.quad %s', [IntfItabSym(TD.Name,
          Names.Strings[J])]));
      end;
      Self.Emit(#9'.quad 0');
    finally
      Names.Free();
    end;
  end;
end;

function TArm64Backend.ClassImplementsAny(ATD: TTypeDecl): Boolean;
var
  J: Integer;
  Walk: TClassTypeDef;
  WalkName: string;
begin
  Result := False;
  Walk := TClassTypeDef(ATD.Def);
  WalkName := ATD.Name;
  while Walk <> nil do
  begin
    if Walk.ImplementsNames.Count > 0 then
    begin
      Result := True;
      Exit;
    end;
    WalkName := Walk.ParentName;
    Walk := nil;
    for J := 0 to FClassDecls.Count - 1 do
      if SameText(TTypeDecl(FClassDecls.Items[J]).Name, WalkName) then
      begin
        Walk := TClassTypeDef(TTypeDecl(FClassDecls.Items[J]).Def);
        Break;
      end;
  end;
end;

function TArm64Backend.FindClassMethodImpl(ATD: TTypeDecl;
  const AName: string): TMethodDecl;
var
  J, K: Integer;
  Walk: TClassTypeDef;
  WalkName: string;
  MD: TMethodDecl;
begin
  { walk the ancestor chain for the nearest implementation }
  Result := nil;
  Walk := TClassTypeDef(ATD.Def);
  WalkName := ATD.Name;
  while Walk <> nil do
  begin
    for K := 0 to Walk.Methods.Count - 1 do
    begin
      MD := TMethodDecl(Walk.Methods.Items[K]);
      if SameText(MD.Name, AName) and (MD.Body <> nil) then
      begin
        Result := MD;
        Exit;
      end;
    end;
    WalkName := Walk.ParentName;
    Walk := nil;
    for J := 0 to FClassDecls.Count - 1 do
      if SameText(TTypeDecl(FClassDecls.Items[J]).Name, WalkName) then
      begin
        Walk := TClassTypeDef(TTypeDecl(FClassDecls.Items[J]).Def);
        Break;
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

procedure TArm64Backend.EmitMethodCallOnExpr(AMethod: TMethodDecl;
  const AName: string; AArgs: TObjectList; AObjExpr: TASTExpr);
var
  Owned: Boolean;
begin
  { chained receiver: the object pointer is the value of AObjExpr.  An
    OWNED +1 receiver (Create()/call result) is kept in a stack slot
    across the call and released afterwards — the transient must outlive
    the method invocation. }
  Owned := ArcExprOwnsRef(AObjExpr);
  Self.EmitExprToX0(AObjExpr);
  if Owned then
    EmitPushX0();               { copy for the post-call release }
  EmitPushX0();                 { the receiver EmitCall pops into x0 }
  EmitCall(AMethod, AName, AArgs, '', True, AMethod.VTableSlot);
  if Owned then
  begin
    EmitPushX0();               { park the result }
    Self.Emit(#9'ldr x0, [sp, #16]');
    Self.Emit(#9'bl _ClassRelease');
    EmitPopTo('x0');
    Self.Emit(#9'add sp, sp, #16');   { drop the receiver copy }
  end;
end;

procedure TArm64Backend.EmitMethodCallStmt(AStmt: TMethodCallStmt);
var
  MD: TMethodDecl;
begin
  if AStmt.IsConstructorCall or AStmt.IsImplicitSelf or
     ((AStmt.ObjectName = '') and (AStmt.ObjExpr = nil)
      and not AStmt.IsStaticCall) then
    NotYet('this method-call form', AStmt);
  if (AStmt.ResolvedClassType <> nil) and
     (AStmt.ResolvedClassType.Kind = tyInterface) then
  begin
    { itab dispatch on an interface-typed receiver }
    if AStmt.IsVarParam or (AStmt.ObjExpr <> nil) then
      NotYet('interface dispatch on this receiver form', AStmt);
    if (AStmt.ResolvedReturnTypeDesc <> nil) and
       (AStmt.ResolvedReturnTypeDesc.Kind in [tyRecord, tyInterface]) then
      NotYet('discarded aggregate-returning interface call', AStmt);
    EmitIntfDispatch(AStmt.ObjectName,
      TInterfaceTypeDesc(AStmt.ResolvedClassType).MethodIndex(AStmt.Name),
      AStmt.Args);
    if (AStmt.ResolvedReturnTypeDesc <> nil) and
       (AStmt.ResolvedReturnTypeDesc.Kind = tyClass) then
      Self.Emit(#9'bl _ClassRelease');
    if (AStmt.ResolvedReturnTypeDesc <> nil) and
       (AStmt.ResolvedReturnTypeDesc.Kind = tyString) then
      Self.Emit(#9'bl _StringRelease');
    Exit;
  end;
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
  if AStmt.ObjExpr <> nil then
    EmitMethodCallOnExpr(MD, AStmt.Name, AStmt.Args, AStmt.ObjExpr)
  else
  begin
    EmitLoadSlot('x0', AStmt.ObjectName);
    if AStmt.IsVarParam then
      Self.Emit(#9'ldr x0, [x0]');
    EmitMethodCallCommon(MD, AStmt.Name, AStmt.Args);
  end;
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
      plain method on the new instance.  A metaclass receiver loads the
      typeinfo VALUE from its variable — _ClassCreate reads size/cleanup/
      vtable from it at runtime, and a virtual constructor dispatches
      through the NEW INSTANCE's vtable (EmitMethodCallCommon keys on the
      ctor's VTableSlot). }
    if AExpr.IsMetaclassDispatch then
    begin
      EmitLoadSlot('x0', AExpr.ObjectName);
      Self.Emit(#9'bl _ClassCreate');
      MD := TMethodDecl(AExpr.ResolvedMethod);
      if (MD <> nil) and (MD.Body <> nil) then
      begin
        EmitPushX0();
        EmitMethodCallCommon(MD, 'Create', AExpr.Args);
        EmitPopTo('x0');
      end
      else if AExpr.Args.Count > 0 then
        NotYet('constructor arguments without a declared constructor', AExpr);
      Exit;
    end;
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
  if AExpr.IsBuiltinInheritsFrom then
  begin
    { _InheritsFrom(child_ti, parent_ti): the receiver is a class
      instance (typeinfo from vtable[0]) or a metaclass variable }
    if (AExpr.ObjExpr <> nil) or AExpr.IsVarParam or
       (AExpr.ObjectName = '') then
      NotYet('InheritsFrom on this receiver form', AExpr);
    Self.EmitExprToX0(TASTExpr(AExpr.Args.Items[0]));
    EmitPushX0();
    EmitLoadSlot('x0', AExpr.ObjectName);
    if (AExpr.ResolvedClassType <> nil) and
       (AExpr.ResolvedClassType.Kind = tyClass) then
    begin
      Self.Emit(#9'ldr x0, [x0]');    { vtable }
      Self.Emit(#9'ldr x0, [x0]');    { slot 0 = typeinfo }
    end;
    EmitPopTo('x1');
    Self.Emit(#9'bl _InheritsFrom');
    Exit;
  end;
  if AExpr.IsMetaclassDispatch or AExpr.IsProcFieldCall or
     ((AExpr.ObjectName = '') and (AExpr.ObjExpr = nil)
      and not AExpr.IsStaticCall) then
    NotYet('this method-call form', AExpr);
  if (AExpr.ResolvedClassType <> nil) and
     (AExpr.ResolvedClassType.Kind = tyInterface) then
  begin
    if AExpr.IsVarParam or (AExpr.ObjExpr <> nil) then
      NotYet('interface dispatch on this receiver form', AExpr);
    if (AExpr.ResolvedType <> nil) and
       (AExpr.ResolvedType.Kind in [tyRecord, tyInterface]) then
      NotYet('aggregate-returning interface call', AExpr);
    EmitIntfDispatch(AExpr.ObjectName,
      TInterfaceTypeDesc(AExpr.ResolvedClassType).MethodIndex(AExpr.Name),
      AExpr.Args);
    Exit;
  end;
  MD := TMethodDecl(AExpr.ResolvedMethod);
  if MD = nil then
    NotYet('unresolved method ''' + AExpr.Name + '''', AExpr);
  if AExpr.IsStaticCall or MD.IsStatic then
  begin
    { static (class-level) call: no Self, plain call to the mangled name }
    EmitCall(MD, AExpr.Name, AExpr.Args);
    Exit;
  end;
  if AExpr.ObjExpr <> nil then
  begin
    EmitMethodCallOnExpr(MD, AExpr.Name, AExpr.Args, AExpr.ObjExpr);
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
  SavedAsm, BodyBuf: TStringBuilder;
begin
  FProgramName := AProg.Name;
  FCurrentUnitName := '';
  for I := 0 to AProg.Block.TypeDecls.Count - 1 do
  begin
    TDcl := TTypeDecl(AProg.Block.TypeDecls.Items[I]);
    if TDcl.Def is TClassTypeDef then
    begin
      CDef := TClassTypeDef(TDcl.Def);
      if CDef.Attributes.Count > 0 then
        NotYet('class attributes', nil);
      FClassDecls.Add(TDcl);
    end
    else if TDcl.Def is TInterfaceTypeDef then
      FIntfDecls.Add(TDcl)
    else if (TDcl.Def is TTypeAliasDef) or (TDcl.Def is TEnumTypeDef) or
            (TDcl.Def is TSetTypeDef) or (TDcl.Def is TProceduralTypeDef) then
      { declaration-only: aliases (incl. 'class of'), enums, sets and
        procedural types need no emission — unsupported USES still gate
        at their expression/variable sites }
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
                                       tyRecord, tyClass, tyInterface,
                                       tyMetaClass, tyStaticArray,
                                       tyDynArray, tySet]))) then
      NotYet('program variable of this type', VD);
    if (VD.ResolvedType.Kind = tySet) and
       TSetTypeDesc(VD.ResolvedType).IsJumbo() then
      NotYet('jumbo sets (more than 64 members)', VD);
    for J := 0 to VD.Names.Count - 1 do
    begin
      FGlobalNames.Add(VD.Names.Strings[J]);
      if VD.InitConst <> nil then
        RegisterGlobalInit(VD.Names.Strings[J], VD);
      if VD.ResolvedType.Kind = tyString then
        FStrGlobals.Add(VD.Names.Strings[J]);
      if (VD.ResolvedType.Kind = tyClass) and not VD.IsWeak then
        FObjGlobals.Add(VD.Names.Strings[J]);
      if VD.ResolvedType.Kind = tyDynArray then
        FDynGlobals.Add(VD.Names.Strings[J]);
      if VD.ResolvedType.Kind = tyInterface then
      begin
        FGlobalNames.Add(VD.Names.Strings[J] + '_itab');
        FGlobalSize.Add(VD.Names.Strings[J] + '_itab', 8);
        if not VD.IsWeak then
          FIntfGlobals.Add(VD.Names.Strings[J]);
      end;
      if VD.IsThreadVar then
      begin
        { threadvars get a Mach-O TLV descriptor; only unmanaged scalar
          kinds for now (per-thread ARC teardown is its own problem) }
        if not (IsIntFam(VD.ResolvedType) or
                (VD.ResolvedType.Kind = tyDouble)) then
          NotYet('threadvar of this type', VD);
        if VD.InitConst <> nil then
          NotYet('initialised threadvar', VD);
        FTlvGlobals.Add(VD.Names.Strings[J]);
        { not an ordinary global: no _g_ bss entry }
        FGlobalNames.Delete(FGlobalNames.Count - 1);
      end;
      if VD.ResolvedType.Kind in [tyRecord, tyStaticArray] then
      begin
        FRecGlobals.AddObject(VD.Names.Strings[J], VD.ResolvedType);
        FGlobalSize.Add(VD.Names.Strings[J], VD.ResolvedType.RawSize());
      end
      else
        FGlobalSize.Add(VD.Names.Strings[J], 8);
    end;
  end;

  { generic instantiations need monomorphised emission — honest hole }
  if (AProg.GenericInstances.Count > 0) or
     (AProg.GenericRecordInstances.Count > 0) or
     (AProg.GenericFuncInstances.Count > 0) or
     (AProg.GenericMethodInstances.Count > 0) then
    NotYet('generic instantiations', nil);

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
  AddLocal('__iret', 16);   { interface-returning call scratch }
  J := 0;
  for I := 0 to AProg.Block.Stmts.Count - 1 do
    if MaxManagedRecRet(TASTStmt(AProg.Block.Stmts.Items[I])) > J then
      J := MaxManagedRecRet(TASTStmt(AProg.Block.Stmts.Items[I]));
  if J > 0 then
    AddLocal('__rret', J);
  for I := 0 to AProg.Block.Stmts.Count - 1 do
    RegisterForSlots(TASTStmt(AProg.Block.Stmts.Items[I]));
  FForN := 0;
  FrameAligned := (FFrameSize + 15) and (not 15);

  Self.Emit('');
  Self.Emit('.globl _main');
  Self.Emit('_main:');
  { Prologue: fp/lr pair + frame chain — ALWAYS (Darwin unwind).  argc/argv
    arrive in x0/x1 and pass straight through to _SetArgs, which must run
    before _BlaiseInit (that clobbers the argument registers).  The body is
    buffered so try statements can lazily grow the frame (see
    EmitFunctionDef). }
  Self.Emit(#9'stp x29, x30, [sp, #-16]!');
  Self.Emit(#9'mov x29, sp');
  SavedAsm := FAsm;
  BodyBuf := TStringBuilder.Create();
  FAsm := BodyBuf;
  FExcDepth := 0;
  FExcSlotN := 0;
  FFinallyBodies.Clear();
  FLoopExcDepth.Clear();
  Self.Emit(#9'bl _SetArgs');
  Self.Emit(#9'bl _BlaiseInit');
  { unit initialization sections, in dependency (append) order }
  for I := 0 to FUnitInits.Count - 1 do
    Self.Emit(Format(#9'bl %s', [FUnitInits.Strings[I]]));

  EmitStmtList(AProg.Block.Stmts);

  Self.Emit(FExitLabel + ':');
  { unit finalization sections, REVERSE dependency order, before the
    global releases (finalizers may still touch their unit's globals) }
  for I := FUnitFinals.Count - 1 downto 0 do
    Self.Emit(Format(#9'bl %s', [FUnitFinals.Strings[I]]));
  { release string globals before returning (ARC parity with x86-64's
    program-exit global release) }
  for I := 0 to FStrGlobals.Count - 1 do
  begin
    EmitLoadSlot('x0', FStrGlobals.Strings[I]);
    Self.Emit(#9'bl _StringRelease');
  end;
  for I := 0 to FRecGlobals.Count - 1 do
    if AggHasManaged(TTypeDesc(FRecGlobals.Objects[I])) then
    begin
      Self.Emit(#9'str x19, [sp, #-16]!');
      EmitSlotAddr('x19', FRecGlobals.Strings[I]);
      Self.EmitManagedReleaseAt(TTypeDesc(FRecGlobals.Objects[I]),
        'x19', False);
      Self.Emit(#9'ldr x19, [sp], #16');
    end;
  for I := 0 to FObjGlobals.Count - 1 do
  begin
    EmitLoadSlot('x0', FObjGlobals.Strings[I]);
    Self.Emit(#9'bl _ClassRelease');
  end;
  for I := 0 to FIntfGlobals.Count - 1 do
  begin
    EmitLoadSlot('x0', FIntfGlobals.Strings[I]);
    Self.Emit(#9'bl _ClassRelease');
  end;
  for I := 0 to FDynGlobals.Count - 1 do
  begin
    EmitLoadSlot('x0', FDynGlobals.Strings[I]);
    Self.Emit(#9'bl _DynArrayRelease');
  end;
  Self.Emit(#9'movz w0, #0');
  Self.Emit(#9'mov sp, x29');
  Self.Emit(#9'ldp x29, x30, [sp], #16');
  Self.Emit(#9'ret');
  FAsm := SavedAsm;
  FrameAligned := (FFrameSize + 15) and (not 15);
  if FrameAligned > 0 then
    Self.Emit(Format(#9'sub sp, sp, #%d', [FrameAligned]));
  FAsm.Append(BodyBuf.ToString());
  BodyBuf.Free();

  EmitStrLitSection();
  EmitFloatLitSection();
  EmitGlobalsSection();
  if FClassDecls.Count > 0 then
    EmitClassMetaSections();
  EmitIntfMetaSections();
  EmitTlvSections();
end;

procedure TArm64Backend.EmitTlvSections;
var
  I: Integer;
begin
  if FTlvGlobals.Count = 0 then Exit;
  { per-thread storage: zerofill in __thread_bss }
  Self.Emit('.section __DATA,__thread_bss');
  for I := 0 to FTlvGlobals.Count - 1 do
  begin
    Self.Emit('.balign 8');
    Self.Emit(Format('_ts_%s:', [FTlvGlobals.Strings[I]]));
    Self.Emit(#9'.zero 8');
  end;
  { TLV descriptors: three quads — __tlv_bootstrap, 0, storage.  dyld
    rebinds the thunk slot at load; the access sequence calls through it }
  Self.Emit('.section __DATA,__thread_vars');
  for I := 0 to FTlvGlobals.Count - 1 do
  begin
    Self.Emit('.balign 8');
    Self.Emit(Format('_tv_%s:', [FTlvGlobals.Strings[I]]));
    Self.Emit(#9'.quad __tlv_bootstrap');
    Self.Emit(#9'.quad 0');
    Self.Emit(Format(#9'.quad _ts_%s', [FTlvGlobals.Strings[I]]));
  end;
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
    calls (in dependency order) right after _BlaiseInit.  Finalization
    becomes <unit>_final, called at program exit in REVERSE order —
    genuinely invoked, unlike the x86 emit-but-never-call shape. }
  if (AUnit.InitStmts <> nil) and (AUnit.InitStmts.Count > 0) then
    EmitUnitInit(AUnit);
  if (AUnit.FinalStmts <> nil) and (AUnit.FinalStmts.Count > 0) then
    EmitUnitSection(AUnit, AUnit.FinalStmts,
      CodegenMangle(AUnit.Name) + '_final', FUnitFinals);
  FCurrentUnitName := '';
end;

procedure TArm64Backend.EmitUnitInit(AUnit: TUnit);
begin
  EmitUnitSection(AUnit, AUnit.InitStmts,
    CodegenMangle(AUnit.Name) + '_init', FUnitInits);
end;

procedure TArm64Backend.EmitUnitSection(AUnit: TUnit; AStmts: TObjectList;
  const ASym: string; ARegistry: TStringList);
var
  I, J: Integer;
  FrameAligned: Integer;
  SavedAsm, BodyBuf: TStringBuilder;
begin
  ARegistry.Add(ASym);
  FIsFunction := False;
  FResultFloat := False;
  FResultSingle := False;
  FExitLabel := NewLabel('usectexit');
  FFrame.Clear();
  FFrameSize := 0;
  FStrLocals.Clear();
  FRecLocals.Clear();
  FObjLocals.Clear();
  FIntfLocals.Clear();
  FForN := 0;
  AddLocal('__iret', 16);
  J := 0;
  for I := 0 to AStmts.Count - 1 do
    if MaxManagedRecRet(TASTStmt(AStmts.Items[I])) > J then
      J := MaxManagedRecRet(TASTStmt(AStmts.Items[I]));
  if J > 0 then
    AddLocal('__rret', J);
  for I := 0 to AStmts.Count - 1 do
    RegisterForSlots(TASTStmt(AStmts.Items[I]));
  FForN := 0;
  FrameAligned := (FFrameSize + 15) and (not 15);
  Self.Emit('');
  Self.Emit(Format('.globl %s', [ASym]));
  Self.Emit(ASym + ':');
  Self.Emit(#9'stp x29, x30, [sp, #-16]!');
  Self.Emit(#9'mov x29, sp');
  SavedAsm := FAsm;
  BodyBuf := TStringBuilder.Create();
  FAsm := BodyBuf;
  FExcDepth := 0;
  FExcSlotN := 0;
  FFinallyBodies.Clear();
  FLoopExcDepth.Clear();
  EmitStmtList(AStmts);
  Self.Emit(FExitLabel + ':');
  Self.Emit(#9'mov sp, x29');
  Self.Emit(#9'ldp x29, x30, [sp], #16');
  Self.Emit(#9'ret');
  FAsm := SavedAsm;
  FrameAligned := (FFrameSize + 15) and (not 15);
  if FrameAligned > 0 then
    Self.Emit(Format(#9'sub sp, sp, #%d', [FrameAligned]));
  FAsm.Append(BodyBuf.ToString());
  BodyBuf.Free();
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

    for J := 0 to VD.Names.Count - 1 do
    begin
      FModuleVarNames.Add(VD.Names.Strings[J]);
      { register under the owning-unit-prefixed symbol so same-named vars
        in different units (or the program) cannot collide }
      N := GlobalSym(VD.Names.Strings[J]);
      FGlobalNames.Add(N);
      if VD.InitConst <> nil then
        RegisterGlobalInit(N, VD);
      if VD.IsThreadVar then
      begin
        if not (IsIntFam(VD.ResolvedType) or
                (VD.ResolvedType.Kind = tyDouble)) then
          NotYet('threadvar of this type', VD);
        if VD.InitConst <> nil then
          NotYet('initialised threadvar', VD);
        FTlvGlobals.Add(N);
        FGlobalNames.Delete(FGlobalNames.Count - 1);
        FGlobalSize.Remove(N);
      end;
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
