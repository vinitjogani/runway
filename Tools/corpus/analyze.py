#!/usr/bin/env python3
"""Runway corpus analyzer: what do real macOS apps need, and what does Runway have?

Static text analysis only. It reads app sources (Swift, project.pbxproj,
Package.swift, Package.resolved, plists) and Runway's own public declarations,
and writes a ranked gap report. It never builds, resolves, evaluates or runs
anything it reads.

    python3 -I analyze.py                        # analyze + write report.md / report.json
    python3 -I analyze.py --corpus DIR           # where the app clones live
    python3 -I analyze.py fetch                  # clone missing apps (git clone --depth 1)
    python3 -I analyze.py deps                   # list third-party packages + clone dirs
    python3 -I analyze.py query type NSStatusItem
    python3 -I analyze.py query member NSWindow.styleMask
    python3 -I analyze.py query module Combine
    python3 -I analyze.py query app Maccy

Inputs:  apps.json (the corpus), runway/Sources/** (what Runway provides).
Outputs: report.md, report.json, apps.json (computed fields refreshed).
Env:     RUNWAY_CORPUS_DIR (default ~/.cache/runway-corpus/apps),
         RUNWAY_CORPUS_DEPS (default <corpus>/../deps).
"""
import argparse
import datetime
import json
import os
import re
import subprocess
import sys
from collections import Counter, defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import apple_names as A  # noqa: E402
import projects as P  # noqa: E402
from runway_api import RunwayAPI  # noqa: E402
from sources import analyze_source  # noqa: E402

RUNWAY_DIR = os.path.dirname(os.path.dirname(HERE))
REPO_DIR = os.environ.get('RUNWAY_REPO') or os.path.dirname(RUNWAY_DIR)
APPS_JSON = os.path.join(HERE, 'apps.json')
VCS_DIR = '.' + 'git'

ANNOTATION_KEYS = ('name', 'url', 'license', 'ui', 'notes', 'source')


# ---------------------------------------------------------------------------
# Corpus


def default_corpus():
    return os.environ.get('RUNWAY_CORPUS_DIR') or os.path.expanduser('~/.cache/runway-corpus/apps')


def app_root(app, corpus):
    src = app['source']
    if src['kind'] == 'repo':
        return os.path.join(REPO_DIR, src['path'])
    return os.path.join(corpus, src['dir'])


def read_commit(root):
    g = os.path.join(root, VCS_DIR)
    try:
        head = open(os.path.join(g, 'HEAD')).read().strip()
    except OSError:
        return None
    if not head.startswith('ref:'):
        return head
    ref = head[4:].strip()
    try:
        return open(os.path.join(g, ref)).read().strip()
    except OSError:
        pass
    try:
        for line in open(os.path.join(g, 'packed-refs')):
            parts = line.split()
            if len(parts) == 2 and parts[1] == ref:
                return parts[0]
    except OSError:
        pass
    return None


def detect_license(root):
    for f in sorted(os.listdir(root)) if os.path.isdir(root) else []:
        if f.lower().startswith(('license', 'licence', 'copying')):
            t = open(os.path.join(root, f), errors='ignore').read(4000)
            if 'Commons Clause' in t:
                return 'Commons-Clause (not permissive)'
            if 'GNU GENERAL PUBLIC LICENSE' in t:
                return 'GPL'
            if 'Apache License' in t:
                return 'Apache-2.0'
            if 'Permission is hereby granted, free of charge' in t:
                return 'MIT'
            if 'Redistribution and use in source and binary forms' in t:
                return 'BSD-3-Clause' if 'Neither the name' in t or 'endorse or promote' in t else 'BSD-2-Clause'
            if 'Mozilla Public License' in t:
                return 'MPL-2.0'
            return 'unknown (' + f + ')'
    return None


# ---------------------------------------------------------------------------
# Per-app inventory


def find_files(root, pred, max_depth=None):
    out = []
    for dp, dirs, files in os.walk(root):
        rel = os.path.relpath(dp, root)
        depth = 0 if rel == '.' else rel.count(os.sep) + 1
        keep = []
        for d in dirs:
            if d in P.SKIP_DIRS:
                continue
            if pred(d, True):
                out.append(os.path.join(dp, d))
                continue
            if max_depth is None or depth < max_depth:
                keep.append(d)
        dirs[:] = sorted(keep)
        for f in files:
            if pred(f, False):
                out.append(os.path.join(dp, f))
    return sorted(out)


def is_manifest(path, root):
    b = os.path.basename(path)
    rel = os.path.relpath(path, root)
    if b in ('Package.swift', 'Project.swift', 'Workspace.swift', 'Config.swift', 'Dependencies.swift') and \
            (b == 'Package.swift' or rel.split(os.sep)[0] in ('Tuist', 'Project.swift', 'Workspace.swift') or rel == b):
        return True
    return rel.split(os.sep)[0] == 'Tuist' or '/Tuist/' in rel or 'ProjectDescriptionHelpers' in rel


def inventory_app(app, root):
    inv = {'root': root}
    xcodeprojs = find_files(root, lambda n, d: d and n.endswith('.xcodeproj'), max_depth=3)
    workspaces = [w for w in find_files(root, lambda n, d: d and n.endswith('.xcworkspace'), max_depth=2)]
    pkg_files = find_files(root, lambda n, d: (not d) and n == 'Package.swift')
    tuist_manifests = [p for p in pkg_files if is_manifest_tuist(p, root)]
    tuist_manifests += [p for p in (os.path.join(root, 'Project.swift'), os.path.join(root, 'Workspace.swift')) if os.path.exists(p)]
    pkg_files = [p for p in pkg_files if not is_manifest_tuist(p, root)]
    resolved = find_files(root, lambda n, d: (not d) and n == 'Package.resolved')
    tuist = os.path.exists(os.path.join(root, 'Project.swift')) or os.path.isdir(os.path.join(root, 'Tuist'))
    xcodegen = find_files(root, lambda n, d: (not d) and n == 'project.yml', max_depth=2)
    podfile = find_files(root, lambda n, d: (not d) and n == 'Podfile', max_depth=2)
    cartfile = find_files(root, lambda n, d: (not d) and n == 'Cartfile', max_depth=2)
    root_pkg = os.path.join(root, 'Package.swift')

    fmt = []
    if os.path.exists(root_pkg):
        fmt.append('swiftpm')
    if tuist:
        fmt.append('tuist')
    if xcodegen:
        fmt.append('xcodegen')
    if xcodeprojs:
        fmt.append('xcodeproj')
    if any(not os.path.exists(os.path.join(x, 'project.pbxproj')) and os.path.exists(os.path.join(x, 'project.xcproj')) for x in xcodeprojs):
        fmt.append('xcproj-json')
    if [w for w in workspaces if not w.endswith('project.xcworkspace')]:
        fmt.append('xcworkspace')
    if podfile:
        fmt.append('cocoapods')
    if cartfile:
        fmt.append('carthage')
    local_pkgs = [p for p in pkg_files if p != root_pkg]
    if local_pkgs:
        fmt.append('local-packages')
    inv['format'] = fmt
    inv['primary_format'] = ('xcodeproj' if xcodeprojs and not os.path.exists(root_pkg) and not tuist
                             else 'swiftpm' if os.path.exists(root_pkg) else 'tuist' if tuist else 'none')

    file_targets = defaultdict(list)
    targets = []
    pbx_packages = []
    sync = False
    for xp in xcodeprojs:
        try:
            x = P.open_project(xp).inventory()
        except Exception as e:  # malformed project: record and carry on
            targets.append({'name': os.path.basename(xp), 'error': str(e)[:200]})
            continue
        sync = sync or x['synchronized_folders']
        for t in x['targets']:
            t['project'] = os.path.relpath(xp, root)
            targets.append(t)
            for f in x['target_files'][t['name']]:
                file_targets[os.path.normpath(f)].append((t['name'], t['test'], t['platform']))
        for p in x['packages']:
            p['project'] = os.path.relpath(xp, root)
            pbx_packages.append(p)
    pkgs = []
    for pf in pkg_files:
        try:
            pk = P.parse_package_swift(pf)
        except Exception:
            continue
        pkgs.append(pk)
        for t in pk['targets']:
            if t['kind'] in ('binaryTarget', 'systemLibrary'):
                continue
            is_test = t['kind'] == 'testTarget'
            n = 0
            if os.path.isdir(t['dir']):
                for dp, _, fs in P.walk(t['dir']):
                    for f in fs:
                        if f.endswith('.swift'):
                            file_targets[os.path.normpath(os.path.join(dp, f))].append(
                                (pk['name'] + '/' + t['name'], is_test or t['kind'] == 'plugin', 'macos'))
                            n += 1
            targets.append({'name': pk['name'] + '/' + t['name'], 'product_type': 'swiftpm-' + t['kind'], 'platform': 'macos',
                            'test': is_test, 'swift_files': n, 'project': os.path.relpath(pf, root),
                            'package_products': t['products']})
    inv['targets'] = targets
    inv['synchronized_folders'] = sync

    # Swift files and scope
    all_swift = find_files(root, lambda n, d: (not d) and n.endswith('.swift'))
    in_scope, out = [], Counter()
    for f in all_swift:
        f = os.path.normpath(f)
        rel = os.path.relpath(f, root)
        if is_manifest(f, root):
            out['manifest'] += 1
            continue
        tg = file_targets.get(f)
        if tg:
            if any((not test) and plat in ('macos', 'multi') for _, test, plat in tg):
                in_scope.append(f)
            elif all(test for _, test, _ in tg):
                out['test target'] += 1
            else:
                out['iOS-only target'] += 1
        else:
            if P.TEST_DIR_RE.search(rel):
                out['test dir (unassigned)'] += 1
            elif xcodeprojs and not tuist and not os.path.exists(root_pkg):
                out['not in any target'] += 1
            else:
                in_scope.append(f)
    inv['swift_files_total'] = len(all_swift)
    inv['swift_files_in_scope'] = len(in_scope)
    inv['out_of_scope'] = dict(out)
    inv['scope_files'] = in_scope

    # dependencies
    direct = {}
    for p in pbx_packages:
        if p.get('url'):
            u = P.norm_url(p['url'])
            d = direct.setdefault(u, {'url': u, 'via': set(), 'products': set(), 'used_by': set(), 'requirement': None})
            d['via'].add('xcodeproj')
            d['products'].update(p['products'])
            d['used_by'].update(p['used_by'])
            d['requirement'] = d['requirement'] or _req(p.get('requirement'))
    test_targets = {t['name'] for t in targets if t.get('test')}
    for pk in pkgs:
        for u in pk['remote']:
            u = P.norm_url(u)
            d = direct.setdefault(u, {'url': u, 'via': set(), 'products': set(), 'used_by': set(), 'requirement': None})
            d['via'].add(os.path.relpath(pk['path'], root))
        ident_users = defaultdict(set)
        for t in pk['targets']:
            for prod in t['products']:
                pass
        text = open(pk['path'], encoding='utf-8', errors='ignore').read()
        for m in re.finditer(r'\.product\(\s*name:\s*"([^"]+)"\s*,\s*package:\s*"([^"]+)"', text):
            ident_users[m.group(2).lower()].add(m.group(1))
        for u in pk['remote']:
            ident = P.norm_url(u).rsplit('/', 1)[-1]
            for prod in ident_users.get(ident, ()):
                direct[P.norm_url(u)]['products'].add(prod)
            # which targets use it
            for t in pk['targets']:
                if any(prod in t['products'] for prod in ident_users.get(ident, ())):
                    direct[P.norm_url(u)]['used_by'].add(pk['name'] + '/' + t['name'])
                    if t['kind'] == 'testTarget':
                        test_targets.add(pk['name'] + '/' + t['name'])
    for tm in tuist_manifests:  # Tuist's dependency manifests: remote packages only
        text = open(tm, encoding='utf-8', errors='ignore').read()
        for m in re.finditer(r'\.(?:package|remote)\(\s*url:\s*"([^"]+)"', text):
            u = P.norm_url(m.group(1))
            d = direct.setdefault(u, {'url': u, 'via': set(), 'products': set(), 'used_by': set(), 'requirement': None})
            d['via'].add(os.path.relpath(tm, root))
    for pf in podfile:
        for m in re.finditer(r"^\s*pod\s+'([^']+)'", open(pf, errors='ignore').read(), re.M):
            u = 'cocoapods:' + m.group(1).lower()
            direct.setdefault(u, {'url': u, 'via': {'Podfile'}, 'products': {m.group(1)}, 'used_by': set(), 'requirement': None})
    for cf in cartfile:
        for m in re.finditer(r'^\s*(github|git|binary)\s+"([^"]+)"', open(cf, errors='ignore').read(), re.M):
            u = P.norm_url('https://github.com/' + m.group(2) if m.group(1) == 'github' else m.group(2))
            direct.setdefault(u, {'url': u, 'via': {'Cartfile'}, 'products': set(), 'used_by': set(), 'requirement': None})
    pins = {}
    for rf in resolved:
        for pin in P.parse_resolved(rf):
            if pin['url']:
                pins[P.norm_url(pin['url'])] = pin
    deps = []
    for u, d in sorted(direct.items()):
        used = d['used_by']
        deps.append({'url': u, 'name': u.rsplit('/', 1)[-1], 'direct': True, 'via': sorted(d['via']),
                     'products': sorted(d['products']), 'used_by': sorted(used),
                     'test_only': bool(used) and used <= test_targets,
                     'version': (pins.get(u) or {}).get('version') or (pins.get(u) or {}).get('branch') or d['requirement']})
    for u, pin in sorted(pins.items()):
        if u not in direct:
            deps.append({'url': u, 'name': u.rsplit('/', 1)[-1], 'direct': False, 'via': ['Package.resolved'],
                         'products': [], 'used_by': [], 'test_only': False, 'version': pin.get('version') or pin.get('branch')})
    inv['dependencies'] = deps
    inv['local_packages'] = [os.path.relpath(p['path'], root) for p in pkgs if p['path'] != root_pkg]

    # plists, entitlements, resources
    files, keys = P.info_plists(root)
    for t in targets:
        for k, v in (t.get('generated_info_plist_keys') or {}).items():
            keys.setdefault(k, v)
    inv['info_plist_files'] = files
    inv['info_plist_keys'] = keys
    inv['entitlements'] = P.entitlements(root)
    inv['resources'] = P.resources(root)
    return inv


def is_manifest_tuist(path, root):
    rel = os.path.relpath(path, root)
    return rel.split(os.sep)[0] in ('Tuist',) or rel.startswith('Plugins' + os.sep + 'Tuist')


def _req(r):
    if not r:
        return None
    for k in ('version', 'minimumVersion', 'branch', 'revision'):
        if r.get(k):
            return r.get('kind', '') + ' ' + r[k]
    return r.get('kind')


# ---------------------------------------------------------------------------
# Usage aggregation per app


def analyze_usage(inv, dep_decls):
    totals = {k: Counter() for k in ('imports', 'objc', 'if_atoms', 'symbols', 'members', 'inits', 'overrides', 'subclasses',
                                     'swiftui_types', 'swiftui_modifiers', 'chained_other', 'wrappers', 'env_keys')}
    decl_types, decl_funcs, type_positions = set(), set(), set()
    decl_members = defaultdict(set)
    loc = 0
    if_conditions = 0
    entry = Counter()
    file_imports = []
    for f in inv['scope_files']:
        try:
            raw = open(f, encoding='utf-8', errors='ignore').read()
        except OSError:
            continue
        r = analyze_source(raw)
        loc += r['loc']
        if_conditions += r['if_conditions']
        for k in totals:
            totals[k].update(r[k])
        decl_types |= r['decl_types']
        type_positions |= r['type_positions']
        decl_funcs |= r['decl_funcs']
        for t, ms in r['decl_members'].items():
            decl_members[t] |= ms
        if r['swiftui_app_main']:
            entry['SwiftUI App'] += 1
        if r['appkit_main']:
            entry['AppKit delegate'] += 1
        file_imports.append(set(r['imports']))
    own = decl_types | dep_decls

    # attribute symbols
    fw_of = {}
    symbols = Counter()
    for (fw, name), n in totals['symbols'].items():
        if name in own and fw not in ('Combine', 'os', 'OSLog', 'SwiftData', 'Foundation'):
            continue
        symbols[(fw, name)] += n
        fw_of.setdefault(name, fw)
    for name, n in totals['swiftui_types'].items():
        if name not in own:
            symbols[('SwiftUI', name)] += n
            fw_of.setdefault(name, 'SwiftUI')
    # wrappers that are Apple's
    wrappers = Counter()
    for w, n in totals['wrappers'].items():
        if w in A.SWIFTUI_WRAPPERS and w not in own and w not in ('MainActor', 'Sendable'):
            fw = A.NON_SWIFTUI_WRAPPERS.get(w, 'SwiftUI') or 'Swift'
            wrappers[(fw, w)] += n
    apple_type = lambda t: t in fw_of and t not in own  # noqa: E731
    members = Counter()
    for (t, m), n in totals['members'].items():
        t = 'NSApplication' if t == 'NSApp' else t
        if apple_type(t) and m not in decl_members.get(t, ()):
            members[(t, m)] += n
    for (t, m), n in totals['overrides'].items():
        if apple_type(t):
            members[(t, m)] += n
    inits = Counter()
    for (t, k), n in totals['inits'].items():
        if apple_type(t) and t in type_positions and not t.startswith('k'):
            inits[(t, k)] += n
    subclasses = Counter({t: n for t, n in totals['subclasses'].items() if apple_type(t)})
    ui = 'SwiftUI-first' if entry['SwiftUI App'] else 'AppKit-first'
    n_files = max(1, len(file_imports))
    swiftui_files = sum(1 for s in file_imports if 'SwiftUI' in s)
    appkit_files = sum(1 for s in file_imports if s & {'AppKit', 'Cocoa'})
    return {
        'loc': loc, 'if_conditions': if_conditions, 'imports': totals['imports'], 'objc': totals['objc'],
        'if_atoms': totals['if_atoms'], 'symbols': symbols, 'fw_of': fw_of, 'members': members, 'inits': inits,
        'subclasses': subclasses, 'swiftui_modifiers': totals['swiftui_modifiers'],
        'env_keys': Counter({k: v for k, v in totals['env_keys'].items() if k not in decl_members.get('EnvironmentValues', ())}),
        'type_positions': type_positions,
        'static_users': {t for (t, m) in totals['members']},
        'called': {t for (t, k) in totals['inits']},
        'wrappers': wrappers, 'chained_other': Counter({k: v for k, v in totals['chained_other'].items() if k not in decl_funcs}),
        'entry': dict(entry), 'ui_detected': ui,
        'swiftui_file_share': round(swiftui_files / n_files, 3), 'appkit_file_share': round(appkit_files / n_files, 3),
        'own_modules': set(),
    }


# ---------------------------------------------------------------------------
# Third-party dependency classification (reads clones under the deps dir)

KNOWN_DEP_HINTS = {
    'sparkle': ('binary-only', 'SwiftPM package is a binaryTarget (Sparkle.xcframework); ObjC/AppKit inside'),
    'firebase-ios-sdk': ('binary+source', 'mixed binaryTargets (Analytics) and ObjC/C++ sources'),
    'sentry-cocoa': ('binary+source', 'binaryTarget xcframeworks plus ObjC sources'),
    'realm-swift': ('binary+source', 'realm-core shipped as a binaryTarget'),
    'plcrashreporter': ('ObjC/C source', 'ObjC + C crash reporter'),
    'swift-syntax': ('pure-Swift source', 'swiftlang parser library; used for macros'),
    'tree-sitter': ('ObjC/C source', 'C parser runtime'),
    'realm-core': ('binary-only', 'prebuilt xcframework'),
    'googleappmeasurement': ('binary-only', 'Firebase Analytics xcframeworks'),
    'google-ads-on-device-conversion-ios-sdk': ('binary-only', 'xcframework'),
}


def dep_dir(deps_root, url):
    m = re.match(r'https://github\.com/([^/]+)/([^/]+)$', url or '')
    if not m:
        return None
    return os.path.join(deps_root, m.group(1) + '__' + m.group(2))


DEP_SKIP = re.compile(r'(^|/)(Tests?|UITests|Example[s]?|Demo[s]?|Sample[s]?|Docs?|Documentation|Benchmarks?|Playground[s]?|Fixtures|Tuist|Scripts|fastlane|vendor/.*test)(/|$)', re.I)


def classify_dep(path, runway_modules):
    if not path or not os.path.isdir(path):
        return None
    pkg = os.path.join(path, 'Package.swift')
    info = {'has_package_swift': os.path.exists(pkg), 'binary_targets': [], 'products': [], 'plugin_only': False}
    if info['has_package_swift']:
        pk = P.parse_package_swift(pkg)
        info['binary_targets'] = pk['binary_targets']
        info['products'] = pk['products']
        kinds = {t['kind'] for t in pk['targets'] if t['kind'] != 'testTarget'}
        info['plugin_only'] = bool(kinds) and kinds <= {'plugin', 'binaryTarget', 'executableTarget'} and 'plugin' in kinds
        info['source_targets'] = [t['name'] for t in pk['targets'] if t['kind'] in ('target', 'executableTarget', 'macro')]
    swift_loc = objc_loc = 0
    imports = Counter()
    decls = set()
    for dp, dirs, files in os.walk(path):
        dirs[:] = [d for d in dirs if d not in P.SKIP_DIRS]
        rel = os.path.relpath(dp, path)
        if rel != '.' and DEP_SKIP.search(rel):
            dirs[:] = []
            continue
        for f in files:
            ext = os.path.splitext(f)[1]
            fp = os.path.join(dp, f)
            if ext == '.swift':
                if f in ('Package.swift', 'Project.swift') or f.startswith('Package@swift'):
                    continue
                try:
                    t = open(fp, encoding='utf-8', errors='ignore').read()
                except OSError:
                    continue
                swift_loc += t.count('\n')
                for m in re.finditer(r'^\s*(?:@\w+(?:\([^)]*\))?\s+)*import\s+(?:(?:class|struct|enum|func|var|let|protocol|typealias)\s+)?(\w+)', t, re.M):
                    imports[m.group(1)] += 1
                decls.update(re.findall(r'\b(?:class|struct|enum|protocol|actor|typealias)\s+([A-Z]\w*)', t))
            elif ext in ('.m', '.mm', '.c', '.cc', '.cpp', '.h', '.hpp'):
                try:
                    t = open(fp, encoding='utf-8', errors='ignore').read()
                except OSError:
                    continue
                objc_loc += t.count('\n')
                for m in re.finditer(r'#import\s+<(\w+)/|@import\s+(\w+)', t):
                    imports[m.group(1) or m.group(2)] += 1
                for a, b in re.findall(r'@interface\s+([A-Z]\w*)|@protocol\s+([A-Z]\w*)', t):
                    decls.add(a or b)
    apple = {i for i in imports if i in A.APPLE_MODULES}
    ui = apple & {'AppKit', 'Cocoa', 'UIKit', 'SwiftUI', 'Carbon'}
    info.update({'swift_loc': swift_loc, 'objc_c_loc': objc_loc, 'apple_imports': sorted(apple)})
    nonsource = not info.get('source_targets') and info['has_package_swift']
    if info['binary_targets'] and (nonsource or swift_loc + objc_loc < 200):
        kind = 'binary-only'
    elif info['binary_targets']:
        kind = 'binary+source'
    elif info['plugin_only']:
        kind = 'build-tool plugin'
    elif objc_loc > swift_loc:
        kind = 'ObjC/C source'
    elif apple & {'AppKit', 'Cocoa', 'Carbon'}:
        kind = 'AppKit-dependent Swift source'
    elif 'SwiftUI' in apple:
        kind = 'SwiftUI-dependent Swift source'
    elif 'UIKit' in apple:
        kind = 'UIKit-dependent Swift source'
    elif apple - A.TOOLCHAIN_MODULES - set(runway_modules):
        kind = 'Apple-framework-dependent Swift source'
    else:
        kind = 'pure-Swift source'
    info['kind'] = kind
    info['ui_imports'] = sorted(ui)
    info['needs_beyond_runway'] = sorted(apple - A.TOOLCHAIN_MODULES - set(runway_modules))
    return info, decls


# ---------------------------------------------------------------------------
# Gap computation


def status_symbol(api, fw, name):
    if api.has_symbol(name):
        return 'runway'
    if fw == 'Foundation':
        return 'missing (Darwin-only Foundation)' if name in A.DARWIN_ONLY_FOUNDATION else 'corelibs'
    if name in A.CORELIBS_PROVIDED:
        return 'corelibs'
    if fw in ('Dispatch',):
        return 'corelibs'
    if fw == 'Observation':
        return 'toolchain'
    return 'missing'


def status_module(api, mod, own_modules):
    if mod in own_modules:
        return 'app'
    if mod in api.modules or os.path.isdir(os.path.join(RUNWAY_DIR, 'Sources', mod)) and mod in api.modules:
        return 'runway'
    if mod in A.TOOLCHAIN_MODULES:
        return 'toolchain'
    if mod in A.APPLE_MODULES:
        return 'missing'
    return 'third-party'


def build(apps_meta, corpus, deps_root, only=None):
    api = RunwayAPI(RUNWAY_DIR)
    results = []
    # dependency declarations are collected first so their type names aren't mistaken for Apple's
    dep_info = {}
    inventories = []
    for app in apps_meta:
        if only and app['name'] not in only:
            continue
        root = app_root(app, corpus)
        if not os.path.isdir(root):
            print('skip (not cloned): %s -> %s' % (app['name'], root), file=sys.stderr)
            continue
        inv = inventory_app(app, root)
        inventories.append((app, root, inv))
        for d in inv['dependencies']:
            if d['url'] not in dep_info:
                dep_info[d['url']] = None
    all_dep_decls = set()
    dep_classes = {}
    for url in dep_info:
        c = classify_dep(dep_dir(deps_root, url), api.modules)
        if c:
            dep_classes[url], decls = c
            all_dep_decls |= decls
    apple_type_names = {n for n in all_dep_decls if n in A.SWIFTUI_TYPES}
    all_dep_decls -= apple_type_names
    for app, root, inv in inventories:
        u = analyze_usage(inv, all_dep_decls)
        own_modules = {t['name'].split('/')[-1] for t in inv['targets'] if t.get('name')}
        own_modules |= {re.sub(r'\W', '_', t['name'].split('/')[-1]) for t in inv['targets'] if t.get('name')}
        dep_modules = set()
        for d in inv['dependencies']:
            dep_modules |= set(d['products'])
            dep_modules.add(d['name'])
        results.append((app, root, inv, u, own_modules, dep_modules))
    return api, results, dep_classes


_VERBISH = re.compile(r'(Is|Create|Copy|Get|Set|Make|Register|Unregister|Install|Remove|Post|Release|Retain|Perform|Request|Warp|Associate|Preflight|Show|Hide|Begin|End|Draw|Fill|Free|Enable|Disable|Add|Find|Open|Close|Load|Lock|Unlock|Move|Translate|Contains|Equal|Main)(?=[A-Z]|$)')


def symbol_kind(s, fw, type_pos, static, called):
    """Heuristic: 'type' or 'function/constant'."""
    if s.startswith('k') or fw in ('Carbon',) and s[:1].islower():
        return 'function/constant'
    if s in type_pos or s in static or fw == 'SwiftUI':
        return 'type'
    if s in called:
        return 'function/constant' if _VERBISH.search(s[2:]) else 'type'
    return 'function/constant' if _VERBISH.search(s[2:]) or not s[:1].isupper() else 'type'


def aggregate(api, results, dep_classes):
    n_apps = len(results)
    modules = defaultdict(lambda: {'apps': set(), 'files': 0})
    types = defaultdict(lambda: {'apps': set(), 'uses': 0})
    members = defaultdict(lambda: {'apps': set(), 'uses': 0})
    inits = defaultdict(lambda: {'apps': set(), 'uses': 0})
    modifiers = defaultdict(lambda: {'apps': set(), 'uses': 0})
    env_keys = defaultdict(lambda: {'apps': set(), 'uses': 0})
    wrappers = defaultdict(lambda: {'apps': set(), 'uses': 0})
    subclasses = defaultdict(lambda: {'apps': set(), 'uses': 0})
    chained = defaultdict(lambda: {'apps': set(), 'uses': 0})
    objc_tot = Counter()
    objc_apps = defaultdict(set)
    if_atoms = defaultdict(lambda: {'apps': set(), 'uses': 0})
    plist_keys = defaultdict(set)
    ent_keys = defaultdict(set)
    deps = {}
    fw_of = {}
    apps_out = []
    all_type_pos, all_static, all_called = set(), set(), set()
    for app, root, inv, u, own_modules, dep_modules in results:
        name = app['name']
        all_type_pos |= u['type_positions']
        all_static |= u['static_users']
        all_called |= u['called']
        mod_status = {}
        for m, n in u['imports'].items():
            st = status_module(api, m, own_modules)
            if st == 'third-party' and m not in dep_modules:
                st = 'third-party'
            modules[m]['apps'].add(name)
            modules[m]['files'] += n
            modules[m]['status'] = st if modules[m].get('status') in (None, 'third-party') else modules[m]['status']
            mod_status[m] = st
        for (fw, s), n in u['symbols'].items():
            types[(fw, s)]['apps'].add(name); types[(fw, s)]['uses'] += n
            fw_of.setdefault(s, fw)
        for (t, m), n in u['members'].items():
            members[(t, m)]['apps'].add(name); members[(t, m)]['uses'] += n
        for (t, k), n in u['inits'].items():
            inits[(t, k)]['apps'].add(name); inits[(t, k)]['uses'] += n
        for m, n in u['swiftui_modifiers'].items():
            modifiers[m]['apps'].add(name); modifiers[m]['uses'] += n
        for m, n in u['env_keys'].items():
            env_keys[m]['apps'].add(name); env_keys[m]['uses'] += n
        for (fw, w), n in u['wrappers'].items():
            wrappers[(fw, w)]['apps'].add(name); wrappers[(fw, w)]['uses'] += n
        for t, n in u['subclasses'].items():
            subclasses[t]['apps'].add(name); subclasses[t]['uses'] += n
        for m, n in u['chained_other'].items():
            chained[m]['apps'].add(name); chained[m]['uses'] += n
        for k, n in u['objc'].items():
            objc_tot[k] += n; objc_apps[k].add(name)
        for k, n in u['if_atoms'].items():
            if_atoms[k]['apps'].add(name); if_atoms[k]['uses'] += n
        for k in inv['info_plist_keys']:
            plist_keys[k].add(name)
        for k in inv['entitlements']:
            ent_keys[k].add(name)
        for d in inv['dependencies']:
            e = deps.setdefault(d['url'], {'url': d['url'], 'name': d['name'], 'apps': set(), 'direct_apps': set(),
                                           'products': set(), 'test_only_apps': set()})
            e['apps'].add(name)
            if d['direct']:
                e['direct_apps'].add(name)
            e['products'].update(d['products'])
            if d['test_only']:
                e['test_only_apps'].add(name)
        res = inv['resources']
        apps_out.append({
            'name': name, 'url': app.get('url'), 'license': app.get('license'), 'license_detected': detect_license(root),
            'commit': read_commit(root) or app.get('commit'), 'ui_declared': app.get('ui'), 'ui_detected': u['ui_detected'],
            'entry': u['entry'], 'project_format': inv['format'], 'primary_format': inv['primary_format'],
            'synchronized_folders': inv['synchronized_folders'],
            'swift_files_total': inv['swift_files_total'], 'swift_files_in_scope': inv['swift_files_in_scope'],
            'swift_loc_in_scope': u['loc'], 'out_of_scope': inv['out_of_scope'],
            'swiftui_file_share': u['swiftui_file_share'], 'appkit_file_share': u['appkit_file_share'],
            'targets': [{k: v for k, v in t.items() if k not in ('generated_info_plist_keys',)} for t in inv['targets']],
            'local_packages': inv['local_packages'],
            'dependencies': inv['dependencies'],
            'imports': dict(sorted(u['imports'].items(), key=lambda x: -x[1])),
            'import_status': mod_status,
            'objc_features': dict(u['objc']),
            'if_conditions': u['if_conditions'], 'if_atoms': dict(u['if_atoms'].most_common()),
            'info_plist_files': inv['info_plist_files'], 'info_plist_keys': inv['info_plist_keys'],
            'entitlements': inv['entitlements'],
            'resources': res,
            'apple_symbols': len(u['symbols']),
        })

    def sym_status(fw, s):
        return status_symbol(api, fw, s)

    type_rows = []
    for (fw, s), d in types.items():
        type_rows.append({'framework': fw, 'name': s, 'apps': len(d['apps']), 'uses': d['uses'],
                          'kind': symbol_kind(s, fw, all_type_pos, all_static, all_called),
                          'status': sym_status(fw, s), 'app_list': sorted(d['apps'])})
    tstatus = {(r['name']): r['status'] for r in type_rows}
    member_rows = []
    for (t, m), d in members.items():
        ts = tstatus.get(t) or sym_status(fw_of.get(t, '?'), t)
        if ts == 'runway':
            st = 'runway' if (api.has_member(t, m) or api.find_type(t + '.' + m)) else 'missing'
        elif ts in ('corelibs', 'toolchain'):
            st = ts
        else:
            st = 'type missing'
        member_rows.append({'framework': fw_of.get(t, '?'), 'type': t, 'member': m, 'apps': len(d['apps']),
                            'uses': d['uses'], 'status': st, 'type_status': ts, 'app_list': sorted(d['apps'])})
    for (t, k), d in inits.items():
        ts = tstatus.get(t) or sym_status(fw_of.get(t, '?'), t)
        labels = [x for x in k[5:-1].split(':') if x]
        if ts == 'runway':
            ok = api.init_status(t, labels)
            st = 'runway' if ok else ('missing' if ok is False else 'runway (no init info)')
        elif ts in ('corelibs', 'toolchain'):
            st = ts
        else:
            st = 'type missing'
        member_rows.append({'framework': fw_of.get(t, '?'), 'type': t, 'member': k, 'apps': len(d['apps']),
                            'uses': d['uses'], 'status': st, 'type_status': ts, 'app_list': sorted(d['apps'])})
    mod_rows = [{'module': m, 'apps': len(d['apps']), 'files': d['files'], 'status': d.get('status'),
                 'app_list': sorted(d['apps'])} for m, d in modules.items()]
    swiftui_mod_rows = [{'modifier': m, 'apps': len(d['apps']), 'uses': d['uses'],
                         'status': 'runway' if api.member_anywhere('SwiftUI', m) else 'missing',
                         'app_list': sorted(d['apps'])} for m, d in modifiers.items()]
    env_rows = [{'key': m, 'apps': len(d['apps']), 'uses': d['uses'],
                 'status': 'runway' if api.has_member('EnvironmentValues', m) else 'missing',
                 'app_list': sorted(d['apps'])} for m, d in env_keys.items()]
    wrapper_rows = [{'framework': fw, 'wrapper': w, 'apps': len(d['apps']), 'uses': d['uses'],
                     'status': 'runway' if api.defines_type(w) else ('toolchain' if fw == 'Observation' else 'missing'),
                     'app_list': sorted(d['apps'])} for (fw, w), d in wrappers.items()]
    subclass_rows = [{'superclass': t, 'framework': fw_of.get(t, '?'), 'apps': len(d['apps']), 'uses': d['uses'],
                      'status': 'runway' if api.defines_type(t) else sym_status(fw_of.get(t, '?'), t),
                      'app_list': sorted(d['apps'])} for t, d in subclasses.items()]
    chained_rows = [{'name': m, 'apps': len(d['apps']), 'uses': d['uses'],
                     'runway_has': api.member_anywhere('SwiftUI', m)} for m, d in chained.items() if len(d['apps']) >= 2]
    dep_rows = []
    for u, e in deps.items():
        c = dep_classes.get(u)
        hint = None
        if c:
            kind = c['kind']
        else:
            h = KNOWN_DEP_HINTS.get(e['name'])
            kind, hint = (h if h else ('unknown (not fetched)', None))
        dep_rows.append({'url': u, 'name': e['name'], 'apps': len(e['apps']), 'direct_apps': len(e['direct_apps']),
                         'app_list': sorted(e['apps']), 'products': sorted(e['products']),
                         'test_only': bool(e['test_only_apps']) and e['test_only_apps'] >= e['direct_apps'],
                         'kind': kind, 'hint': hint,
                         'evidence': ({k: c[k] for k in ('swift_loc', 'objc_c_loc', 'apple_imports', 'binary_targets',
                                                          'needs_beyond_runway', 'plugin_only')} if c else None)})
    key = lambda r: (-r['apps'], -r.get('uses', r.get('files', 0)))  # noqa: E731
    for rows in (type_rows, member_rows, mod_rows, swiftui_mod_rows, env_rows, wrapper_rows, subclass_rows, chained_rows, dep_rows):
        rows.sort(key=lambda r: (key(r), str(r.get('name') or r.get('member') or r.get('module') or '')))
    fw_rows = defaultdict(lambda: {'apps': set(), 'symbols': 0, 'missing_symbols': 0, 'uses': 0})
    for r in type_rows:
        f = fw_rows[r['framework']]
        f['apps'].update(r['app_list']); f['symbols'] += 1; f['uses'] += r['uses']
        if r['status'].startswith('missing'):
            f['missing_symbols'] += 1
    framework_rows = sorted(({'framework': k, 'apps': len(v['apps']), 'symbols': v['symbols'],
                              'missing_symbols': v['missing_symbols'], 'uses': v['uses'],
                              'runway_module': k in api.modules, 'app_list': sorted(v['apps'])} for k, v in fw_rows.items()),
                            key=lambda r: (-r['apps'], -r['uses']))
    by_fw = {}
    for r in type_rows:
        f = by_fw.setdefault(r['framework'], {'apps': set(), 'types': {}})
        f['apps'].update(r['app_list'])
        f['types'][r['name']] = {'apps': r['apps'], 'uses': r['uses'], 'status': r['status'], 'kind': r['kind'], 'members': {}}
    for r in member_rows:
        f = by_fw.get(r['framework'])
        if f and r['type'] in f['types']:
            f['types'][r['type']]['members'][r['member']] = {'apps': r['apps'], 'uses': r['uses'], 'status': r['status']}
    for f in by_fw.values():
        f['apps'] = len(f['apps'])
    formats = Counter(a['primary_format'] for a in apps_out)
    fmt_detail = Counter(f for a in apps_out for f in a['project_format'])
    return {
        'apps': apps_out, 'n_apps': n_apps,
        'modules': mod_rows, 'frameworks': framework_rows, 'types': type_rows, 'members': member_rows,
        'swiftui_modifiers': swiftui_mod_rows, 'swiftui_environment_keys': env_rows, 'property_wrappers': wrapper_rows,
        'subclassed_apple_types': subclass_rows, 'unclassified_chained_calls': chained_rows[:200],
        'objc_totals': {k: {'uses': v, 'apps': len(objc_apps[k]), 'app_list': sorted(objc_apps[k])} for k, v in objc_tot.most_common()},
        'if_atoms': sorted(({'atom': k, 'apps': len(v['apps']), 'uses': v['uses']} for k, v in if_atoms.items()),
                           key=lambda r: (-r['apps'], -r['uses'])),
        'info_plist_keys': sorted(({'key': k, 'apps': len(v), 'app_list': sorted(v)} for k, v in plist_keys.items()), key=lambda r: -r['apps']),
        'entitlement_keys': sorted(({'key': k, 'apps': len(v), 'app_list': sorted(v)} for k, v in ent_keys.items()), key=lambda r: -r['apps']),
        'dependencies': dep_rows,
        'by_framework': by_fw,
        'project_formats': {'primary': dict(formats), 'features': dict(fmt_detail)},
    }


# ---------------------------------------------------------------------------
# Report rendering


def _apps(r, limit=6):
    lst = r.get('app_list') or []
    s = ', '.join(lst[:limit])
    return s + (' +%d' % (len(lst) - limit) if len(lst) > limit else '')


def render_md(rep, api, args):
    L = []
    n = rep['n_apps']
    w = L.append
    w('# Runway corpus gap report')
    w('')
    w('Generated by `runway/Tools/corpus/analyze.py` (static text analysis; nothing in the corpus is built or run). '
      'Re-run it after changing Runway and this report updates. Counts are **number of corpus apps** using a name; '
      '"uses" is occurrences in in-scope Swift files (macOS, non-test targets).')
    w('')
    w('Corpus: %d apps, %s in-scope Swift lines. Runway modules: %s.' % (
        n, format(sum(a['swift_loc_in_scope'] for a in rep['apps']), ','), ', '.join(api.modules)))
    w('')
    w('Status legend: `runway` declared publicly in runway/Sources; `corelibs` assumed provided by swift-corelibs-foundation; '
      '`toolchain` ships with Swift on Linux; `missing` nobody provides it; `type missing` the member\'s type itself is missing.')
    w('')
    w('## Corpus')
    w('')
    w('| App | UI | Format | Targets (mac, non-test) | Swift files in scope | LOC | SwiftUI/AppKit files | Third-party deps (direct) |')
    w('|---|---|---|---|---|---|---|---|')
    for a in sorted(rep['apps'], key=lambda a: -a['swift_loc_in_scope']):
        mt = sum(1 for t in a['targets'] if not t.get('test') and t.get('platform') in ('macos', 'multi'))
        w('| %s | %s | %s | %d | %d | %s | %d%% / %d%% | %d |' % (
            a['name'], a['ui_detected'], '+'.join(a['project_format']) or '-', mt, a['swift_files_in_scope'],
            format(a['swift_loc_in_scope'], ','), round(a['swiftui_file_share'] * 100), round(a['appkit_file_share'] * 100),
            sum(1 for d in a['dependencies'] if d['direct'])))
    w('')
    pf = rep['project_formats']
    w('**Project formats** (primary): ' + ', '.join('%s %d' % kv for kv in sorted(pf['primary'].items(), key=lambda x: -x[1])) +
      '. Features: ' + ', '.join('%s %d' % kv for kv in sorted(pf['features'].items(), key=lambda x: -x[1])) +
      '. Xcode 16 synchronized folders: %d apps.' % sum(1 for a in rep['apps'] if a['synchronized_folders']))
    w('')

    w('## Top missing modules (imports of Apple frameworks Runway lacks)')
    w('')
    w('| # | Module | Apps | Files | Used by |')
    w('|---|---|---|---|---|')
    rows = [r for r in rep['modules'] if r['status'] == 'missing'][:50]
    for i, r in enumerate(rows, 1):
        w('| %d | %s | %d/%d | %d | %s |' % (i, r['module'], r['apps'], n, r['files'], _apps(r)))
    w('')
    prov = [r for r in rep['modules'] if r['status'] in ('runway', 'toolchain')]
    w('Covered imports: ' + ', '.join('%s (%d apps, %s)' % (r['module'], r['apps'], r['status']) for r in prov[:30]) + '.')
    w('')

    w('## Frameworks by apps using their API')
    w('')
    w('| Framework | Apps | Distinct names used | Missing names | Uses | Runway module |')
    w('|---|---|---|---|---|---|')
    for r in rep['frameworks'][:40]:
        w('| %s | %d | %d | %d | %d | %s |' % (r['framework'], r['apps'], r['symbols'], r['missing_symbols'], r['uses'],
                                               'yes' if r['runway_module'] else ''))
    w('')

    w('## Top 50 missing types / symbols')
    w('')
    w('| # | Name | Kind | Framework | Apps | Uses | Status | Used by |')
    w('|---|---|---|---|---|---|---|---|')
    rows = [r for r in rep['types'] if r['status'].startswith('missing')][:50]
    for i, r in enumerate(rows, 1):
        w('| %d | `%s` | %s | %s | %d | %d | %s | %s |' % (i, r['name'], r['kind'], r['framework'], r['apps'], r['uses'], r['status'], _apps(r)))
    w('')

    w('## Top 50 missing members of types Runway already has')
    w('')
    w('Members (`Type.member`, typed-variable `.member`, overrides in subclasses, and `init(labels:)` call shapes) on types '
      'Runway declares, where Runway lacks that member.')
    w('')
    w('| # | Type | Member | Apps | Uses | Used by |')
    w('|---|---|---|---|---|---|')
    rows = [r for r in rep['members'] if r['status'] == 'missing'][:50]
    for i, r in enumerate(rows, 1):
        w('| %d | `%s` | `%s` | %d | %d | %s |' % (i, r['type'], r['member'], r['apps'], r['uses'], _apps(r)))
    w('')

    w('## Top 50 members on missing types')
    w('')
    w('| # | Type | Member | Framework | Apps | Uses |')
    w('|---|---|---|---|---|---|')
    rows = [r for r in rep['members'] if r['status'] == 'type missing'][:50]
    for i, r in enumerate(rows, 1):
        w('| %d | `%s` | `%s` | %s | %d | %d |' % (i, r['type'], r['member'], r['framework'], r['apps'], r['uses']))
    w('')

    w('## SwiftUI')
    w('')
    sm = rep['swiftui_modifiers']
    miss = [r for r in sm if r['status'] == 'missing']
    w('Modifiers used: %d distinct, %d provided by Runway, %d missing.' % (len(sm), len(sm) - len(miss), len(miss)))
    w('')
    w('| Missing modifier | Apps | Uses | Used by |')
    w('|---|---|---|---|')
    for r in miss[:40]:
        w('| `.%s` | %d | %d | %s |' % (r['modifier'], r['apps'], r['uses'], _apps(r)))
    w('')
    st = [r for r in rep['types'] if r['framework'] == 'SwiftUI']
    stm = [r for r in st if r['status'].startswith('missing')]
    w('SwiftUI types/views used: %d distinct, %d missing: %s.' % (
        len(st), len(stm), ', '.join('`%s` (%d)' % (r['name'], r['apps']) for r in stm[:40]) or 'none'))
    w('')
    em = [r for r in rep['swiftui_environment_keys'] if r['status'] == 'missing']
    w('Environment keys missing: ' + (', '.join('`\\.%s` (%d)' % (r['key'], r['apps']) for r in em[:30]) or 'none') + '.')
    w('')
    wm = [r for r in rep['property_wrappers'] if r['status'] == 'missing']
    w('Property wrappers / macros missing: ' + (', '.join('`@%s` %s (%d)' % (r['wrapper'], r['framework'], r['apps']) for r in wm) or 'none') + '.')
    w('')

    w('## Objective-C runtime features')
    w('')
    w('| Feature | Uses | Apps |')
    w('|---|---|---|')
    for k, v in rep['objc_totals'].items():
        w('| `%s` | %d | %d/%d |' % (k, v['uses'], v['apps'], n))
    w('')
    w('Per app:')
    w('')
    keys = ['@objc', '#selector', '@IBAction', '@IBOutlet', 'dynamic', 'NSObject subclass', 'KVO observe(\\.)',
            'addObserver(forKeyPath:)', 'perform(selector)', 'responds(to:)', 'NSClassFromString', '#keyPath',
            'objc runtime C API', '@_silgen_name / dlsym (private API)']
    w('| App | ' + ' | '.join('`%s`' % k for k in keys) + ' |')
    w('|---|' + '---|' * len(keys))
    for a in sorted(rep['apps'], key=lambda a: a['name'].lower()):
        w('| %s | ' % a['name'] + ' | '.join(str(a['objc_features'].get(k, 0)) for k in keys) + ' |')
    w('')
    sc = [r for r in rep['subclassed_apple_types']][:25]
    w('Most-subclassed Apple classes: ' + ', '.join('`%s` %d apps%s' % (r['superclass'], r['apps'], '' if r['status'] == 'runway' else ' (missing)') for r in sc) + '.')
    w('')

    w('## Platform conditionals (`#if`)')
    w('')
    w(', '.join('`%s` %d apps/%d' % (r['atom'], r['apps'], r['uses']) for r in rep['if_atoms'][:30]) + '.')
    w('')

    w('## Third-party dependencies')
    w('')
    kinds = Counter()
    for d in rep['dependencies']:
        if d['direct_apps']:
            kinds[d['kind']] += 1
    w('Direct dependencies by kind: ' + ', '.join('%s %d' % kv for kv in kinds.most_common()) + '.')
    w('')
    w('| # | Package | Apps (direct) | Kind | Needs beyond Runway | Test-only | Used by |')
    w('|---|---|---|---|---|---|---|')
    rows = [d for d in rep['dependencies'] if d['direct_apps']]
    for i, d in enumerate(rows[:60], 1):
        ev = d.get('evidence') or {}
        w('| %d | [%s](%s) | %d | %s | %s | %s | %s |' % (
            i, d['name'], d['url'], d['direct_apps'], d['kind'] + (' (hint)' if d.get('hint') else ''),
            ', '.join(ev.get('needs_beyond_runway') or []) or '', 'yes' if d['test_only'] else '', _apps(d)))
    w('')
    trans = [d for d in rep['dependencies'] if not d['direct_apps']]
    w('Transitive-only (from Package.resolved): ' + ', '.join('%s (%s)' % (d['name'], d['kind']) for d in trans[:40]) + '.')
    w('')

    w('## Info.plist and entitlements')
    w('')
    ui_el = [a['name'] for a in rep['apps'] if str(a['info_plist_keys'].get('LSUIElement')).lower() in ('true', 'yes', '1')]
    w('Menu-bar-only apps (`LSUIElement` true): %d/%d (%s).' % (len(ui_el), n, ', '.join(ui_el)))
    w('')
    w('Info.plist keys: ' + ', '.join('`%s` %d' % (r['key'], r['apps']) for r in rep['info_plist_keys'][:30]) + '.')
    w('')
    w('Entitlements: ' + ', '.join('`%s` %d' % (r['key'], r['apps']) for r in rep['entitlement_keys'][:20]) + '.')
    w('')
    w('## Resources')
    w('')
    w('| App | xcassets | imagesets | colorsets | storyboards | xibs | .strings | .xcstrings | languages | vendored frameworks |')
    w('|---|---|---|---|---|---|---|---|---|---|')
    for a in sorted(rep['apps'], key=lambda a: a['name'].lower()):
        r = a['resources']
        w('| %s | %d | %d | %d | %d | %d | %d | %d | %d | %s |' % (a['name'], r['xcassets'], r['imagesets'], r['colorsets'],
                                                                  r['storyboards'], r['xibs'], r['strings'], r['xcstrings'],
                                                                  len(r['lproj_languages']),
                                                                  ', '.join(os.path.basename(x) for x in (r['xcframeworks'] + r['frameworks'])[:4])))
    w('')
    w('## Caveats')
    w('')
    w('- Text heuristics, not a type checker. Apple names are attributed by prefix (NS/CG/AX/kAX/IO/UN/Sec/...) and curated '
      'lists (`apple_names.py`); names the app or a cloned dependency declares are excluded. Members are found from '
      '`Type.member`, typed variables (`let w: NSWindow`, `= NSWindow(`, `as? NSWindow`), `self.`/`super.`/`override` in '
      'subclasses, and `init` label shapes; implicit-member expressions (`.titled`) are not attributed.')
    w('- Scope: Swift files in non-test macOS targets (pbxproj build phases, Xcode 16 synchronized folders with their '
      'exceptions, the JSON `project.xcproj` format, SwiftPM targets). `#if` branches that are certainly off on macOS '
      '(`os(iOS)`, `canImport(UIKit)`, ...) are dropped; unknown flags keep both branches.')
    w('- `corelibs` status is an assumption about swift-corelibs-foundation (no toolchain is consulted); '
      '`DARWIN_ONLY_FOUNDATION` lists the known exceptions.')
    w('- Dependency kinds come from read-only shallow clones (`analyze.py deps --clone`); `(hint)` marks a built-in guess '
      'for packages that were not cloned.')
    w('')
    w('## How to query')
    w('')
    w('`report.json` holds every row (not just the top 50) with app lists. From this directory:')
    w('')
    w('```')
    w('python3 -I analyze.py query type NSStatusItem')
    w('python3 -I analyze.py query member NSWindow.styleMask')
    w('python3 -I analyze.py query module Combine')
    w('python3 -I analyze.py query app Rectangle')
    w('python3 -I analyze.py query missing AppKit 30     # top missing names in a framework')
    w('```')
    w('')
    return '\n'.join(L)


def to_jsonable(o):
    if isinstance(o, set):
        return sorted(o)
    if isinstance(o, Counter):
        return dict(o)
    raise TypeError(type(o))


# ---------------------------------------------------------------------------
# CLI


def cmd_analyze(args):
    apps = json.load(open(APPS_JSON))
    corpus = args.corpus or default_corpus()
    deps_root = args.deps or os.environ.get('RUNWAY_CORPUS_DEPS') or os.path.join(os.path.dirname(corpus.rstrip('/')), 'deps')
    missing = [a['name'] for a in apps['apps'] if not os.path.isdir(app_root(a, corpus))]
    if missing and not args.only:
        sys.exit('not cloned under %s: %s\nrun `analyze.py --corpus %s fetch` first (or use --only); report left unchanged'
                 % (corpus, ', '.join(missing), corpus))
    api, results, dep_classes = build(apps['apps'], corpus, deps_root, only=set(args.only) if args.only else None)
    rep = aggregate(api, results, dep_classes)
    rep_meta = {
        'generated': datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
        'runway': {'modules': api.modules, 'symbols': sum(len(t['members']) for t in api.types.values()),
                   'types': len(api.types), 'globals': len(api.globals), 'summary': api.summary()},
        'deps_classified': len(dep_classes),
    }
    out = dict(rep_meta, **rep)
    if rep['n_apps'] == 0:
        sys.exit('no corpus apps found under %s (run `analyze.py fetch` or pass --corpus); report left unchanged' % corpus)
    if args.only:  # a partial run never overwrites the corpus-wide report
        for r in [r for r in rep['types'] if r['status'].startswith('missing')][:40]:
            print('%-45s %-20s %2d apps %6d uses' % (r['name'], r['framework'], r['apps'], r['uses']))
        return
    with open(os.path.join(HERE, 'report.json'), 'w') as f:
        json.dump(out, f, indent=1, default=to_jsonable, sort_keys=False)
    with open(os.path.join(HERE, 'report.md'), 'w') as f:
        f.write(render_md(rep, api, args))
    if not args.only and not args.no_update_apps:
        by = {a['name']: a for a in rep['apps']}
        for a in apps['apps']:
            r = by.get(a['name'])
            if r:
                a['commit'] = r['commit']
                a['license_detected'] = r['license_detected']
                a['project_type'] = '+'.join(r['project_format'])
                a['swift_loc'] = r['swift_loc_in_scope']
                a['swift_files'] = r['swift_files_in_scope']
                a['ui_detected'] = r['ui_detected']
        with open(APPS_JSON, 'w') as f:
            json.dump(apps, f, indent=2)
            f.write('\n')
    print('wrote report.md, report.json (%d apps, %d deps classified)' % (rep['n_apps'], len(dep_classes)))


def cmd_fetch(args):
    apps = json.load(open(APPS_JSON))
    corpus = args.corpus or default_corpus()
    os.makedirs(corpus, exist_ok=True)
    for a in apps['apps']:
        if a['source']['kind'] != 'git':
            continue
        dest = os.path.join(corpus, a['source']['dir'])
        if os.path.isdir(dest):
            continue
        cmd = ['git', 'clone', '--depth', '1', a['url'], dest]
        print(' '.join(cmd))
        if not args.dry_run:
            subprocess.run(cmd, check=False, env=dict(os.environ, GIT_TERMINAL_PROMPT='0', GIT_LFS_SKIP_SMUDGE='1'))


def cmd_deps(args):
    apps = json.load(open(APPS_JSON))
    corpus = args.corpus or default_corpus()
    deps_root = args.deps or os.environ.get('RUNWAY_CORPUS_DEPS') or os.path.join(os.path.dirname(corpus.rstrip('/')), 'deps')
    seen = set()
    for a in apps['apps']:
        root = app_root(a, corpus)
        if not os.path.isdir(root):
            continue
        inv = inventory_app(a, root)
        for d in inv['dependencies']:
            if d['url'] in seen:
                continue
            seen.add(d['url'])
            dd = dep_dir(deps_root, d['url'])
            have = dd and os.path.isdir(dd)
            print('%s\t%s\t%s' % (d['url'], dd or '-', 'have' if have else 'missing'))
            if args.clone and dd and not have:
                subprocess.run(['git', 'clone', '--depth', '1', d['url'], dd], check=False,
                               env=dict(os.environ, GIT_TERMINAL_PROMPT='0', GIT_LFS_SKIP_SMUDGE='1'))


def cmd_query(args):
    rep = json.load(open(os.path.join(HERE, 'report.json')))
    what, arg = args.what, args.arg
    if what == 'type':
        for r in rep['types']:
            if r['name'] == arg:
                print(json.dumps(r, indent=1))
        for r in rep['members']:
            if r['type'] == arg:
                print('  .%-40s %2d apps %5d uses  %s' % (r['member'], r['apps'], r['uses'], r['status']))
    elif what == 'member':
        t, _, m = arg.partition('.')
        for r in rep['members']:
            if r['type'] == t and (r['member'] == m or r['member'].startswith(m)):
                print(json.dumps(r, indent=1))
    elif what == 'module':
        for r in rep['modules']:
            if r['module'] == arg:
                print(json.dumps(r, indent=1))
        for r in rep['types']:
            if r['framework'] == arg and args.limit:
                pass
    elif what == 'app':
        for a in rep['apps']:
            if a['name'].lower() == arg.lower():
                print(json.dumps(a, indent=1))
    elif what == 'missing':
        lim = int(args.limit or 30)
        rows = [r for r in rep['types'] if r['framework'] == arg and r['status'].startswith('missing')][:lim]
        for r in rows:
            print('%-45s %2d apps %6d uses' % (r['name'], r['apps'], r['uses']))
        print('-- members --')
        rows = [r for r in rep['members'] if r['framework'] == arg and r['status'] in ('missing',)][:lim]
        for r in rows:
            print('%-30s %-35s %2d apps %6d uses' % (r['type'], r['member'], r['apps'], r['uses']))
    elif what == 'dep':
        for d in rep['dependencies']:
            if arg.lower() in d['url']:
                print(json.dumps(d, indent=1))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--corpus', help='directory holding the app clones')
    ap.add_argument('--deps', help='directory holding dependency clones (owner__repo)')
    sub = ap.add_subparsers(dest='cmd')
    a = sub.add_parser('analyze')
    a.add_argument('--only', nargs='*')
    a.add_argument('--no-update-apps', action='store_true')
    f = sub.add_parser('fetch')
    f.add_argument('--dry-run', action='store_true')
    d = sub.add_parser('deps')
    d.add_argument('--clone', action='store_true', help='git clone --depth 1 missing dependency repos (read-only use)')
    q = sub.add_parser('query')
    q.add_argument('what', choices=['type', 'member', 'module', 'app', 'missing', 'dep'])
    q.add_argument('arg')
    q.add_argument('limit', nargs='?')
    args = ap.parse_args()
    if args.cmd in (None, 'analyze'):
        if args.cmd is None:
            args.only = None
            args.no_update_apps = False
        cmd_analyze(args)
    elif args.cmd == 'fetch':
        cmd_fetch(args)
    elif args.cmd == 'deps':
        cmd_deps(args)
    elif args.cmd == 'query':
        cmd_query(args)


if __name__ == '__main__':
    main()
