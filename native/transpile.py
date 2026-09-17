#!/usr/bin/env python3
"""Clarity-to-JavaScript transpiler.

Reads Clarity source, parses to AST, emits JavaScript.
The output runs on Bun/Node with the Clarity runtime.

Usage:
  python native/transpile.py <file.clarity>           # Transpile single file
  python native/transpile.py --bundle                 # Transpile CLI + stdlib → single JS
  python native/transpile.py --bundle --compile        # + compile to native binary via Bun
"""

import os
import sys
import textwrap

# Add native/ to path so local modules are found
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from lexer import tokenize
from parser import parse
import ast_nodes as ast


class TranspileError(Exception):
    """A node the emitter has no case for. Raised rather than emitted as a
    comment: generated JavaScript that quietly omits a statement is worse
    than a build that stops and names the node."""


class JSEmitter:
    """Transpiles a Clarity AST to JavaScript source code."""

    # All known class names across the stdlib — needed for `new` insertion
    # since individual files don't see class definitions from imports
    KNOWN_CLASSES = {
        # tokens.clarity
        'Token',
        # ast_nodes.clarity
        'Program', 'LetStatement', 'DestructureLetStatement', 'AssignStatement',
        'FnStatement', 'ReturnStatement', 'IfStatement', 'ForStatement',
        'WhileStatement', 'TryCatch', 'BreakStatement', 'ContinueStatement',
        'ThrowStatement', 'ShowStatement', 'ImportStatement', 'ClassStatement',
        'InterfaceStatement', 'MatchStatement', 'MultiAssignStatement',
        'EnumStatement', 'DecoratedStatement', 'ExpressionStatement', 'Block',
        'NumberLiteral', 'StringLiteral', 'BoolLiteral', 'NullLiteral',
        'Identifier', 'ThisExpression', 'ListLiteral', 'MapLiteral',
        'BinaryOp', 'UnaryOp', 'CallExpression', 'MemberExpression',
        'OptionalMemberExpression', 'IndexExpression', 'SliceExpression',
        'FnExpression', 'PipeExpression', 'RangeExpression', 'AskExpression',
        'NullCoalesce', 'SpreadExpression', 'IfExpression',
        'ComprehensionExpression', 'MapComprehensionExpression',
        'AwaitExpression', 'YieldExpression',
        # lexer.clarity
        'Lexer',
        # parser.clarity
        'Parser',
        # interpreter.clarity
        'Environment', 'ClarityFunction', 'ClarityClass', 'ClarityInstance',
        'ClarityInterface', 'ClarityEnum', 'Interpreter',
        # bytecode.clarity
        'CodeObject', 'Compiler', 'VMFrame', 'VMFunction', 'VMClass',
        'VMInstance', 'VMIterator', 'VM',
        # collections.clarity
        'Set', 'OrderedMap', 'Queue', 'Stack', 'PriorityQueue',
        # channel.clarity
        'Channel', 'BufferedChannel', 'FanOut', 'FanIn',
        # completer.clarity
        'Completer',
        # datetime.clarity
        'Duration', 'DateTime',
        # db.clarity
        'KVStore', 'Table', 'Query',
        # debugger.clarity
        'Breakpoint', 'DebugFrame', 'Debugger',
        # formatter.clarity
        'Formatter',
        # linter.clarity
        'LintScope', 'Linter',
        # lsp.clarity
        'LanguageServer',
        # mutex.clarity
        'Mutex', 'RWLock', 'Atomic', 'AtomicFlag', 'Once', 'Semaphore', 'FileLock',
        # net.clarity
        'HttpResponse', 'HttpServer', 'URL',
        # profiler.clarity
        'Profiler',
        # registry.clarity
        'Registry',
        # repl.clarity
        'ReplState',
        # semver.clarity
        'SemVer', 'VersionRange',
        # task.clarity
        'Task', 'BackgroundTask', 'TaskGroup', 'Future',
        # transpile.clarity
        'JSEmitter',
        # type_checker.clarity
        'TypeScope', 'TypeChecker',
        # worker.clarity
        'WorkerPool', 'Pipeline',
    }

    def __init__(self, module_name="<main>", base_dir=None):
        self.indent = 0
        self.module_name = module_name
        self.base_dir = base_dir  # where the module's own imports are resolved
        self.imports = set()  # Track Clarity imports to resolve
        self.classes = set(self.KNOWN_CLASSES)  # Seed with all known classes
        self.source_map = []  # (js_line, clarity_file, clarity_line) entries
        self.hoisted_imports = []  # Imports found inside blocks, hoisted to top

    def _seed_classes(self, program):
        """`Foo(1)` must become `new Foo(1)` when Foo is a class, and the
        emitter cannot tell from the call site. Until this existed the
        class set grew as declarations were met, so a class constructed
        above its own declaration was emitted as a plain call: the
        bytecode VM's VMInstance built a VMBoundMethod that way, and
        every method call under `run --fast` in a binary this transpiler
        produced died with "Cannot call a class constructor without
        new". The self-hosted transpiler seeds the set up front; this is
        the same rule: classes declared anywhere in this module, plus
        classes this module imports by name from a sibling file."""
        classes, imports = [], []
        _collect_declarations(program.body, classes, imports)
        self.classes.update(classes)
        if self.base_dir is None:
            return
        for stmt in imports:
            path = getattr(stmt, 'path', None)
            names = getattr(stmt, 'names', None)
            if not path or not names:
                continue
            exported = _module_class_names(os.path.join(self.base_dir, path))
            for n in names:
                if n in exported:
                    self.classes.add(n)

    def emit(self, program):
        """Emit a full program."""
        self.top_level = True
        self._seed_classes(program)
        lines = []
        for stmt in program.body:
            lines.append(self.emit_stmt(stmt))
        self.top_level = False
        # Prepend any imports that were inside function/block bodies
        if self.hoisted_imports:
            hoisted = '\n'.join(self.hoisted_imports)
            return hoisted + '\n' + '\n'.join(lines)
        return '\n'.join(lines)

    def _indent(self):
        return '  ' * self.indent

    # ── Statements ────────────────────────────────────────

    def emit_stmt(self, node):
        name = node.__class__.__name__
        method = getattr(self, f'emit_{name}', None)
        if method is None:
            # See stdlib/transpile.clarity: a missing case is a hole in the
            # emitter, and a comment in its place silently drops the code.
            line = getattr(node, 'line', 0) or 0
            raise TranspileError(
                f'no case for statement node {name} (line {line}). The emitter '
                f'needs one; a comment in its place would silently drop this code.')
        result = method(node)
        # Emit source location comment for debuggable stack traces
        line = getattr(node, 'line', None)
        if line is not None:
            result = f'{self._indent()}/*@{self.module_name}:{line}*/\n{result}'
        return result

    def emit_ExpressionStatement(self, node):
        return f'{self._indent()}{self.emit_expr(node.expression)};'

    def emit_LetStatement(self, node):
        # Use 'let' for all declarations in bootstrap build — some Clarity source
        # reassigns 'let' variables which would fail with JS 'const'
        val = self.emit_expr(node.value)
        name = self._safe_name(node.name)
        export = 'export ' if self.indent == 0 else ''
        return f'{self._indent()}{export}let {name} = {val};'

    def emit_DestructureLetStatement(self, node):
        keyword = 'let'
        export = 'export ' if self.indent == 0 else ''
        val = self.emit_expr(node.value)
        if node.kind == 'list':
            targets = ', '.join(self._safe_name(t) if isinstance(t, str) else self.emit_expr(t) for t in node.targets)
            return f'{self._indent()}{export}{keyword} [{targets}] = {val};'
        else:
            targets = ', '.join(self._safe_name(t) if isinstance(t, str) else self.emit_expr(t) for t in node.targets)
            return f'{self._indent()}{export}{keyword} {{{targets}}} = {val};'

    def emit_AssignStatement(self, node):
        target = self._emit_assign_target(node.target)
        val = self.emit_expr(node.value)
        op = node.operator
        return f'{self._indent()}{target} {op} {val};'

    def emit_MultiAssignStatement(self, node):
        lines = []
        for t, v in zip(node.targets, node.values):
            lines.append(f'{self._indent()}{self._emit_assign_target(t)} = {self.emit_expr(v)};')
        return '\n'.join(lines)

    def _emit_assign_target(self, target):
        if isinstance(target, ast.IndexExpression):
            return self._emit_index_lhs(target)
        return self.emit_expr(target)

    def emit_FnStatement(self, node):
        name = self._safe_name(node.name)
        params = ', '.join(self._emit_param(p) for p in node.params)
        prefix = 'async ' if node.is_async else ''
        export = 'export ' if self.indent == 0 else ''
        body = self._emit_block_body(node.body)
        return f'{self._indent()}{export}{prefix}function {name}({params}) {{\n{body}\n{self._indent()}}}'

    def emit_ReturnStatement(self, node):
        if node.value:
            return f'{self._indent()}return {self.emit_expr(node.value)};'
        return f'{self._indent()}return;'

    def emit_IfStatement(self, node):
        cond = self.emit_expr(node.condition)
        body = self._emit_block_body(node.body)
        result = f'{self._indent()}if ($truthy({cond})) {{\n{body}\n{self._indent()}}}'

        if node.elif_clauses:
            for elif_cond, elif_body in node.elif_clauses:
                c = self.emit_expr(elif_cond)
                b = self._emit_block_body(elif_body)
                result += f' else if ($truthy({c})) {{\n{b}\n{self._indent()}}}'

        if node.else_body:
            b = self._emit_block_body(node.else_body)
            result += f' else {{\n{b}\n{self._indent()}}}'

        return result

    def emit_ForStatement(self, node):
        var = self._safe_name(node.variable)
        iterable = self.emit_expr(node.iterable)
        body = self._emit_block_body(node.body)
        return f'{self._indent()}for (let {var} of {iterable}) {{\n{body}\n{self._indent()}}}'

    def emit_WhileStatement(self, node):
        cond = self.emit_expr(node.condition)
        body = self._emit_block_body(node.body)
        return f'{self._indent()}while ($truthy({cond})) {{\n{body}\n{self._indent()}}}'

    def emit_TryCatch(self, node):
        try_body = self._emit_block_body(node.try_body)
        var = self._safe_name(node.catch_var) if node.catch_var else '_e'
        catch_body = self._emit_block_body(node.catch_body)
        result = f'{self._indent()}try {{\n{try_body}\n{self._indent()}}}'
        result += f' catch ({var}) {{\n{catch_body}\n{self._indent()}}}'
        if node.finally_body:
            fin = self._emit_block_body(node.finally_body)
            result += f' finally {{\n{fin}\n{self._indent()}}}'
        return result

    def emit_BreakStatement(self, node):
        return f'{self._indent()}break;'

    def emit_ContinueStatement(self, node):
        return f'{self._indent()}continue;'

    def emit_ThrowStatement(self, node):
        val = self.emit_expr(node.value)
        return f'{self._indent()}throw {val};'

    def emit_ShowStatement(self, node):
        vals = ', '.join(self.emit_expr(v) for v in node.values)
        return f'{self._indent()}$show({vals});'

    def emit_ImportStatement(self, node):
        if node.path:
            # File import: from "file.clarity" import x, y
            self.imports.add(node.path)
            js_path = node.path.replace('.clarity', '.js')
            if not js_path.startswith('./') and not js_path.startswith('/'):
                js_path = './' + js_path
            if node.names:
                names = ', '.join(self._safe_name(n) for n in node.names)
                import_line = f'import {{ {names} }} from "{js_path}";'
            else:
                alias = self._safe_name(node.alias or node.path.replace('.clarity', ''))
                import_line = f'import * as {alias} from "{js_path}";'
            # JS imports must be at module top level — hoist if nested
            if self.indent > 0:
                self.hoisted_imports.append(import_line)
                return f'{self._indent()}/* import hoisted: {js_path} */'
            return f'{self._indent()}{import_line}'
        elif node.module:
            # Module import: import math
            return f'{self._indent()}// module import: {node.module} (provided by runtime)'
        return f'{self._indent()}/* import */'

    def emit_ClassStatement(self, node):
        name = self._safe_name(node.name)
        self.classes.add(node.name)
        parent = f' extends {self._safe_name(node.parent)}' if node.parent else ''
        export = 'export ' if self.indent == 0 else ''
        lines = [f'{self._indent()}{export}class {name}{parent} {{']
        self.indent += 1
        for method in node.methods:
            if isinstance(method, ast.FnStatement):
                mname = method.name
                if mname == 'init':
                    mname = 'constructor'
                params = ', '.join(self._emit_param(p) for p in method.params)
                body = self._emit_block_body(method.body)
                lines.append(f'{self._indent()}{mname}({params}) {{')
                lines.append(body)
                lines.append(f'{self._indent()}}}')
        self.indent -= 1
        lines.append(f'{self._indent()}}}')
        return '\n'.join(lines)

    def emit_InterfaceStatement(self, node):
        return f'{self._indent()}/* interface {node.name} */'

    def emit_MatchStatement(self, node):
        subject = self.emit_expr(node.subject)
        tmp = '__match_val'
        lines = [f'{self._indent()}let {tmp} = {subject};']
        first = True
        for arm in node.arms:
            if len(arm) == 3:
                pattern, guard, body = arm
            else:
                pattern, body = arm[0], arm[1]
                guard = None
            kw = 'if' if first else 'else if'
            pat = self.emit_expr(pattern)
            cond = f'{tmp} === {pat}'
            if guard:
                cond += f' && $truthy({self.emit_expr(guard)})'
            b = self._emit_block_body(body)
            lines.append(f'{self._indent()}{kw} ({cond}) {{')
            lines.append(b)
            lines.append(f'{self._indent()}}}')
            first = False
        if node.default:
            b = self._emit_block_body(node.default)
            lines.append(f'{self._indent()}else {{')
            lines.append(b)
            lines.append(f'{self._indent()}}}')
        return '\n'.join(lines)

    def emit_EnumStatement(self, node):
        name = self._safe_name(node.name)
        members = []
        for i, (mname, mval) in enumerate(node.members):
            if mval is not None:
                members.append(f'"{mname}": {self.emit_expr(mval)}')
            else:
                members.append(f'"{mname}": {i}')
        inner = ', '.join(members)
        export = 'export ' if self.indent == 0 else ''
        return f'{self._indent()}{export}let {name} = new $ClarityEnum("{node.name}", {{{inner}}});'

    def emit_DecoratedStatement(self, node):
        # Emit the target, then wrap it
        target_code = self.emit_stmt(node.target)
        name = node.target.name if hasattr(node.target, 'name') else None
        if name and node.decorators:
            lines = [target_code]
            for dec in reversed(node.decorators):
                dec_expr = self.emit_expr(dec)
                safe = self._safe_name(name)
                lines.append(f'{self._indent()}{safe} = {dec_expr}({safe});')
            return '\n'.join(lines)
        return target_code

    def emit_Block(self, node):
        return self._emit_block_body(node)

    # ── Expressions ───────────────────────────────────────

    def emit_expr(self, node):
        if node is None:
            return 'null'
        name = node.__class__.__name__
        method = getattr(self, f'expr_{name}', None)
        if method is None:
            line = getattr(node, 'line', 0) or 0
            raise TranspileError(
                f'no case for expression node {name} (line {line}). The emitter '
                f'needs one; a comment in its place would silently drop this code.')
        return method(node)

    def expr_NumberLiteral(self, node):
        return str(node.value)

    def expr_StringLiteral(self, node):
        # Convert Clarity string interpolation to JS template literals
        s = node.value
        if self._has_interpolation(s):
            # Replace {expr} with ${expr}
            result = self._convert_interpolation(s)
            return f'`{result}`'
        # Escape special characters for JS string literal
        escaped = s.replace('\\', '\\\\')
        escaped = escaped.replace('\n', '\\n')
        escaped = escaped.replace('\r', '\\r')
        escaped = escaped.replace('\t', '\\t')
        escaped = escaped.replace('\0', '\\0')
        escaped = escaped.replace('"', '\\"')
        return f'"{escaped}"'

    def _has_interpolation(self, s):
        """Check if a string contains Clarity interpolation {expr} vs literal braces.

        Skips ${...} ranges (JS template-literal syntax that may appear in
        embedded JS strings) so they don't trigger interpolation just because
        they happen to contain {letter."""
        import re
        i = 0
        while i < len(s):
            if s[i] == '$' and i + 1 < len(s) and s[i+1] == '{':
                depth = 1
                j = i + 2
                while j < len(s) and depth > 0:
                    if s[j] == '{': depth += 1
                    elif s[j] == '}': depth -= 1
                    j += 1
                i = j
            elif s[i] == '{' and i + 1 < len(s) and re.match(r'[a-zA-Z_]', s[i+1]):
                return True
            else:
                i += 1
        return False

    def expr_BoolLiteral(self, node):
        return 'true' if node.value else 'false'

    def expr_NullLiteral(self, node):
        return 'null'

    def expr_Identifier(self, node):
        return self._safe_name(node.name)

    def expr_ThisExpression(self, node):
        return 'this'

    def expr_ListLiteral(self, node):
        elements = []
        for el in node.elements:
            if isinstance(el, ast.SpreadExpression):
                elements.append(f'...{self.emit_expr(el.value)}')
            else:
                elements.append(self.emit_expr(el))
        return '[' + ', '.join(elements) + ']'

    def expr_MapLiteral(self, node):
        pairs = []
        for key, val in node.pairs:
            if key is None and isinstance(val, ast.SpreadExpression):
                pairs.append(f'...{self.emit_expr(val.value)}')
            else:
                k = self.emit_expr(key)
                v = self.emit_expr(val)
                pairs.append(f'[{k}]: {v}')
        return '{' + ', '.join(pairs) + '}'

    def expr_BinaryOp(self, node):
        left = self.emit_expr(node.left)
        right = self.emit_expr(node.right)
        op = node.operator

        # Equality must deep-compare arrays and plain maps
        if op in ('==', 'is'):
            return f'$eq({left}, {right})'
        if op == '!=':
            return f'$ne({left}, {right})'

        op_map = {
            'and': '&&', 'or': '||',
            '**': '**',
        }
        js_op = op_map.get(op, op)

        if op == '+':
            return f'({left} + {right})'
        return f'({left} {js_op} {right})'

    def expr_UnaryOp(self, node):
        operand = self.emit_expr(node.operand)
        op = node.operator
        if op == 'not':
            return f'(!$truthy({operand}))'
        return f'({op}{operand})'

    def expr_CallExpression(self, node):
        callee = self.emit_expr(node.callee)
        args = ', '.join(self.emit_expr(a) for a in node.arguments)
        # In Clarity, class instantiation looks like a function call.
        # In JS, classes require `new`.
        if isinstance(node.callee, ast.Identifier) and node.callee.name in self.classes:
            return f'new {callee}({args})'
        return f'{callee}({args})'

    def expr_MemberExpression(self, node):
        obj = self.emit_expr(node.object)
        prop = node.property
        # Don't rename properties — JS reserved words are fine as property names
        return f'{obj}.{prop}'

    def expr_OptionalMemberExpression(self, node):
        obj = self.emit_expr(node.object)
        prop = node.property
        return f'{obj}?.{prop}'

    def expr_IndexExpression(self, node):
        obj = self.emit_expr(node.object)
        idx = self.emit_expr(node.index)
        return f'$index({obj}, {idx})'

    def _emit_index_lhs(self, node):
        # Raw [] access for assignment targets — JS won't accept $index(...) on the LHS
        obj = self.emit_expr(node.object)
        idx = self.emit_expr(node.index)
        return f'{obj}[{idx}]'

    def expr_SliceExpression(self, node):
        obj = self.emit_expr(node.object)
        start = self.emit_expr(node.start) if node.start else '0'
        end = self.emit_expr(node.end) if node.end else ''
        if end:
            return f'{obj}.slice({start}, {end})'
        return f'{obj}.slice({start})'

    def expr_FnExpression(self, node):
        params = ', '.join(self._emit_param(p) for p in node.params)
        if len(node.body.statements) == 1 and isinstance(node.body.statements[0], ast.ReturnStatement):
            # Arrow function shorthand
            val = self.emit_expr(node.body.statements[0].value)
            return f'(({params}) => {val})'
        # Use arrow functions to preserve lexical `this` binding
        body = self._emit_block_body(node.body)
        return f'(({params}) => {{\n{body}\n{self._indent()}}})'

    def expr_PipeExpression(self, node):
        val = self.emit_expr(node.value)
        fn = node.function
        if isinstance(fn, ast.CallExpression):
            callee = self.emit_expr(fn.callee)
            args = ', '.join(self.emit_expr(a) for a in fn.arguments)
            if args:
                return f'{callee}({val}, {args})'
            return f'{callee}({val})'
        return f'{self.emit_expr(fn)}({val})'

    def expr_RangeExpression(self, node):
        start = self.emit_expr(node.start)
        end = self.emit_expr(node.end) if node.end else 'undefined'
        return f'$range({start}, {end})'

    def expr_AskExpression(self, node):
        prompt = self.emit_expr(node.prompt)
        return f'$ask({prompt})'

    def expr_NullCoalesce(self, node):
        left = self.emit_expr(node.left)
        right = self.emit_expr(node.right)
        return f'(({left}) ?? ({right}))'

    def expr_SpreadExpression(self, node):
        return f'...{self.emit_expr(node.value)}'

    def expr_IfExpression(self, node):
        cond = self.emit_expr(node.condition)
        true_expr = self.emit_expr(node.true_expr)
        false_expr = self.emit_expr(node.false_expr)
        return f'($truthy({cond}) ? {true_expr} : {false_expr})'

    def expr_ComprehensionExpression(self, node):
        var = self._safe_name(node.variable)
        iterable = self.emit_expr(node.iterable)
        expr = self.emit_expr(node.expr)
        if node.condition:
            cond = self.emit_expr(node.condition)
            return f'{iterable}.filter(({var}) => $truthy({cond})).map(({var}) => {expr})'
        return f'{iterable}.map(({var}) => {expr})'

    def expr_MapComprehensionExpression(self, node):
        var = self._safe_name(node.variables) if isinstance(node.variables, str) else ', '.join(self._safe_name(v) for v in node.variables)
        iterable = self.emit_expr(node.iterable)
        key_expr = self.emit_expr(node.key_expr)
        val_expr = self.emit_expr(node.value_expr)
        if node.condition:
            cond = self.emit_expr(node.condition)
            return f'Object.fromEntries({iterable}.filter(({var}) => $truthy({cond})).map(({var}) => [{key_expr}, {val_expr}]))'
        return f'Object.fromEntries({iterable}.map(({var}) => [{key_expr}, {val_expr}]))'

    def expr_AwaitExpression(self, node):
        return f'(await {self.emit_expr(node.value)})'

    def expr_YieldExpression(self, node):
        if node.value:
            return f'(yield {self.emit_expr(node.value)})'
        return '(yield)'

    # ── Helpers ───────────────────────────────────────────

    def _emit_block_body(self, block):
        self.indent += 1
        lines = []
        stmts = block.statements if hasattr(block, 'statements') else block.body if hasattr(block, 'body') else []
        for stmt in stmts:
            lines.append(self.emit_stmt(stmt))
        self.indent -= 1
        return '\n'.join(lines)

    def _emit_param(self, param):
        if isinstance(param, str):
            return self._safe_name(param)
        if isinstance(param, tuple):
            name, default = param[0], param[1] if len(param) > 1 else None
            if isinstance(name, str) and name.startswith('...'):
                return f'...{self._safe_name(name[3:])}'
            safe = self._safe_name(name) if isinstance(name, str) else str(name)
            if default is not None:
                return f'{safe} = {self.emit_expr(default)}'
            return safe
        return str(param)

    def _safe_name(self, name):
        """Rename Clarity identifiers that clash with JS reserved words or runtime."""
        if not isinstance(name, str):
            return str(name)
        js_reserved = {
            'int': '$int', 'float': '$float', 'bool': '$bool',
            'set': '$set', 'min': '$min', 'max': '$max',
            'join': '$join', 'repeat': '$repeat', 'range': '$range',
            'class': '$class', 'new': '$new', 'delete': '$delete',
            'switch': '$switch', 'case': '$case', 'default': '$default',
            'typeof': '$typeof', 'void': '$void', 'with': '$with',
            'yield': '$yield', 'debugger': '$debugger',
            'instanceof': '$instanceof', 'in': '$in',
            'var': '$var', 'const': '$const',
            'function': '$function', 'enum': '$enum',
            'implements': '$implements', 'interface': '$interface',
            'package': '$package', 'private': '$private',
            'protected': '$protected', 'public': '$public',
            'static': '$static', 'arguments': '$arguments',
            'eval': '$eval', 'import': '$import', 'export': '$export',
        }
        return js_reserved.get(name, name)

    def _convert_interpolation(self, s):
        """Convert Clarity string interpolation {expr} to JS template ${expr}."""
        import re
        result = []
        i = 0
        while i < len(s):
            if s[i] == '$' and i + 1 < len(s) and s[i+1] == '{':
                # Literal ${...} from source — escape the $ so the surrounding
                # JS template literal doesn't try to evaluate it.
                depth = 1
                j = i + 2
                while j < len(s) and depth > 0:
                    if s[j] == '{': depth += 1
                    elif s[j] == '}': depth -= 1
                    j += 1
                result.append('\\' + s[i:j])
                i = j
            elif s[i] == '{':
                # Find matching close brace
                depth = 1
                j = i + 1
                while j < len(s) and depth > 0:
                    if s[j] == '{': depth += 1
                    elif s[j] == '}': depth -= 1
                    j += 1
                expr = s[i+1:j-1]
                # Only treat as interpolation if content starts with identifier char
                if expr and re.match(r'^[a-zA-Z_]', expr):
                    result.append('${' + self._safe_name(expr) + '}')
                else:
                    # Literal braces — preserve them. Still escape any
                    # backticks inside, since the surrounding string is
                    # being emitted as a JS template literal.
                    result.append('{' + expr.replace('`', '\\`') + '}')
                i = j
            elif s[i] == '`':
                result.append('\\`')
                i += 1
            elif s[i] == '\\':
                result.append(s[i:i+2] if i + 1 < len(s) else '\\')
                i += 2
            else:
                result.append(s[i])
                i += 1
        return ''.join(result)


# ── Public API ────────────────────────────────────────────

_CLASS_NAME_CACHE = {}


def _collect_declarations(value, classes, imports):
    """Every ClassStatement name and every ImportStatement in a subtree,
    wherever they sit: an import inside a function body is hoisted to the
    top of the output, so a class it names needs `new` from that function
    just as from the top level. Nodes are walked by their fields."""
    if isinstance(value, list):
        for item in value:
            _collect_declarations(item, classes, imports)
        return
    if not isinstance(value, ast.Node):
        return
    if isinstance(value, ast.ClassStatement):
        classes.append(value.name)
    if isinstance(value, ast.ImportStatement):
        imports.append(value)
        return
    for field in getattr(value, '_fields', ()):
        _collect_declarations(getattr(value, field, None), classes, imports)


def _module_class_names(path):
    """The classes a sibling module declares at top level. A missing or
    unparseable module is not fatal here: the worst case is that a call
    keeps its plain-call form, which is what always happened before."""
    if path in _CLASS_NAME_CACHE:
        return _CLASS_NAME_CACHE[path]
    names = set()
    try:
        if os.path.exists(path):
            with open(path, encoding='utf-8') as f:
                src = f.read()
            for stmt in parse(tokenize(src, path), src).body:
                if isinstance(stmt, ast.ClassStatement):
                    names.add(stmt.name)
    except Exception:
        names = set()
    _CLASS_NAME_CACHE[path] = names
    return names


def transpile_source(source, filename="<input>", base_dir=None):
    """Transpile Clarity source code to JavaScript."""
    tokens = tokenize(source, filename)
    tree = parse(tokens, source)
    emitter = JSEmitter(module_name=filename, base_dir=base_dir)
    js_code = emitter.emit(tree)
    return js_code, emitter.imports


def transpile_file(path):
    """Transpile a .clarity file to .js."""
    with open(path, encoding='utf-8') as f:
        source = f.read()
    js_code, imports = transpile_source(source, os.path.basename(path), os.path.dirname(os.path.abspath(path)))
    return js_code, imports


def transpile_with_runtime(path):
    """Transpile a file and prepend the runtime import."""
    js_code, imports = transpile_file(path)

    # Add runtime imports
    header = (
        '// Generated by Clarity transpiler — do not edit\n'
        'import { show as $show, ask as $ask, read, write, append, exists, lines, read_bytes, write_bytes, read_mem, write_mem,\n'
        '  $int, $float, str, $bool, $eq, $ne, $index, type, len, push, pop, sort, reverse, range as $range,\n'
        '  map, filter, reduce, each, find, every, some, flat, zip, unique,\n'
        '  keys, values, entries, merge, has, split, $join, replace, trim,\n'
        '  upper, lower, contains, starts, ends, chars, $repeat,\n'
        '  pad_left, pad_right, char_at, char_code, from_char_code, index_of, substring,\n'
        '  is_digit, is_alpha, is_alnum, is_space,\n'
        '  abs, round, floor, ceil, $min, $max, sum, random, pow,\n'
        '  pi, e, sqrt, sin, cos, tan, log,\n'
        '  exec, exec_full, exec_tty, exit, sleep, time, env, args, cwd,\n'
        '  json_parse, json_string, hash, encode64, decode64,\n'
        '  fetch, serve, compose, tap, $set, error as $error,\n'
        '  regex_match, regex_search, regex_find, regex_replace, regex_split, exec_full_regex,\n'
        '  print,\n'
        '  display, repr, identical, truthy as $truthy, ClarityEnum as $ClarityEnum,\n'
        '  ClarityInstance as $ClarityInstance,\n'
        '  _ffi_open, _ffi_bind, _ffi_close,\n'
        '  _ffi_alloc, _ffi_alloc_cstring, _ffi_read_cstring, _ffi_ptr_addr, _ffi_pointer_release,\n'
        '  _ffi_read_u8, _ffi_read_i8, _ffi_read_u16, _ffi_read_i16,\n'
        '  _ffi_read_u32, _ffi_read_i32, _ffi_read_u64, _ffi_read_i64,\n'
        '  _ffi_read_f32, _ffi_read_f64, _ffi_read_ptr,\n'
        '  _ffi_write_u8, _ffi_write_i8, _ffi_write_u16, _ffi_write_i16,\n'
        '  _ffi_write_u32, _ffi_write_i32, _ffi_write_u64, _ffi_write_i64,\n'
        '  _ffi_write_f32, _ffi_write_f64,\n'
        '  _ffi_callback, _ffi_callback_close,\n'
        '  _ffi_fill_u32, _ffi_blend_u32, _ffi_box_blur, _ffi_blit_scaled_alpha, _ffi_copy, _ffi_write_buffer, _ffi_read_buffer,\n'
        '  _pty_supported, _pty_spawn, _pty_read, _pty_write, _pty_resize, _pty_poll, _pty_close,\n'
        '  _host_supported, _host_open, _host_present, _host_poll, _host_ticks, _host_delay, _host_close,\n'
        '  _embedded_source, _register_embedded_stdlib, _host_exe,\n'
        '  formatClarityError, clarityMain\n'
        '} from "./runtime.js";\n\n'
    )

    return header + js_code


# ── CLI ───────────────────────────────────────────────────

def main():
    import argparse
    ap = argparse.ArgumentParser(description='Clarity → JavaScript transpiler')
    ap.add_argument('file', nargs='?', help='Clarity source file to transpile')
    ap.add_argument('--bundle', action='store_true', help='Bundle CLI + stdlib into single JS')
    ap.add_argument('--compile', action='store_true', help='Compile to native binary via Bun')
    ap.add_argument('--out', '-o', help='Output path')
    args = ap.parse_args()

    if args.file:
        js = transpile_with_runtime(args.file)
        out = args.out or args.file.replace('.clarity', '.js')
        with open(out, 'w', encoding='utf-8') as f:
            f.write(js)
        print(f'  Transpiled: {args.file} → {out}')

    elif args.bundle:
        bundle(compile_native=args.compile)

    else:
        ap.print_help()


def bundle_module_list(stdlib_dir):
    """The modules a bundle ships: every non-test file under stdlib/, plus
    any test_ module a non-test module imports (the CLI imports test_smoke).

    Derived from the directory rather than listed by hand. Two hand-kept
    lists, this one and STDLIB_FILES in stdlib/transpile.clarity, disagreed
    for months: twelve modules the CLI imports were only in one, the whole
    RE toolkit was in neither, and a bundle produced by the self-hosted
    compiler could not start. The same rule, implemented in both places, is
    what keeps them equal; CI checks that the two emitted sets match.
    """
    import re as _re
    names = sorted(f for f in os.listdir(stdlib_dir) if f.endswith('.clarity'))
    mods = [n for n in names if not n.startswith('test_')]
    imp = _re.compile(r'from\s+"([^"]+)"\s+import')
    extra = set()
    for n in mods:
        with open(os.path.join(stdlib_dir, n), encoding='utf-8') as f:
            for target in imp.findall(f.read()):
                base = os.path.basename(target)
                if base.startswith('test_') and base in names:
                    extra.add(base)
    return mods + sorted(extra)


def bundle(compile_native=False):
    """Bundle the entire Clarity CLI + stdlib into a single JS program."""
    import subprocess

    project_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    native_dir = os.path.join(project_root, 'native')
    stdlib_dir = os.path.join(project_root, 'stdlib')
    dist_dir = os.path.join(native_dir, 'dist')
    os.makedirs(dist_dir, exist_ok=True)

    stdlib_files = bundle_module_list(stdlib_dir)

    # De-collision: a Clarity `fn max` transpiles to `export function $max`
    # while the header also imports `$max` from the runtime — a redeclaration
    # that ESM bundlers reject once the file is reachable from the compile
    # entry. The local definition shadows the builtin anyway, so drop the
    # colliding name from the runtime import. (build_web.sh does the same for
    # the browser bundle.)
    import re as _re
    def _decollide(txt):
        locals_ = set(_re.findall(r'^export\s+function\s+(\$?\w+)', txt, _re.M))
        locals_ |= set(_re.findall(r'^function\s+(\$?\w+)', txt, _re.M))
        m = _re.search(r"import\s*\{([^}]*)\}\s*from\s*['\"]\./runtime\.js['\"]", txt)
        if not m:
            return txt
        kept = []
        for part in m.group(1).split(','):
            p = part.strip()
            if not p:
                continue
            name = p.split(' as ')[-1].strip() if ' as ' in p else p
            if name in locals_:
                continue
            kept.append(p)
        new_import = 'import { ' + ', '.join(kept) + ' } from "./runtime.js"'
        return txt[:m.start()] + new_import + txt[m.end():]

    print('  Transpiling stdlib...')
    for fname in stdlib_files:
        src = os.path.join(stdlib_dir, fname)
        # A module that fails to transpile used to be printed as SKIP and the
        # bundle declared ready. That is a hole in the binary nothing reports
        # until an import fails at runtime, so it is fatal now.
        try:
            js = _decollide(transpile_with_runtime(src))
        except Exception as e:
            raise SystemExit(f'transpile --bundle: {fname} failed to transpile: {e}')
        out = os.path.join(dist_dir, fname.replace('.clarity', '.js'))
        with open(out, 'w', encoding='utf-8') as f:
            f.write(js)
        print(f'    {fname} -> {os.path.basename(out)}')

    # The sources themselves, so the binary can import its own library from
    # anywhere. Only the modules the bundle ships, in the same order; a
    # module missing from here would be one an installed binary cannot import.
    import json
    sources = os.path.join(dist_dir, 'stdlib_sources.js')
    with open(sources, 'w', encoding='utf-8') as f:
        f.write('// Generated by the Clarity bundler: the standard library, as source.\n')
        f.write('export const STDLIB_SOURCES = {\n')
        for fname in stdlib_files:
            if fname.startswith('test_'):
                continue
            with open(os.path.join(stdlib_dir, fname), encoding='utf-8') as src:
                f.write('  %s: %s,\n' % (json.dumps(fname), json.dumps(src.read())))
        f.write('};\n')
    print('    stdlib_sources.js created')

    # Copy runtime
    import shutil
    runtime_src = os.path.join(native_dir, 'runtime.js')
    runtime_dst = os.path.join(dist_dir, 'runtime.js')
    shutil.copy2(runtime_src, runtime_dst)
    print(f'    runtime.js copied')

    # Create entry point
    entry = os.path.join(dist_dir, 'clarity-entry.js')
    with open(entry, 'w', encoding='utf-8') as f:
        f.write('#!/usr/bin/env bun\n')
        f.write('// Clarity native entry point\n')
        f.write('import { clarityMain, _register_embedded_stdlib } from "./runtime.js";\n')
        f.write('import { STDLIB_SOURCES } from "./stdlib_sources.js";\n')
        f.write('_register_embedded_stdlib(STDLIB_SOURCES);\n')
        f.write('clarityMain(() => {\n')
        f.write('  import("./cli.js");\n')
        f.write('});\n')
    print(f'    clarity-entry.js created')

    # Create package.json for the bundle
    pkg_json = os.path.join(dist_dir, 'package.json')
    with open(pkg_json, 'w', encoding='utf-8') as f:
        f.write('{"type": "module"}\n')

    if compile_native:
        print()
        print('  Compiling to native binary...')
        out_bin = os.path.join(dist_dir, 'clarity')
        # Find bun — check PATH first, then common install locations
        import shutil
        bun = shutil.which('bun')
        if not bun:
            home = os.path.expanduser('~')
            for candidate in [
                os.path.join(home, '.bun', 'bin', 'bun'),
                '/usr/local/bin/bun',
            ]:
                if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
                    bun = candidate
                    break
        if not bun:
            print('  ERROR: Bun not found. Install it:')
            print('    curl -fsSL https://bun.sh/install | bash')
            print('  Then either restart your shell or run:')
            print('    export PATH="$HOME/.bun/bin:$PATH"')
            return
        # Build targets: current platform + cross-compile for macOS/Linux
        targets = [
            ('clarity',              None),                # current platform
            ('clarity-macos-arm64',  'bun-darwin-arm64'),  # macOS Apple Silicon
            ('clarity-macos-x64',    'bun-darwin-x64'),    # macOS Intel
            ('clarity-linux-x64',    'bun-linux-x64'),     # Linux x64
            ('clarity-linux-arm64',  'bun-linux-arm64'),   # Linux ARM64
        ]
        try:
            for bin_name, target in targets:
                out = os.path.join(dist_dir, bin_name)
                cmd = [bun, 'build', '--compile', entry, '--outfile', out]
                if target:
                    cmd += [f'--target={target}']
                subprocess.check_call(cmd, cwd=dist_dir)
                size = os.path.getsize(out) / (1024 * 1024)
                print(f'  {bin_name} ({size:.1f} MB)')
            print()
            print('  Install (pick the right one for your platform):')
            print(f'    sudo cp {os.path.join(dist_dir, "clarity-macos-arm64")} /usr/local/bin/clarity')
            print('    clarity shell')
        except FileNotFoundError:
            print('  ERROR: Bun not found. Install it:')
            print('    curl -fsSL https://bun.sh/install | bash')
        except subprocess.CalledProcessError as e:
            print(f'  ERROR: Bun compile failed: {e}')
    else:
        print()
        print(f'  Bundle ready at: {dist_dir}/')
        print(f'  Run with:   bun {entry}')
        print(f'  Compile:    bun build --compile {entry} --outfile clarity')


if __name__ == '__main__':
    main()
