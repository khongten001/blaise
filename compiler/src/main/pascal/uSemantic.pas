unit uSemantic;

{$mode objfpc}{$H+}

// Semantic analysis pass — walks the AST produced by uParser and:
//   1. Resolves record type declarations and registers them in the symbol table.
//   2. Resolves every identifier to a TSymbol in the symbol table.
//   3. Infers and annotates every expression node with ResolvedType.
//   4. Type-checks assignments and field assignments.
//   5. Validates procedure/function calls.
//   6. Raises ESemanticError with source position on any violation.

interface

uses
  SysUtils, contnrs, uAST, uSymbolTable;

type
  ESemanticError = class(Exception);

  TSemanticAnalyser = class
  private
    FTable: TSymbolTable;

    procedure AnalyseBlock(ABlock: TBlock);
    procedure AnalyseTypeDecls(ABlock: TBlock);
    procedure AnalyseVarDecls(ABlock: TBlock);
    procedure AnalyseStmts(ABlock: TBlock);
    procedure AnalyseStmt(AStmt: TASTStmt);
    procedure AnalyseAssignment(AAssign: TAssignment);
    procedure AnalyseFieldAssignment(AAssign: TFieldAssignment);
    procedure AnalyseProcCall(ACall: TProcCall);
    function  AnalyseExpr(AExpr: TASTExpr): TTypeDesc;
    function  AnalyseBinaryExpr(ABin: TBinaryExpr): TTypeDesc;
    function  AnalyseFieldAccess(AAccess: TFieldAccessExpr): TTypeDesc;

    procedure SemanticError(const AMsg: string; ALine, ACol: Integer);
    procedure CheckTypesMatch(AExpected, AActual: TTypeDesc;
      const AContext: string; ALine, ACol: Integer);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Analyse(AProg: TProgram);
  end;

implementation

constructor TSemanticAnalyser.Create;
begin
  inherited Create;
  FTable := TSymbolTable.Create;
end;

destructor TSemanticAnalyser.Destroy;
begin
  FTable.Free;
  inherited Destroy;
end;

procedure TSemanticAnalyser.SemanticError(const AMsg: string; ALine, ACol: Integer);
begin
  raise ESemanticError.CreateFmt('%s at line %d col %d', [AMsg, ALine, ACol]);
end;

procedure TSemanticAnalyser.CheckTypesMatch(AExpected, AActual: TTypeDesc;
  const AContext: string; ALine, ACol: Integer);
begin
  if AExpected <> AActual then
    SemanticError(
      Format('Type mismatch in %s: expected ''%s'' but got ''%s''',
        [AContext, AExpected.Name, AActual.Name]),
      ALine, ACol);
end;

procedure TSemanticAnalyser.Analyse(AProg: TProgram);
begin
  AnalyseBlock(AProg.Block);
  { Transfer symbol table ownership to the program so that TTypeDesc
    objects (referenced by ResolvedType pointers on AST nodes) outlive
    this analyser. }
  AProg.SymbolTable := FTable;
  FTable := nil;
end;

procedure TSemanticAnalyser.AnalyseBlock(ABlock: TBlock);
begin
  { Type declarations are registered in the outer scope so they remain visible
    after the block scope is popped — needed for var declarations and the
    transferred symbol table used by codegen. }
  AnalyseTypeDecls(ABlock);
  FTable.PushScope;
  try
    AnalyseVarDecls(ABlock);
    AnalyseStmts(ABlock);
  finally
    FTable.PopScope;
  end;
end;

procedure TSemanticAnalyser.AnalyseTypeDecls(ABlock: TBlock);
var
  I, J, K:   Integer;
  TD:        TTypeDecl;
  FieldList: TObjectList;
  FDecl:     TFieldDecl;
  RT:        TRecordTypeDesc;
  FldType:   TTypeDesc;
  FldName:   string;
  Sym:       TSymbol;
begin
  for I := 0 to ABlock.TypeDecls.Count - 1 do
  begin
    TD := TTypeDecl(ABlock.TypeDecls[I]);

    if TD.Def is TRecordTypeDef then
    begin
      RT        := FTable.NewRecordType(TD.Name);
      FieldList := TRecordTypeDef(TD.Def).Fields;
    end
    else if TD.Def is TClassTypeDef then
    begin
      RT        := FTable.NewClassType(TD.Name);
      FieldList := TClassTypeDef(TD.Def).Fields;
    end
    else
    begin
      SemanticError('Only record and class type definitions are supported',
        TD.Line, TD.Col);
      Continue;
    end;

    { Resolve each field declaration }
    for J := 0 to FieldList.Count - 1 do
    begin
      FDecl   := TFieldDecl(FieldList[J]);
      FldType := FTable.FindType(FDecl.TypeName);
      if FldType = nil then
        SemanticError(
          Format('Unknown type ''%s'' for field', [FDecl.TypeName]),
          FDecl.Line, FDecl.Col);
      FDecl.ResolvedType := FldType;

      for K := 0 to FDecl.Names.Count - 1 do
      begin
        FldName := FDecl.Names[K];
        RT.AddField(FldName, FldType);
      end;
    end;

    { Register the type as a skType symbol }
    Sym := TSymbol.Create(TD.Name, skType, RT);
    if not FTable.Define(Sym) then
    begin
      Sym.Free;
      SemanticError(
        Format('Duplicate type name ''%s''', [TD.Name]),
        TD.Line, TD.Col);
    end;
  end;
end;

procedure TSemanticAnalyser.AnalyseVarDecls(ABlock: TBlock);
var
  I, J:    Integer;
  Decl:    TVarDecl;
  Typ:     TTypeDesc;
  VarName: string;
  Sym:     TSymbol;
begin
  for I := 0 to ABlock.Decls.Count - 1 do
  begin
    Decl := TVarDecl(ABlock.Decls[I]);

    Typ := FTable.FindType(Decl.TypeName);
    if Typ = nil then
      SemanticError(
        Format('Unknown type ''%s''', [Decl.TypeName]),
        Decl.Line, Decl.Col);

    Decl.ResolvedType := Typ;

    for J := 0 to Decl.Names.Count - 1 do
    begin
      VarName := Decl.Names[J];
      Sym := TSymbol.Create(VarName, skVariable, Typ);
      if not FTable.Define(Sym) then
      begin
        Sym.Free;
        SemanticError(
          Format('Duplicate identifier ''%s''', [VarName]),
          Decl.Line, Decl.Col);
      end;
    end;
  end;
end;

procedure TSemanticAnalyser.AnalyseStmts(ABlock: TBlock);
var
  I: Integer;
begin
  for I := 0 to ABlock.Stmts.Count - 1 do
    AnalyseStmt(TASTStmt(ABlock.Stmts[I]));
end;

procedure TSemanticAnalyser.AnalyseStmt(AStmt: TASTStmt);
begin
  if AStmt is TFieldAssignment then
    AnalyseFieldAssignment(TFieldAssignment(AStmt))
  else if AStmt is TAssignment then
    AnalyseAssignment(TAssignment(AStmt))
  else if AStmt is TProcCall then
    AnalyseProcCall(TProcCall(AStmt));
end;

procedure TSemanticAnalyser.AnalyseAssignment(AAssign: TAssignment);
var
  VarSym:   TSymbol;
  ExprType: TTypeDesc;
begin
  VarSym := FTable.Lookup(AAssign.Name);
  if VarSym = nil then
    SemanticError(
      Format('Undeclared variable ''%s''', [AAssign.Name]),
      AAssign.Line, AAssign.Col);
  if VarSym.Kind <> skVariable then
    SemanticError(
      Format('''%s'' is not a variable', [AAssign.Name]),
      AAssign.Line, AAssign.Col);

  ExprType := AnalyseExpr(AAssign.Expr);
  CheckTypesMatch(VarSym.TypeDesc, ExprType, 'assignment', AAssign.Line, AAssign.Col);
end;

procedure TSemanticAnalyser.AnalyseFieldAssignment(AAssign: TFieldAssignment);
var
  RecSym:   TSymbol;
  RT:       TRecordTypeDesc;
  FldInfo:  TFieldInfo;
  ExprType: TTypeDesc;
begin
  RecSym := FTable.Lookup(AAssign.RecordName);
  if RecSym = nil then
    SemanticError(
      Format('Undeclared variable ''%s''', [AAssign.RecordName]),
      AAssign.Line, AAssign.Col);
  if RecSym.Kind <> skVariable then
    SemanticError(
      Format('''%s'' is not a variable', [AAssign.RecordName]),
      AAssign.Line, AAssign.Col);
  if not (RecSym.TypeDesc.Kind in [tyRecord, tyClass]) then
    SemanticError(
      Format('''%s'' is not a record or class variable', [AAssign.RecordName]),
      AAssign.Line, AAssign.Col);

  AAssign.IsClassAccess := RecSym.TypeDesc.Kind = tyClass;

  RT      := TRecordTypeDesc(RecSym.TypeDesc);
  FldInfo := RT.FindField(AAssign.FieldName);
  if FldInfo = nil then
    SemanticError(
      Format('Type ''%s'' has no field ''%s''',
        [AAssign.RecordName, AAssign.FieldName]),
      AAssign.Line, AAssign.Col);

  AAssign.FieldInfo := FldInfo;
  ExprType := AnalyseExpr(AAssign.Expr);
  CheckTypesMatch(FldInfo.TypeDesc, ExprType, 'field assignment',
    AAssign.Line, AAssign.Col);
end;

procedure TSemanticAnalyser.AnalyseProcCall(ACall: TProcCall);
var
  Sym: TSymbol;
  I:   Integer;
begin
  Sym := FTable.Lookup(ACall.Name);
  if Sym = nil then
    SemanticError(
      Format('Undeclared procedure ''%s''', [ACall.Name]),
      ACall.Line, ACall.Col);
  if not (Sym.Kind in [skProcedure, skFunction]) then
    SemanticError(
      Format('''%s'' is not a procedure or function', [ACall.Name]),
      ACall.Line, ACall.Col);

  for I := 0 to ACall.Args.Count - 1 do
    AnalyseExpr(TASTExpr(ACall.Args[I]));
end;

function TSemanticAnalyser.AnalyseExpr(AExpr: TASTExpr): TTypeDesc;
var
  Sym: TSymbol;
begin
  if AExpr is TIntLiteral then
    Result := FTable.TypeInteger
  else if AExpr is TStringLiteral then
    Result := FTable.TypeString
  else if AExpr is TIdentExpr then
  begin
    Sym := FTable.Lookup(TIdentExpr(AExpr).Name);
    if Sym = nil then
      SemanticError(
        Format('Undeclared identifier ''%s''', [TIdentExpr(AExpr).Name]),
        AExpr.Line, AExpr.Col);
    Result := Sym.TypeDesc;
  end
  else if AExpr is TFieldAccessExpr then
    Result := AnalyseFieldAccess(TFieldAccessExpr(AExpr))
  else if AExpr is TBinaryExpr then
    Result := AnalyseBinaryExpr(TBinaryExpr(AExpr))
  else
    SemanticError('Unknown expression node', AExpr.Line, AExpr.Col);

  AExpr.ResolvedType := Result;
end;

function TSemanticAnalyser.AnalyseFieldAccess(AAccess: TFieldAccessExpr): TTypeDesc;
var
  RecSym:  TSymbol;
  RT:      TRecordTypeDesc;
  FldInfo: TFieldInfo;
begin
  RecSym := FTable.Lookup(AAccess.RecordName);
  if RecSym = nil then
    SemanticError(
      Format('Undeclared identifier ''%s''', [AAccess.RecordName]),
      AAccess.Line, AAccess.Col);

  { Constructor call: TypeName.Create }
  if RecSym.Kind = skType then
  begin
    if RecSym.TypeDesc.Kind <> tyClass then
      SemanticError(
        Format('Cannot call constructor on non-class type ''%s''',
          [AAccess.RecordName]),
        AAccess.Line, AAccess.Col);
    if not SameText(AAccess.FieldName, 'Create') then
      SemanticError(
        Format('Unknown class method ''%s'' on type ''%s''',
          [AAccess.FieldName, AAccess.RecordName]),
        AAccess.Line, AAccess.Col);
    AAccess.IsConstructorCall := True;
    Result := RecSym.TypeDesc;
    Exit;
  end;

  { Field access on variable }
  if RecSym.Kind <> skVariable then
    SemanticError(
      Format('''%s'' is not a variable or type', [AAccess.RecordName]),
      AAccess.Line, AAccess.Col);

  if not (RecSym.TypeDesc.Kind in [tyRecord, tyClass]) then
    SemanticError(
      Format('''%s'' is not a record or class', [AAccess.RecordName]),
      AAccess.Line, AAccess.Col);

  AAccess.IsClassAccess := RecSym.TypeDesc.Kind = tyClass;

  RT      := TRecordTypeDesc(RecSym.TypeDesc);
  FldInfo := RT.FindField(AAccess.FieldName);
  if FldInfo = nil then
    SemanticError(
      Format('Type ''%s'' has no field ''%s''',
        [AAccess.RecordName, AAccess.FieldName]),
      AAccess.Line, AAccess.Col);

  AAccess.FieldInfo := FldInfo;
  Result := FldInfo.TypeDesc;
end;

function TSemanticAnalyser.AnalyseBinaryExpr(ABin: TBinaryExpr): TTypeDesc;
var
  LType, RType: TTypeDesc;
begin
  LType := AnalyseExpr(ABin.Left);
  RType := AnalyseExpr(ABin.Right);

  if not LType.IsNumeric then
    SemanticError(
      Format('Left operand of ''%s'' must be numeric, got ''%s''',
        [BinaryOpName(ABin.Op), LType.Name]),
      ABin.Line, ABin.Col);
  if not RType.IsNumeric then
    SemanticError(
      Format('Right operand of ''%s'' must be numeric, got ''%s''',
        [BinaryOpName(ABin.Op), RType.Name]),
      ABin.Line, ABin.Col);

  CheckTypesMatch(LType, RType, 'binary expression', ABin.Line, ABin.Col);

  Result := LType;
end;

end.
