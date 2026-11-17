"""What Runway provides: public declarations in runway/Sources/<Module>/*.swift.

Builds a symbol table {type: {module, kind, supers, members, inits}} plus
top-level globals, by brace-tracking the stripped source line by line. Only
public/open declarations (and members of public protocols, `public extension`
blocks and cases of public enums) count.
"""
import os
import re

from swiftscan import strip_swift, match_paren, param_labels

_MODS = r'(?:(?:@\w+(?:\([^()]*\))?|public|open|internal|package|private|fileprivate|final|static|class|override|required|convenience|nonisolated(?:\(unsafe\))?|mutating|nonmutating|lazy|weak|unowned|dynamic|indirect|optional|prefix|postfix|infix|distributed|private\(set\)|fileprivate\(set\)|internal\(set\))\s+)*'
_DECL = re.compile(r'^\s*(' + _MODS + r')(func|var|let|init[?!]?|subscript|case|class|struct|enum|protocol|extension|actor|typealias|associatedtype|macro)\b(.*)$')
_TYPE_KINDS = {'class', 'struct', 'enum', 'protocol', 'extension', 'actor'}
_RAW_TYPES = {'Int', 'UInt', 'Int8', 'Int16', 'Int32', 'Int64', 'UInt8', 'UInt16', 'UInt32', 'UInt64', 'String', 'Double', 'Float', 'Character', 'CGFloat'}


def library_products(package_swift):
    try:
        text = open(package_swift, encoding='utf-8', errors='ignore').read()
    except OSError:
        return []
    return re.findall(r'\.library\(\s*name:\s*"([^"]+)"', text)


def provided_modules(support_swift):
    """Module names in `let runwayModules: Set<String> = [...]` of the build tool."""
    import re
    try:
        text = open(support_swift, encoding='utf-8').read()
    except OSError:
        return set()
    m = re.search(r'let runwayModules[^=]*=\s*\[(.*?)\]', text, re.S)
    return set(re.findall(r'"([A-Za-z_][A-Za-z0-9_]*)"', m.group(1))) if m else set()


class RunwayAPI:
    def __init__(self, runway_dir):
        self.root = runway_dir
        self.modules = library_products(os.path.join(runway_dir, 'Package.swift'))
        # Products built in loops (e.g. `mediaModules.map { .library(...) }`)
        # aren't literal: also count every Sources/<Module> that has Swift files
        # and is listed in the tool's provided-modules set.
        self.modules = sorted(set(self.modules) | provided_modules(os.path.join(runway_dir, 'Sources', 'runway', 'Support.swift')))
        self.types = {}      # full name -> info
        self.short = {}      # short name -> [full names]
        self.globals = {}    # name -> module
        self.aliases = {}    # name -> target
        self.reexports = {}  # module -> [modules]
        src = os.path.join(runway_dir, 'Sources')
        for mod in sorted(os.listdir(src)) if os.path.isdir(src) else []:
            d = os.path.join(src, mod)
            if not os.path.isdir(d):
                continue
            for dp, _, files in os.walk(d):
                for f in sorted(files):
                    if f.endswith('.swift'):
                        self._scan(mod, os.path.join(dp, f))

    # -- building ----------------------------------------------------------

    def _type(self, full, module, kind):
        t = self.types.get(full)
        if t is None:
            t = {'module': module, 'kind': kind, 'supers': [], 'members': set(), 'inits': [], 'public': False}
            self.types[full] = t
            self.short.setdefault(full.split('.')[-1], []).append(full)
        if kind != 'extension' and t['kind'] == 'extension':
            t['kind'] = kind
            t['module'] = module
        return t

    def _scan(self, module, path):
        raw = open(path, encoding='utf-8', errors='ignore').read()
        for m in re.finditer(r'@_exported\s+import\s+(\w+)', raw):
            self.reexports.setdefault(module, []).append(m.group(1))
        code = strip_swift(raw)
        stack = []      # each: None (body) or dict(name, kind, public_default)
        pending = None  # a type header whose '{' has not been seen yet
        offset = 0
        for line in code.split('\n'):
            line_start = offset
            offset += len(line) + 1
            in_body = any(s is None for s in stack)
            ctx = stack[-1] if stack else None
            m = _DECL.match(line) if not in_body else None
            push = None
            if m:
                mods, kw, rest = m.group(1), m.group(2), m.group(3)
                explicit_public = bool(re.search(r'\b(public|open)\b', mods))
                is_private = bool(re.search(r'\b(private|fileprivate|internal)\b(?!\()', mods))
                visible = explicit_public or (ctx is not None and ctx['public_default'] and not is_private)
                parent = ctx['name'] if ctx else None
                if kw in _TYPE_KINDS and not (kw == 'class' and re.match(r'\s*(func|var|let|subscript)\b', rest)):
                    nm = re.match(r'\s*([A-Za-z_][\w.]*)', rest)
                    if nm:
                        name = nm.group(1)
                        full = name if (kw == 'extension' or not parent) else parent + '.' + name
                        full = self.aliases.get(full, full)
                        t = self._type(full, module, kw)
                        if kw != 'extension' and visible:
                            t['public'] = True
                        if kw != 'extension' and parent and visible:
                            self.types[parent]['members'].add(name)
                        inh = re.match(r'\s*[\w.]+\s*(?:<[^>]*>)?\s*:\s*([^{]*?)(?:\bwhere\b|\{|$)', rest)
                        if inh:
                            for s in inh.group(1).split(','):
                                s = s.strip().split('<')[0].strip()
                                if s and s not in t['supers'] and re.match(r'^[A-Za-z_][\w.]*$', s):
                                    t['supers'].append(s)
                                    if kw == 'enum' and s in _RAW_TYPES:
                                        t['members'].update({'rawValue'})
                                        t['inits'].append([('rawValue', False)])
                        public_default = (kw == 'protocol' and visible) or (kw == 'extension' and explicit_public)
                        frame = {'name': full, 'kind': kw, 'public_default': public_default,
                                 'enum_public': kw == 'enum' and visible}
                        push = frame
                elif ctx is None:
                    if visible or explicit_public:
                        if kw == 'typealias':
                            a = re.match(r'\s*(\w+)\s*(?:<[^>]*>)?\s*=\s*([\w.]+)', rest)
                            if a:
                                self.aliases[a.group(1)] = a.group(2)
                                self.globals[a.group(1)] = module
                        elif kw in ('func', 'var', 'let', 'macro'):
                            for nm in self._names(kw, rest):
                                self.globals[nm] = module
                else:
                    t = self.types[ctx['name']]
                    vis = visible or (kw == 'case' and ctx.get('enum_public'))
                    if vis:
                        if kw.startswith('init'):
                            p = line.find('(', line.find('init'))
                            if p >= 0:
                                a = line_start + p
                                b = match_paren(code, a)
                                t['inits'].append(param_labels(code[a + 1:b]))
                                t['members'].add('init')
                        elif kw == 'typealias':
                            a = re.match(r'\s*(\w+)\s*(?:<[^>]*>)?\s*=\s*([\w.]+)', rest)
                            if a:
                                t['members'].add(a.group(1))
                                self.aliases[ctx['name'] + '.' + a.group(1)] = a.group(2)
                        else:
                            t['members'].update(self._names(kw, rest))
            # braces on this line
            for ch in line:
                if ch == '{':
                    if push is not None:
                        stack.append(push); push = None
                    elif pending is not None:
                        stack.append(pending); pending = None
                    else:
                        stack.append(None)
                elif ch == '}':
                    if stack:
                        stack.pop()
            if push is not None:
                pending = push

    @staticmethod
    def _names(kw, rest):
        if kw == 'func':
            m = re.match(r'\s*([^\s(<]+)', rest)
            return [m.group(1)] if m else []
        if kw == 'subscript':
            return ['subscript']
        if kw == 'case':
            names = []
            depth = 0
            cur = ''
            for c in rest:
                if c in '([':
                    depth += 1
                elif c in ')]':
                    depth -= 1
                if c == ',' and depth == 0:
                    names.append(cur); cur = ''
                else:
                    cur += c
            names.append(cur)
            out = []
            for n in names:
                m = re.match(r'\s*`?(\w+)`?', n)
                if m:
                    out.append(m.group(1))
            return out
        if kw in ('var', 'let'):
            out = re.findall(r'(?:^|,)\s*`?([A-Za-z_]\w*)`?\s*[:=]', rest)
            if not out:
                m = re.match(r'\s*`?(\w+)', rest)
                out = [m.group(1)] if m else []
            return out
        if kw == 'macro':
            m = re.match(r'\s*(\w+)', rest)
            return [m.group(1)] if m else []
        return []

    # -- queries -----------------------------------------------------------

    def resolve(self, name):
        seen = set()
        while name in self.aliases and name not in seen:
            seen.add(name)
            name = self.aliases[name]
        return name

    def find_type(self, name):
        name = self.resolve(name)
        if name in self.types:
            return name
        cands = self.short.get(name)
        if cands:
            return cands[0]
        return None

    def has_symbol(self, name):
        """A type, alias or global with this name exists anywhere in Runway."""
        if name in self.globals or name in self.aliases:
            return True
        t = self.find_type(name)
        if t is None:
            return False
        # an extension alone (e.g. `extension Notification.Name`) doesn't mean Runway defines it
        return self.types[t]['kind'] != 'extension'

    def defines_type(self, name):
        t = self.find_type(name)
        return t is not None and self.types[t]['kind'] != 'extension'

    def _chain(self, tname, seen=None):
        seen = seen if seen is not None else set()
        full = self.find_type(tname)
        if full is None or full in seen:
            return
        seen.add(full)
        yield full
        for s in self.types[full]['supers']:
            yield from self._chain(s, seen)

    def has_member(self, tname, member):
        for full in self._chain(tname):
            if member in self.types[full]['members']:
                return True
        return False

    def init_status(self, tname, labels):
        from swiftscan import labels_match
        any_init = False
        for full in self._chain(tname):
            inits = self.types[full]['inits']
            if inits:
                any_init = True
            for params in inits:
                if labels_match(labels, params):
                    return True
            if self.types[full]['kind'] == 'class' and inits:
                break  # designated inits aren't inherited once a subclass declares its own
        return False if any_init or self.find_type(tname) else None

    def member_anywhere(self, module, member):
        for full, t in self.types.items():
            if t['module'] == module and member in t['members']:
                return True
        return member in self.globals and self.globals[member] == module

    def summary(self):
        by_mod = {}
        for t in self.types.values():
            d = by_mod.setdefault(t['module'], {'types': 0, 'members': 0})
            d['types'] += 1
            d['members'] += len(t['members'])
        for g, m in self.globals.items():
            by_mod.setdefault(m, {'types': 0, 'members': 0}).setdefault('globals', 0)
            by_mod[m]['globals'] = by_mod[m].get('globals', 0) + 1
        return {'modules': self.modules, 'by_module': by_mod, 'reexports': self.reexports}
