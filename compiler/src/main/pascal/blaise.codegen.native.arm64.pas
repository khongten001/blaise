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

    function  NewLabel(const APrefix: string): string;
    procedure NotYet(const AWhat: string; ANode: TASTNode);

    { ---- frame + operands ---- }
    procedure AddLocal(const AName: string; ASize: Integer);
    function  IsLocal(const AName: string): Boolean;
    { Load/store x-register <-> local slot / global (int-family only). }
    procedure EmitLoadSlot(const AReg, AName: string);
    procedure EmitStoreSlot(const AReg, AName: string);

    { ---- expression lowering (result in x0) ---- }
    procedure EmitExprToX0(AExpr: TASTExpr);
    procedure EmitPushX0;
    procedure EmitPopTo(const AReg: string);
    procedure EmitIntLiteral(const AReg: string; AValue: Int64);
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

    procedure EmitStrLitSection;
    procedure EmitGlobalsSection;
  protected
    procedure EmitProgram(AProg: TProgram); override;
    procedure EmitUnit(AUnit: TUnit); override;
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
  FFrameSize   := 0;
  FLabelN      := 0;
end;

destructor TArm64Backend.Destroy;
begin
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
  if FGlobalNames.IndexOf(AName) >= 0 then
  begin
    Self.Emit(Format(#9'adrp x9, _g_%s@PAGE', [AName]));
    Self.Emit(Format(#9'ldr %s, [x9, _g_%s@PAGEOFF]', [AReg, AName]));
    Exit;
  end;
  NotYet('load of variable ''' + AName + '''', nil);
end;

procedure TArm64Backend.EmitStoreSlot(const AReg, AName: string);
var
  Off: Integer;
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
  if FGlobalNames.IndexOf(AName) >= 0 then
  begin
    Self.Emit(Format(#9'adrp x9, _g_%s@PAGE', [AName]));
    Self.Emit(Format(#9'str %s, [x9, _g_%s@PAGEOFF]', [AReg, AName]));
    Exit;
  end;
  NotYet('store to variable ''' + AName + '''', nil);
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
  if AExpr is TIdentExpr then
  begin
    EmitLoadSlot('x0', TIdentExpr(AExpr).Name);
    Exit;
  end;
  if AExpr is TBinaryExpr then
  begin
    BE := TBinaryExpr(AExpr);
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
  NotYet('expression ' + AExpr.ClassName, AExpr);
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
  if AStmt is TProcCall then
  begin
    EmitProcCallStmt(TProcCall(AStmt));
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
  NotYet('statement ' + AStmt.ClassName, AStmt);
end;

procedure TArm64Backend.EmitAssignment(AAsgn: TAssignment);
begin
  if (AAsgn.ResolvedLhsType <> nil) and
     not IsIntFam(AAsgn.ResolvedLhsType) and
     not (AAsgn.ResolvedLhsType.Kind = tyBoolean) then
    NotYet('assignment to non-integer variable', AAsgn);
  Self.EmitExprToX0(AAsgn.Expr);
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
      Self.Emit(#9'mov x1, x0');
      Self.Emit(#9'movz w0, #1');           { fd = stdout }
      Self.Emit(#9'bl _SysWriteStr');
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

procedure TArm64Backend.EmitGlobalsSection;
var
  I: Integer;
begin
  if FGlobalNames.Count = 0 then Exit;
  Self.Emit('.section .bss');
  for I := 0 to FGlobalNames.Count - 1 do
  begin
    Self.Emit('.balign 8');
    Self.Emit(Format('_g_%s:', [FGlobalNames.Strings[I]]));
    Self.Emit(#9'.zero 8');
  end;
end;

{ ---- program / unit ------------------------------------------------------ }

procedure TArm64Backend.EmitProgram(AProg: TProgram);
var
  I, J: Integer;
  VD:   TVarDecl;
begin
  FProgramName := AProg.Name;
  if AProg.Block.ProcDecls.Count > 0 then
    NotYet('standalone procedures/functions', nil);
  if AProg.Block.TypeDecls.Count > 0 then
    NotYet('type declarations', nil);

  { Program-level variables become globals (int-family only for now). }
  for I := 0 to AProg.Block.Decls.Count - 1 do
  begin
    VD := TVarDecl(AProg.Block.Decls.Items[I]);
    if not IsIntFam(VD.ResolvedType) then
      NotYet('non-integer program variable', VD);
    for J := 0 to VD.Names.Count - 1 do
      FGlobalNames.Add(VD.Names.Strings[J]);
  end;

  Self.Emit('.text');
  Self.Emit('.globl _main');
  Self.Emit('_main:');
  { Prologue: fp/lr pair + frame chain — ALWAYS (Darwin unwind).  argc/argv
    arrive in x0/x1 and pass straight through to _SetArgs, which must run
    before _BlaiseInit (that clobbers the argument registers). }
  Self.Emit(#9'stp x29, x30, [sp, #-16]!');
  Self.Emit(#9'mov x29, sp');
  Self.Emit(#9'bl _SetArgs');
  Self.Emit(#9'bl _BlaiseInit');

  EmitStmtList(AProg.Block.Stmts);

  Self.Emit(#9'movz w0, #0');
  Self.Emit(#9'ldp x29, x30, [sp], #16');
  Self.Emit(#9'ret');

  EmitStrLitSection();
  EmitGlobalsSection();
end;

procedure TArm64Backend.EmitUnit(AUnit: TUnit);
begin
  NotYet('unit compilation (' + AUnit.Name + ')', nil);
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
