#!/usr/bin/env python3
#
# Blaise — An Object Pascal Compiler
# Copyright (c) 2026 Graeme Geldenhuys
# SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
# Licensed under the Apache License v2.0 with Runtime Library Exception.
# See LICENSE file in the project root for full license terms.
#
"""
Full self-hosting migration script.

Processes all 8 compiler units into tests/blaise-compiler.pas — a single
self-contained Pascal source that the compiler can compile into a
second-stage compiler (blaise2b). Source layout on disk:

    compiler/src/main/pascal/  — compiler units (uLexer, uParser, ...)
    rtl/src/main/pascal/       — blaise RTL units compiled by this script
    tests/blaise-compiler.pas  — generated output

The script strips FPC-specific syntax, rewrites idioms blaise does not
yet understand, and postprocess() injects the vtable fixes required on
root classes after the TObject hierarchy is dropped.

Caveat: blaise's parser does not yet support nested procedures; the
generated file may need a minor hand edit (e.g. promoting a nested proc
to a class method) before it links as a second-stage compiler. Run the
script, compile tests/blaise-compiler.pas with blaise, and patch any
`undefined reference` linker errors in place.
"""
import re, subprocess, sys

SRC = '/data/devel/new-pascal-compiler/compiler/src/main/pascal'
RTL = '/data/devel/new-pascal-compiler/rtl/src/main/pascal'
OUT = '/data/devel/new-pascal-compiler/tests/blaise-compiler.pas'

def read(p):
    with open(p) as f: return f.read()

def write(p, text):
    with open(p, 'w') as f: f.write(text)

def strip_block_comments(text):
    """Remove { ... } block comments including FPC-style nested ones.
    FPC supports nested { } comments (comment depth > 1 gives a warning but compiles)."""
    out = []
    i = 0
    n = len(text)
    depth = 0   # nesting depth for { } comments
    in_string = False
    while i < n:
        ch = text[i]
        if in_string:
            out.append(ch)
            if ch == "'":
                if i + 1 < n and text[i + 1] == "'":
                    out.append(text[i + 1])
                    i += 2
                    continue
                in_string = False
        elif depth > 0:
            # Inside a { } comment
            if ch == '{':
                if i + 1 < n and text[i + 1] != '$':
                    depth += 1  # nested comment
                # else directive inside comment — ignore
            elif ch == '}':
                depth -= 1
            elif ch == '\n':
                out.append(ch)  # keep newlines for line numbering
        elif text[i:i+2] == '//':
            # Line comment — keep through end of line
            j = text.find('\n', i)
            if j < 0:
                break  # strip rest
            i = j  # keep the newline
            out.append(text[i])
        elif text[i:i+2] == '(*':
            # (* ... *) comment — remove
            j = text.find('*)', i + 2)
            if j < 0:
                break
            # preserve newlines inside
            for c in text[i:j + 2]:
                if c == '\n':
                    out.append(c)
            i = j + 2
            continue
        elif ch == '{':
            if i + 1 < n and text[i + 1] == '$':
                # Compiler directive — keep it
                j = text.find('}', i + 1)
                if j < 0:
                    out.append(text[i:])
                    break
                out.append(text[i:j + 1])
                i = j + 1
                continue
            depth = 1  # start of { } comment
        elif ch == "'":
            in_string = True
            out.append(ch)
        else:
            out.append(ch)
        i += 1
    return ''.join(out)


def strip_fpc(text):
    text = strip_block_comments(text)
    lines, out, skip = text.split('\n'), [], False
    for line in lines:
        s = line.strip()
        if re.match(r'\{\$[A-Za-z]', s): continue
        if re.match(r'^unit\s+\w', s, re.I): continue
        if re.match(r'^program\s+\w', s, re.I): continue
        if s.lower() in ('interface', 'implementation'): continue
        if s == 'end.': continue
        if re.match(r'^uses\b', s, re.I): skip = True; continue
        if skip:
            if ';' in line: skip = False
            continue
        out.append(line)
    return '\n'.join(out)

def basic(text):
    def replace_incdec(text, fn_name, op):
        # Scan for 'Inc('/'Dec(' and find its matching ')'.
        out = []
        i = 0
        pat = re.compile(rf'\b{fn_name}\(')
        while i < len(text):
            m = pat.search(text, i)
            if not m:
                out.append(text[i:])
                break
            start = m.start()
            out.append(text[i:start])
            depth = 1
            j = m.end()
            while j < len(text) and depth > 0:
                if text[j] == '(':
                    depth += 1
                elif text[j] == ')':
                    depth -= 1
                j += 1
            if depth != 0:
                out.append(text[start:])
                break
            args = text[m.end(): j - 1]
            # Split at the top-level comma only
            depth = 0
            comma = -1
            for k, ch in enumerate(args):
                if ch == '(':
                    depth += 1
                elif ch == ')':
                    depth -= 1
                elif ch == ',' and depth == 0:
                    comma = k
                    break
            if comma >= 0:
                lhs = args[:comma].strip()
                rhs = args[comma + 1:].strip()
                out.append(f"{lhs} := {lhs} {op} {rhs}")
            else:
                a = args.strip()
                out.append(f"{a} := {a} {op} 1")
            i = j
        return ''.join(out)
    text = replace_incdec(text, 'Inc', '+')
    text = replace_incdec(text, 'Dec', '-')
    # FreeAndNil(X) → X := nil  (ARC handles the release)
    text = re.sub(r"\bFreeAndNil\(([^)]+)\)",
                  lambda m: f"{m.group(1).strip()} := nil", text)
    # StrToInt64 → StrToInt (Blaise lacks Int64 parsing)
    text = text.replace("StrToInt64", "StrToInt")
    text = text.replace('UpCase(', 'UpperCase(')
    text = re.sub(r'\bconstructor\b', 'procedure', text)
    text = re.sub(r'\bdestructor\b', 'procedure', text)
    # Keep `override` — descendants of TASTNode/Exception need it for the
    # vtable to propagate. Root classes (no parent after migration) get
    # their `override` stripped or turned into `virtual` in postprocess.
    text = re.sub(r';\s*overload\b', '', text)
    text = re.sub(r';\s*inline\b', '', text)  # inline directive not supported
    # 'out' parameter modifier → 'var' (Blaise has var but not out)
    text = re.sub(r'\bout\s+(\w+\s*:)', r'var \1', text)
    # Empty if/else branches (comment-only in FPC become empty after stripping):
    # "then\n<blank lines>\nelse" → "then begin end\nelse"
    text = re.sub(r'\bthen\s*\n(\s*\n)+(\s*)(else\b)', r'then begin end\n\2\3', text)
    # "then\s*\n<blank lines>\nend" — trailing branch with no body
    text = re.sub(r'\bthen\s*\n(\s*\n)+(\s*)(end\b)', r'then begin end\n\2\3', text)
    # Exit(expr) -> { Result := expr; Exit } (Delphi-style exit with value)
    text = re.sub(r'\bExit\((False)\)',  'begin Result := False; Exit end', text)
    text = re.sub(r'\bExit\((True)\)',   'begin Result := True;  Exit end', text)
    text = re.sub(r'\bExit\((\w+)\)',    r'begin Result := \1; Exit end', text)
    text = re.sub(r'\bshr\s+(\d+)', lambda m: f'div {2**int(m.group(1))}', text)
    text = re.sub(r'\bshl\s+(\d+)', lambda m: f'* {2**int(m.group(1))}', text)
    # Strip access modifier lines in class bodies
    text = re.sub(r'^\s*(private|public|protected|published)\s*$', '', text, flags=re.MULTILINE)
    # repeat ... until <expr>; → while True do begin ... if <expr> then break end;
    # Match a repeat..until with a boolean expression in parens.
    def repeat_until_cond(m):
        body = m.group(1)
        cond = m.group(2).strip()
        return f"while True do\nbegin{body}  if {cond} then break;\nend;"
    # repeat\n<body>  until (...);
    text = re.sub(r"\brepeat\b(.*?)\buntil\s+(.+?);\s*\n",
                  repeat_until_cond, text, flags=re.DOTALL)
    # Format('fmt', [a, b, c]) → Format('fmt', a, b, c)
    # Also CreateFmt('fmt', [args]) → CreateFmt('fmt', args)
    # Walk text, find ", [" preceded by a balanced-paren call, rewrite.
    def strip_array_of_const(text):
        out = []
        i = 0
        while i < len(text):
            m = re.search(r',\s*\[', text[i:])
            if not m:
                out.append(text[i:])
                break
            j = i + m.start()
            # find the matching ']' that is followed by ')'
            k = i + m.end()
            depth = 0
            close = -1
            while k < len(text):
                ch = text[k]
                if ch == '[':
                    depth += 1
                elif ch == ']':
                    if depth == 0:
                        close = k
                        break
                    depth -= 1
                k += 1
            if close == -1 or close + 1 >= len(text) or text[close + 1] != ')':
                out.append(text[i:j+1])
                i = j + 1
                continue
            # Replace ', [content])' with ', content)'
            inner = text[i + m.end():close]
            out.append(text[i:j])
            out.append(', ')
            out.append(inner.strip())
            out.append(')')
            i = close + 2
        return ''.join(out)
    text = strip_array_of_const(text)
    # Exception.CreateFmt(fmt, args...) → Exception.Create(Format(fmt, args...))
    # Blaise's Exception only has Create(msg); use Format builtin to build msg.
    # Balanced-paren + string-literal-aware scan.
    def createfmt_to_create(text):
        out = []
        i = 0
        pat = re.compile(r"\b([A-Z]\w*)\.CreateFmt\s*\(")
        while i < len(text):
            m = pat.search(text, i)
            if not m:
                out.append(text[i:])
                break
            out.append(text[i:m.start()])
            class_name = m.group(1)
            j = m.end()
            depth = 1
            in_str = False
            while j < len(text) and depth > 0:
                ch = text[j]
                if in_str:
                    if ch == "'":
                        if j + 1 < len(text) and text[j + 1] == "'":
                            j += 2
                            continue
                        in_str = False
                elif ch == "'":
                    in_str = True
                elif ch == '(':
                    depth += 1
                elif ch == ')':
                    depth -= 1
                j += 1
            if depth != 0:
                out.append(text[m.start():])
                break
            args = text[m.end(): j - 1].strip()
            out.append(f"{class_name}.Create(Format({args}))")
            i = j
        return ''.join(out)
    text = createfmt_to_create(text)
    # Strip bare inherited calls (TObject in Blaise has no Create/Destroy)
    text = re.sub(r"^\s*inherited(\s+\w+)?\s*;\s*$", "", text, flags=re.MULTILINE)
    # Ord(enum_val) → enum_val (Blaise stores enums as integers)
    text = re.sub(r"\bOrd\(([^()]+(?:\([^()]*\)[^()]*)?)\)",
                  lambda m: m.group(1), text)
    # Strip forward class declarations: TFoo = class; (Blaise doesn't need them)
    text = re.sub(r"^\s*T\w+\s*=\s*class\s*;\s*(\{[^}]*\})?\s*$", "",
                  text, flags=re.MULTILINE)
    # Strip default parameter values in method signatures: param: Type = default
    # Match inside parens: "name: Type = default_expr" before ';' or ')'
    text = re.sub(r"(:\s*\w+)\s*=\s*[^,;)]+([,;)])", r"\1\2", text)
    # Generic `x in [a, b, c]` → (x = a) or (x = b) or (x = c). Elements are
    # treated as identifier-valued; char literals are handled by specialised
    # transforms earlier in the pipeline.
    def expand_in(m):
        var = m.group(1).strip()
        elems = [e.strip() for e in m.group(2).split(',')]
        # Skip if any element looks like a char literal or range
        for e in elems:
            if e.startswith("'") or '..' in e:
                return m.group(0)
        conditions = [f"({var} = {e})" for e in elems if e]
        return '(' + ' or '.join(conditions) + ')'

    def expand_typecast_in(m):
        # TypeCast(simple_arg).FieldChain in [...] — capture the full LHS
        full_expr = m.group(1) + m.group(2)
        elems = [e.strip() for e in m.group(3).split(',')]
        for e in elems:
            if e.startswith("'") or '..' in e:
                return m.group(0)
        conditions = [f"({full_expr} = {e})" for e in elems if e]
        return '(' + ' or '.join(conditions) + ')'

    # Handle TypeCast(simple_arg).FieldChain in [...] first (no nested parens in arg)
    text = re.sub(r'(T\w+\([^)]+\))((?:\.\w+)+)\s+in\s+\[([^\]]+)\]',
                  expand_typecast_in, text)
    text = re.sub(r'(\w+(?:\.\w+)*)\s+in\s+\[([^\]]+)\]', expand_in, text)
    return text

# ---- uPasTokeniser transforms ----

def char_literal_to_int(c):
    """Convert a Pascal char literal to its ASCII integer value."""
    c = c.strip()
    if c == "''''": return 39  # single quote
    if c.startswith("'") and c.endswith("'") and len(c) == 3:
        return ord(c[1])
    if c.startswith('#'):
        return int(c[1:])
    return None

def ordify_char_range(match_text):
    """Convert a 'in [...]' expression for chars/tokens to an integer comparison."""
    # match_text is the bracketed part like ['0'..'9', 'A'..'F']
    # Returns a Blaise expression
    # First, extract the variable being tested
    # This is called with the full 'x in [...]' string
    m = re.match(r'(.+?)\s+in\s+\[([^\]]+)\]', match_text.strip())
    if not m: return match_text
    
    var = m.group(1).strip()
    elems = m.group(2).strip()
    
    # Parse the elements: 'a'..'z', 'A'..'Z', '_', etc.
    conditions = []
    for elem in re.split(r',', elems):
        elem = elem.strip()
        # Range: 'a'..'z'
        rm = re.match(r"'(.)'\.\.'(.)'", elem)
        if rm:
            lo, hi = ord(rm.group(1)), ord(rm.group(2))
            conditions.append(f"(({var} >= {lo}) and ({var} <= {hi}))")
            continue
        # Single char: 'x' or #n
        nm = re.match(r"'(.)'", elem)
        if nm:
            conditions.append(f"({var} = {ord(nm.group(1))})")
            continue
        nm = re.match(r'#(\d+)', elem)
        if nm:
            conditions.append(f"({var} = {nm.group(1)})")
            continue
        # Unknown - leave as-is with a comment
        conditions.append(f"(False {'{'}TODO: {elem}{'}'})")
    
    return ' or '.join(conditions) if conditions else 'False'

def transform_tokeniser_in_exprs(text):
    """Replace 'x in [char ranges]' with integer comparison chains."""
    # Pattern: variable in [...]
    # We need to handle the common patterns in uPasTokeniser
    
    def replace_in(m):
        full = m.group(0)
        result = ordify_char_range(full)
        return result
    
    # Match: expr in ['..']
    text = re.sub(r'\w+\s+in\s+\[[^\]]+\]', replace_in, text)
    return text

def transform_string_indexing(text):
    """Replace FSource[FPos] with OrdAt(FSource, FPos)."""
    # Simple case: FSource[FPos]
    text = re.sub(r'\bFSource\[FPos\]', 'OrdAt(FSource, FPos)', text)
    # FSource[FPos] might be compared with char literals - need to convert
    # e.g., FSource[FPos] = '#' -> OrdAt(FSource, FPos) = 35
    def conv_char(m):
        char = m.group(1)
        if len(char) == 1:
            return str(ord(char))
        return m.group(0)
    text = re.sub(r"OrdAt\(FSource, FPos\) ([<>=!]+) '(.)'",
                  lambda m: f"OrdAt(FSource, FPos) {m.group(1)} {ord(m.group(2))}",
                  text)
    # Handle #nn char literals too
    text = re.sub(r"OrdAt\(FSource, FPos\) ([<>=!]+) #(\d+)",
                  lambda m: f"OrdAt(FSource, FPos) {m.group(1)} {m.group(2)}",
                  text)
    return text

def transform_char_vars(text):
    """Convert Char variable declarations and usage to Integer."""
    # var c: Char -> var c: Integer
    text = re.sub(r'\bChar\b', 'Integer', text)
    # c := 'X' -> c := ORD_X (need char literal → integer conversion)
    def conv_assign(m):
        char = m.group(2)
        if len(char) == 1:
            return f"{m.group(1)} := {ord(char)}"
        return m.group(0)
    text = re.sub(r'(\w+)\s*:=\s*\'(.)\'', conv_assign, text)
    # = '#nn' -> = nn
    text = re.sub(r'= #(\d+)', r'= \1', text)
    return text

def transform_repeat_until(text):
    """Convert repeat...until False to while True do begin...end."""
    # Handle 'repeat...until False' (loops with break)
    # Simple pattern: replace 'repeat' with 'while True do begin'
    # and 'until False;' with 'end;'
    text = re.sub(r'\brepeat\b', 'while True do\nbegin', text)
    text = re.sub(r'\buntil False;', 'end;', text)
    # Handle 'until not (condition)' - convert to while loop
    def until_to_while(m):
        cond = m.group(1).strip()
        return f"end;  {{ was: until not {cond} }}\n{{ TODO: check loop semantics }}''"
    text = re.sub(r'\buntil not \(([^)]+)\);', until_to_while, text)
    return text

# ---- uSymbolTable transforms ----
def transform_symtable_indexed(text):
    """Convert direct indexed access on owned list fields to .Get(I) calls."""
    # FFields[I] -> FFields.Get(I)
    for field in ['FFields', 'FVTable', 'FProperties', 'FImplements', 'FScopeStack',
                  'FAllTypes', 'FSymbols', 'FMethods', 'FReturnTypes',
                  'Members', 'FMembers']:
        # field[expr] -> field.Get(expr)  (but NOT field[I] where this is already a TObjectList call)
        text = re.sub(rf'\b{field}\[([^\]]+)\]', rf'{field}.Get(\1)', text)
    # .Objects[I] -> .GetObject(I)
    text = re.sub(r'\.Objects\[([^\]]+)\]', r'.GetObject(\1)', text)
    # FKeys.Duplicates := dupIgnore -> FKeys.Duplicates := 1
    text = text.replace('FKeys.Duplicates    := dupIgnore', 'FKeys.Duplicates    := 1')
    text = text.replace('FKeys.Duplicates := dupIgnore', 'FKeys.Duplicates := 1')
    # Assignment to field via typecast: TCast(expr).Field := value
    # Not supported by Blaise's statement parser — rewrite using a temp via Self helper.
    # OverrideVTableSlot: store through an intermediate variable.
    text = text.replace(
        '''procedure TRecordTypeDesc.OverrideVTableSlot(ASlot: Integer; const AImplName: string);
begin
  if (FVTable <> nil) and (ASlot >= 0) and (ASlot < FVTable.Count) then
    TVTableEntry(FVTable.Get(ASlot)).ImplName := AImplName;
end;''',
        '''procedure TRecordTypeDesc.OverrideVTableSlot(ASlot: Integer; const AImplName: string);
var
  E: TVTableEntry;
begin
  if (FVTable <> nil) and (ASlot >= 0) and (ASlot < FVTable.Count) then
  begin
    E := TVTableEntry(FVTable.Get(ASlot));
    E.ImplName := AImplName;
  end;
end;''')
    return text

# ---- uSemantic transforms ----
def transform_semantic_assignments(text):
    """Rewrite FProcIndex.Objects[I] := X as a method call."""
    # After transform_semantic_in, .Objects[I] has been rewritten to .GetObject(I).
    # Convert 'X.GetObject(I) := Expr' to 'X.SetObject(I, Expr)'.
    def setobj(m):
        prefix = m.group(1)
        idx = m.group(2)
        expr = m.group(3).rstrip(';').rstrip()
        return f"{prefix}.SetObject({idx}, {expr});"
    text = re.sub(
        r"(\w+(?:\.\w+)*)\.GetObject\(([^()]+)\)\s*:=\s*([^;]+);",
        setobj, text)
    # X.Get(I) := Expr → X.Put(I, Expr)
    def setget(m):
        prefix = m.group(1)
        idx = m.group(2)
        expr = m.group(3).rstrip(';').rstrip()
        return f"{prefix}.Put({idx}, {expr});"
    text = re.sub(
        r"(\w+(?:\.\w+)*)\.Get\(([^()]+)\)\s*:=\s*([^;]+);",
        setget, text)
    # Replace TStringList.DelimitedText pattern with manual split
    text = text.replace(
        '''    Args.StrictDelimiter := True;
    Args.Delimiter       := ',';
    Args.DelimitedText   := ArgsStr;''',
        '''    SplitIntoList(ArgsStr, 44, Args);''')
    # Remove the now-redundant Args[I] := Trim(Args[I]) loop (already trimmed)
    text = text.replace(
        '''    for I := 0 to Args.Count - 1 do
      Args.Put(I, Trim(Args.Get(I)));''', '')
    text = text.replace(
        '''    for I := 0 to Args.Count - 1 do
      Args[I] := Trim(Args[I]);''', '')
    return text

def expand_with_stmts(text):
    """Expand 'with TypeCast(Var) do begin...end' to direct field access.
    Only replaces field names within the with-block body, not globally."""
    type_fields = {
        'TWhileStmt':      ['Condition', 'Body'],
        'TTryFinallyStmt': ['TryBody', 'FinallyBody'],
        'TTryExceptStmt':  ['TryBody', 'ExceptBody'],
        'TRaiseStmt':      ['Expr'],
        'TFuncCallExpr':   ['Name', 'Args', 'ResolvedDecl', 'ResolvedType',
                            'IsImplicitSelfMethod'],
    }
    lines = text.split('\n')
    result = []
    i = 0
    while i < len(lines):
        line = lines[i]
        m = re.match(r'^(\s*)with\s+(T\w+)\((\w+)\)\s+do\s*$', line)
        if m and m.group(2) in type_fields:
            type_name = m.group(2)
            var_name  = m.group(3)
            cast_expr = f'{type_name}({var_name})'
            fields    = type_fields[type_name]
            i += 1  # skip 'with ... do' line
            # Collect body lines for the begin...end block
            block_lines = []
            while i < len(lines):
                l = lines[i]
                if re.match(r'^\s*begin\s*$', l):
                    block_lines.append(l)
                    i += 1
                    depth = 1
                    while i < len(lines) and depth > 0:
                        l = lines[i]
                        # Count begin/try/case as openers; end as closer
                        opens  = len(re.findall(r'\b(?:begin|try|case)\b', l))
                        closes = len(re.findall(r'\bend\b', l))
                        depth += opens - closes
                        block_lines.append(l)
                        i += 1
                    break
                else:
                    block_lines.append(l)
                    i += 1
            # Replace bare field names ONLY within these block lines.
            # Use negative lookbehind for '.' so that already-qualified
            # access patterns like OtherObj.Field are not touched.
            body = '\n'.join(block_lines)
            for field in fields:
                body = re.sub(rf'(?<!\.)\b{field}\b', f'{cast_expr}.{field}', body)
            result.append(body)
            continue
        result.append(line)
        i += 1
    return '\n'.join(result)


def transform_semantic_in(text):
    """Convert 'Kind in [tyX, tyY, ...]' to explicit OR chains."""
    def expand_in(m):
        var = m.group(1).strip()
        elems = [e.strip() for e in m.group(2).split(',')]
        conditions = [f"({var} = {e})" for e in elems if e]
        return '(' + ' or '.join(conditions) + ')'
    # Match: expr in [ident1, ident2, ...]
    text = re.sub(r'(\w+(?:\.\w+)*)\s+in\s+\[([^\]]+)\]', expand_in, text)
    # .Objects[I] -> .GetObject(I)
    text = re.sub(r'\.Objects\[([^\]]+)\]', r'.GetObject(\1)', text)
    # TStringList/TObjectList param/local subscripting: AAttrs[I] → AAttrs.Get(I)
    for name in ['AAttrs', 'AArgs', 'ParamNames', 'ParamConstraints',
                 'AParamNames', 'AParamConstraints', 'Args', 'IntfNames',
                 'MethodList', 'FieldList']:
        text = re.sub(rf'\b{name}\[([^\]]+)\]', rf'{name}.Get(\1)', text)
    # AST ObjectList fields accessed as Obj.Field[expr] → Obj.Field.Get(expr)
    for name in ['ProcDecls', 'TypeDecls', 'ConstDecls', 'Decls',
                 'Methods', 'Fields', 'Args', 'Params', 'Stmts',
                 'Branches', 'Values', 'TypeParams', 'TypeParamConstraints',
                 'OwnerTypeParams', 'OwnerTypeParamConstraints',
                 'UsedUnits', 'Names', 'Attributes', 'Properties',
                 'Implements', 'GenericInstances', 'GenericFuncInstances',
                 'ImplementsNames', 'VTable', 'Members']:
        text = re.sub(rf'\.{name}\[([^\]]+)\]', rf'.{name}.Get(\1)', text)
    # String indexing with char literal comparison: str[N] = 'X' → OrdAt(str, N) = NN
    text = re.sub(r"(\w+)\[([^\]]+)\]\s*=\s*''''",
                  lambda m: f"OrdAt({m.group(1)}, {m.group(2)}) = 39", text)
    text = re.sub(r"(\w+)\[([^\]]+)\]\s*<>\s*''''",
                  lambda m: f"OrdAt({m.group(1)}, {m.group(2)}) <> 39", text)
    text = re.sub(r"(\w+)\[([^\]]+)\]\s*=\s*'(.)'",
                  lambda m: f"OrdAt({m.group(1)}, {m.group(2)}) = {ord(m.group(3))}", text)
    text = re.sub(r"(\w+)\[([^\]]+)\]\s*<>\s*'(.)'",
                  lambda m: f"OrdAt({m.group(1)}, {m.group(2)}) <> {ord(m.group(3))}", text)
    text = re.sub(r"(\w+)\[([^\]]+)\]\s*=\s*#(\d+)",
                  lambda m: f"OrdAt({m.group(1)}, {m.group(2)}) = {m.group(3)}", text)
    text = re.sub(r"(\w+)\[([^\]]+)\]\s*<>\s*#(\d+)",
                  lambda m: f"OrdAt({m.group(1)}, {m.group(2)}) <> {m.group(3)}", text)
    # Strip ESemanticError redeclaration (already in header)
    text = re.sub(r"^\s*ESemanticError\s*=\s*class\(Exception\)\s*;?\s*$",
                  "", text, flags=re.MULTILINE)
    return text

# ---- uAST transforms ----
def transform_ast(text):
    # .Objects[I] -> .GetObject(I)
    text = re.sub(r'\.Objects\[([^\]]+)\]', r'.GetObject(\1)', text)
    return text

# ---- uCodeGenQBE transforms ----
def patch_codegen_raw(text):
    """Pre-processing on the RAW Pascal source before any other transforms.
    Replaces patterns that Blaise can't handle with compatible equivalents."""
    # Replace QbeEscapeString with a Blaise-compatible version.
    # The original uses Char type and string subscripting; Blaise has OrdAt.
    NEW_FUNC = (
        "function TCodeGenQBE.QbeEscapeString(const AStr: string): string;\n"
        "var\n"
        "  I: Integer;\n"
        "  C: Integer;\n"
        "begin\n"
        "  Result := '';\n"
        "  for I := 1 to Length(AStr) do\n"
        "  begin\n"
        "    C := OrdAt(AStr, I);\n"
        "    if C = 34 then\n"
        "      Result := Result + '\\\"'\n"
        "    else if C = 92 then\n"
        "      Result := Result + '\\\\'\n"
        "    else if C = 10 then\n"
        "      Result := Result + '\\n'\n"
        "    else if C = 13 then\n"
        "      Result := Result + '\\r'\n"
        "    else if C = 9 then\n"
        "      Result := Result + '\\t'\n"
        "    else if (C < 32) or (C > 126) then\n"
        "      Result := Result + Format('\\%02x', C)\n"
        "    else\n"
        "      Result := Result + Copy(AStr, I, 1);\n"
        "  end;\n"
        "end;"
    )
    # Replace QBEMangle: uses AName[I] string subscripting + case/char literals
    NEW_MANGLE = (
        "function TCodeGenQBE.QBEMangle(const AName: string): string;\n"
        "var\n"
        "  I: Integer;\n"
        "  C: Integer;\n"
        "begin\n"
        "  Result := '';\n"
        "  for I := 1 to Length(AName) do\n"
        "  begin\n"
        "    C := OrdAt(AName, I);\n"
        "    if C = 60 then\n"
        "      Result := Result + '_'\n"
        "    else if C = 62 then\n"
        "      begin end\n"
        "    else if C = 44 then\n"
        "      Result := Result + '_'\n"
        "    else\n"
        "      Result := Result + Copy(AName, I, 1);\n"
        "  end;\n"
        "end;"
    )
    marker2 = 'function TCodeGenQBE.QBEMangle('
    lines = text.split('\n')
    start2 = next((i for i, l in enumerate(lines) if marker2 in l), -1)
    if start2 >= 0:
        depth2 = 0
        end2 = start2
        for j in range(start2, len(lines)):
            lw = lines[j].strip().lower()
            if lw in ('begin', 'try') or re.match(r'case\b.*\bof\s*$', lw):
                depth2 += 1
            elif lw == 'end;' and depth2 > 0:
                depth2 -= 1
                if depth2 == 0:
                    end2 = j
                    break
        text = '\n'.join(lines[:start2]) + '\n' + NEW_MANGLE + '\n' + '\n'.join(lines[end2+1:])

    # Find and replace via line scan to avoid regex escaping nightmares
    marker = 'function TCodeGenQBE.QbeEscapeString('
    lines = text.split('\n')
    start = next((i for i, l in enumerate(lines) if marker in l), -1)
    if start >= 0:
        # Find the closing 'end;' of the function.
        # Count begin/try/case-of as openers; bare 'end;' as closers.
        depth = 0
        end = start
        for j in range(start, len(lines)):
            lw = lines[j].strip().lower()
            if lw in ('begin', 'try') or re.match(r'case\b.*\bof\s*$', lw):
                depth += 1
            elif lw == 'end;' and depth > 0:
                depth -= 1
                if depth == 0:
                    end = j
                    break
        text = '\n'.join(lines[:start]) + '\n' + NEW_FUNC + '\n' + '\n'.join(lines[end+1:])
    return text


def expand_codegen_in_sets(text):
    """Expand 'expr in [...]' patterns.  Must run BEFORE expand_with_stmts so
    that the LHS is still a simple word.word chain without typecast parens."""
    def expand_in(m):
        var = m.group(1).strip()
        elems = [e.strip() for e in m.group(2).split(',')]
        conditions = [f"({var} = {e})" for e in elems if e]
        return '(' + ' or '.join(conditions) + ')'

    def expand_typecast_in(m):
        # group(1)=TypeCast(expr), group(2)=.Field.Kind, group(3)=set members
        full_expr = m.group(1) + m.group(2)
        elems = [e.strip() for e in m.group(3).split(',')]
        conditions = [f"({full_expr} = {e})" for e in elems if e]
        return '(' + ' or '.join(conditions) + ')'

    # Handle TypeCast(simple_expr).FieldChain in [...] where the arg has no
    # nested parens (e.g. TASTExpr(Args[I]).ResolvedType.Kind in [...])
    text = re.sub(
        r'(T\w+\([^)]+\))((?:\.\w+)+)\s+in\s+\[([^\]]+)\]',
        expand_typecast_in,
        text
    )
    # Generic simple word.word chain before 'in [...]'
    return re.sub(r'(\w+(?:\.\w+)*)\s+in\s+\[([^\]]+)\]', expand_in, text)


def transform_codegen_in(text):
    # Strip ECodeGenError redeclaration (already in header)
    text = re.sub(r"^\s*ECodeGenError\s*=\s*class\(Exception\)\s*;?\s*$",
                  "", text, flags=re.MULTILINE)
    # TStringList has GetText not Text property
    text = text.replace('.Text', '.GetText')
    # Bare variable subscripts: FStrLits[I] → FStrLits.Get(I), etc.
    for name in ['FStrLits', 'BranchLabels', 'Args',
                 'FBreakLabels', 'FContinueLabels']:
        text = re.sub(rf'\b{name}\[([^\]]+)\]', rf'{name}.Get(\1)', text)
    # .Objects[I] -> .GetObject(I)
    text = re.sub(r'\.Objects\[([^\]]+)\]', r'.GetObject(\1)', text)
    # AST ObjectList fields accessed as Obj.Field[expr] → Obj.Field.Get(expr)
    for name in ['ProcDecls', 'TypeDecls', 'ConstDecls', 'Decls',
                 'Methods', 'Fields', 'Args', 'Params', 'Stmts',
                 'Branches', 'Values', 'TypeParams', 'UsedUnits',
                 'VTable', 'Members', 'ImplementsNames', 'Names',
                 'GenericInstances', 'GenericFuncInstances', 'GenericIntfInstances',
                 'Implements', 'Properties', 'Attributes']:
        text = re.sub(rf'\.{name}\[([^\]]+)\]', rf'.{name}.Get(\1)', text)
    return text

# ---- uLexer transforms ----
def transform_lexer_in(text):
    def expand_in(m):
        var = m.group(1).strip()
        elems = [e.strip() for e in m.group(2).split(',')]
        conditions = [f"({var} = {e})" for e in elems if e]
        return '(' + ' or '.join(conditions) + ')'
    text = re.sub(r'(\w+(?:\.\w+)*)\s+in\s+\[([^\]]+)\]', expand_in, text)
    # ARaw[I] = '''' / ARaw[I] = 'X' / ARaw[I] = #NN → OrdAt(ARaw, I) = NN
    text = re.sub(r"(\w+)\[([^\]]+)\]\s*=\s*''''",
                  lambda m: f"OrdAt({m.group(1)}, {m.group(2)}) = 39", text)
    text = re.sub(r"(\w+)\[([^\]]+)\]\s*<>\s*''''",
                  lambda m: f"OrdAt({m.group(1)}, {m.group(2)}) <> 39", text)
    text = re.sub(r"(\w+)\[([^\]]+)\]\s*=\s*'(.)'",
                  lambda m: f"OrdAt({m.group(1)}, {m.group(2)}) = {ord(m.group(3))}", text)
    text = re.sub(r"(\w+)\[([^\]]+)\]\s*<>\s*'(.)'",
                  lambda m: f"OrdAt({m.group(1)}, {m.group(2)}) <> {ord(m.group(3))}", text)
    text = re.sub(r"(\w+)\[([^\]]+)\]\s*=\s*#(\d+)",
                  lambda m: f"OrdAt({m.group(1)}, {m.group(2)}) = {m.group(3)}", text)
    text = re.sub(r"(\w+)\[([^\]]+)\]\s*<>\s*#(\d+)",
                  lambda m: f"OrdAt({m.group(1)}, {m.group(2)}) <> {m.group(3)}", text)
    # Result := Result + ARaw[I] → Result := Result + Copy(ARaw, I, 1)
    text = re.sub(r"(\w+)\s*:=\s*(\w+)\s*\+\s*(\w+)\[([^\]]+)\]",
                  lambda m: f"{m.group(1)} := {m.group(2)} + Copy({m.group(3)}, {m.group(4)}, 1)",
                  text)
    return text

# ---- uParser transforms ----
def transform_parser_in(text):
    def expand_in(m):
        var = m.group(1).strip()
        elems = [e.strip() for e in m.group(2).split(',')]
        conditions = [f"({var} = {e})" for e in elems if e]
        return '(' + ' or '.join(conditions) + ')'
    text = re.sub(r'(\w+(?:\.\w+)*)\s+in\s+\[([^\]]+)\]', expand_in, text)
    text = re.sub(r'\.Objects\[([^\]]+)\]', r'.GetObject(\1)', text)
    # Names[I] (TStringList indexed) -> Names.Get(I)
    text = re.sub(r'\bNames\[([^\]]+)\]', r'Names.Get(\1)', text)
    # AST ObjectList fields: Obj.Field[expr] → Obj.Field.Get(expr)
    for name in ['Args', 'Params', 'TypeDecls', 'ProcDecls', 'ConstDecls',
                 'Decls', 'Methods', 'Fields', 'Stmts', 'Branches', 'Values',
                 'TypeParams', 'TypeParamConstraints', 'OwnerTypeParams',
                 'OwnerTypeParamConstraints', 'UsedUnits', 'Names',
                 'Attributes', 'Properties', 'Implements', 'ImplementsNames',
                 'VTable', 'Members', 'GenericInstances', 'GenericFuncInstances']:
        text = re.sub(rf'\.{name}\[([^\]]+)\]', rf'.{name}.Get(\1)', text)
    # Strip EParseError redeclaration (already in header)
    text = re.sub(r"^\s*EParseError\s*=\s*class\(Exception\)\s*;?\s*$",
                  "", text, flags=re.MULTILINE)
    # FPC-style Extract(Items[0]) → Blaise-style Extract(0)
    text = re.sub(r"\.Extract\(\w+(?:\.\w+)*\.Items\[(\d+)\]\)",
                  r".Extract(\1)", text)
    # X.Items[I] → X.Get(I)  (generic FPC Items property → Blaise method)
    text = re.sub(r"\.Items\[([^\]]+)\]", r".Get(\1)", text)
    return text

# ---- Keyword list replacement ----
INIT_KEYWORDS = """
var KwList: TStringList;

procedure InitKeywords;
begin
  KwList := TStringList.Create;
  KwList.Sorted := True;
  KwList.CaseSensitive := True;
  KwList.Add('ABSOLUTE');  KwList.Add('AND');       KwList.Add('ARRAY');
  KwList.Add('AS');        KwList.Add('ASM');        KwList.Add('BEGIN');
  KwList.Add('BITPACKED'); KwList.Add('CASE');       KwList.Add('CLASS');
  KwList.Add('CONST');     KwList.Add('CONSTREF');   KwList.Add('CONSTRUCTOR');
  KwList.Add('CONTAINS');  KwList.Add('DESTRUCTOR'); KwList.Add('DISPINTERFACE');
  KwList.Add('DIV');       KwList.Add('DO');         KwList.Add('DOWNTO');
  KwList.Add('ELSE');      KwList.Add('END');        KwList.Add('EXCEPT');
  KwList.Add('EXPORTS');   KwList.Add('FALSE');      KwList.Add('FILE');
  KwList.Add('FINALIZATION'); KwList.Add('FINALLY'); KwList.Add('FOR');
  KwList.Add('FUNCTION');  KwList.Add('GENERIC');    KwList.Add('GOTO');
  KwList.Add('IF');        KwList.Add('IMPLEMENTATION'); KwList.Add('IN');
  KwList.Add('INHERITED'); KwList.Add('INITIALIZATION'); KwList.Add('INLINE');
  KwList.Add('INTERFACE'); KwList.Add('IS');         KwList.Add('LABEL');
  KwList.Add('LIBRARY');   KwList.Add('MOD');        KwList.Add('NIL');
  KwList.Add('NOT');       KwList.Add('OBJCCATEGORY'); KwList.Add('OBJCCLASS');
  KwList.Add('OBJCPROTOCOL'); KwList.Add('OBJECT'); KwList.Add('OF');
  KwList.Add('OPERATOR');  KwList.Add('OR');         KwList.Add('OTHERWISE');
  KwList.Add('PACKAGE');   KwList.Add('PACKED');     KwList.Add('PROCEDURE');
  KwList.Add('PROGRAM');   KwList.Add('PROPERTY');   KwList.Add('RAISE');
  KwList.Add('RECORD');    KwList.Add('REPEAT');     KwList.Add('REQUIRES');
  KwList.Add('RESOURCESTRING'); KwList.Add('SELF'); KwList.Add('SET');
  KwList.Add('SHL');       KwList.Add('SHR');        KwList.Add('SPECIALIZE');
  KwList.Add('THEN');      KwList.Add('THREADVAR');  KwList.Add('TO');
  KwList.Add('TRUE');      KwList.Add('TRY');        KwList.Add('TYPE');
  KwList.Add('UNIT');      KwList.Add('UNTIL');      KwList.Add('USES');
  KwList.Add('VAR');       KwList.Add('WHILE');      KwList.Add('WITH');
  KwList.Add('XOR')
end;

function BinarySearchKeyword(const AText: string): Boolean;
var
  Idx: Integer;
begin
  Result := KwList.Find(AText, Idx)
end;

"""

def transform_tokeniser(text):
    """Full transformation of uPasTokeniser for Blaise."""
    text = basic(text)

    # Step 1: Find the const block containing KeywordCount/Keywords and remove it
    # Find '\nconst\n' that is followed eventually by 'KeywordCount'
    lines = text.split('\n')
    out_lines = []
    skip = False
    for i, line in enumerate(lines):
        stripped = line.strip()
        # Start of const block with keyword array
        if stripped == 'const' and i + 1 < len(lines) and 'KeywordCount' in '\n'.join(lines[i:i+5]):
            skip = True
            continue
        # End of Keywords array (the );  line)
        if skip and stripped == ');':
            skip = False
            continue
        if not skip:
            out_lines.append(line)
    text = '\n'.join(out_lines)

    # Step 2: Remove old BinarySearchKeyword function
    m = re.search(r'\nfunction BinarySearchKeyword[^\n]*\n', text)
    if m:
        # Find the matching 'end;' after this
        start = m.start()
        end_match = re.search(r'\nend;\n', text[m.end():])
        if end_match:
            end_pos = m.end() + end_match.end()
            text = text[:start] + text[end_pos:]

    # Step 3: Prepend new keyword list + new BinarySearchKeyword
    text = INIT_KEYWORDS + text
    
    # Convert FSource[expr] to OrdAt(FSource, expr)
    text = re.sub(r'\bFSource\[([^\]]+)\]', r'OrdAt(FSource, \1)', text)
    
    # Handle escaped single-quote in OrdAt comparisons first
    text = text.replace("OrdAt(FSource, FPos) = ''''", "OrdAt(FSource, FPos) = 39")
    text = text.replace("OrdAt(FSource, FPos) <> ''''", "OrdAt(FSource, FPos) <> 39")
    # Convert char literals in comparisons with OrdAt result
    def oat_cmp(op):
        return re.sub(
            rf"OrdAt\(FSource, ([^)]+)\) {op} '(.)'",
            lambda m: f"OrdAt(FSource, {m.group(1)}) {op} {ord(m.group(2))}",
            text)
    # Apply to all OrdAt(FSource, expr) = 'X' patterns
    text = re.sub(r"OrdAt\(FSource, ([^)]+)\) = '(.)'",
                  lambda m: f"OrdAt(FSource, {m.group(1)}) = {ord(m.group(2))}", text)
    text = re.sub(r"OrdAt\(FSource, ([^)]+)\) <> '(.)'",
                  lambda m: f"OrdAt(FSource, {m.group(1)}) <> {ord(m.group(2))}", text)
    text = re.sub(r"OrdAt\(FSource, ([^)]+)\) = #(\d+)",
                  lambda m: f"OrdAt(FSource, {m.group(1)}) = {m.group(2)}", text)
    # PeekAt(...) comparisons
    text = re.sub(r"PeekAt\(([^)]+)\) = '(.)'",
                  lambda m: f"PeekAt({m.group(1)}) = {ord(m.group(2))}", text)
    text = re.sub(r"PeekAt\(([^)]+)\) <> '(.)'",
                  lambda m: f"PeekAt({m.group(1)}) <> {ord(m.group(2))}", text)
    text = re.sub(r"PeekAt\(([^)]+)\) = #(\d+)",
                  lambda m: f"PeekAt({m.group(1)}) = {m.group(2)}", text)
    text = re.sub(r"PeekAt\(([^)]+)\) <> #(\d+)",
                  lambda m: f"PeekAt({m.group(1)}) <> {m.group(2)}", text)
    # FSource[FPos] = #NN (line 210 etc) - convert to OrdAt
    text = re.sub(r"FSource\[FPos\]\s*=\s*#(\d+)",
                  lambda m: f"OrdAt(FSource, FPos) = {m.group(1)}", text)
    text = re.sub(r"FSource\[FPos\]\s*<>\s*#(\d+)",
                  lambda m: f"OrdAt(FSource, FPos) <> {m.group(1)}", text)
    text = re.sub(r"FSource\[FPos\]\s*=\s*'(.)'",
                  lambda m: f"OrdAt(FSource, FPos) = {ord(m.group(1))}", text)
    text = re.sub(r"FSource\[FPos\]\s*<>\s*'(.)'",
                  lambda m: f"OrdAt(FSource, FPos) <> {ord(m.group(1))}", text)
    # Strip inherited Create; calls - TObject has no Create in Blaise
    text = re.sub(r"^\s*inherited Create;\s*$", "", text, flags=re.MULTILINE)
    # Case labels using char literals - convert '.': to 46:
    text = re.sub(r"^(\s+)'(.)':",
                  lambda m: f"{m.group(1)}{ord(m.group(2))}:",
                  text, flags=re.MULTILINE)
    
    # Convert c2 := char (local char var assignments)
    text = re.sub(r"(c|c2)\s*:=\s*FSource\[FPos\]", r"\1 := OrdAt(FSource, FPos)", text)
    text = re.sub(r"(c|c2)\s*:=\s*FSource\[FPos\s*\+\s*1\]", r"\1 := OrdAt(FSource, FPos + 1)", text)
    
    # c2 is assigned from PeekAt or Peek - those return chars 
    # We need those to return integers too
    # For now, convert char comparisons on c and c2
    # Handle escaped single-quote comparisons first
    for var in ['c', 'c2']:
        text = text.replace(f"{var} = ''''", f"{var} = 39")
        text = text.replace(f"{var} <> ''''", f"{var} <> 39")
    for var in ['c', 'c2']:
        text = re.sub(rf"{var} = '(.)'", lambda m, v=var: f"{v} = {ord(m.group(1))}", text)
        text = re.sub(rf"{var} = #(\d+)", lambda m, v=var: f"{v} = {m.group(1)}", text)
        text = re.sub(rf"{var} <> '(.)'", lambda m, v=var: f"{v} <> {ord(m.group(1))}", text)
    
    # Convert 'in [...]' patterns involving chars
    def expand_char_in(m):
        var = m.group(1).strip()
        body = m.group(2)
        parts = []
        for elem in re.split(r',\s*', body):
            elem = elem.strip()
            rm = re.match(r"'(.)'\.\.\'(.)'", elem)
            if rm:
                lo, hi = ord(rm.group(1)), ord(rm.group(2))
                parts.append(f"(({var} >= {lo}) and ({var} <= {hi}))")
                continue
            rm = re.match(r"'(.)'", elem)
            if rm:
                parts.append(f"({var} = {ord(rm.group(1))})")
                continue
            rm = re.match(r'#(\d+)', elem)
            if rm:
                parts.append(f"({var} = {rm.group(1)})")
                continue
            # Identifier (fptkXxx)
            parts.append(f"({var} = {elem})")
        return '(' + ' or '.join(parts) + ')' if parts else 'False'
    
    # Match: expr in [...] where expr can be ident, field access, or function call
    text = re.sub(r'([\w.]+(?:\([^)]*\))?)\s+in\s+\[([^\]]+)\]', expand_char_in, text)
    
    # Convert Char type declarations
    text = re.sub(r'\bChar\b', 'Integer', text)
    
    # Handle escaped single-quote char literal '''' = 39 BEFORE general transforms
    text = text.replace("= ''''", "= 39")
    text = text.replace(":= ''''", ":= 39")
    # Convert char literal assignments: c := 'x'
    text = re.sub(r"(\w+)\s*:=\s*'(.)'",
                  lambda m: f"{m.group(1)} := {ord(m.group(2))}", text)
    text = re.sub(r"(\w+)\s*:=\s*#(\d+)",
                  lambda m: f"{m.group(1)} := {m.group(2)}", text)
    
    # repeat...until False -> while True do begin...end
    text = text.replace('repeat\n', 'while True do\nbegin\n')
    text = re.sub(r'\buntil False;', 'end;', text)
    # until not (condition) - the one in uLexer: convert to while + break
    text = re.sub(r'\buntil not \((.+?)\);\n',
                  lambda m: f'  if not ({m.group(1)}) then break\nend;\n', text)
    
    # Peek and PeekAt methods - they return chars, now need to return integers
    # The return type is Integer (we changed Char -> Integer)
    
    # FToken.Len and FToken.TextStart are Integer - fine
    
    # Copy() for string extraction is fine
    
    # GetSource: returns string - fine
    # TokenText: returns string via Copy - fine
    
    return text

# ======================================================================
# Main build
# ======================================================================

HEADER = """{
  Blaise - An Object Pascal Compiler
  Copyright (c) 2026 Graeme Geldenhuys
  SPDX-License-Identifier: Apache-2.0 WITH Swift-exception
  Licensed under the Apache License v2.0 with Runtime Library Exception.
  See LICENSE file in the project root for full license terms.

  blaise-compiler.pas - Self-hosting source.
  Concatenated from all compiler units.
}

program BlaiseCompiler;

const
  CHR_QUOTE    = 39;    CHR_HASH     = 35;    CHR_DOLLAR   = 36;
  CHR_LF       = 10;    CHR_CR       = 13;    CHR_TAB      = 9;
  CHR_SPACE    = 32;    CHR_0        = 48;    CHR_9        = 57;
  CHR_A_UP     = 65;    CHR_F_UP     = 70;    CHR_Z_UP     = 90;
  CHR_a_LO     = 97;    CHR_f_LO     = 102;   CHR_z_LO     = 122;
  CHR_UNDER    = 95;    CHR_CARET    = 94;    CHR_DOT      = 46;
  CHR_AT       = 64;    CHR_LT       = 60;    CHR_GT       = 62;
  CHR_EQ       = 61;    CHR_PLUS     = 43;    CHR_MINUS    = 45;
  CHR_STAR     = 42;    CHR_SLASH    = 47;    CHR_LPAREN   = 40;
  CHR_RPAREN   = 41;    CHR_SEMI     = 59;    CHR_COLON    = 58;
  CHR_LBRACKET = 91;    CHR_RBRACKET = 93;    CHR_e_LO     = 101;
  CHR_E_UP     = 69;    CHR_DQUOTE   = 34;
  MaxInt       = 2147483647;

type
  Exception = class
    FMessage: string;
    procedure Create(AMessage: string);
    procedure CreateFmt(const AFmt: string; AArg: Integer);
    procedure Destroy; virtual;
    property Message: string read FMessage;
  end;
  EParseError    = class(Exception);
  ESemanticError = class(Exception);
  ECodeGenError  = class(Exception);

procedure Exception.Create(AMessage: string);
begin
  Self.FMessage := AMessage
end;

procedure Exception.CreateFmt(const AFmt: string; AArg: Integer);
begin
  Self.FMessage := Format(AFmt, AArg)
end;

procedure Exception.Destroy;
begin

end;

{ File path helpers — replacements for FPC SysUtils functions }

function ExtractFileName(const APath: string): string;
var
  I: Integer;
begin
  Result := APath;
  I := Length(APath);
  while I >= 1 do
  begin
    if OrdAt(APath, I) = 47 then
    begin
      Result := Copy(APath, I + 1, Length(APath) - I);
      Exit;
    end;
    I := I - 1;
  end;
end;

function ChangeFileExt(const AFileName: string; const AExt: string): string;
var
  I: Integer;
begin
  I := Length(AFileName);
  while I >= 1 do
  begin
    if OrdAt(AFileName, I) = 46 then
    begin
      Result := Copy(AFileName, 1, I - 1) + AExt;
      Exit;
    end;
    if OrdAt(AFileName, I) = 47 then
      break;
    I := I - 1;
  end;
  Result := AFileName + AExt;
end;

"""

def section(title):
    return (f'\n{{ === {title} === }}\n\n')

def _edit_class_body(text, cls, mutate):
    """Find `<cls> = class` (no parent), call mutate(body_lines) on the
    list of lines between the header and the matching `end;`, and splice
    the result back. Returns text unchanged if no match. Line-oriented
    and O(n) — avoids regex backtracking on the 60k-line output."""
    lines = text.split('\n')
    i = 0
    header = cls + ' = class'
    while i < len(lines):
        stripped = lines[i].strip()
        if stripped == header or stripped.startswith(header + ' ') \
                or stripped.startswith(header + '\t'):
            j = i + 1
            while j < len(lines) and lines[j].strip() != 'end;':
                j += 1
            if j < len(lines):
                lines[i + 1:j] = mutate(lines[i + 1:j])
            return '\n'.join(lines)
        i += 1
    return text

def postprocess(text):
    """Apply vtable / override fixes so the migrated file compiles under
    the self-hosted Blaise compiler. Idempotent and safe to apply in
    incremental tests as well as the final output."""

    # Inject `procedure Destroy; virtual;` into root classes whose
    # descendants are used in `is` checks.
    for cls, anchor in (('TASTNode', 'procedure TIfStmt.Destroy;'),
                        ('TTypeDesc', 'procedure TRecordTypeDesc.Destroy;')):
        def add_virtual(body):
            for ln in body:
                if 'procedure Destroy;' in ln:
                    return body  # already present
            return body + ['    procedure Destroy; virtual;']
        new_text = _edit_class_body(text, cls, add_virtual)
        if new_text != text and f'procedure {cls}.Destroy;' not in new_text:
            new_text = new_text.replace(
                anchor,
                f'procedure {cls}.Destroy;\nbegin\n\nend;\n\n' + anchor, 1)
        text = new_text

    # Strip `override` from root classes that have no virtual base
    # post-migration (their FPC source used `destructor Destroy; override`
    # to override TObject's destructor, which no longer exists).
    non_vtable_roots = (
        'TObjectList', 'TStringList', 'TLexer', 'TParser',
        'TSymbol', 'TScope', 'TSymbolTable', 'TFieldInfo', 'TVTableEntry',
        'TPropertyInfo', 'TParamDesc',
        'TCaseBranch', 'TGenericFuncInstance', 'TGenericInstance',
        'TGenericInterfaceInstance',
        'TCodeGenQBE', 'TSemanticAnalyser',
    )
    def strip_override(body):
        return [ln.replace('procedure Destroy; override;',
                           'procedure Destroy;') for ln in body]
    for cls in non_vtable_roots:
        text = _edit_class_body(text, cls, strip_override)
    return text

def test(path):
    with open(path) as f: content = f.read()
    content = postprocess(content)
    with open('/tmp/_t.pas', 'w') as f:
        f.write(content)
        if not content.strip().endswith('end.'):
            f.write('\nbegin\nend.\n')
    r = subprocess.run(
        ['/data/devel/new-pascal-compiler/compiler/target/blaise',
         '--source', '/tmp/_t.pas', '--emit-ir'],
        capture_output=True, text=True)
    out = r.stdout + r.stderr
    if out.startswith('#'): return True, 'OK'
    return False, out.split('\n')[0]

# Build
parts = [HEADER]

# Classes
classes = basic(strip_fpc(read(f'{RTL}/Classes.pas')))
parts.append(section('RTL: Collections'))
parts.append(classes)
parts.append('\n\n')
write(OUT, ''.join(parts))
ok, msg = test(OUT)
print(f"Classes: {'OK' if ok else msg}")
if not ok: sys.exit(1)

# uPasTokeniser
tok = transform_tokeniser(strip_fpc(read(f'{SRC}/uPasTokeniser.pas')))
parts.append(section('uPasTokeniser'))
parts.append(tok)
parts.append('\n\n')
write(OUT, ''.join(parts))
ok, msg = test(OUT)
print(f"uPasTokeniser: {'OK' if ok else msg}")
if not ok:
    # Show context around the error
    err_line = 0
    m = re.search(r'line (\d+)', msg)
    if m: err_line = int(m.group(1))
    lines = ''.join(parts).split('\n')
    if err_line > 5:
        for i in range(max(0,err_line-3), min(len(lines), err_line+3)):
            print(f"  {i+1}: {lines[i]}")
    sys.exit(1)

# uLexer
lex = transform_lexer_in(basic(strip_fpc(read(f'{SRC}/uLexer.pas'))))
# Strip the FPC-only local OrdAt helper — self-hosted builds use the builtin.
lex = re.sub(
    r'function OrdAt\(const S: string; I: Integer\): Integer;\s*\n'
    r'begin\s*\n'
    r'\s*Result := (?:Ord\(S\[I\]\)|S\[I\]);\s*\n'
    r'end;\s*\n', '', lex)
parts.append(section('uLexer'))
parts.append(lex)
parts.append('\n\n')
write(OUT, ''.join(parts))
ok, msg = test(OUT)
print(f"uLexer: {'OK' if ok else msg}")
if not ok: sys.exit(1)

# uSymbolTable
sym = transform_symtable_indexed(basic(strip_fpc(read(f'{SRC}/uSymbolTable.pas'))))
parts.append(section('uSymbolTable'))
parts.append(sym)
parts.append('\n\n')
write(OUT, ''.join(parts))
ok, msg = test(OUT)
print(f"uSymbolTable: {'OK' if ok else msg}")
if not ok: sys.exit(1)

# uAST
ast = transform_ast(basic(strip_fpc(read(f'{SRC}/uAST.pas'))))
parts.append(section('uAST'))
parts.append(ast)
parts.append('\n\n')
write(OUT, ''.join(parts))
ok, msg = test(OUT)
print(f"uAST: {'OK' if ok else msg}")
if not ok: sys.exit(1)

# uParser
par = transform_parser_in(basic(strip_fpc(read(f'{SRC}/uParser.pas'))))
parts.append(section('uParser'))
parts.append(par)
parts.append('\n\n')
write(OUT, ''.join(parts))
ok, msg = test(OUT)
print(f"uParser: {'OK' if ok else msg}")
if not ok: sys.exit(1)

# uSemantic
sem = transform_semantic_assignments(transform_semantic_in(expand_with_stmts(basic(strip_fpc(read(f'{SRC}/uSemantic.pas'))))))
parts.append(section('uSemantic'))
parts.append(sem)
parts.append('\n\n')
write(OUT, ''.join(parts))
ok, msg = test(OUT)
print(f"uSemantic: {'OK' if ok else msg}")
if not ok: sys.exit(1)

# uCodeGenQBE
cg = transform_codegen_in(expand_with_stmts(expand_codegen_in_sets(basic(strip_fpc(patch_codegen_raw(read(f'{SRC}/uCodeGenQBE.pas')))))))
parts.append(section('uCodeGenQBE'))
parts.append(cg)
parts.append('\n\n')
write(OUT, ''.join(parts))
ok, msg = test(OUT)
print(f"uCodeGenQBE: {'OK' if ok else msg}")
if not ok: sys.exit(1)

# Main program from Blaise.pas
main = basic(strip_fpc(read(f'{SRC}/Blaise.pas')))
# String subscript char comparisons: Arg[N] = 'X' → OrdAt(Arg, N) = NN
main = re.sub(r"(\w+)\[([^\]]+)\]\s*<>\s*'(.)'",
              lambda m: f"OrdAt({m.group(1)}, {m.group(2)}) <> {ord(m.group(3))}", main)
main = re.sub(r"(\w+)\[([^\]]+)\]\s*=\s*'(.)'",
              lambda m: f"OrdAt({m.group(1)}, {m.group(2)}) = {ord(m.group(3))}", main)
# Transform Blaise.pas: TProcess -> Exec, path utilities, file I/O
main = main.replace('TStringList.Create', 'TStringList.Create')  # already OK
# TStringList.LoadFromFile -> replace with ReadFile
main = re.sub(r'(\w+)\.LoadFromFile\(([^)]+)\)',
              lambda m: f"{m.group(1)}.Add(ReadFile({m.group(2)}))", main)
# TStringList.SaveToFile -> WriteFile
main = re.sub(r'(\w+)\.SaveToFile\(([^)]+)\)',
              lambda m: f"WriteFile({m.group(2)}, {m.group(1)}.GetText)", main)
# IRFile write block: Source.Text := IR; Source.SaveToFile(IRFile)
# → WriteFile(IRFile, IR) — the SaveToFile transform already ran, so fix up
main = main.replace('Source.Text := IR;', '')
# After SaveToFile transform: WriteFile(IRFile, Source.GetText) → WriteFile(IRFile, IR)
main = main.replace('WriteFile(IRFile, Source.GetText)', 'WriteFile(IRFile, IR)')
# TProcess - replace RunProcess with Exec-based version
# Callers use: RunProcess('exe', [arg1, arg2, ...], MsgVar)
# → replace with a simple version that takes a pre-built command string
main = re.sub(
    r'function RunProcess\(.*?\nend;',
    '''function RunProcess(const ACmd: string; var AOutput: string): Integer;
begin
  Result := Exec(ACmd);
  AOutput := ''
end;''',
    main, flags=re.DOTALL)
# Transform RunProcess callsites: RunProcess(exe, [arg1, arg2, ...], Msg)
# → build command string inline
def inline_runprocess(m):
    exe = m.group(1).strip()
    args_str = m.group(2).strip()
    # Parse comma-separated args (simple, no nested brackets)
    args = [a.strip() for a in args_str.split(',')]
    cmd = exe
    for a in args:
        cmd = cmd + " + ' ' + " + a
    return f"RunProcess({cmd}, Msg)"
main = re.sub(
    r"RunProcess\(([^,]+),\s*\[([^\]]+)\],\s*Msg\)",
    inline_runprocess, main)
# Remove StdErr references (write errors to stdout instead)
main = re.sub(r"WriteLn\(StdErr,\s*", "WriteLn(", main)
main = re.sub(r"Write\(StdErr,\s*", "Write(", main)
# 'on E: ExcType do' filter syntax not supported — strip the filter line
# and replace E.Message with Exception(CurrentException).Message
main = re.sub(r'^\s*on\s+\w+\s*:\s*\w+\s+do\s*$', '', main, flags=re.MULTILINE)
main = re.sub(r'\bE\.Message\b', 'CurrentExceptionMessage', main)
# ExtractFilePath, ChangeFileExt, IncludeTrailingPathDelimiter - implement inline
# These are used in FindRTL and CompileToNative
main = main.replace('ExtractFilePath(ParamStr(0))', 
    "Copy(ParamStr(0), 1, Length(ParamStr(0)) - Length('blaise'))")
# ChangeFileExt - simple string replace: strip last extension and add new one
# This is complex - leave as TODO for now, use format string approach
main = re.sub(r"ChangeFileExt\((\w+),\s*'\.(\w+)'\)",
              lambda m: f"{m.group(1)} + '.{m.group(2)}'", main)
main = re.sub(r'IncludeTrailingPathDelimiter\(([^)]+)\)', r"(\1 + '/')", main)
# GetEnvironmentVariable → GetEnvVar (Blaise builtin name)
main = main.replace('GetEnvironmentVariable(', 'GetEnvVar(')
# TStringList.Text property → GetText method
main = main.replace('.Text', '.GetText')
# DeleteFile -> add as a builtin (we have it in the RTL as _Halt, need _DeleteFile)
main = main.replace('DeleteFile(', 'DeleteFile(')  # keep for now

# Remove TProcess class usage
main = re.sub(r'TProcess\s*:=.*?;', '', main)

parts.append(section('Main program'))
parts.append(main)
parts.append('\nend.\n')  # close the program

# Apply vtable/override fixes to the assembled output (same postprocess
# used by incremental tests).
out = postprocess(''.join(parts))
write(OUT, out)
ok, msg = test(OUT)
print(f"Main (Blaise.pas): {'OK' if ok else msg}")

wc = len(out.split('\n'))
print(f"\nTotal: ~{wc} lines in {OUT}")
