unit uCodeGenQBE;

{$mode objfpc}{$H+}

{ Phase 1 QBE IR emitter.
  String layout: Phase 1 uses raw NUL-terminated bytes (no ARC header).
  The full refcount+length+capacity header is introduced in Phase 2.
  WriteLn/Write are built-ins resolved directly to libc printf calls. }

interface

uses
  SysUtils, StrUtils, Classes, uAST;

type
  ECodeGenError = class(Exception);

  TCodeGenQBE = class
  private
    FOutput:    TStringList;
    FStrLits:   TStringList;  { index → raw value; label = $__s<index> }
    FTempCount: Integer;
    FVarTypes:  TStringList;  { name → type ('w'=integer, 'l'=string ptr) }

    function  AllocTemp: string;
    function  EmitStrLit(const AValue: string): string;
    procedure EmitLine(const ALine: string);
    procedure EmitDataSection;
    procedure EmitMainHeader;
    procedure EmitMainFooter;
    procedure EmitBlock(ABlock: TBlock);
    procedure EmitVarAllocs(ABlock: TBlock);
    procedure EmitStmt(AStmt: TASTStmt);
    procedure EmitAssignment(AAssign: TAssignment);
    procedure EmitProcCall(ACall: TProcCall);
    procedure EmitWriteLn(ACall: TProcCall);
    procedure EmitWrite(ACall: TProcCall; ANewline: Boolean);
    function  EmitExpr(AExpr: TASTExpr): string;
    function  QbeTypeForVar(const AName: string): string;
    function  QbeEscapeString(const AStr: string): string;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Generate(AProg: TProgram);
    function  GetOutput: string;
  end;

implementation

constructor TCodeGenQBE.Create;
begin
  inherited Create;
  FOutput    := TStringList.Create;
  FStrLits   := TStringList.Create;
  FVarTypes  := TStringList.Create;
  FTempCount := 0;
end;

destructor TCodeGenQBE.Destroy;
begin
  FOutput.Free;
  FStrLits.Free;
  FVarTypes.Free;
  inherited Destroy;
end;

function TCodeGenQBE.AllocTemp: string;
begin
  Result := Format('%%_t%d', [FTempCount]);
  Inc(FTempCount);
end;

function TCodeGenQBE.EmitStrLit(const AValue: string): string;
{ Returns the global label for this string literal, e.g. $__s0 }
var
  Idx: Integer;
begin
  Idx := FStrLits.IndexOf(AValue);
  if Idx < 0 then
    Idx := FStrLits.Add(AValue);
  Result := Format('$__s%d', [Idx]);
end;

procedure TCodeGenQBE.EmitLine(const ALine: string);
begin
  FOutput.Add(ALine);
end;

procedure TCodeGenQBE.EmitDataSection;
var
  I: Integer;
begin
  if FStrLits.Count = 0 then
    Exit;
  EmitLine('# String literals');
  for I := 0 to FStrLits.Count - 1 do
    EmitLine(Format('data $__s%d = { b "%s", b 0 }',
      [I, QbeEscapeString(FStrLits[I])]));
  EmitLine('data $__fmt_s_nl = { b "%s\n", b 0 }');
  EmitLine('data $__fmt_s    = { b "%s", b 0 }');
  EmitLine('data $__fmt_d_nl = { b "%d\n", b 0 }');
  EmitLine('data $__fmt_d    = { b "%d", b 0 }');
  EmitLine('data $__fmt_nl   = { b "\n", b 0 }');
  EmitLine('');
end;

procedure TCodeGenQBE.EmitMainHeader;
begin
  EmitLine('export function w $main() {');
  EmitLine('@start');
end;

procedure TCodeGenQBE.EmitMainFooter;
begin
  EmitLine('  ret 0');
  EmitLine('}');
end;

procedure TCodeGenQBE.EmitVarAllocs(ABlock: TBlock);
var
  I, J: Integer;
  Decl: TVarDecl;
  VarName, Alloc: string;
begin
  for I := 0 to ABlock.Decls.Count - 1 do
  begin
    Decl := TVarDecl(ABlock.Decls[I]);
    for J := 0 to Decl.Names.Count - 1 do
    begin
      VarName := Decl.Names[J];
      if SameText(Decl.TypeName, 'Integer') or
         SameText(Decl.TypeName, 'Boolean') then
      begin
        Alloc := Format('  %%_var_%s =l alloc4 1', [VarName]);
        FVarTypes.Values[VarName] := 'w';
      end
      else if SameText(Decl.TypeName, 'string') then
      begin
        Alloc := Format('  %%_var_%s =l alloc8 1', [VarName]);
        FVarTypes.Values[VarName] := 'l';
        { Initialise string pointer to nil (0) }
        EmitLine(Alloc);
        EmitLine(Format('  storel 0, %%_var_%s', [VarName]));
        Continue;
      end
      else
        raise ECodeGenError.CreateFmt(
          'Unknown type ''%s'' for variable ''%s''', [Decl.TypeName, VarName]);
      EmitLine(Alloc);
    end;
  end;
end;

procedure TCodeGenQBE.EmitBlock(ABlock: TBlock);
var
  I: Integer;
begin
  EmitVarAllocs(ABlock);
  for I := 0 to ABlock.Stmts.Count - 1 do
    EmitStmt(TASTStmt(ABlock.Stmts[I]));
end;

procedure TCodeGenQBE.EmitStmt(AStmt: TASTStmt);
begin
  if AStmt is TAssignment then
    EmitAssignment(TAssignment(AStmt))
  else if AStmt is TProcCall then
    EmitProcCall(TProcCall(AStmt))
  else
    raise ECodeGenError.Create('Unknown statement node type');
end;

procedure TCodeGenQBE.EmitAssignment(AAssign: TAssignment);
var
  ValTemp, QType, StoreInstr: string;
begin
  QType    := QbeTypeForVar(AAssign.Name);
  ValTemp  := EmitExpr(AAssign.Expr);
  if QType = 'w' then
    StoreInstr := 'storew'
  else
    StoreInstr := 'storel';
  EmitLine(Format('  %s %s, %%_var_%s', [StoreInstr, ValTemp, AAssign.Name]));
end;

procedure TCodeGenQBE.EmitProcCall(ACall: TProcCall);
var
  UCaseName: string;
begin
  UCaseName := UpperCase(ACall.Name);
  if (UCaseName = 'WRITELN') then
    EmitWriteLn(ACall)
  else if UCaseName = 'WRITE' then
    EmitWrite(ACall, False)
  else
    raise ECodeGenError.CreateFmt(
      'Unknown procedure ''%s'' at line %d', [ACall.Name, ACall.Line]);
end;

procedure TCodeGenQBE.EmitWriteLn(ACall: TProcCall);
begin
  EmitWrite(ACall, True);
end;

procedure TCodeGenQBE.EmitWrite(ACall: TProcCall; ANewline: Boolean);
var
  ArgExpr: TASTExpr;
  ArgTemp: string;
  FmtLabel: string;
  IsString: Boolean;
begin
  if ACall.Args.Count = 0 then
  begin
    if ANewline then
      EmitLine('  call $printf(l $__fmt_nl)');
    Exit;
  end;

  if ACall.Args.Count > 1 then
    raise ECodeGenError.CreateFmt(
      'Phase 1: Write/WriteLn takes at most 1 argument (line %d)', [ACall.Line]);

  ArgExpr  := TASTExpr(ACall.Args[0]);
  IsString := (ArgExpr is TStringLiteral) or
              ((ArgExpr is TIdentExpr) and
               (QbeTypeForVar(TIdentExpr(ArgExpr).Name) = 'l'));

  ArgTemp := EmitExpr(ArgExpr);

  if IsString then
    FmtLabel := IfThen(ANewline, '$__fmt_s_nl', '$__fmt_s')
  else
    FmtLabel := IfThen(ANewline, '$__fmt_d_nl', '$__fmt_d');

  if IsString then
    EmitLine(Format('  call $printf(l %s, ..., l %s)', [FmtLabel, ArgTemp]))
  else
    EmitLine(Format('  call $printf(l %s, ..., w %s)', [FmtLabel, ArgTemp]));
end;

function TCodeGenQBE.EmitExpr(AExpr: TASTExpr): string;
var
  T, L, R: string;
  Op:      string;
  BinExpr: TBinaryExpr;
  QType:   string;
begin
  if AExpr is TIntLiteral then
  begin
    T := AllocTemp;
    EmitLine(Format('  %s =w copy %d', [T, TIntLiteral(AExpr).Value]));
    Result := T;
  end
  else if AExpr is TStringLiteral then
  begin
    Result := EmitStrLit(TStringLiteral(AExpr).Value);
  end
  else if AExpr is TIdentExpr then
  begin
    T     := AllocTemp;
    QType := QbeTypeForVar(TIdentExpr(AExpr).Name);
    if QType = 'w' then
      EmitLine(Format('  %s =w loadw %%_var_%s', [T, TIdentExpr(AExpr).Name]))
    else
      EmitLine(Format('  %s =l loadl %%_var_%s', [T, TIdentExpr(AExpr).Name]));
    Result := T;
  end
  else if AExpr is TBinaryExpr then
  begin
    BinExpr := TBinaryExpr(AExpr);
    L := EmitExpr(BinExpr.Left);
    R := EmitExpr(BinExpr.Right);
    T := AllocTemp;
    case BinExpr.Op of
      boAdd: Op := 'add';
      boSub: Op := 'sub';
      boMul: Op := 'mul';
      boDiv: Op := 'div';
    end;
    EmitLine(Format('  %s =w %s %s, %s', [T, Op, L, R]));
    Result := T;
  end
  else
    raise ECodeGenError.Create('Unknown expression node type');
end;

function TCodeGenQBE.QbeTypeForVar(const AName: string): string;
begin
  Result := FVarTypes.Values[AName];
  if Result = '' then
    Result := 'w';  { default to integer if unknown (e.g. undeclared) }
end;

function TCodeGenQBE.QbeEscapeString(const AStr: string): string;
var
  I: Integer;
  C: Char;
begin
  Result := '';
  for I := 1 to Length(AStr) do
  begin
    C := AStr[I];
    case C of
      '"':  Result := Result + '\"';
      '\':  Result := Result + '\\';
      #10:  Result := Result + '\n';
      #13:  Result := Result + '\r';
      #9:   Result := Result + '\t';
      else if (Ord(C) < 32) or (Ord(C) > 126) then
        Result := Result + Format('\%02x', [Ord(C)])
      else
        Result := Result + C;
    end;
  end;
end;

procedure TCodeGenQBE.Generate(AProg: TProgram);
var
  Body:        TStringList;
  SavedOutput: TStringList;
begin
  FOutput.Clear;
  FStrLits.Clear;
  FVarTypes.Clear;
  FTempCount := 0;

  { Two-pass emit: collect string literals by emitting the body first,
    then prepend the data section. }
  Body := TStringList.Create;
  try
    SavedOutput := FOutput;
    FOutput := Body;
    try
      EmitMainHeader;
      EmitBlock(AProg.Block);
      EmitMainFooter;
    finally
      FOutput := SavedOutput;
    end;

    EmitLine('# Generated by Blaise Compiler (Phase 1)');
    EmitLine('# Source: ' + AProg.Name);
    EmitLine('');
    EmitDataSection;
    FOutput.AddStrings(Body);
  finally
    Body.Free;
  end;
end;

function TCodeGenQBE.GetOutput: string;
begin
  Result := FOutput.Text;
end;

end.
