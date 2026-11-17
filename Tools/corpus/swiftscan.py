"""Text-level Swift scanning shared by the corpus analyzer.

Nothing here executes or evaluates the code it reads: it strips comments and
string literals, evaluates `#if` conditions for a macOS build where the answer
is certain, and pulls declarations and uses out with regular expressions.
"""
import re

# ---------------------------------------------------------------------------
# Lexing: drop comments, blank string contents (keep the quotes), keep newlines.


def strip_swift(src):
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == '/' and i + 1 < n:
            d = src[i + 1]
            if d == '/':
                j = src.find('\n', i)
                i = n if j < 0 else j
                continue
            if d == '*':
                depth, i = 1, i + 2
                while i < n and depth:
                    if src.startswith('/*', i):
                        depth += 1; i += 2
                    elif src.startswith('*/', i):
                        depth -= 1; i += 2
                    else:
                        if src[i] == '\n':
                            out.append('\n')
                        i += 1
                continue
        if c == '#' or c == '"':
            j = i
            while j < n and src[j] == '#':
                j += 1
            if j < n and src[j] == '"':
                hashes = j - i
                end, nl = _scan_string(src, j, hashes)
                out.append('""')
                out.append('\n' * nl)
                i = end
                continue
        out.append(c)
        i += 1
    return ''.join(out)


def _scan_string(src, i, hashes):
    """i points at the opening quote. Returns (index after literal, newlines inside)."""
    n = len(src)
    multi = src.startswith('"""', i)
    i += 3 if multi else 1
    close = ('"""' if multi else '"') + '#' * hashes
    esc = '\\' + '#' * hashes
    nl = 0
    while i < n:
        if src.startswith(esc, i):
            k = i + len(esc)
            if k < n and src[k] == '(':
                i = _skip_interpolation(src, k + 1)
                continue
            i = k + 1
            continue
        if src.startswith(close, i):
            return i + len(close), nl
        if src[i] == '\n':
            nl += 1
            if not multi:
                return i, nl - 1  # unterminated single-line literal: stop at the newline
        i += 1
    return n, nl


def _skip_interpolation(src, i):
    depth, n = 1, len(src)
    while i < n and depth:
        c = src[i]
        if c == '"' or (c == '#' and src[i:].lstrip('#').startswith('"')):
            j = i
            while j < n and src[j] == '#':
                j += 1
            i, _ = _scan_string(src, j, j - i)
            continue
        if c == '(':
            depth += 1
        elif c == ')':
            depth -= 1
        elif c == '\n':
            return i
        i += 1
    return i


# ---------------------------------------------------------------------------
# #if evaluation for a macOS (AppKit) build. Three-valued: True / False / None.

MAC_OS = {'macOS': True, 'OSX': True}
MAC_IMPORTABLE = None  # canImport(X): unknown in general, decided below


def _canimport(mod):
    if mod in ('UIKit', 'WatchKit', 'Glibc', 'WinSDK', 'Android', 'Musl', 'TVUIKit', 'CarPlay'):
        return False
    if mod in ('AppKit', 'Cocoa', 'Darwin', 'Foundation', 'SwiftUI', 'Combine', 'CoreGraphics'):
        return True
    return None


_IF_TOKEN = re.compile(r'\s*(\|\||&&|!|\(|\)|[A-Za-z_]\w*\s*\([^()]*\)|[A-Za-z_]\w*)')


def eval_condition(expr):
    toks = []
    pos = 0
    expr = expr.strip()
    while pos < len(expr):
        m = _IF_TOKEN.match(expr, pos)
        if not m:
            return None
        toks.append(m.group(1).strip())
        pos = m.end()
    p = [0]

    def atom(t):
        m = re.match(r'(\w+)\s*\(\s*([^()]*?)\s*\)$', t)
        if m:
            fn, arg = m.group(1), m.group(2)
            if fn == 'os':
                return MAC_OS.get(arg, False)
            if fn == 'canImport':
                return _canimport(arg.split('.')[0].split(',')[0].strip())
            if fn == 'targetEnvironment':
                return False if arg in ('macCatalyst', 'simulator') else None
            if fn in ('swift', 'compiler'):
                return True
            if fn == 'arch':
                return None
            if fn == 'hasFeature' or fn == 'hasAttribute':
                return None
            return None
        if t == 'true':
            return True
        if t == 'false':
            return False
        return None  # a -D flag: unknown

    def primary():
        if p[0] >= len(toks):
            return None
        t = toks[p[0]]; p[0] += 1
        if t == '!':
            v = primary()
            return None if v is None else not v
        if t == '(':
            v = orx()
            if p[0] < len(toks) and toks[p[0]] == ')':
                p[0] += 1
            return v
        return atom(t)

    def andx():
        v = primary()
        while p[0] < len(toks) and toks[p[0]] == '&&':
            p[0] += 1
            w = primary()
            v = False if (v is False or w is False) else (True if (v and w) else None)
        return v

    def orx():
        v = andx()
        while p[0] < len(toks) and toks[p[0]] == '||':
            p[0] += 1
            w = andx()
            v = True if (v is True or w is True) else (False if (v is False and w is False) else None)
        return v

    try:
        return orx()
    except Exception:
        return None


_DIRECTIVE = re.compile(r'^[ \t]*#(if|elseif|else|endif)\b(.*)$')


def mac_active(code):
    """Blank lines in #if branches that are certainly inactive on macOS.
    Returns (code, conditions) where conditions lists every #if/#elseif text."""
    lines = code.split('\n')
    stack = []  # entries: [parent_active, branch_taken(True/None/False), this_active]
    conds = []
    out = []
    active = True
    for line in lines:
        m = _DIRECTIVE.match(line)
        if m:
            kind, rest = m.group(1), m.group(2).strip()
            if kind == 'if':
                conds.append(rest)
                v = eval_condition(rest)
                stack.append([active, v, active and v is not False])
                active = stack[-1][2]
            elif kind == 'elseif' and stack:
                conds.append(rest)
                fr = stack[-1]
                v = eval_condition(rest)
                if fr[1] is True:
                    this = False
                else:
                    this = fr[0] and v is not False
                    if v is True and fr[1] is False:
                        fr[1] = True
                    elif v is None and fr[1] is False:
                        fr[1] = None
                fr[2] = this
                active = this
            elif kind == 'else' and stack:
                fr = stack[-1]
                fr[2] = fr[0] and fr[1] is not True
                active = fr[2]
            elif kind == 'endif' and stack:
                fr = stack.pop()
                active = fr[0]
            out.append('')
            continue
        out.append(line if active else '')
    return '\n'.join(out), conds


# ---------------------------------------------------------------------------
# Small helpers


def match_paren(s, i):
    """s[i] == '(' ; return index of the matching ')' (or len(s))."""
    depth = 0
    n = len(s)
    j = i
    while j < n:
        c = s[j]
        if c in '([{':
            depth += 1
        elif c in ')]}':
            depth -= 1
            if depth == 0:
                return j
        j += 1
    return n


def _depth_delta(c, prev):
    if c in '([{<':
        return 1
    if c in ')]}' or (c == '>' and prev != '-'):
        return -1
    return 0


def split_top(s, sep=','):
    parts, depth, cur, prev = [], 0, [], ''
    for c in s:
        depth += _depth_delta(c, prev)
        if c == sep and depth <= 0:
            parts.append(''.join(cur)); cur = []
        else:
            cur.append(c)
        prev = c
    if ''.join(cur).strip():
        parts.append(''.join(cur))
    return parts


_ARG_LABEL = re.compile(r'^\s*([A-Za-z_]\w*)\s*:(?!:)')


def call_labels(argtext):
    if not argtext.strip():
        return []
    labels = []
    for a in split_top(argtext):
        m = _ARG_LABEL.match(a)
        labels.append(m.group(1) if m else '_')
    return labels


def _top_level_eq(s):
    depth, prev = 0, ''
    for i, c in enumerate(s):
        if c == '=' and depth == 0:
            nxt = s[i + 1] if i + 1 < len(s) else ''
            if prev not in '=!<>' and nxt != '=':
                return True
        depth += _depth_delta(c, prev)
        prev = c
    return False


_ATTR = re.compile(r'@\w+(\([^)]*\))?')
_PARAM_MODS = {'inout', 'borrowing', 'consuming', 'isolated', 'sending', '__owned', '__shared'}


def param_labels(paramtext):
    """Declaration params -> [(external label, has_default)]."""
    out = []
    if not paramtext.strip():
        return out
    for p in split_top(paramtext):
        if ':' not in p:
            continue
        head, _, tail = p.partition(':')
        words = [w for w in _ATTR.sub(' ', head).split() if w not in _PARAM_MODS]
        if not words:
            continue
        out.append((words[0], _top_level_eq(tail)))
    return out


def labels_match(call, params):
    """Do call-site labels fit a declaration's params? Defaulted params may be
    skipped, and one unmatched final param may be a trailing closure."""
    i, rest = 0, []
    for label, has_default in params:
        if i < len(call) and call[i] == label:
            i += 1
        elif not has_default:
            rest.append(label)
    if i != len(call):
        return False
    return not rest or (len(rest) == 1 and params[-1][0] == rest[0])


def init_key(labels):
    return 'init(' + ''.join(l + ':' for l in labels) + ')'

