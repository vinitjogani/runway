"""Project inventory by reading text: .xcodeproj (project.pbxproj), Package.swift,
Package.resolved, Tuist/XcodeGen manifests, Info.plist, entitlements and resources.
No manifest is evaluated; Package.swift is pattern-matched, never run."""
import json
import os
import plistlib
import re

SKIP_DIRS = {'.git', '.build', '.swiftpm', 'Pods', 'Carthage', 'DerivedData', 'node_modules', 'xcuserdata', '.runway',
             'build', '.github'}
TEST_DIR_RE = re.compile(r'(^|/)(Tests?|UITests|[A-Za-z0-9_-]*Tests|[A-Za-z0-9_-]*UITests|XCTests?|Specs?)(/|$)')


def walk(root):
    for dp, dirs, files in os.walk(root):
        dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS and not d.endswith(('.xcassets', '.xcframework', '.framework', '.bundle', '.lproj', '.xcodeproj', '.xcworkspace', '.playground')))
        yield dp, dirs, files


# ---------------------------------------------------------------------------
# Old-style (OpenStep) property list, as used by project.pbxproj

_TOK = re.compile(r'\s+|//[^\n]*|/\*.*?\*/|"((?:[^"\\]|\\.)*)"|([{}();,=])|([^\s{}();,="]+)', re.S)


def parse_pbx(text):
    toks = []
    for m in _TOK.finditer(text):
        if m.group(1) is not None:
            toks.append(('s', bytes(m.group(1), 'utf-8').decode('unicode_escape', errors='ignore') if '\\' in m.group(1) else m.group(1)))
        elif m.group(2):
            toks.append(('p', m.group(2)))
        elif m.group(3):
            toks.append(('s', m.group(3)))
    pos = [0]

    def value():
        kind, v = toks[pos[0]]; pos[0] += 1
        if kind == 's':
            return v
        if v == '{':
            d = {}
            while toks[pos[0]] != ('p', '}'):
                k = value()
                pos[0] += 1  # '='
                d[k] = value()
                if toks[pos[0]] == ('p', ';'):
                    pos[0] += 1
            pos[0] += 1
            return d
        if v == '(':
            arr = []
            while toks[pos[0]] != ('p', ')'):
                arr.append(value())
                if toks[pos[0]] == ('p', ','):
                    pos[0] += 1
            pos[0] += 1
            return arr
        raise ValueError('unexpected token ' + v)

    # skip the leading "// !$*UTF8*$!" comment (already dropped by the tokenizer)
    return value()


def _xcconfig(path, depth=0):
    out = {}
    if depth > 4:
        return out
    try:
        lines = open(path, encoding='utf-8', errors='ignore').read().splitlines()
    except OSError:
        return out
    for line in lines:
        line = line.split('//')[0].strip()
        m = re.match(r'#include\??\s+"([^"]+)"', line)
        if m:
            out.update(_xcconfig(os.path.join(os.path.dirname(path), m.group(1)), depth + 1))
            continue
        m = re.match(r'([A-Za-z_][\w]*)(\[[^\]]*\])?\s*=\s*(.*)$', line)
        if m and not m.group(2):
            out[m.group(1)] = m.group(3).strip().rstrip(';').strip()
    return out


def platform_of(s):
    def _s(v):
        return ' '.join(v) if isinstance(v, list) else str(v or '')
    sdk = _s(s.get('SDKROOT'))
    plats = _s(s.get('SUPPORTED_PLATFORMS'))
    platform = 'macos'
    if any(x in sdk for x in ('iphone', 'appletv', 'watch', 'xros')):
        platform = 'ios'
    if sdk in ('', 'auto') and plats and 'macosx' not in plats:
        platform = 'ios'
    if plats and 'macosx' in plats and ('iphone' in plats or 'xr' in plats):
        platform = 'multi'
    return platform


class XcprojJSON:
    """The JSON text project format some projects now commit instead of
    project.pbxproj (`<name>.xcodeproj/project.xcproj`): trailing commas,
    folder-based membership with per-target exclusions."""

    def __init__(self, xcodeproj):
        self.path = xcodeproj
        self.root = os.path.dirname(xcodeproj)
        text = open(os.path.join(xcodeproj, 'project.xcproj'), encoding='utf-8', errors='ignore').read()
        prev = None
        while prev != text:
            prev = text
            text = re.sub(r',(\s*[}\]])', r'\1', text)
        self.data = json.loads(text)

    def inventory(self):
        d = self.data
        proj_settings = d.get('build-settings', {}) or {}
        target_files = {t.get('name'): set() for t in d.get('targets', [])}

        def tname(m):
            if isinstance(m, dict):
                m = m.get('build-phase', '')
            return str(m).split('/')[0]

        def visit(entries, base):
            for e in entries or []:
                p = e.get('path')
                if p and p.startswith('<'):
                    continue
                here = os.path.normpath(os.path.join(base, p)) if p else base
                members = {tname(m) for m in e.get('target-membership', []) or []}
                excl = {}
                for x in e.get('membership-exceptions', []) or []:
                    excl.setdefault(x.get('target'), set()).update(x.get('exclusions', []) or [])
                if e.get('kind') == 'folder' and os.path.isdir(here):
                    for dp, _, fs in walk(here):
                        for f in fs:
                            full = os.path.join(dp, f)
                            rel = os.path.relpath(full, here)
                            for t in members:
                                ex = excl.get(t, set())
                                if rel in ex or any(rel.startswith(x.rstrip('/') + '/') for x in ex):
                                    continue
                                target_files.setdefault(t, set()).add(full)
                elif p and members and not e.get('children'):
                    for t in members:
                        target_files.setdefault(t, set()).add(here)
                visit(e.get('children'), here)

        visit(d.get('files'), self.root)
        packages = []
        for p in d.get('packages', []) or []:
            if p.get('kind') == 'remote':
                packages.append({'url': p.get('repository'), 'requirement': p.get('version', {}), 'products': [], 'used_by': []})
            else:
                packages.append({'local': p.get('path'), 'products': [], 'used_by': []})
        by_ident = {}
        for p in packages:
            ident = (p.get('url') or p.get('local') or '').rstrip('/').split('/')[-1]
            ident = ident[:-4] if ident.endswith('.git') else ident
            by_ident[ident.lower()] = p
        targets = []
        for t in d.get('targets', []):
            s = dict(proj_settings)
            s.update(t.get('build-settings', {}) or {})
            ptype = t.get('product-type', '') or t.get('kind', '')
            prods = []
            for m in t.get('package-product-members', []) or []:
                prods.append(m.get('product-name'))
                p = by_ident.get((m.get('package') or '').lower())
                if p is not None:
                    p['products'].append(m.get('product-name'))
                    p['used_by'].append(t.get('name'))
            files = target_files.get(t.get('name'), set())
            swift = sorted(f for f in files if f.endswith('.swift'))
            targets.append({
                'name': t.get('name'), 'product_type': ptype, 'platform': platform_of(s),
                'test': 'test' in ptype, 'swift_files': len(swift),
                'objc_c_files': sum(1 for f in files if f.endswith(('.m', '.mm', '.c', '.cpp'))),
                'package_products': prods, 'deployment_target': s.get('MACOSX_DEPLOYMENT_TARGET'),
                'swift_version': s.get('SWIFT_VERSION'), 'info_plist': s.get('INFOPLIST_FILE'),
                'generated_info_plist_keys': {k[len('INFOPLIST_KEY_'):]: v for k, v in s.items() if k.startswith('INFOPLIST_KEY_')},
                'sync_groups': 0, 'bridging_header': s.get('SWIFT_OBJC_BRIDGING_HEADER'), 'format': 'xcproj-json',
            })
            target_files[t.get('name')] = swift
        return {'targets': targets, 'packages': packages, 'target_files': target_files, 'synchronized_folders': True}


def open_project(xcodeproj):
    if os.path.exists(os.path.join(xcodeproj, 'project.pbxproj')):
        return XcodeProject(xcodeproj)
    if os.path.exists(os.path.join(xcodeproj, 'project.xcproj')):
        return XcprojJSON(xcodeproj)
    raise FileNotFoundError('no project.pbxproj or project.xcproj in ' + xcodeproj)


class XcodeProject:
    def __init__(self, xcodeproj):
        self.path = xcodeproj
        self.root = os.path.dirname(xcodeproj)
        text = open(os.path.join(xcodeproj, 'project.pbxproj'), encoding='utf-8', errors='ignore').read()
        data = parse_pbx(text)
        self.objects = data.get('objects', {})
        self.rootobj = self.objects.get(data.get('rootObject'), {})
        proj_dir = self.rootobj.get('projectDirPath', '') or ''
        self.base = os.path.normpath(os.path.join(self.root, proj_dir))
        self.parent = {}
        for oid, o in self.objects.items():
            for c in o.get('children', []) or []:
                self.parent[c] = oid
        self._paths = {}

    def obj_path(self, oid):
        if oid in self._paths:
            return self._paths[oid]
        o = self.objects.get(oid, {})
        tree = o.get('sourceTree', '<group>')
        p = o.get('path')
        if tree == '<group>':
            par = self.parent.get(oid)
            base = self.obj_path(par) if par else self.base
            res = None if base is None else (os.path.normpath(os.path.join(base, p)) if p else base)
        elif tree == 'SOURCE_ROOT':
            res = os.path.normpath(os.path.join(self.base, p or ''))
        elif tree == '<absolute>':
            res = p
        else:
            res = None  # BUILT_PRODUCTS_DIR, SDKROOT, DEVELOPER_DIR...
        self._paths[oid] = res
        return res

    def settings(self, conf_list_id):
        cl = self.objects.get(conf_list_id, {})
        confs = [self.objects.get(c, {}) for c in cl.get('buildConfigurations', [])]
        pick = next((c for c in confs if c.get('name') == 'Release'), confs[0] if confs else {})
        s = {}
        base = pick.get('baseConfigurationReference')
        bp = self.obj_path(base) if base else None
        anchor = pick.get('baseConfigurationReferenceAnchor')  # Xcode 16: xcconfig inside a synchronized folder
        if not bp and anchor and self.obj_path(anchor):
            bp = os.path.join(self.obj_path(anchor), pick.get('baseConfigurationReferenceRelativePath', ''))
        if bp:
            s.update(_xcconfig(bp))
        s.update(pick.get('buildSettings', {}) or {})
        return s

    def inventory(self):
        objs = self.objects
        proj_settings = self.settings(self.rootobj.get('buildConfigurationList'))
        packages = {}
        for oid, o in objs.items():
            if o.get('isa') == 'XCRemoteSwiftPackageReference':
                packages[oid] = {'url': o.get('repositoryURL'), 'requirement': o.get('requirement', {}), 'products': [], 'used_by': []}
            elif o.get('isa') == 'XCLocalSwiftPackageReference':
                packages[oid] = {'local': o.get('relativePath') or o.get('path'), 'products': [], 'used_by': []}
        # sync-group exceptions: (group, target) -> set(relative paths)
        sync_exc = {}
        for gid, g in objs.items():
            if g.get('isa') == 'PBXFileSystemSynchronizedRootGroup':
                for eid in g.get('exceptions', []) or []:
                    e = objs.get(eid, {})
                    if e.get('isa') == 'PBXFileSystemSynchronizedBuildFileExceptionSet':
                        sync_exc.setdefault((gid, e.get('target')), set()).update(e.get('membershipExceptions', []) or [])
        sync_groups = {gid for gid, g in objs.items() if g.get('isa') == 'PBXFileSystemSynchronizedRootGroup'}
        targets = []
        target_files = {}
        for tid in self.rootobj.get('targets', []):
            t = objs.get(tid, {})
            if t.get('isa') not in ('PBXNativeTarget', 'PBXAggregateTarget', 'PBXLegacyTarget'):
                continue
            s = dict(proj_settings)
            s.update(self.settings(t.get('buildConfigurationList')))
            files = set()
            for ph in t.get('buildPhases', []):
                p = objs.get(ph, {})
                if p.get('isa') == 'PBXSourcesBuildPhase':
                    for bf in p.get('files', []):
                        ref = objs.get(bf, {}).get('fileRef')
                        if ref:
                            fp = self.obj_path(ref)
                            if fp:
                                files.add(fp)
            own_groups = set(t.get('fileSystemSynchronizedGroups', []) or [])
            for gid in sync_groups:
                gp = self.obj_path(gid)
                if not gp or not os.path.isdir(gp):
                    continue
                exc = sync_exc.get((gid, tid), set())
                if gid in own_groups:
                    for dp, _, fs in walk(gp):
                        for f in fs:
                            full = os.path.join(dp, f)
                            rel = os.path.relpath(full, gp)
                            if rel in exc or any(rel.startswith(x.rstrip('/') + '/') for x in exc):
                                continue
                            files.add(full)
                else:
                    for x in exc:  # files added to a target that doesn't own the group
                        full = os.path.join(gp, x)
                        if os.path.isdir(full):
                            for dp, _, fs in walk(full):
                                files.update(os.path.join(dp, f) for f in fs)
                        else:
                            files.add(full)
            pkg_products = []
            for pd in t.get('packageProductDependencies', []) or []:
                d = objs.get(pd, {})
                name = d.get('productName')
                pkg = d.get('package')
                pkg_products.append(name)
                if pkg in packages:
                    packages[pkg]['products'].append(name)
                    packages[pkg]['used_by'].append(t.get('name'))
            ptype = t.get('productType', '')
            platform = platform_of(s)
            is_test = 'test' in ptype or 'bundle.ui-testing' in ptype
            swift = sorted(f for f in files if f.endswith('.swift'))
            objc = sorted(f for f in files if f.endswith(('.m', '.mm', '.c', '.cpp')))
            infoplist = s.get('INFOPLIST_FILE')
            targets.append({
                'name': t.get('name'), 'product_type': ptype.replace('com.apple.product-type.', ''),
                'platform': platform, 'test': is_test, 'swift_files': len(swift), 'objc_c_files': len(objc),
                'package_products': pkg_products,
                'deployment_target': s.get('MACOSX_DEPLOYMENT_TARGET'),
                'swift_version': s.get('SWIFT_VERSION'),
                'info_plist': infoplist,
                'generated_info_plist_keys': {k[len('INFOPLIST_KEY_'):]: v for k, v in s.items() if k.startswith('INFOPLIST_KEY_')},
                'sync_groups': len(own_groups),
                'bridging_header': s.get('SWIFT_OBJC_BRIDGING_HEADER'),
            })
            target_files[t.get('name')] = swift
        return {'targets': targets, 'packages': list(packages.values()), 'target_files': target_files,
                'synchronized_folders': bool(sync_groups)}


# ---------------------------------------------------------------------------
# Package.swift (pattern-matched; never evaluated)

_PKG_TARGET = re.compile(r'\.(executableTarget|target|testTarget|plugin|binaryTarget|macro|systemLibrary)\s*\(\s*name:\s*"([^"]+)"')


def parse_package_swift(path):
    text = open(path, encoding='utf-8', errors='ignore').read()
    text_nc = re.sub(r'(?<![:"])//[^\n]*', '', text)
    root = os.path.dirname(path)
    targets = []
    for m in _PKG_TARGET.finditer(text_nc):
        kind, name = m.group(1), m.group(2)
        # the target's argument region: up to the next target declaration
        nxt = _PKG_TARGET.search(text_nc, m.end())
        region = text_nc[m.end(): nxt.start() if nxt else len(text_nc)]
        pm = re.search(r'\bpath:\s*"([^"]+)"', region)
        if pm:
            tdir = os.path.join(root, pm.group(1))
        else:
            cands = [os.path.join(root, d, name) for d in (('Tests',) if kind == 'testTarget' else ('Sources', 'Source', 'src', 'srcs', 'Plugins'))]
            tdir = next((c for c in cands if os.path.isdir(c)), cands[0])
        deps = re.findall(r'\.product\(\s*name:\s*"([^"]+)"\s*,\s*package:\s*"([^"]+)"', region)
        targets.append({'name': name, 'kind': kind, 'dir': os.path.normpath(tdir),
                        'products': [d[0] for d in deps]})
    remote = re.findall(r'\.package\(\s*(?:name:\s*"[^"]*"\s*,\s*)?url:\s*"([^"]+)"', text_nc)
    local = re.findall(r'\.package\(\s*(?:name:\s*"[^"]*"\s*,\s*)?path:\s*"([^"]+)"', text_nc)
    name = re.search(r'Package\(\s*name:\s*"([^"]+)"', text_nc)
    return {'path': path, 'name': name.group(1) if name else os.path.basename(root), 'targets': targets,
            'remote': remote, 'local': [os.path.normpath(os.path.join(root, l)) for l in local],
            'binary_targets': [t['name'] for t in targets if t['kind'] == 'binaryTarget'],
            'products': re.findall(r'\.(?:library|executable|plugin)\(\s*name:\s*"([^"]+)"', text_nc)}


def parse_resolved(path):
    try:
        data = json.load(open(path, encoding='utf-8'))
    except Exception:
        return []
    pins = data.get('pins') or data.get('object', {}).get('pins') or []
    out = []
    for p in pins:
        url = p.get('location') or p.get('repositoryURL')
        st = p.get('state', {})
        out.append({'url': url, 'version': st.get('version'), 'revision': st.get('revision'), 'branch': st.get('branch')})
    return out


def norm_url(url):
    if not url:
        return url
    u = url.strip().lower()
    u = re.sub(r'^git@github\.com:', 'https://github.com/', u)
    u = re.sub(r'^http://', 'https://', u)
    u = u.rstrip('/')
    if u.endswith('.git'):
        u = u[:-4]
    return u


# ---------------------------------------------------------------------------
# Plists, entitlements, resources


def read_plist(path):
    try:
        with open(path, 'rb') as f:
            return plistlib.load(f)
    except Exception:
        return None


INTERESTING_PLIST = re.compile(r'^(LSUIElement|LSBackgroundOnly|NSPrincipalClass|NSMainStoryboardFile|NSMainNibFile|'
                               r'CFBundleURLTypes|CFBundleDocumentTypes|UTExportedTypeDeclarations|UTImportedTypeDeclarations|'
                               r'NSServices|SU\w+|NS\w+UsageDescription|NSAppTransportSecurity|LSApplicationCategoryType|'
                               r'NSSupportsAutomaticTermination|NSSupportsSuddenTermination|LSMinimumSystemVersion|'
                               r'NSAppleScriptEnabled|OSAScriptingDefinition|NSExtension|LSMultipleInstancesProhibited|'
                               r'NSHighResolutionCapable|ATSApplicationFontsPath|NSUserActivityTypes|LSEnvironment|'
                               r'NSSupportsLiveResize|NSRequiresAquaSystemAppearance|SMPrivilegedExecutables|SMAuthorizedClients)$')


def resources(root):
    r = {'xcassets': 0, 'imagesets': 0, 'colorsets': 0, 'appiconsets': 0, 'strings': 0, 'xcstrings': 0,
         'stringsdict': 0, 'storyboards': 0, 'xibs': 0, 'lproj_languages': set(), 'icns': 0, 'sdef': 0,
         'entitlements': 0, 'xcdatamodel': 0, 'metal': 0, 'js_css_html': 0, 'fonts': 0, 'sounds': 0,
         'xcframeworks': [], 'frameworks': [], 'bundles': 0, 'intentdefinition': 0, 'icon_files': 0}
    for dp, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        base = os.path.basename(dp)
        if base.endswith('.xcassets'):
            r['xcassets'] += 1
        elif base.endswith('.imageset'):
            r['imagesets'] += 1
        elif base.endswith('.colorset'):
            r['colorsets'] += 1
        elif base.endswith('.appiconset'):
            r['appiconsets'] += 1
        elif base.endswith('.lproj'):
            r['lproj_languages'].add(base[:-6])
        elif base.endswith(('.xcdatamodel',)):
            r['xcdatamodel'] += 1
        elif base.endswith('.xcframework'):
            r['xcframeworks'].append(os.path.relpath(dp, root)); dirs[:] = []
        elif base.endswith('.framework'):
            r['frameworks'].append(os.path.relpath(dp, root)); dirs[:] = []
        elif base.endswith('.icon'):
            r['icon_files'] += 1
        for f in files:
            ext = os.path.splitext(f)[1].lower()
            key = {'.strings': 'strings', '.xcstrings': 'xcstrings', '.stringsdict': 'stringsdict', '.storyboard': 'storyboards',
                   '.xib': 'xibs', '.icns': 'icns', '.sdef': 'sdef', '.entitlements': 'entitlements', '.metal': 'metal',
                   '.js': 'js_css_html', '.css': 'js_css_html', '.html': 'js_css_html', '.ttf': 'fonts', '.otf': 'fonts',
                   '.aiff': 'sounds', '.wav': 'sounds', '.caf': 'sounds', '.mp3': 'sounds', '.intentdefinition': 'intentdefinition'}.get(ext)
            if key:
                r[key] += 1
    r['lproj_languages'] = sorted(r['lproj_languages'] - {'Base'})
    return r


def info_plists(root):
    """Info.plist-like files (not inside resources bundles) -> merged interesting keys."""
    keys = {}
    files = []
    for dp, dirs, fs in walk(root):
        for f in fs:
            if f == 'Info.plist' or (f.endswith('-Info.plist')) or f.endswith('Info.plist'):
                p = os.path.join(dp, f)
                if TEST_DIR_RE.search(os.path.relpath(p, root)):
                    continue
                d = read_plist(p)
                if isinstance(d, dict):
                    files.append(os.path.relpath(p, root))
                    for k, v in d.items():
                        if INTERESTING_PLIST.match(k):
                            keys.setdefault(k, _plist_summary(v))
    return files, keys


def _plist_summary(v):
    if isinstance(v, (str, int, float, bool)):
        return v
    if isinstance(v, list):
        return '[%d items]' % len(v)
    if isinstance(v, dict):
        return '{%s}' % ', '.join(sorted(v)[:6])
    return str(type(v).__name__)


def entitlements(root):
    keys = {}
    for dp, dirs, fs in walk(root):
        for f in fs:
            if f.endswith('.entitlements'):
                d = read_plist(os.path.join(dp, f))
                if isinstance(d, dict):
                    for k, v in d.items():
                        keys.setdefault(k, _plist_summary(v))
    return keys
