"""Per-file Swift usage extraction (imports, ObjC-runtime features, #if
conditions, Apple API identifiers and members, SwiftUI views/modifiers)."""
import re
from collections import Counter, defaultdict

import apple_names as A
from swiftscan import strip_swift, mac_active, match_paren, call_labels, init_key

IMPORT_RE = re.compile(r'^[ \t]*(?:@[\w]+(?:\([^)\n]*\))?[ \t]+)*(?:(?:public|internal|package|private|fileprivate)[ \t]+)?import[ \t]+(?:(?:typealias|struct|class|enum|protocol|let|var|func)[ \t]+)?([A-Za-z_]\w*)', re.M)

OBJC_FEATURES = {
    '@objc': re.compile(r'@objc\b(?!Members)'),
    '@objcMembers': re.compile(r'@objcMembers\b'),
    '#selector': re.compile(r'#selector\s*\('),
    '@IBAction': re.compile(r'@IBAction\b'),
    '@IBOutlet': re.compile(r'@IBOutlet\b'),
    '@IBDesignable/@IBInspectable': re.compile(r'@IB(?:Designable|Inspectable)\b'),
    'dynamic': re.compile(r'\bdynamic\s+(?:(?:public|private|fileprivate|internal|open|final|override|static|class|weak|lazy|required|nonisolated)\s+)*(?:var|func|subscript)\b'),
    'NSObject subclass': re.compile(r'\bclass\s+\w+\s*(?:<[^>{]*>)?\s*:\s*NSObject\b'),
    'KVO observe(\\.)': re.compile(r'\bobserve\s*\(\s*\\'),
    'addObserver(forKeyPath:)': re.compile(r'addObserver\s*\([^;{}]{0,300}?forKeyPath\s*:', re.S),
    'observeValue(forKeyPath:) override': re.compile(r'func\s+observeValue\s*\(\s*forKeyPath'),
    'perform(selector)': re.compile(r'(?<![\w])perform\s*\(\s*(?:#selector|Selector\s*\(|NSSelectorFromString|[\w.]+\s*,\s*(?:with|on|afterDelay)\s*:)|\bperformSelector\w*\s*\('),
    'responds(to:)': re.compile(r'\bresponds\s*\(\s*to\s*:'),
    '@NSManaged': re.compile(r'@NSManaged\b'),
    'NSClassFromString': re.compile(r'\bNSClassFromString\s*\('),
    'NSSelectorFromString/Selector("")': re.compile(r'\bNSSelectorFromString\s*\(|\bSelector\s*\(\s*"'),
    '#keyPath': re.compile(r'#keyPath\s*\('),
    'Cocoa bindings bind(_:to:)': re.compile(r'\.bind\s*\(\s*(?:\.\w+|NSBindingName[^,]*)\s*,\s*to\s*:'),
    'objc runtime C API': re.compile(r'\b(?:method_exchangeImplementations|class_getInstanceMethod|class_getClassMethod|objc_setAssociatedObject|objc_getAssociatedObject|object_getClass|class_addMethod|method_setImplementation|method_getImplementation|objc_getClass|objc_msgSend|class_replaceMethod|objc_allocateClassPair|class_copyMethodList|class_copyPropertyList|object_setClass|sel_registerName|imp_implementationWithBlock)\s*\('),
    '@_silgen_name / dlsym (private API)': re.compile(r'@_silgen_name\s*\(|\bdlsym\s*\(|\bdlopen\s*\('),
    'NSAppleScript / OSAScript': re.compile(r'\b(?:NSAppleScript|OSAScript|NSUserAppleScriptTask)\b'),
    'Process (subprocess)': re.compile(r'\bProcess\s*\(\s*\)|\bNSTask\b'),
    '@objc protocol / optional': re.compile(r'@objc\s+(?:public\s+|internal\s+)?protocol\b|@objc\s+optional\b|\boptional\s+func\b'),
    'NotificationCenter selector observer': re.compile(r'addObserver\s*\(\s*self\s*,\s*selector\s*:'),
    'target/action (.target = / action:)': re.compile(r'\.target\s*=\s*self\b|\baction\s*:\s*#selector'),
    '@NSApplicationMain/@main AppDelegate': re.compile(r'@NSApplicationMain\b'),
}

DECL_RE = re.compile(r'\b(?:class|struct|enum|protocol|actor|typealias|associatedtype)\s+([A-Za-z_]\w*)')
EXT_RE = re.compile(r'\bextension\s+([A-Za-z_][\w.]*)[^{]*\{')
SUBCLASS_RE = re.compile(r'\bclass\s+(\w+)\s*(?:<[^>{]*>)?\s*:\s*([A-Z]\w*)')
FUNC_NAME_RE = re.compile(r'\b(?:func|var|let|case)\s+`?([A-Za-z_]\w*)')
OVERRIDE_RE = re.compile(r'\boverride\s+(?:(?:public|open|internal|private|fileprivate|final|class|static|dynamic|@\w+)\s+)*(func|var)\s+([A-Za-z_]\w*)')
VAR_TYPED_RE = re.compile(r'(?:\b(?:let|var)\s+|[(,]\s*(?:_\s+)?(?:\w+\s+)?)(\w+)\s*:\s*(?:inout\s+)?(?:@\w+\s+)?([A-Z]\w+)\b(?!\s*[.<(\[])')
VAR_INIT_RE = re.compile(r'\b(?:let|var)\s+(\w+)\s*=\s*([A-Z]\w+)\s*(?:\(|\.\s*(?:shared|current|main|default|general|standard)\b)')
VAR_CAST_RE = re.compile(r'\b(?:let|var)\s+(\w+)\s*=\s*[^\n]*?\bas[!?]\s*([A-Z]\w+)\b')
MODIFIER_RE = re.compile(r'(?:^|[)\]}])[ \t]*\n?[ \t]*\.([a-z]\w*)\s*[({]', re.M)
VIEW_CALL_RE = re.compile(r'(?<![\w.])([A-Z]\w*)\s*(?:\(|\{)')
WRAPPER_RE = re.compile(r'@([A-Z]\w*)\b')
ENV_KEY_RE = re.compile(r'@Environment\s*\(\s*\\\.(\w+)|\.environment\s*\(\s*\\\.(\w+)')
TYPE_POS_RE = re.compile(r'(?:[:<\[]|->|\bas[?!]?|\bis|\bextension|\bclass\s+\w+\s*:\s*(?:\w+\s*,\s*)*|,)\s*(?:any\s+|some\s+)?([A-Z]\w+)\b(?!\s*\()|\b([A-Z]\w+)\s*(?:\.\s*(?:self|Type)\b|[?!]?\s*[>\]])')
IF_ATOM_RE = re.compile(r'\b(os|canImport|targetEnvironment|arch|swift|compiler)\s*\(\s*([^)]*?)\s*\)')

SINGLETON_ACCESSORS = {'shared', 'current', 'main', 'default', 'general', 'standard', 'systemWide', 'sharedApplication',
                       'sharedWorkspace', 'mainScreen'}
GLOBAL_INSTANCES = {'NSApp': 'NSApplication'}


def analyze_source(raw):
    """Returns a dict of Counters for one file. App-declared names are filtered later."""
    code0 = strip_swift(raw)
    code, conds = mac_active(code0)
    res = {
        'loc': sum(1 for l in raw.split('\n') if l.strip()),
        'imports': Counter(), 'objc': Counter(), 'if_atoms': Counter(), 'if_conditions': len(conds),
        'symbols': Counter(),          # (framework, name)
        'members': Counter(),          # (type, member)  type may be resolved later
        'inits': Counter(),            # (type, init-key)
        'overrides': Counter(),        # (superclass, member)
        'subclasses': Counter(),       # superclass name
        'swiftui_types': Counter(), 'swiftui_modifiers': Counter(), 'chained_other': Counter(),
        'wrappers': Counter(), 'env_keys': Counter(),
        'decl_types': set(), 'decl_members': defaultdict(set), 'decl_funcs': set(),
        'swiftui_app_main': bool(re.search(r'\bstruct\s+\w+\s*:\s*(?:\w+\s*,\s*)*App\b\s*(?:,|\{)', code)),
        'type_positions': set(),
        'appkit_main': bool(re.search(r'@(?:NSApplicationMain|main)\s+(?:@\w+\s+)*(?:final\s+)?class\s+\w+\s*:\s*NSObject\s*,\s*NSApplicationDelegate', code))
                       or 'NSApplicationMain(' in code,
    }
    for c in conds:
        for m in IF_ATOM_RE.finditer(c):
            res['if_atoms']['%s(%s)' % (m.group(1), m.group(2))] += 1
        for f in re.findall(r'(?<![\w(])([A-Z][A-Z0-9_]+)\b', c):
            res['if_atoms']['flag ' + f] += 1
    imports = set(IMPORT_RE.findall(code0))  # imports in any branch
    for i in imports:
        res['imports'][i] += 1
    active_imports = set(IMPORT_RE.findall(code))
    for k, rx in OBJC_FEATURES.items():
        n = len(rx.findall(code))
        if n:
            res['objc'][k] += n
    # declarations (to tell the app's own names from Apple's)
    res['decl_types'].update(DECL_RE.findall(code0))
    res['decl_funcs'].update(FUNC_NAME_RE.findall(code0))
    for m in EXT_RE.finditer(code0):
        start = m.end() - 1
        end = _match_brace(code0, start)
        body = code0[start:end]
        for n in FUNC_NAME_RE.findall(body):
            res['decl_members'][m.group(1)].add(n)
        for n in DECL_RE.findall(body):
            res['decl_members'][m.group(1)].add(n)

    # Apple identifiers by prefix
    prx = A.prefix_regex()
    for m in prx.finditer(code):
        k, prefix, rest = m.group(1), m.group(2), m.group(3)
        name = k + prefix + rest
        if not k and not re.search(r'[a-z]', prefix + rest):
            continue  # SCREAMING_CASE constants are rarely Apple API
        fw = A.framework_of(prefix, prefix + rest)
        res['symbols'][(fw, name)] += 1
    # Swift-named API, gated on imports
    words = None
    for fw, names in A.SWIFT_NAMED.items():
        gate = A.SWIFT_NAMED_IMPORTS.get(fw)
        if gate is not None and not (active_imports & gate):
            continue
        if words is None:
            words = Counter(re.findall(r'(?<![\w.])([A-Za-z_]\w*)', code))
        for n in names:
            if words.get(n):
                res['symbols'][(fw, n)] += words[n]

    for a, b in TYPE_POS_RE.findall(code):
        res['type_positions'].add(a or b)
    # members via Type.member, singletons, typed variables, subclasses
    var_types = {}
    for rx in (VAR_TYPED_RE, VAR_INIT_RE, VAR_CAST_RE):
        for v, t in rx.findall(code):
            var_types.setdefault(v, t)
    for g, t in GLOBAL_INSTANCES.items():
        var_types[g] = t
    for m in re.finditer(r'(?<![\w.])([A-Z]\w+)\s*\.\s*([a-zA-Z_]\w*)(\s*[?!]?\s*\.\s*([a-zA-Z_]\w*))?', code):
        t, mem, nxt = m.group(1), m.group(2), m.group(4)
        if mem in ('self', 'Type', 'init'):
            continue
        res['members'][(t, mem)] += 1
        if nxt and mem in SINGLETON_ACCESSORS:
            res['members'][(t, nxt)] += 1
    for m in re.finditer(r'(?<![\w.])([a-z_]\w*)\s*[?!]?\s*\.\s*([a-zA-Z_]\w*)', code):
        v, mem = m.group(1), m.group(2)
        t = var_types.get(v)
        if t:
            res['members'][(t, mem)] += 1
    # initializers: Type(label:...) and Type.init(...)
    for m in re.finditer(r'(?<![\w.])([A-Z]\w+)\s*(?:\.\s*init\s*)?\(', code):
        t = m.group(1)
        p = m.end() - 1
        q = match_paren(code, p)
        res['inits'][(t, init_key(call_labels(code[p + 1:q])))] += 1
    # subclasses and their overrides / self.x / super.x
    for m in SUBCLASS_RE.finditer(code):
        cls, sup = m.group(1), m.group(2)
        res['subclasses'][sup] += 1
        brace = code.find('{', m.end())
        if brace < 0:
            continue
        end = _match_brace(code, brace)
        body = code[brace:end]
        own = set(FUNC_NAME_RE.findall(body)) - {n for _, n in OVERRIDE_RE.findall(body)}
        for _, n in OVERRIDE_RE.findall(body):
            res['overrides'][(sup, n)] += 1
        for n in re.findall(r'\b(?:self|super)\s*\.\s*([a-zA-Z_]\w*)', body):
            if n not in own:
                res['members'][(sup, n)] += 1

    # SwiftUI
    if 'SwiftUI' in active_imports:
        for m in VIEW_CALL_RE.finditer(code):
            if m.group(1) in A.SWIFTUI_TYPES:
                res['swiftui_types'][m.group(1)] += 1
        for t in re.findall(r':\s*([A-Z]\w+)\b', code):
            if t in A.SWIFTUI_TYPES and t in ('App', 'Scene', 'View', 'ViewModifier', 'ButtonStyle', 'ToggleStyle', 'Shape',
                                               'PreferenceKey', 'EnvironmentKey', 'NSViewRepresentable', 'NSViewControllerRepresentable',
                                               'LabelStyle', 'PrimitiveButtonStyle', 'Layout', 'Commands', 'DropDelegate',
                                               'FileDocument', 'ReferenceFileDocument', 'ToolbarContent', 'FocusedValueKey',
                                               'TextFieldStyle', 'ProgressViewStyle', 'GroupBoxStyle', 'MenuStyle', 'PickerStyle'):
                res['swiftui_types'][t] += 1
        for m in MODIFIER_RE.finditer(code):
            n = m.group(1)
            if n in A.SWIFTUI_MODIFIERS:
                res['swiftui_modifiers'][n] += 1
            elif n not in A.NOT_MODIFIERS:
                res['chained_other'][n] += 1
        for m in ENV_KEY_RE.finditer(code):
            res['env_keys'][m.group(1) or m.group(2)] += 1
    for w in WRAPPER_RE.findall(code):
        res['wrappers'][w] += 1
    return res


def _match_brace(s, i):
    depth = 0
    for j in range(i, len(s)):
        c = s[j]
        if c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0:
                return j + 1
    return len(s)
