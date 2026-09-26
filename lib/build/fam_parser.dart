import 'dart:collection';
import 'dart:convert';
import 'dart:io';

class FamParseException implements Exception {
  const FamParseException(this.message);

  final String message;

  @override
  String toString() => message;
}

class FamCall {
  const FamCall(this.name, this.args, this.kwargs);

  final String name;
  final List<Object?> args;
  final Map<String, Object?> kwargs;

  Object? operator [](String key) => kwargs[key];
}

class FamName {
  const FamName(this.value);

  final String value;

  String get tail => value.contains('.') ? value.split('.').last : value;

  @override
  String toString() => value;
}

abstract final class FamParser {
  static List<FamCall> parseCalls(
    String source,
    Set<String> names, {
    String? manifestPath,
    Map<String, String> environment = const {},
  }) {
    final program = _Parser(_Lexer(source).tokenize()).parseProgram();
    return _Interpreter(
      manifestPath: manifestPath,
      environment: environment,
    ).run(program, names);
  }
}

Never _fail(int line, String message) =>
    throw FamParseException('application.fam:$line: $message');

enum _T { name, number, string, op, newline, indent, dedent, eof }

class _Token {
  const _Token(this.type, this.text, this.line, [this.value]);

  final _T type;
  final String text;
  final int line;
  final Object? value;
}

class _StringToken {
  const _StringToken(this.body, this.raw, this.formatted);

  final String body;
  final bool raw;
  final bool formatted;
}

const _operators = [
  '**=',
  '//=',
  '>>=',
  '<<=',
  '==',
  '!=',
  '<=',
  '>=',
  '+=',
  '-=',
  '*=',
  '/=',
  '%=',
  '&=',
  '|=',
  '^=',
  '//',
  '**',
  '->',
  '<<',
  '>>',
  ':=',
  '+',
  '-',
  '*',
  '/',
  '%',
  '<',
  '>',
  '=',
  '(',
  ')',
  '[',
  ']',
  '{',
  '}',
  ',',
  ':',
  '.',
  ';',
  '@',
  '~',
  '|',
  '&',
  '^',
];

const _stringPrefixes = {'r', 'u', 'f', 'b', 'rb', 'br', 'fr', 'rf'};

class _Lexer {
  _Lexer(this._src, [this._line = 1]);

  final String _src;
  int _line;
  int _pos = 0;
  int _depth = 0;
  bool _lineStart = true;
  final _indents = [0];
  final _tokens = <_Token>[];

  List<_Token> tokenize() {
    while (_pos < _src.length) {
      if (_lineStart) {
        _lineStart = false;
        if (_depth == 0 && _indentation()) continue;
      }
      final c = _src[_pos];
      if (c == ' ' || c == '\t' || c == '\r' || c == '\f') {
        _pos++;
      } else if (c == '#') {
        while (_pos < _src.length && _src[_pos] != '\n') {
          _pos++;
        }
      } else if (c == '\\' && _continuation(_pos + 1)) {
        continue;
      } else if (c == '\n') {
        _pos++;
        if (_depth == 0) {
          _newline();
          _lineStart = true;
        }
        _line++;
      } else if (_isDigit(c) ||
          (c == '.' && _pos + 1 < _src.length && _isDigit(_src[_pos + 1]))) {
        _number();
      } else if (_isIdentStart(c)) {
        _word();
      } else if (c == '"' || c == "'") {
        _string('');
      } else {
        _operator();
      }
    }
    _newline();
    while (_indents.length > 1) {
      _indents.removeLast();
      _add(_T.dedent, '');
    }
    _add(_T.eof, '');
    return _tokens;
  }

  void _add(_T type, String text, [Object? value]) =>
      _tokens.add(_Token(type, text, _line, value));

  void _newline() {
    if (_tokens.isEmpty) return;
    final last = _tokens.last.type;
    if (last == _T.newline || last == _T.indent || last == _T.dedent) return;
    _add(_T.newline, '');
  }

  bool _continuation(int at) {
    var p = at;
    if (p < _src.length && _src[p] == '\r') p++;
    if (p >= _src.length || _src[p] != '\n') return false;
    _pos = p + 1;
    _line++;
    return true;
  }

  bool _indentation() {
    var width = 0;
    while (_pos < _src.length) {
      final c = _src[_pos];
      if (c == ' ') {
        width++;
      } else if (c == '\t') {
        width = (width ~/ 8 + 1) * 8;
      } else if (c == '\f') {
        width = 0;
      } else {
        break;
      }
      _pos++;
    }
    if (_pos >= _src.length) return true;
    final c = _src[_pos];
    if (c == '\n' || c == '\r' || c == '#') {
      while (_pos < _src.length && _src[_pos] != '\n') {
        _pos++;
      }
      if (_pos < _src.length) {
        _pos++;
        _line++;
      }
      _lineStart = true;
      return true;
    }
    if (width > _indents.last) {
      _indents.add(width);
      _add(_T.indent, '');
    } else {
      while (width < _indents.last) {
        _indents.removeLast();
        _add(_T.dedent, '');
      }
      if (width != _indents.last) {
        _fail(_line, 'unindent does not match any outer indentation level');
      }
    }
    return false;
  }

  void _number() {
    final start = _pos;
    if (_src[_pos] == '0' &&
        _pos + 1 < _src.length &&
        'xXoObB'.contains(_src[_pos + 1])) {
      final radix = switch (_src[_pos + 1].toLowerCase()) {
        'x' => 16,
        'o' => 8,
        _ => 2,
      };
      _pos += 2;
      while (_pos < _src.length &&
          (_isIdentPart(_src[_pos]) || _src[_pos] == '_')) {
        _pos++;
      }
      final digits = _src.substring(start + 2, _pos).replaceAll('_', '');
      final value = int.tryParse(digits, radix: radix);
      if (value == null) _fail(_line, 'invalid number literal');
      _add(_T.number, _src.substring(start, _pos), value);
      return;
    }
    var isDouble = false;
    _digits();
    if (_pos < _src.length && _src[_pos] == '.') {
      isDouble = true;
      _pos++;
      _digits();
    }
    if (_pos < _src.length && (_src[_pos] == 'e' || _src[_pos] == 'E')) {
      isDouble = true;
      _pos++;
      if (_pos < _src.length && (_src[_pos] == '+' || _src[_pos] == '-')) {
        _pos++;
      }
      _digits();
    }
    if (_pos < _src.length && _isIdentStart(_src[_pos])) {
      _fail(_line, 'invalid number literal');
    }
    final text = _src.substring(start, _pos);
    final clean = text.replaceAll('_', '');
    final Object? value = isDouble
        ? double.tryParse(clean)
        : int.tryParse(clean);
    if (value == null) _fail(_line, 'invalid number literal "$text"');
    _add(_T.number, text, value);
  }

  void _digits() {
    while (_pos < _src.length && (_isDigit(_src[_pos]) || _src[_pos] == '_')) {
      _pos++;
    }
  }

  void _word() {
    final start = _pos;
    while (_pos < _src.length && _isIdentPart(_src[_pos])) {
      _pos++;
    }
    final word = _src.substring(start, _pos);
    if (_pos < _src.length &&
        (_src[_pos] == '"' || _src[_pos] == "'") &&
        _stringPrefixes.contains(word.toLowerCase())) {
      _string(word.toLowerCase());
      return;
    }
    _add(_T.name, word);
  }

  void _string(String prefix) {
    final line = _line;
    final quote = _src[_pos];
    final terminator = _src.startsWith(quote * 3, _pos) ? quote * 3 : quote;
    _pos += terminator.length;
    final start = _pos;
    while (true) {
      if (_pos >= _src.length) _fail(line, 'unterminated string literal');
      final c = _src[_pos];
      if (c == '\\') {
        if (_pos + 1 < _src.length && _src[_pos + 1] == '\n') _line++;
        _pos += 2;
        continue;
      }
      if (_src.startsWith(terminator, _pos)) break;
      if (c == '\n') {
        if (terminator.length == 1) _fail(line, 'unterminated string literal');
        _line++;
      }
      _pos++;
    }
    final body = _src.substring(start, _pos);
    _pos += terminator.length;
    _tokens.add(
      _Token(
        _T.string,
        body,
        line,
        _StringToken(body, prefix.contains('r'), prefix.contains('f')),
      ),
    );
  }

  void _operator() {
    for (final op in _operators) {
      if (_src.startsWith(op, _pos)) {
        _pos += op.length;
        if (op == '(' || op == '[' || op == '{') _depth++;
        if ((op == ')' || op == ']' || op == '}') && _depth > 0) _depth--;
        _add(_T.op, op);
        return;
      }
    }
    _fail(_line, 'unexpected character "${_src[_pos]}"');
  }
}

bool _isDigit(String c) => c.codeUnitAt(0) ^ 0x30 <= 9;

bool _isIdentStart(String c) {
  final code = c.codeUnitAt(0);
  return (code >= 0x41 && code <= 0x5A) ||
      (code >= 0x61 && code <= 0x7A) ||
      code == 0x5F ||
      code >= 0x80;
}

bool _isIdentPart(String c) => _isIdentStart(c) || _isDigit(c);

String _unescape(String s) {
  if (!s.contains('\\')) return s;
  final out = StringBuffer();
  var i = 0;
  while (i < s.length) {
    final c = s[i++];
    if (c != '\\' || i >= s.length) {
      out.write(c);
      continue;
    }
    final n = s[i++];
    switch (n) {
      case '\n':
        break;
      case '\r':
        if (i < s.length && s[i] == '\n') i++;
      case '\\' || "'" || '"':
        out.write(n);
      case 'n':
        out.write('\n');
      case 't':
        out.write('\t');
      case 'r':
        out.write('\r');
      case 'a':
        out.write('\x07');
      case 'b':
        out.write('\b');
      case 'f':
        out.write('\f');
      case 'v':
        out.write('\v');
      case 'x' || 'u' || 'U':
        final width = switch (n) {
          'x' => 2,
          'u' => 4,
          _ => 8,
        };
        final code = i + width <= s.length
            ? int.tryParse(s.substring(i, i + width), radix: 16)
            : null;
        if (code == null) {
          throw const FamParseException(
            'application.fam: truncated \\x/\\u escape in a string',
          );
        }
        out.writeCharCode(code);
        i += width;
      default:
        if (n.codeUnitAt(0) >= 0x30 && n.codeUnitAt(0) <= 0x37) {
          var end = i;
          while (end < s.length &&
              end < i + 2 &&
              s.codeUnitAt(end) >= 0x30 &&
              s.codeUnitAt(end) <= 0x37) {
            end++;
          }
          out.writeCharCode(int.parse(n + s.substring(i, end), radix: 8));
          i = end;
        } else {
          out
            ..write('\\')
            ..write(n);
        }
    }
  }
  return out.toString();
}

sealed class _Expr {
  const _Expr(this.line);

  final int line;
}

class _Const extends _Expr {
  const _Const(super.line, this.value);

  final Object? value;
}

class _Name extends _Expr {
  const _Name(super.line, this.id);

  final String id;
}

class _FPart {
  const _FPart(this.expr, this.conversion);

  final _Expr expr;
  final String? conversion;
}

class _FString extends _Expr {
  const _FString(super.line, this.parts);

  final List<Object> parts;
}

class _ListE extends _Expr {
  const _ListE(super.line, this.items);

  final List<_Expr> items;
}

class _TupleE extends _Expr {
  const _TupleE(super.line, this.items);

  final List<_Expr> items;
}

class _DictE extends _Expr {
  const _DictE(super.line, this.keys, this.values);

  final List<_Expr> keys;
  final List<_Expr> values;
}

class _CompFor {
  const _CompFor(this.target, this.iter, this.conditions);

  final _Expr target;
  final _Expr iter;
  final List<_Expr> conditions;
}

class _ListComp extends _Expr {
  const _ListComp(super.line, this.element, this.clauses);

  final _Expr element;
  final List<_CompFor> clauses;
}

class _Attr extends _Expr {
  const _Attr(super.line, this.object, this.name);

  final _Expr object;
  final String name;
}

class _Index extends _Expr {
  const _Index(super.line, this.object, this.index);

  final _Expr object;
  final _Expr index;
}

class _Slice extends _Expr {
  const _Slice(super.line, this.lower, this.upper, this.step);

  final _Expr? lower;
  final _Expr? upper;
  final _Expr? step;
}

class _Call extends _Expr {
  const _Call(super.line, this.function, this.args, this.kwargs);

  final _Expr function;
  final List<_Expr> args;
  final Map<String, _Expr> kwargs;
}

class _Unary extends _Expr {
  const _Unary(super.line, this.op, this.operand);

  final String op;
  final _Expr operand;
}

class _Binary extends _Expr {
  const _Binary(super.line, this.op, this.left, this.right);

  final String op;
  final _Expr left;
  final _Expr right;
}

class _BoolOp extends _Expr {
  const _BoolOp(super.line, this.isAnd, this.left, this.right);

  final bool isAnd;
  final _Expr left;
  final _Expr right;
}

class _Compare extends _Expr {
  const _Compare(super.line, this.first, this.ops, this.rest);

  final _Expr first;
  final List<String> ops;
  final List<_Expr> rest;
}

class _IfExp extends _Expr {
  const _IfExp(super.line, this.condition, this.then, this.otherwise);

  final _Expr condition;
  final _Expr then;
  final _Expr otherwise;
}

sealed class _Stmt {
  const _Stmt(this.line);

  final int line;
}

class _ExprStmt extends _Stmt {
  const _ExprStmt(super.line, this.expr);

  final _Expr expr;
}

class _Assign extends _Stmt {
  const _Assign(super.line, this.targets, this.value);

  final List<_Expr> targets;
  final _Expr value;
}

class _AugAssign extends _Stmt {
  const _AugAssign(super.line, this.target, this.op, this.value);

  final _Expr target;
  final String op;
  final _Expr value;
}

class _If extends _Stmt {
  const _If(super.line, this.conditions, this.bodies, this.otherwise);

  final List<_Expr> conditions;
  final List<List<_Stmt>> bodies;
  final List<_Stmt> otherwise;
}

class _For extends _Stmt {
  const _For(super.line, this.target, this.iter, this.body, this.otherwise);

  final _Expr target;
  final _Expr iter;
  final List<_Stmt> body;
  final List<_Stmt> otherwise;
}

class _Param {
  const _Param(this.name, this.defaultValue);

  final String name;
  final _Expr? defaultValue;
}

class _Def extends _Stmt {
  const _Def(super.line, this.name, this.params, this.body);

  final String name;
  final List<_Param> params;
  final List<_Stmt> body;
}

class _Return extends _Stmt {
  const _Return(super.line, this.value);

  final _Expr? value;
}

class _With extends _Stmt {
  const _With(super.line, this.context, this.target, this.body);

  final _Expr context;
  final _Expr? target;
  final List<_Stmt> body;
}

class _Import extends _Stmt {
  const _Import(super.line, this.modules, this.aliases);

  final List<String> modules;
  final List<String?> aliases;
}

class _FromImport extends _Stmt {
  const _FromImport(super.line, this.module, this.names, this.aliases);

  final String module;
  final List<String> names;
  final List<String?> aliases;
}

class _Raise extends _Stmt {
  const _Raise(super.line, this.value);

  final _Expr? value;
}

class _Pass extends _Stmt {
  const _Pass(super.line);
}

class _Break extends _Stmt {
  const _Break(super.line);
}

class _Continue extends _Stmt {
  const _Continue(super.line);
}

const _keywords = {
  'and',
  'as',
  'assert',
  'async',
  'await',
  'break',
  'class',
  'continue',
  'def',
  'del',
  'elif',
  'else',
  'except',
  'finally',
  'for',
  'from',
  'global',
  'if',
  'import',
  'in',
  'is',
  'lambda',
  'nonlocal',
  'not',
  'or',
  'pass',
  'raise',
  'return',
  'try',
  'while',
  'with',
  'yield',
};

const _unsupportedStatements = {
  'assert',
  'async',
  'await',
  'class',
  'del',
  'global',
  'nonlocal',
  'try',
  'while',
  'yield',
};

const _augmentedOps = {'+=', '-=', '*=', '/=', '//=', '%='};

class _Parser {
  _Parser(this._t);

  final List<_Token> _t;
  int _i = 0;

  _Token get _cur => _t[_i];

  bool _isOp(String s) => _cur.type == _T.op && _cur.text == s;

  bool _isKw(String s) => _cur.type == _T.name && _cur.text == s;

  bool _acceptOp(String s) {
    if (!_isOp(s)) return false;
    _i++;
    return true;
  }

  bool _acceptKw(String s) {
    if (!_isKw(s)) return false;
    _i++;
    return true;
  }

  void _expectOp(String s) {
    if (!_acceptOp(s)) _error('expected "$s"');
  }

  void _expectKw(String s) {
    if (!_acceptKw(s)) _error('expected "$s"');
  }

  String _expectName() {
    final token = _cur;
    if (token.type != _T.name || _keywords.contains(token.text)) {
      _error('expected a name');
    }
    _i++;
    return token.text;
  }

  bool get _atLineEnd =>
      _cur.type == _T.newline || _cur.type == _T.eof || _isOp(';');

  Never _error(String message) {
    final token = _cur;
    final found = switch (token.type) {
      _T.newline => 'end of line',
      _T.eof => 'end of file',
      _T.indent => 'indent',
      _T.dedent => 'dedent',
      _ => '"${token.text}"',
    };
    _fail(token.line, '$message, found $found');
  }

  List<_Stmt> parseProgram() {
    final body = <_Stmt>[];
    while (_cur.type != _T.eof) {
      if (_cur.type == _T.newline) {
        _i++;
        continue;
      }
      body.addAll(_statement());
    }
    return body;
  }

  List<_Stmt> _statement() {
    if (_cur.type == _T.indent) _error('unexpected indent');
    if (_cur.type == _T.name) {
      switch (_cur.text) {
        case 'if':
          return [_if()];
        case 'for':
          return [_for()];
        case 'def':
          return [_def()];
        case 'with':
          return _with();
      }
    }
    return _simpleLine();
  }

  List<_Stmt> _simpleLine() {
    final statements = [_simple()];
    while (_acceptOp(';')) {
      if (_atLineEnd) break;
      statements.add(_simple());
    }
    if (_cur.type == _T.newline) {
      _i++;
    } else if (_cur.type != _T.eof) {
      _error('expected end of statement');
    }
    return statements;
  }

  List<_Stmt> _block() {
    _expectOp(':');
    if (_cur.type != _T.newline) return _simpleLine();
    _i++;
    if (_cur.type != _T.indent) _error('expected an indented block');
    _i++;
    final body = <_Stmt>[];
    while (_cur.type != _T.dedent && _cur.type != _T.eof) {
      if (_cur.type == _T.newline) {
        _i++;
        continue;
      }
      body.addAll(_statement());
    }
    if (_cur.type == _T.dedent) _i++;
    return body;
  }

  _Stmt _if() {
    final line = _cur.line;
    _i++;
    final conditions = [_expr()];
    final bodies = [_block()];
    var otherwise = <_Stmt>[];
    while (true) {
      if (_acceptKw('elif')) {
        conditions.add(_expr());
        bodies.add(_block());
      } else if (_acceptKw('else')) {
        otherwise = _block();
        break;
      } else {
        break;
      }
    }
    return _If(line, conditions, bodies, otherwise);
  }

  _Stmt _for() {
    final line = _cur.line;
    _i++;
    final target = _targetList();
    _expectKw('in');
    final iter = _exprList();
    final body = _block();
    final otherwise = _acceptKw('else') ? _block() : <_Stmt>[];
    return _For(line, target, iter, body, otherwise);
  }

  _Stmt _def() {
    final line = _cur.line;
    _i++;
    final name = _expectName();
    _expectOp('(');
    final params = <_Param>[];
    while (!_acceptOp(')')) {
      if (_isOp('*') || _isOp('**')) {
        _fail(_cur.line, '*args and **kwargs are not supported');
      }
      final param = _expectName();
      final defaultValue = _acceptOp('=') ? _expr() : null;
      if (defaultValue == null &&
          params.isNotEmpty &&
          params.last.defaultValue != null) {
        _fail(line, 'parameter without a default follows parameter with one');
      }
      params.add(_Param(param, defaultValue));
      if (!_acceptOp(',')) {
        _expectOp(')');
        break;
      }
    }
    if (_acceptOp('->')) _expr();
    return _Def(line, name, params, _block());
  }

  List<_Stmt> _with() {
    final line = _cur.line;
    _i++;
    final items = <(_Expr, _Expr?)>[];
    do {
      final context = _expr();
      final target = _acceptKw('as') ? _targetList() : null;
      items.add((context, target));
    } while (_acceptOp(','));
    var body = _block();
    for (final (context, target) in items.reversed) {
      body = [_With(line, context, target, body)];
    }
    return body;
  }

  _Stmt _simple() {
    final token = _cur;
    final line = token.line;
    if (token.type == _T.name) {
      switch (token.text) {
        case 'pass':
          _i++;
          return _Pass(line);
        case 'break':
          _i++;
          return _Break(line);
        case 'continue':
          _i++;
          return _Continue(line);
        case 'return':
          _i++;
          return _Return(line, _atLineEnd ? null : _exprList());
        case 'raise':
          _i++;
          final value = _atLineEnd ? null : _expr();
          if (_isKw('from')) _fail(line, '"raise ... from" is not supported');
          return _Raise(line, value);
        case 'import':
          _i++;
          return _import(line);
        case 'from':
          _i++;
          return _fromImport(line);
      }
      if (_unsupportedStatements.contains(token.text)) {
        _fail(line, '"${token.text}" is not supported in application.fam');
      }
    }

    final first = _exprList();
    if (_isOp('=')) {
      final targets = [first];
      while (_acceptOp('=')) {
        targets.add(_exprList());
      }
      final value = targets.removeLast();
      for (final target in targets) {
        _checkTarget(target);
      }
      return _Assign(line, targets, value);
    }
    if (_cur.type == _T.op && _augmentedOps.contains(_cur.text)) {
      final op = _cur.text.substring(0, _cur.text.length - 1);
      _i++;
      if (first is! _Name && first is! _Index) {
        _fail(line, 'illegal target for augmented assignment');
      }
      return _AugAssign(line, first, op, _exprList());
    }
    return _ExprStmt(line, first);
  }

  void _checkTarget(_Expr target) {
    switch (target) {
      case _Name() || _Index() || _Attr():
        return;
      case final _TupleE tuple:
        tuple.items.forEach(_checkTarget);
      case final _ListE list:
        list.items.forEach(_checkTarget);
      default:
        _fail(target.line, 'cannot assign to expression');
    }
  }

  String _dotted() {
    final parts = [_expectName()];
    while (_acceptOp('.')) {
      parts.add(_expectName());
    }
    return parts.join('.');
  }

  _Stmt _import(int line) {
    final modules = <String>[];
    final aliases = <String?>[];
    do {
      modules.add(_dotted());
      aliases.add(_acceptKw('as') ? _expectName() : null);
    } while (_acceptOp(','));
    return _Import(line, modules, aliases);
  }

  _Stmt _fromImport(int line) {
    if (_isOp('.')) _fail(line, 'relative imports are not supported');
    final module = _dotted();
    _expectKw('import');
    if (_isOp('*')) _fail(line, '"import *" is not supported');
    final parenthesized = _acceptOp('(');
    final names = <String>[];
    final aliases = <String?>[];
    do {
      if (parenthesized && _isOp(')')) break;
      names.add(_expectName());
      aliases.add(_acceptKw('as') ? _expectName() : null);
    } while (_acceptOp(','));
    if (parenthesized) _expectOp(')');
    return _FromImport(line, module, names, aliases);
  }

  bool get _endsExprList {
    if (_cur.type != _T.op) return _atLineEnd || _isKw('in');
    return !const {'(', '[', '{', '-', '+'}.contains(_cur.text);
  }

  _Expr _exprList() {
    final line = _cur.line;
    final first = _expr();
    if (!_isOp(',')) return first;
    final items = [first];
    while (_acceptOp(',')) {
      if (_endsExprList) break;
      items.add(_expr());
    }
    return _TupleE(line, items);
  }

  _Expr _targetList() {
    final line = _cur.line;
    final first = _primary();
    if (!_isOp(',')) return first;
    final items = [first];
    while (_acceptOp(',')) {
      if (_endsExprList) break;
      items.add(_primary());
    }
    final target = _TupleE(line, items);
    _checkTarget(target);
    return target;
  }

  _Expr _expr() {
    final line = _cur.line;
    if (_isKw('lambda')) _fail(line, 'lambda is not supported');
    final value = _orTest();
    if (!_acceptKw('if')) return value;
    final condition = _orTest();
    _expectKw('else');
    return _IfExp(line, condition, value, _expr());
  }

  _Expr _orTest() {
    var left = _andTest();
    while (_isKw('or')) {
      final line = _cur.line;
      _i++;
      left = _BoolOp(line, false, left, _andTest());
    }
    return left;
  }

  _Expr _andTest() {
    var left = _notTest();
    while (_isKw('and')) {
      final line = _cur.line;
      _i++;
      left = _BoolOp(line, true, left, _notTest());
    }
    return left;
  }

  _Expr _notTest() {
    if (_isKw('not')) {
      final line = _cur.line;
      _i++;
      return _Unary(line, 'not', _notTest());
    }
    return _comparison();
  }

  _Expr _comparison() {
    final line = _cur.line;
    final first = _arith();
    final ops = <String>[];
    final rest = <_Expr>[];
    while (true) {
      final op = _comparisonOp();
      if (op == null) break;
      ops.add(op);
      rest.add(_arith());
    }
    return ops.isEmpty ? first : _Compare(line, first, ops, rest);
  }

  String? _comparisonOp() {
    final token = _cur;
    if (token.type == _T.op &&
        const {'<', '>', '==', '>=', '<=', '!='}.contains(token.text)) {
      _i++;
      return token.text;
    }
    if (_acceptKw('in')) return 'in';
    if (_isKw('not') && _t[_i + 1].type == _T.name && _t[_i + 1].text == 'in') {
      _i += 2;
      return 'not in';
    }
    if (_acceptKw('is')) return _acceptKw('not') ? 'is not' : 'is';
    return null;
  }

  _Expr _arith() {
    var left = _term();
    while (_isOp('+') || _isOp('-')) {
      final token = _t[_i++];
      left = _Binary(token.line, token.text, left, _term());
    }
    return left;
  }

  _Expr _term() {
    var left = _factor();
    while (_isOp('*') || _isOp('/') || _isOp('//') || _isOp('%')) {
      final token = _t[_i++];
      left = _Binary(token.line, token.text, left, _factor());
    }
    return left;
  }

  _Expr _factor() {
    if (_isOp('-') || _isOp('+')) {
      final token = _t[_i++];
      return _Unary(token.line, token.text, _factor());
    }
    return _primary();
  }

  _Expr _primary() {
    var expr = _atom();
    while (true) {
      final line = _cur.line;
      if (_isOp('(')) {
        expr = _call(expr);
      } else if (_acceptOp('[')) {
        final index = _subscript();
        _expectOp(']');
        expr = _Index(line, expr, index);
      } else if (_acceptOp('.')) {
        expr = _Attr(line, expr, _expectName());
      } else {
        return expr;
      }
    }
  }

  _Expr _subscript() {
    final line = _cur.line;
    final lower = _isOp(':') ? null : _expr();
    if (!_acceptOp(':')) return lower!;
    final upper = _isOp(':') || _isOp(']') ? null : _expr();
    _Expr? step;
    if (_acceptOp(':')) step = _isOp(']') ? null : _expr();
    return _Slice(line, lower, upper, step);
  }

  _Expr _call(_Expr function) {
    final line = _cur.line;
    _i++;
    final args = <_Expr>[];
    final kwargs = <String, _Expr>{};
    while (!_acceptOp(')')) {
      if (_isOp('*') || _isOp('**')) {
        _fail(_cur.line, 'argument unpacking is not supported');
      }
      final next = _t[_i + 1];
      if (_cur.type == _T.name && next.type == _T.op && next.text == '=') {
        final name = _cur.text;
        _i += 2;
        if (kwargs.containsKey(name)) {
          _fail(line, 'keyword argument repeated: $name');
        }
        kwargs[name] = _expr();
      } else {
        if (kwargs.isNotEmpty) {
          _fail(_cur.line, 'positional argument follows keyword argument');
        }
        args.add(_expr());
        if (_isKw('for')) {
          _fail(_cur.line, 'generator expressions are not supported');
        }
      }
      if (!_acceptOp(',')) {
        _expectOp(')');
        break;
      }
    }
    return _Call(line, function, args, kwargs);
  }

  List<_CompFor> _compClauses() {
    final clauses = <_CompFor>[];
    while (_acceptKw('for')) {
      final target = _targetList();
      _expectKw('in');
      final iter = _orTest();
      final conditions = <_Expr>[];
      while (_acceptKw('if')) {
        conditions.add(_orTest());
      }
      clauses.add(_CompFor(target, iter, conditions));
    }
    return clauses;
  }

  _Expr _atom() {
    final token = _cur;
    final line = token.line;
    switch (token.type) {
      case _T.number:
        _i++;
        return _Const(line, token.value);
      case _T.string:
        return _strings();
      case _T.name:
        switch (token.text) {
          case 'True':
            _i++;
            return _Const(line, true);
          case 'False':
            _i++;
            return _Const(line, false);
          case 'None':
            _i++;
            return _Const(line, null);
          case 'lambda':
            _fail(line, 'lambda is not supported');
        }
        if (_keywords.contains(token.text)) _error('unexpected keyword');
        _i++;
        return _Name(line, token.text);
      case _T.op:
        if (_acceptOp('(')) return _parenthesized(line);
        if (_acceptOp('[')) return _list(line);
        if (_acceptOp('{')) return _dict(line);
      default:
    }
    _error('expected an expression');
  }

  _Expr _parenthesized(int line) {
    if (_acceptOp(')')) return _TupleE(line, const []);
    final first = _expr();
    if (_isKw('for')) _fail(line, 'generator expressions are not supported');
    final items = [first];
    var tuple = false;
    while (_acceptOp(',')) {
      tuple = true;
      if (_isOp(')')) break;
      items.add(_expr());
    }
    _expectOp(')');
    return tuple ? _TupleE(line, items) : first;
  }

  _Expr _list(int line) {
    if (_acceptOp(']')) return _ListE(line, const []);
    final first = _expr();
    if (_isKw('for')) {
      final clauses = _compClauses();
      _expectOp(']');
      return _ListComp(line, first, clauses);
    }
    final items = [first];
    while (_acceptOp(',')) {
      if (_isOp(']')) break;
      items.add(_expr());
    }
    _expectOp(']');
    return _ListE(line, items);
  }

  _Expr _dict(int line) {
    final keys = <_Expr>[];
    final values = <_Expr>[];
    while (!_acceptOp('}')) {
      keys.add(_expr());
      if (!_isOp(':')) _fail(line, 'set literals are not supported');
      _i++;
      values.add(_expr());
      if (_isKw('for')) {
        _fail(line, 'dict comprehensions are not supported');
      }
      if (!_acceptOp(',')) {
        _expectOp('}');
        break;
      }
    }
    return _DictE(line, keys, values);
  }

  _Expr _strings() {
    final line = _cur.line;
    final parts = <Object>[];
    var formatted = false;
    while (_cur.type == _T.string) {
      final token = _cur.value! as _StringToken;
      final tokenLine = _cur.line;
      _i++;
      if (token.formatted) {
        formatted = true;
        parts.addAll(_formatParts(token, tokenLine));
      } else {
        parts.add(token.raw ? token.body : _unescape(token.body));
      }
    }
    if (!formatted) return _Const(line, parts.cast<String>().join());
    return _FString(line, parts);
  }

  static List<Object> _formatParts(_StringToken token, int line) {
    final body = token.body;
    final parts = <Object>[];
    final literal = StringBuffer();

    void flush() {
      if (literal.isEmpty) return;
      final text = literal.toString();
      parts.add(token.raw ? text : _unescape(text));
      literal.clear();
    }

    var i = 0;
    while (i < body.length) {
      final c = body[i];
      if (c == '{' && i + 1 < body.length && body[i + 1] == '{') {
        literal.write('{');
        i += 2;
      } else if (c == '}' && i + 1 < body.length && body[i + 1] == '}') {
        literal.write('}');
        i += 2;
      } else if (c == '}') {
        _fail(line, "f-string: single '}' is not allowed");
      } else if (c == '{') {
        flush();
        var j = i + 1;
        var depth = 0;
        String? quote;
        while (j < body.length) {
          final ch = body[j];
          if (quote != null) {
            if (ch == quote) quote = null;
          } else if (ch == '"' || ch == "'") {
            quote = ch;
          } else if (ch == '(' || ch == '[' || ch == '{') {
            depth++;
          } else if (ch == ')' || ch == ']' || ch == '}') {
            if (depth == 0) break;
            depth--;
          } else if (depth == 0 &&
              ch == '!' &&
              j + 1 < body.length &&
              body[j + 1] != '=') {
            break;
          } else if (depth == 0 && ch == ':') {
            break;
          }
          j++;
        }
        final source = body.substring(i + 1, j);
        if (source.trim().isEmpty) {
          _fail(line, 'f-string: empty expression not allowed');
        }
        String? conversion;
        if (j < body.length && body[j] == '!') {
          conversion = j + 1 < body.length ? body[j + 1] : null;
          if (conversion != 'r' && conversion != 's' && conversion != 'a') {
            _fail(line, 'f-string: invalid conversion character');
          }
          j += 2;
        }
        if (j < body.length && body[j] == ':') {
          _fail(line, 'f-string format specifiers are not supported');
        }
        if (j >= body.length || body[j] != '}') {
          _fail(line, "f-string: expecting '}'");
        }
        final parser = _Parser(_Lexer('($source)', line).tokenize());
        final expr = parser._expr();
        if (parser._cur.type != _T.newline && parser._cur.type != _T.eof) {
          parser._error('f-string: invalid expression');
        }
        parts.add(_FPart(expr, conversion));
        i = j + 1;
      } else if (c == '\\' && !token.raw && i + 1 < body.length) {
        literal
          ..write(c)
          ..write(body[i + 1]);
        i += 2;
      } else {
        literal.write(c);
        i++;
      }
    }
    flush();
    return parts;
  }
}

class _Tuple extends ListBase<Object?> {
  _Tuple(Iterable<Object?> items) : _items = List.unmodifiable(items);

  final List<Object?> _items;

  @override
  int get length => _items.length;

  @override
  set length(int value) => throw UnsupportedError('tuple is immutable');

  @override
  Object? operator [](int index) => _items[index];

  @override
  void operator []=(int index, Object? value) =>
      throw UnsupportedError('tuple is immutable');
}

typedef _Native =
    Object? Function(List<Object?> args, Map<String, Object?> kwargs, int line);

class _Builtin {
  const _Builtin(this.name, this.call, [this.instanceCheck]);

  final String name;
  final _Native call;
  final bool Function(Object?)? instanceCheck;
}

class _Function {
  const _Function(
    this.name,
    this.params,
    this.defaults,
    this.body,
    this.closure,
  );

  final String name;
  final List<_Param> params;
  final List<Object?> defaults;
  final List<_Stmt> body;
  final _Scope closure;
}

class _Module {
  const _Module(this.name, this.attributes);

  final String name;
  final Map<String, Object?> attributes;
}

class _EnumNamespace {
  _EnumNamespace(this.name);

  final String name;
  final _members = <String, FamName>{};

  FamName member(String member) =>
      _members.putIfAbsent(member, () => FamName('$name.$member'));
}

class _ErrorType {
  const _ErrorType(this.name);

  final String name;
}

class _ErrorValue {
  const _ErrorValue(this.type, this.message);

  final _ErrorType type;
  final String message;
}

class _TextFile {
  const _TextFile(this.text);

  final String text;

  List<String> get lines {
    final lines = <String>[];
    var start = 0;
    while (start < text.length) {
      final end = text.indexOf('\n', start);
      if (end < 0) {
        lines.add(text.substring(start));
        break;
      }
      lines.add(text.substring(start, end + 1));
      start = end + 1;
    }
    return lines;
  }
}

class _Scope {
  _Scope(this.parent);

  final _Scope? parent;
  final vars = <String, Object?>{};
}

class _ReturnSignal implements Exception {
  const _ReturnSignal(this.value);

  final Object? value;
}

class _BreakSignal implements Exception {
  const _BreakSignal();
}

class _ContinueSignal implements Exception {
  const _ContinueSignal();
}

const _missing = Object();

const _maxCallDepth = 200;

const _maxRange = 1000000;

class _Interpreter {
  _Interpreter({required this.manifestPath, required this.environment});

  final String? manifestPath;
  final Map<String, String> environment;

  late final _Scope _builtins = _Scope(null)..vars.addAll(_builtinFunctions());
  late final _Scope _globals = _Scope(_builtins)
    ..vars.addAll({
      'os': _os,
      'FlipperAppType': _EnumNamespace('FlipperAppType'),
    });
  late final _Scope _locals = _Scope(_globals);
  late final _Module _osPath = _pathModule();
  late final _Module _os = _Module('os', {
    'path': _osPath,
    'environ': Map<Object?, Object?>.of(environment),
    'sep': Platform.pathSeparator,
  });
  int _depth = 0;

  List<FamCall> run(List<_Stmt> program, Set<String> names) {
    final calls = <FamCall>[];
    for (final name in {'Lib', 'ExtFile'}) {
      _locals.vars[name] = _Builtin(
        name,
        (args, kwargs, line) => FamCall(name, args, kwargs),
      );
    }
    for (final name in names) {
      _locals.vars[name] = _Builtin(name, (args, kwargs, line) {
        calls.add(FamCall(name, args, kwargs));
        return null;
      });
    }
    if (manifestPath != null) {
      _locals.vars['app_manifest_path'] = manifestPath;
    }
    try {
      _exec(program, _locals);
    } on _ReturnSignal {
      throw const FamParseException(
        "application.fam: 'return' outside function",
      );
    } on _BreakSignal {
      throw const FamParseException("application.fam: 'break' outside loop");
    } on _ContinueSignal {
      throw const FamParseException(
        "application.fam: 'continue' not properly in loop",
      );
    }
    return calls;
  }

  void _exec(List<_Stmt> body, _Scope scope) {
    for (final statement in body) {
      _statement(statement, scope);
    }
  }

  void _statement(_Stmt statement, _Scope scope) {
    final line = statement.line;
    switch (statement) {
      case final _ExprStmt s:
        _eval(s.expr, scope);
      case final _Assign s:
        final value = _eval(s.value, scope);
        for (final target in s.targets) {
          _assign(target, value, scope);
        }
      case final _AugAssign s:
        final target = s.target;
        if (target is _Name) {
          final current = _lookup(target.id, scope, line);
          scope.vars[target.id] = _augment(
            s.op,
            current,
            _eval(s.value, scope),
            line,
          );
        } else if (target is _Index) {
          final object = _eval(target.object, scope);
          final index = _eval(target.index, scope);
          final current = _getItem(object, index, line);
          _setItem(
            object,
            index,
            _augment(s.op, current, _eval(s.value, scope), line),
            line,
          );
        }
      case final _If s:
        for (var i = 0; i < s.conditions.length; i++) {
          if (_truthy(_eval(s.conditions[i], scope))) {
            _exec(s.bodies[i], scope);
            return;
          }
        }
        _exec(s.otherwise, scope);
      case final _For s:
        final items = _iterate(_eval(s.iter, scope), line);
        for (final item in items) {
          _assign(s.target, item, scope);
          try {
            _exec(s.body, scope);
          } on _BreakSignal {
            return;
          } on _ContinueSignal {
            continue;
          }
        }
        _exec(s.otherwise, scope);
      case final _Def s:
        final defaults = [
          for (final param in s.params)
            param.defaultValue == null
                ? _missing
                : _eval(param.defaultValue!, scope),
        ];
        final closure = identical(scope, _locals) ? _globals : scope;
        scope.vars[s.name] = _Function(
          s.name,
          s.params,
          defaults,
          s.body,
          closure,
        );
      case final _Return s:
        throw _ReturnSignal(s.value == null ? null : _eval(s.value!, scope));
      case final _With s:
        final context = _eval(s.context, scope);
        if (context is! _TextFile) {
          _fail(
            line,
            "'${_typeName(context)}' object does not support the context "
            'manager protocol',
          );
        }
        if (s.target != null) _assign(s.target!, context, scope);
        _exec(s.body, scope);
      case final _Import s:
        for (var i = 0; i < s.modules.length; i++) {
          final module = _module(s.modules[i], line);
          final alias = s.aliases[i];
          if (alias != null) {
            scope.vars[alias] = module;
          } else {
            scope.vars['os'] = _os;
          }
        }
      case final _FromImport s:
        final module = _module(s.module, line);
        for (var i = 0; i < s.names.length; i++) {
          final name = s.names[i];
          final value = module.attributes[name];
          if (value == null) {
            _fail(line, "cannot import name '$name' from '${module.name}'");
          }
          scope.vars[s.aliases[i] ?? name] = value;
        }
      case final _Raise s:
        final value = s.value == null ? null : _eval(s.value!, scope);
        final error = value is _ErrorType ? _ErrorValue(value, '') : value;
        if (error is! _ErrorValue) {
          _fail(line, 'exceptions must derive from BaseException');
        }
        _fail(
          line,
          error.message.isEmpty
              ? error.type.name
              : '${error.type.name}: ${error.message}',
        );
      case _Pass():
        return;
      case _Break():
        throw const _BreakSignal();
      case _Continue():
        throw const _ContinueSignal();
    }
  }

  _Module _module(String name, int line) => switch (name) {
    'os' => _os,
    'os.path' => _osPath,
    _ => _fail(line, "module '$name' is not supported in application.fam"),
  };

  void _assign(_Expr target, Object? value, _Scope scope) {
    final line = target.line;
    switch (target) {
      case final _Name t:
        scope.vars[t.id] = value;
      case final _Index t:
        _setItem(_eval(t.object, scope), _eval(t.index, scope), value, line);
      case final _TupleE t:
        _unpack(t.items, value, scope, line);
      case final _ListE t:
        _unpack(t.items, value, scope, line);
      case final _Attr t:
        _fail(line, "cannot set attribute '${t.name}' in application.fam");
      default:
        _fail(line, 'cannot assign to expression');
    }
  }

  void _unpack(List<_Expr> targets, Object? value, _Scope scope, int line) {
    final items = _iterate(value, line);
    if (items.length != targets.length) {
      _fail(
        line,
        'ValueError: expected ${targets.length} values to unpack, '
        'got ${items.length}',
      );
    }
    for (var i = 0; i < targets.length; i++) {
      _assign(targets[i], items[i], scope);
    }
  }

  Object? _lookup(String name, _Scope scope, int line) {
    for (_Scope? s = scope; s != null; s = s.parent) {
      if (s.vars.containsKey(name)) return s.vars[name];
    }
    _fail(line, "NameError: name '$name' is not defined");
  }

  Object? _eval(_Expr expr, _Scope scope) {
    final line = expr.line;
    switch (expr) {
      case final _Const e:
        return e.value;
      case final _Name e:
        return _lookup(e.id, scope, line);
      case final _FString e:
        final out = StringBuffer();
        for (final part in e.parts) {
          if (part is String) {
            out.write(part);
          } else if (part is _FPart) {
            final value = _eval(part.expr, scope);
            out.write(
              part.conversion == null || part.conversion == 's'
                  ? _str(value)
                  : _repr(value),
            );
          }
        }
        return out.toString();
      case final _ListE e:
        return [for (final item in e.items) _eval(item, scope)];
      case final _TupleE e:
        return _Tuple([for (final item in e.items) _eval(item, scope)]);
      case final _DictE e:
        final map = <Object?, Object?>{};
        for (var i = 0; i < e.keys.length; i++) {
          map[_eval(e.keys[i], scope)] = _eval(e.values[i], scope);
        }
        return map;
      case final _ListComp e:
        final out = <Object?>[];
        _comprehend(e, 0, _Scope(scope), out);
        return out;
      case final _Attr e:
        return _getAttr(_eval(e.object, scope), e.name, line);
      case final _Index e:
        final object = _eval(e.object, scope);
        final index = e.index;
        if (index is _Slice) {
          return _slice(
            object,
            index.lower == null ? null : _eval(index.lower!, scope),
            index.upper == null ? null : _eval(index.upper!, scope),
            index.step == null ? null : _eval(index.step!, scope),
            line,
          );
        }
        return _getItem(object, _eval(index, scope), line);
      case _Slice():
        _fail(line, 'invalid syntax');
      case final _Call e:
        final function = _eval(e.function, scope);
        final args = [for (final arg in e.args) _eval(arg, scope)];
        final kwargs = {
          for (final entry in e.kwargs.entries)
            entry.key: _eval(entry.value, scope),
        };
        return _call(function, args, kwargs, line);
      case final _Unary e:
        final value = _eval(e.operand, scope);
        if (e.op == 'not') return !_truthy(value);
        if (value is! num || value is bool) {
          _fail(
            line,
            "TypeError: bad operand type for unary ${e.op}: "
            "'${_typeName(value)}'",
          );
        }
        return e.op == '-' ? -value : value;
      case final _Binary e:
        return _binary(e.op, _eval(e.left, scope), _eval(e.right, scope), line);
      case final _BoolOp e:
        final left = _eval(e.left, scope);
        if (_truthy(left) != e.isAnd) return left;
        return _eval(e.right, scope);
      case final _Compare e:
        var left = _eval(e.first, scope);
        for (var i = 0; i < e.ops.length; i++) {
          final right = _eval(e.rest[i], scope);
          if (!_compare(e.ops[i], left, right, line)) return false;
          left = right;
        }
        return true;
      case final _IfExp e:
        return _truthy(_eval(e.condition, scope))
            ? _eval(e.then, scope)
            : _eval(e.otherwise, scope);
    }
  }

  void _comprehend(_ListComp comp, int level, _Scope scope, List<Object?> out) {
    if (level == comp.clauses.length) {
      out.add(_eval(comp.element, scope));
      return;
    }
    final clause = comp.clauses[level];
    for (final item in _iterate(_eval(clause.iter, scope), comp.line)) {
      _assign(clause.target, item, scope);
      if (clause.conditions.every((c) => _truthy(_eval(c, scope)))) {
        _comprehend(comp, level + 1, scope, out);
      }
    }
  }

  Object? _call(
    Object? function,
    List<Object?> args,
    Map<String, Object?> kwargs,
    int line,
  ) {
    switch (function) {
      case final _Builtin f:
        return f.call(args, kwargs, line);
      case final _ErrorType f:
        return _ErrorValue(f, args.isEmpty ? '' : _str(args.first));
      case final _Function f:
        return _callFunction(f, args, kwargs, line);
    }
    _fail(line, "TypeError: '${_typeName(function)}' object is not callable");
  }

  Object? _callFunction(
    _Function function,
    List<Object?> args,
    Map<String, Object?> kwargs,
    int line,
  ) {
    final params = function.params;
    final name = function.name;
    if (args.length > params.length) {
      _fail(
        line,
        'TypeError: $name() takes ${params.length} positional arguments '
        'but ${args.length} were given',
      );
    }
    final scope = _Scope(function.closure);
    for (var i = 0; i < args.length; i++) {
      scope.vars[params[i].name] = args[i];
    }
    for (final entry in kwargs.entries) {
      final index = params.indexWhere((p) => p.name == entry.key);
      if (index < 0) {
        _fail(
          line,
          "TypeError: $name() got an unexpected keyword argument "
          "'${entry.key}'",
        );
      }
      if (index < args.length) {
        _fail(
          line,
          "TypeError: $name() got multiple values for argument '${entry.key}'",
        );
      }
      scope.vars[entry.key] = entry.value;
    }
    for (var i = 0; i < params.length; i++) {
      if (scope.vars.containsKey(params[i].name)) continue;
      final fallback = function.defaults[i];
      if (identical(fallback, _missing)) {
        _fail(
          line,
          "TypeError: $name() missing required argument '${params[i].name}'",
        );
      }
      scope.vars[params[i].name] = fallback;
    }
    if (_depth >= _maxCallDepth) {
      _fail(line, 'RecursionError: maximum recursion depth exceeded');
    }
    _depth++;
    try {
      _exec(function.body, scope);
    } on _ReturnSignal catch (signal) {
      return signal.value;
    } on _BreakSignal {
      _fail(line, "'break' outside loop");
    } on _ContinueSignal {
      _fail(line, "'continue' not properly in loop");
    } finally {
      _depth--;
    }
    return null;
  }

  Object? _getAttr(Object? object, String name, int line) {
    Never missing() => _fail(
      line,
      "AttributeError: '${_typeName(object)}' object has no attribute '$name'",
    );

    _Builtin method(_Native call) => _Builtin(name, call);

    switch (object) {
      case final _Module m:
        if (!m.attributes.containsKey(name)) {
          _fail(
            line,
            "AttributeError: module '${m.name}' has no attribute '$name' "
            'in application.fam',
          );
        }
        return m.attributes[name];
      case final _EnumNamespace e:
        return e.member(name);
      case final String s:
        return switch (name) {
          'strip' => method((a, k, l) => _strip(s, a, l, true, true)),
          'lstrip' => method((a, k, l) => _strip(s, a, l, true, false)),
          'rstrip' => method((a, k, l) => _strip(s, a, l, false, true)),
          'split' => method((a, k, l) => _split(s, a, k, l)),
          'startswith' => method((a, k, l) => _affix(s, a, l, true)),
          'endswith' => method((a, k, l) => _affix(s, a, l, false)),
          'lower' => method((a, k, l) => s.toLowerCase()),
          'upper' => method((a, k, l) => s.toUpperCase()),
          'replace' => method((a, k, l) => _replace(s, a, l)),
          'join' => method((a, k, l) => _join(s, a, l)),
          _ => missing(),
        };
      case final _Tuple _:
        missing();
      case final List<Object?> list:
        return switch (name) {
          'append' => method((a, k, l) {
            _arity('append', a, 1, 1, l);
            list.add(a.first);
            return null;
          }),
          'extend' => method((a, k, l) {
            _arity('extend', a, 1, 1, l);
            list.addAll(_iterate(a.first, l));
            return null;
          }),
          _ => missing(),
        };
      case final Map<Object?, Object?> map:
        return switch (name) {
          'get' => method((a, k, l) {
            _arity('get', a, 1, 2, l);
            final key = _findKey(map, a.first);
            if (!identical(key, _missing)) return map[key];
            return a.length > 1 ? a[1] : null;
          }),
          _ => missing(),
        };
      case final _TextFile file:
        return switch (name) {
          'read' => method((a, k, l) => file.text),
          'readlines' => method((a, k, l) => file.lines),
          'close' => method((a, k, l) => null),
          _ => missing(),
        };
    }
    missing();
  }

  Object? _getItem(Object? object, Object? index, int line) {
    if (object is Map<Object?, Object?>) {
      final key = _findKey(object, index);
      if (identical(key, _missing)) _fail(line, 'KeyError: ${_repr(index)}');
      return object[key];
    }
    if (object is String || object is List) {
      if (index is! int) {
        _fail(
          line,
          'TypeError: ${_typeName(object)} indices must be integers, '
          "not '${_typeName(index)}'",
        );
      }
      final length = object is String ? object.length : (object as List).length;
      final i = index < 0 ? index + length : index;
      if (i < 0 || i >= length) {
        _fail(line, 'IndexError: ${_typeName(object)} index out of range');
      }
      return object is String ? object[i] : (object as List)[i];
    }
    _fail(
      line,
      "TypeError: '${_typeName(object)}' object is not subscriptable",
    );
  }

  void _setItem(Object? object, Object? index, Object? value, int line) {
    if (object is Map<Object?, Object?>) {
      final key = _findKey(object, index);
      object[identical(key, _missing) ? index : key] = value;
      return;
    }
    if (object is List && object is! _Tuple) {
      if (index is! int) {
        _fail(line, 'TypeError: list indices must be integers');
      }
      final i = index < 0 ? index + object.length : index;
      if (i < 0 || i >= object.length) {
        _fail(line, 'IndexError: list assignment index out of range');
      }
      object[i] = value;
      return;
    }
    _fail(
      line,
      "TypeError: '${_typeName(object)}' object does not support item "
      'assignment',
    );
  }

  Object? _slice(
    Object? object,
    Object? lower,
    Object? upper,
    Object? step,
    int line,
  ) {
    if (object is! String && object is! List) {
      _fail(
        line,
        "TypeError: '${_typeName(object)}' object is not subscriptable",
      );
    }
    for (final bound in [lower, upper, step]) {
      if (bound != null && bound is! int) {
        _fail(line, 'TypeError: slice indices must be integers or None');
      }
    }
    final length = object is String ? object.length : (object as List).length;
    final stride = (step as int?) ?? 1;
    if (stride == 0) _fail(line, 'ValueError: slice step cannot be zero');

    int clamp(int? value, int fallback) {
      if (value == null) return fallback;
      var v = value < 0 ? value + length : value;
      if (stride > 0) {
        v = v < 0 ? 0 : (v > length ? length : v);
      } else {
        v = v < 0 ? -1 : (v >= length ? length - 1 : v);
      }
      return v;
    }

    final start = clamp(lower as int?, stride > 0 ? 0 : length - 1);
    final stop = clamp(upper as int?, stride > 0 ? length : -1);
    final indices = <int>[];
    for (var i = start; stride > 0 ? i < stop : i > stop; i += stride) {
      indices.add(i);
    }
    if (object is String) return indices.map((i) => object[i]).join();
    final list = object as List;
    final items = indices.map((i) => list[i]);
    return object is _Tuple ? _Tuple(items) : items.toList();
  }

  List<Object?> _iterate(Object? value, int line) {
    switch (value) {
      case final String s:
        return [for (final rune in s.runes) String.fromCharCode(rune)];
      case final List<Object?> list:
        return List.of(list);
      case final Map<Object?, Object?> map:
        return map.keys.toList();
      case final _TextFile file:
        return file.lines;
    }
    _fail(line, "TypeError: '${_typeName(value)}' object is not iterable");
  }

  Object? _augment(String op, Object? current, Object? value, int line) {
    if (op == '+' && current is List && current is! _Tuple) {
      current.addAll(_iterate(value, line));
      return current;
    }
    return _binary(op, current, value, line);
  }

  Object? _binary(String op, Object? a, Object? b, int line) {
    Never unsupported() => _fail(
      line,
      "TypeError: unsupported operand type(s) for $op: "
      "'${_typeName(a)}' and '${_typeName(b)}'",
    );

    final numbers = a is num && b is num && a is! bool && b is! bool;
    switch (op) {
      case '+':
        if (numbers) return a + b;
        if (a is String && b is String) return a + b;
        if (a is _Tuple && b is _Tuple) return _Tuple([...a, ...b]);
        if (a is List && b is List && a is! _Tuple && b is! _Tuple) {
          return [...a, ...b];
        }
        unsupported();
      case '-':
        if (numbers) return a - b;
        unsupported();
      case '*':
        if (numbers) return a * b;
        if (a is int && (b is String || b is List)) return _repeat(b, a);
        if (b is int && (a is String || a is List)) return _repeat(a, b);
        unsupported();
      case '/':
        if (!numbers) unsupported();
        if (b == 0) _fail(line, 'ZeroDivisionError: division by zero');
        return a / b;
      case '//' || '%':
        if (!numbers) unsupported();
        if (b == 0) {
          _fail(line, 'ZeroDivisionError: integer division or modulo by zero');
        }
        var remainder = a.remainder(b);
        if (remainder != 0 && (remainder < 0) != (b < 0)) remainder += b;
        if (op == '%') return remainder;
        final quotient = (a - remainder) / b;
        return a is int && b is int
            ? quotient.round()
            : quotient.floorToDouble();
    }
    unsupported();
  }

  Object _repeat(Object? sequence, int count) {
    final times = count < 0 ? 0 : count;
    if (sequence is String) return sequence * times;
    final list = sequence as List;
    final items = [for (var i = 0; i < times; i++) ...list];
    return sequence is _Tuple ? _Tuple(items) : items;
  }

  bool _compare(String op, Object? a, Object? b, int line) {
    switch (op) {
      case '==':
        return _eq(a, b);
      case '!=':
        return !_eq(a, b);
      case 'in':
        return _contains(b, a, line);
      case 'not in':
        return !_contains(b, a, line);
      case 'is':
        return identical(a, b);
      case 'is not':
        return !identical(a, b);
    }
    final int order;
    if (a is num && b is num && a is! bool && b is! bool) {
      order = a.compareTo(b);
    } else if (a is String && b is String) {
      order = a.compareTo(b);
    } else {
      _fail(
        line,
        "TypeError: '$op' not supported between instances of "
        "'${_typeName(a)}' and '${_typeName(b)}'",
      );
    }
    return switch (op) {
      '<' => order < 0,
      '>' => order > 0,
      '<=' => order <= 0,
      _ => order >= 0,
    };
  }

  bool _contains(Object? container, Object? item, int line) {
    switch (container) {
      case final String s:
        if (item is! String) {
          _fail(
            line,
            "TypeError: 'in <string>' requires string as left operand, "
            'not ${_typeName(item)}',
          );
        }
        return s.contains(item);
      case final List<Object?> list:
        return list.any((element) => _eq(element, item));
      case final Map<Object?, Object?> map:
        return !identical(_findKey(map, item), _missing);
    }
    _fail(
      line,
      "TypeError: argument of type '${_typeName(container)}' is not iterable",
    );
  }

  Object? _findKey(Map<Object?, Object?> map, Object? key) {
    if (map.containsKey(key)) return key;
    for (final candidate in map.keys) {
      if (_eq(candidate, key)) return candidate;
    }
    return _missing;
  }

  Map<String, Object?> _builtinFunctions() {
    const valueError = _ErrorType('ValueError');
    return {
      'len': _Builtin('len', (args, kwargs, line) {
        _arity('len', args, 1, 1, line);
        return switch (args.first) {
          final String s => s.runes.length,
          final List<Object?> l => l.length,
          final Map<Object?, Object?> m => m.length,
          final other => _fail(
            line,
            "TypeError: object of type '${_typeName(other)}' has no len()",
          ),
        };
      }),
      'open': _Builtin('open', _open),
      'range': _Builtin('range', _range),
      'str': _Builtin('str', (args, kwargs, line) {
        _arity('str', args, 0, 1, line);
        return args.isEmpty ? '' : _str(args.first);
      }, (value) => value is String),
      'int': _Builtin('int', _int, (value) => (value is int || value is bool)),
      'list': _Builtin('list', (args, kwargs, line) {
        _arity('list', args, 0, 1, line);
        return args.isEmpty ? <Object?>[] : _iterate(args.first, line);
      }, (value) => value is List && value is! _Tuple),
      'enumerate': _Builtin('enumerate', (args, kwargs, line) {
        _arity('enumerate', args, 1, 2, line);
        final start = args.length > 1 ? args[1] : (kwargs['start'] ?? 0);
        if (start is! int) {
          _fail(line, 'TypeError: enumerate() start must be an integer');
        }
        final items = _iterate(args.first, line);
        return [
          for (var i = 0; i < items.length; i++) _Tuple([start + i, items[i]]),
        ];
      }),
      'isinstance': _Builtin('isinstance', (args, kwargs, line) {
        _arity('isinstance', args, 2, 2, line);
        final types = args[1] is _Tuple ? args[1] as _Tuple : [args[1]];
        return types.any((type) {
          if (type is! _Builtin || type.instanceCheck == null) {
            _fail(
              line,
              'TypeError: isinstance() arg 2 must be a type or tuple of types',
            );
          }
          return type.instanceCheck!(args.first);
        });
      }),
      'ValueError': valueError,
    };
  }

  Object? _open(List<Object?> args, Map<String, Object?> kwargs, int line) {
    _arity('open', args, 1, 2, line);
    final path = args.first;
    final mode = args.length > 1 ? args[1] : (kwargs['mode'] ?? 'r');
    if (path is! String) {
      _fail(line, 'TypeError: open() expects a path string');
    }
    if (mode != 'r' && mode != 'rt') {
      _fail(line, 'open() is read-only in application.fam');
    }
    final resolved = _resolve(path);
    final List<int> bytes;
    try {
      bytes = File(resolved).readAsBytesSync();
    } on FileSystemException {
      _fail(line, "FileNotFoundError: No such file or directory: '$path'");
    }
    final text = utf8
        .decode(bytes, allowMalformed: true)
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n');
    return _TextFile(text);
  }

  Object? _range(List<Object?> args, Map<String, Object?> kwargs, int line) {
    _arity('range', args, 1, 3, line);
    for (final arg in args) {
      if (arg is! int) {
        _fail(
          line,
          "TypeError: '${_typeName(arg)}' object cannot be interpreted as an "
          'integer',
        );
      }
    }
    final ints = args.cast<int>();
    final start = ints.length == 1 ? 0 : ints[0];
    final stop = ints.length == 1 ? ints[0] : ints[1];
    final step = ints.length == 3 ? ints[2] : 1;
    if (step == 0) _fail(line, 'ValueError: range() arg 3 must not be zero');
    final count = step > 0
        ? (stop - start + step - 1) ~/ step
        : (start - stop - step - 1) ~/ -step;
    if (count > _maxRange) _fail(line, 'range() is too large');
    return [for (var i = 0; i < count; i++) start + i * step];
  }

  Object? _int(List<Object?> args, Map<String, Object?> kwargs, int line) {
    _arity('int', args, 0, 2, line);
    if (args.isEmpty) return 0;
    final value = args.first;
    final base = args.length > 1 ? args[1] : (kwargs['base'] ?? 10);
    if (value is bool) return value ? 1 : 0;
    if (value is int) return value;
    if (value is double) {
      if (!value.isFinite) {
        _fail(line, 'ValueError: cannot convert float to integer');
      }
      return value.truncate();
    }
    if (value is String && base is int) {
      final parsed = int.tryParse(
        value.trim().replaceAll('_', ''),
        radix: base,
      );
      if (parsed != null) return parsed;
      _fail(
        line,
        'ValueError: invalid literal for int() with base $base: '
        '${_repr(value)}',
      );
    }
    _fail(
      line,
      "TypeError: int() argument must be a string or a number, not "
      "'${_typeName(value)}'",
    );
  }

  _Module _pathModule() {
    final separators = Platform.isWindows ? const {'/', r'\'} : const {'/'};
    final sep = Platform.pathSeparator;

    bool isSep(String c) => separators.contains(c);

    String drive(String p) {
      if (!Platform.isWindows) return '';
      return RegExp(r'^[A-Za-z]:').stringMatch(p) ?? '';
    }

    bool isAbsolute(String p) {
      final rest = p.substring(drive(p).length);
      return rest.isNotEmpty && isSep(rest[0]);
    }

    int lastSep(String p) {
      for (var i = p.length - 1; i >= 0; i--) {
        if (isSep(p[i])) return i;
      }
      return -1;
    }

    String text(List<Object?> args, int index, String function, int line) {
      final value = args[index];
      if (value is! String) {
        _fail(
          line,
          "TypeError: $function() argument must be str, not "
          "'${_typeName(value)}'",
        );
      }
      return value;
    }

    _Builtin function(String name, Object? Function(String, int) body) =>
        _Builtin(name, (args, kwargs, line) {
          _arity(name, args, 1, 1, line);
          return body(text(args, 0, name, line), line);
        });

    return _Module('os.path', {
      'join': _Builtin('join', (args, kwargs, line) {
        _arity('join', args, 1, null, line);
        var path = text(args, 0, 'join', line);
        for (var i = 1; i < args.length; i++) {
          final part = text(args, i, 'join', line);
          if (isAbsolute(part) || drive(part).isNotEmpty) {
            path = part;
          } else if (path.isEmpty || isSep(path[path.length - 1])) {
            path += part;
          } else {
            path += sep + part;
          }
        }
        return path;
      }),
      'dirname': function('dirname', (p, line) {
        final prefix = drive(p);
        final rest = p.substring(prefix.length);
        var head = rest.substring(0, lastSep(rest) + 1);
        if (head.split('').any((c) => !isSep(c))) {
          var end = head.length;
          while (end > 0 && isSep(head[end - 1])) {
            end--;
          }
          head = head.substring(0, end);
        }
        return prefix + head;
      }),
      'basename': function('basename', (p, line) {
        final rest = p.substring(drive(p).length);
        return rest.substring(lastSep(rest) + 1);
      }),
      'splitext': function('splitext', (p, line) {
        final sepIndex = lastSep(p);
        final dotIndex = p.lastIndexOf('.');
        if (dotIndex > sepIndex) {
          for (var i = sepIndex + 1; i < dotIndex; i++) {
            if (p[i] != '.') {
              return _Tuple([p.substring(0, dotIndex), p.substring(dotIndex)]);
            }
          }
        }
        return _Tuple([p, '']);
      }),
      'exists': function(
        'exists',
        (p, line) =>
            FileSystemEntity.typeSync(_resolve(p)) !=
            FileSystemEntityType.notFound,
      ),
      'isfile': function(
        'isfile',
        (p, line) => FileSystemEntity.isFileSync(_resolve(p)),
      ),
      'isdir': function(
        'isdir',
        (p, line) => FileSystemEntity.isDirectorySync(_resolve(p)),
      ),
    });
  }

  String _resolve(String path) {
    final base = manifestPath;
    if (base == null || path.isEmpty) return path;
    final absolute =
        path.startsWith('/') ||
        (Platform.isWindows &&
            (path.startsWith(r'\') || RegExp(r'^[A-Za-z]:').hasMatch(path)));
    if (absolute) return path;
    return '${File(base).parent.path}${Platform.pathSeparator}$path';
  }
}

void _arity(String name, List<Object?> args, int min, int? max, int line) {
  if (args.length < min || (max != null && args.length > max)) {
    final expected = max == null
        ? 'at least $min'
        : (min == max ? '$min' : '$min to $max');
    _fail(
      line,
      'TypeError: $name() takes $expected arguments (${args.length} given)',
    );
  }
}

String _strip(
  String s,
  List<Object?> args,
  int line,
  bool leading,
  bool trailing,
) {
  _arity('strip', args, 0, 1, line);
  final chars = args.isEmpty ? null : args.first;
  if (chars != null && chars is! String) {
    _fail(line, 'TypeError: strip arg must be None or str');
  }
  bool strip(String c) =>
      chars == null ? c.trim().isEmpty : (chars as String).contains(c);
  var start = 0;
  var end = s.length;
  if (leading) {
    while (start < end && strip(s[start])) {
      start++;
    }
  }
  if (trailing) {
    while (end > start && strip(s[end - 1])) {
      end--;
    }
  }
  return s.substring(start, end);
}

List<Object?> _split(
  String s,
  List<Object?> args,
  Map<String, Object?> kwargs,
  int line,
) {
  _arity('split', args, 0, 2, line);
  final sep = args.isNotEmpty ? args[0] : kwargs['sep'];
  final limit = args.length > 1 ? args[1] : (kwargs['maxsplit'] ?? -1);
  if (limit is! int) _fail(line, 'TypeError: maxsplit must be an integer');
  final out = <Object?>[];
  if (sep == null) {
    bool isSpace(int i) => s[i].trim().isEmpty;
    var i = 0;
    while (true) {
      while (i < s.length && isSpace(i)) {
        i++;
      }
      if (i >= s.length) break;
      if (limit >= 0 && out.length == limit) {
        out.add(s.substring(i));
        break;
      }
      var j = i;
      while (j < s.length && !isSpace(j)) {
        j++;
      }
      out.add(s.substring(i, j));
      i = j;
    }
    return out;
  }
  if (sep is! String) _fail(line, 'TypeError: must be str or None');
  if (sep.isEmpty) _fail(line, 'ValueError: empty separator');
  var start = 0;
  while (limit < 0 || out.length < limit) {
    final index = s.indexOf(sep, start);
    if (index < 0) break;
    out.add(s.substring(start, index));
    start = index + sep.length;
  }
  out.add(s.substring(start));
  return out;
}

bool _affix(String s, List<Object?> args, int line, bool prefix) {
  final name = prefix ? 'startswith' : 'endswith';
  _arity(name, args, 1, 1, line);
  final value = args.first;
  final candidates = value is _Tuple ? value : [value];
  return candidates.any((candidate) {
    if (candidate is! String) {
      _fail(line, 'TypeError: $name arg must be str or a tuple of str');
    }
    return prefix ? s.startsWith(candidate) : s.endsWith(candidate);
  });
}

String _replace(String s, List<Object?> args, int line) {
  _arity('replace', args, 2, 3, line);
  final from = args[0];
  final to = args[1];
  final count = args.length > 2 ? args[2] : -1;
  if (from is! String || to is! String || count is! int) {
    _fail(line, 'TypeError: replace() arguments must be str, str[, int]');
  }
  if (count < 0) return s.replaceAll(from, to);
  var result = s;
  var start = 0;
  for (var i = 0; i < count; i++) {
    final index = result.indexOf(from, start);
    if (index < 0) break;
    result = result.replaceRange(index, index + from.length, to);
    start = index + to.length;
    if (from.isEmpty) start++;
  }
  return result;
}

String _join(String separator, List<Object?> args, int line) {
  _arity('join', args, 1, 1, line);
  final value = args.first;
  final Iterable<Object?> items = switch (value) {
    final List<Object?> list => list,
    final String s => s.split(''),
    _ => _fail(line, "TypeError: can only join an iterable"),
  };
  return items
      .map((item) {
        if (item is! String) {
          _fail(
            line,
            'TypeError: sequence item: expected str instance, '
            '${_typeName(item)} found',
          );
        }
        return item;
      })
      .join(separator);
}

bool _truthy(Object? value) => switch (value) {
  null => false,
  final bool b => b,
  final num n => n != 0,
  final String s => s.isNotEmpty,
  final List<Object?> l => l.isNotEmpty,
  final Map<Object?, Object?> m => m.isNotEmpty,
  _ => true,
};

bool _eq(Object? a, Object? b) {
  if (a is List && b is List) {
    if ((a is _Tuple) != (b is _Tuple) || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_eq(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key) || !_eq(a[key], b[key])) return false;
    }
    return true;
  }
  if (a is bool || b is bool) return identical(a, b);
  return a == b;
}

String _typeName(Object? value) => switch (value) {
  null => 'NoneType',
  bool() => 'bool',
  int() => 'int',
  double() => 'float',
  String() => 'str',
  _Tuple() => 'tuple',
  List() => 'list',
  Map() => 'dict',
  _Function() => 'function',
  _Builtin() => 'builtin_function_or_method',
  _Module() => 'module',
  _TextFile() => 'TextIOWrapper',
  _ErrorType() => 'type',
  _ErrorValue(:final type) => type.name,
  _ => 'object',
};

String _str(Object? value) => value is String ? value : _repr(value);

String _repr(Object? value) {
  switch (value) {
    case null:
      return 'None';
    case true:
      return 'True';
    case false:
      return 'False';
    case final double d:
      if (d.isNaN) return 'nan';
      if (d.isInfinite) return d > 0 ? 'inf' : '-inf';
      return d.toString();
    case final String s:
      final quote = s.contains("'") && !s.contains('"') ? '"' : "'";
      final escaped = s
          .replaceAll('\\', r'\\')
          .replaceAll('\n', r'\n')
          .replaceAll('\r', r'\r')
          .replaceAll('\t', r'\t')
          .replaceAll(quote, '\\$quote');
      return '$quote$escaped$quote';
    case final _Tuple t:
      final items = t.map(_repr).join(', ');
      return t.length == 1 ? '($items,)' : '($items)';
    case final List<Object?> l:
      return '[${l.map(_repr).join(', ')}]';
    case final Map<Object?, Object?> m:
      final entries = m.entries.map(
        (e) => '${_repr(e.key)}: ${_repr(e.value)}',
      );
      return '{${entries.join(', ')}}';
    case final FamName n:
      return n.value;
    case final FamCall c:
      return '${c.name}(...)';
    case final _Function f:
      return '<function ${f.name}>';
    case final _Builtin b:
      return '<built-in function ${b.name}>';
    case final _Module m:
      return "<module '${m.name}'>";
    case final _ErrorValue e:
      return '${e.type.name}(${_repr(e.message)})';
    case final _ErrorType e:
      return "<class '${e.name}'>";
  }
  return value.toString();
}
