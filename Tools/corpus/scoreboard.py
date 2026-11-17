#!/usr/bin/env python3
"""Runway corpus scoreboard: build every corpus app with `runway build` and
record how far each gets.

    python3 -I scoreboard.py [--corpus DIR] [--deps DIR] [--only App,App]
                             [--units app,local,dep] [--no-launch] [--keep-builds]
                             [--report-only] [--baseline FILE]

For each app it builds, one at a time:
  app    the app itself (its Package.swift, or its Xcode project once the
         build tool imports those),
  local  the SwiftPM packages inside the app's tree (NetNewsWire's Modules…),
  dep    third-party packages the app uses that import Apple frameworks
         (clones under the deps dir), each built once and shared by the apps
         using it,
and records the stage reached (import → stage → resolve deps → compile →
link → launch → runs), compiler errors by category with the most common
ones, and for an app that builds, a launch under Xvfb with Runway's
screenshot hook. Each staged package's .build is deleted after scoring
(disk), unless --keep-builds.

Results merge into scoreboard.json (units not rebuilt keep their last
result) and render to scoreboard.md. --baseline adds a before/after column
(scoreboard.baseline.json by default, when present).

Static context comes from report.json (analyze.py): app formats, local
packages and dependency kinds.
"""
import argparse
import collections
import datetime
import json
import os
import re
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
RUNWAY = os.path.dirname(os.path.dirname(HERE))
REPO = os.environ.get('RUNWAY_REPO') or os.path.dirname(RUNWAY)
SWIFT_BIN = '/opt/swift/swift-6.4.2-RELEASE-ubuntu24.04/usr/bin'

STAGES = ['import', 'stage', 'resolve', 'compile', 'link', 'launch', 'runs']
STAGE_LABEL = {'import': 'import', 'stage': 'stage', 'resolve': 'resolve deps', 'compile': 'compile',
               'link': 'link', 'launch': 'launch', 'runs': 'runs'}
CATEGORIES = ['missing module', 'missing type', 'missing member', 'signature mismatch', 'isolation', 'transpiler',
              'C/ObjC source', 'other']
DEP_KINDS = ('AppKit-dependent', 'SwiftUI-dependent', 'Apple-framework-dependent', 'UIKit-dependent')

ANSI = re.compile(r'\x1b\[[0-9;]*[A-Za-z]|\x1b\]8;;[^\x1b]*\x1b\\')
DIAG = re.compile(r'^(?P<file>/[^:\n]+):(?P<line>\d+):(?P<col>\d+): (?:fatal )?error: (?P<msg>.*)$')
TAIL_HINT = re.compile(r'\s*\[#\w+\]\s*$')


# ---------------------------------------------------------------------------
# Units


def load_json(path, default=None):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def dep_dir(deps_root, url):
    m = re.match(r'https://github\.com/([^/]+)/([^/]+?)(\.git)?/?$', url or '')
    return os.path.join(deps_root, (m.group(1) + '__' + m.group(2)).lower()) if m else None


def app_root(app, corpus):
    src = app['source']
    return os.path.join(REPO, src['path']) if src['kind'] == 'repo' else os.path.join(corpus, src['dir'])


def units_for(app, report_app, corpus, deps_root):
    """(kind, name, path) for everything scored for `app`."""
    root = app_root(app, corpus)
    out = [('app', app['name'], root)]
    for p in (report_app or {}).get('local_packages', []):
        d = os.path.dirname(os.path.join(root, p))
        if os.path.isfile(os.path.join(d, 'Package.swift')):
            out.append(('local', app['name'] + '/' + os.path.relpath(d, root), d))
    return out


def dep_units(report, deps_root):
    """Third-party packages that import Apple frameworks: name → (path, apps)."""
    out = {}
    for d in report.get('dependencies', []):
        if not any(d.get('kind', '').startswith(k) for k in DEP_KINDS) or d.get('test_only'):
            continue
        path = dep_dir(deps_root, d['url'])
        if path and os.path.isfile(os.path.join(path, 'Package.swift')):
            key = os.path.basename(path)
            e = out.setdefault(key, {'path': path, 'apps': set(), 'url': d['url']})
            e['apps'].update(d.get('app_list', []))
    return out


# ---------------------------------------------------------------------------
# Building and classifying


def classify(msg, file):
    m = msg
    if re.search(r'\.(m|mm|c|h|cpp)$', file):
        return 'C/ObjC source'
    if "no such module" in m or re.search(r"product '.*' required by", m):
        return 'missing module'
    if 'actor-isolated' in m or 'Sendable' in m or 'nonisolated' in m or 'main actor' in m or 'data race' in m \
            or 'isolation' in m or 'global actor' in m:
        return 'isolation'
    if '/.runway/stage/' in file or 'RunwayObjC' in m or '#selector' in m or '@objc' in m or 'Selector' in m:
        return 'transpiler'
    if m.startswith('cannot find type'):
        return 'missing type'
    if re.match(r"cannot find '[^']+' in scope", m) or 'has no member' in m or 'has no dynamic member' in m:
        return 'missing member'
    if re.search(r'argument|cannot convert|no exact matches|cannot be used|does not conform|ambiguous|'
                 r'no (accessible )?initializers|cannot (assign|override|infer)|requires that|'
                 r'generic parameter|candidate|mismatch|is not a member type|cannot call|expected type|'
                 r'does not override|overriding|invalid redeclaration|non-optional|optional type|'
                 r'cannot inherit|is not convertible|instance method|used as a type|not available', m):
        return 'signature mismatch'
    return 'other'


def missing_name(msg):
    """The API name an error says is missing, normalised for counting."""
    for pat, fmt in [
        (r"no such module '([^']+)'", 'module {0}'),
        (r"'([^']+\.h)' file not found", 'header {0}'),
        (r"cannot find type '([^']+)' in scope", '{0}'),
        (r"cannot find '([^']+)' in scope", '{0}'),
        (r"(?:value of|type) (?:type )?'([^']+)' has no member '([^']+)'", '{0}.{1}'),
        (r"module '([^']+)' has no member named '([^']+)'", '{0}.{1}'),
        (r"'([^']+)' is not a member type of (?:class|struct|enum|protocol|type) '([^']+)'", '{1}.{0}'),
        (r"type '([^']+)' has no member '([^']+)'", '{0}.{1}'),
    ]:
        mm = re.search(pat, msg)
        if mm:
            g = [re.sub(r'<.*>', '', x).replace('?', '').replace('!', '') for x in mm.groups()]
            g = [x.split('.')[-1] if i == 0 and len(g) > 1 else x for i, x in enumerate(g)]
            return fmt.format(*g)
    return None


def run(cmd, cwd=None, env=None, timeout=None):
    e = dict(os.environ)
    e['PATH'] = SWIFT_BIN + ':' + e.get('PATH', '')
    e['NO_COLOR'] = '1'
    e['TERM'] = 'dumb'
    if env:
        e.update(env)
    t0 = time.time()
    try:
        p = subprocess.run(cmd, cwd=cwd, env=e, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
        out, rc = p.stdout.decode('utf-8', 'replace'), p.returncode
    except subprocess.TimeoutExpired as ex:
        out, rc = (ex.stdout or b'').decode('utf-8', 'replace') + '\n[timeout]', 124
    return rc, ANSI.sub('', out), time.time() - t0


def runway_tool():
    tool = os.path.join(RUNWAY, '.build', 'debug', 'runway')
    rc, out, _ = run(['swift', 'build', '--product', 'runway'], cwd=RUNWAY)
    if rc != 0:
        sys.exit('building the runway tool failed:\n' + out[-3000:])
    return tool


def analyse_build(rc, out):
    """Stage reached and diagnostics from a `runway build` transcript."""
    res = {'exit': rc}
    lines = out.splitlines()
    staged = next((l.split(' at ', 1)[1].strip() for l in lines if l.startswith('runway: staged ') and ' at ' in l), None)
    res['staged_dir'] = staged
    errors, seen = [], set()
    for l in lines:
        m = DIAG.match(l.strip())
        if not m:
            continue
        msg = TAIL_HINT.sub('', m.group('msg')).strip()
        key = (m.group('file'), m.group('line'), m.group('col'), msg)
        if key in seen:
            continue
        seen.add(key)
        errors.append({'file': m.group('file'), 'line': int(m.group('line')), 'msg': msg,
                       'category': classify(msg, m.group('file')), 'missing': missing_name(msg)})
    res['error_count'] = len(errors)
    res['categories'] = dict(collections.Counter(e['category'] for e in errors))
    res['missing_counts'] = dict(collections.Counter(e['missing'] for e in errors if e['missing']))
    res['message_counts'] = dict(collections.Counter(e['msg'] for e in errors).most_common(60))
    res['errors'] = errors[:200]
    general = [l.strip() for l in lines if re.match(r'^\s*(error|runway: error|fatal error):', l.strip())
               and 'failed with a nonzero exit code' not in l and l.strip() != 'error: Build failed'
               and 'emit-module command failed' not in l]
    linker = [l for l in lines if re.search(r'undefined reference to|ld(\.lld|\.gold)?: error|link command failed|'
                                            r'linker command failed|relocation .* against', l)]
    if staged is None:
        res['stage'] = 'import'
        res['blocker'] = next((l for l in lines if 'runway:' in l and ('error' in l or 'no Package.swift' in l)),
                              (general or lines or ['?'])[-1])[:300]
    elif rc == 0:
        res['stage'] = 'launch'
    elif errors:
        res['stage'] = 'compile'
    elif linker:
        res['stage'] = 'link'
        res['blocker'] = linker[0].strip()[:300]
        res['link_errors'] = sorted(set(re.sub(r'^.*undefined reference to', 'undefined reference to', l.strip())[:200]
                                        for l in linker))[:40]
    elif any(re.search(r'[Dd]ependencies could not be resolved|Failed to clone|failed to resolve|'
                       r'could not find a package|unknown package|fetching|is not a valid|manifest|'
                       r'package resolution|product .* not found', l) for l in general):
        res['stage'] = 'resolve'
        res['blocker'] = general[0][:300]
    else:
        res['stage'] = 'compile' if any('SwiftCompile' in l or 'Compiling' in l for l in lines) else 'resolve'
        res['blocker'] = (general or [l for l in lines if 'error' in l.lower()] or lines[-1:] or ['?'])[0].strip()[:300]
    return res


def executables(staged_dir):
    """Executable products of a staged package (from its generated manifest)."""
    try:
        text = open(os.path.join(staged_dir, 'Package.swift')).read()
    except OSError:
        return []
    return re.findall(r'\.executableTarget\(name: "([^"]+)"', text)


def launch(staged_dir, name, shots):
    rc, out, _ = run(['swift', 'build', '--show-bin-path'], cwd=staged_dir)
    bindir = out.strip().splitlines()[-1] if rc == 0 and out.strip() else None
    exes = [e for e in executables(staged_dir) if bindir and os.path.isfile(os.path.join(bindir, e))]
    if not exes:
        return {'stage': 'launch', 'blocker': 'no executable built'}
    exe = exes[0]
    os.makedirs(shots, exist_ok=True)
    shot = os.path.join(shots, re.sub(r'[^A-Za-z0-9_.-]', '_', name) + '.png')
    if os.path.exists(shot):
        os.remove(shot)
    home = os.path.join(shots, 'home')
    os.makedirs(home, exist_ok=True)
    rc, out, secs = run(['timeout', '90', 'xvfb-run', '-a', '-s', '-screen 0 1280x800x24', os.path.join(bindir, exe)],
                        cwd=bindir, env={'RUNWAY_SCREENSHOT': shot, 'HOME': home}, timeout=150)
    ok = os.path.isfile(shot) and os.path.getsize(shot) > 0
    tail = [l for l in out.splitlines() if l.strip()][-8:]
    res = {'executable': exe, 'launch_exit': rc, 'launch_seconds': round(secs, 1), 'launch_tail': tail}
    if ok:
        res.update(stage='runs', screenshot=os.path.relpath(shot, HERE) if shot.startswith(HERE) else shot)
    else:
        crash = next((l for l in out.splitlines() if re.search(r'Fatal error|fatal error|Segmentation|Illegal instruction|'
                                                              r'Trace/breakpoint|Aborted|Unexpectedly found nil', l)), None)
        res.update(stage='launch', blocker=(crash or ('timed out without a window' if rc == 124 else
                                                      'exited %d without a screenshot' % rc))[:300])
    return res


def score_unit(tool, kind, name, path, args, shots):
    t0 = time.time()
    rc, out, secs = run([tool, 'build', path], cwd=RUNWAY, timeout=args.timeout, env={'RUNWAY_DEPS_MIRROR': args.deps_root})
    res = analyse_build(rc, out)
    res.update(kind=kind, name=name, path=path, build_seconds=round(secs, 1),
               when=datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds'))
    if res['stage'] == 'launch' and kind == 'app' and not args.no_launch:
        res.update(launch(res['staged_dir'], name, shots))
    elif res['stage'] == 'launch':
        res['stage'] = 'runs' if kind != 'app' else 'launch'
        if kind != 'app':
            res['note'] = 'library builds'
    os.makedirs(os.path.join(args.logs), exist_ok=True)
    with open(os.path.join(args.logs, re.sub(r'[^A-Za-z0-9_.-]', '_', name) + '.log'), 'w') as f:
        f.write(out)
    if res.get('staged_dir') and not args.keep_builds:
        shutil.rmtree(os.path.join(res['staged_dir'], '.build'), ignore_errors=True)
    print('  %-40s %-8s %4d errors  %5.0fs' % (name, STAGE_LABEL[res['stage']], res['error_count'], time.time() - t0),
          flush=True)
    return res


# ---------------------------------------------------------------------------
# Report


def summarize(unit):
    cats = unit.get('categories', {})
    return {c: cats[c] for c in CATEGORIES if cats.get(c)}


def nerrors(u):
    return u.get('error_count', len(u.get('errors', [])))


def render(board, baseline):
    units = board['units']
    apps = board['apps']
    w = []
    w.append('# Runway corpus scoreboard\n')
    w.append('Generated by `runway/Tools/corpus/scoreboard.py` (real `runway build` of each corpus app, its local '
             'packages and the Apple-framework-dependent third-party packages it uses; apps that build are launched '
             'under Xvfb with `RUNWAY_SCREENSHOT`). Updated %s, Runway %s.\n' % (board['generated'], board.get('commit', '?')))
    w.append('Stages: ' + ' → '.join(STAGE_LABEL[s] for s in STAGES) + '. A unit\'s stage is where it stopped '
             '(`runs` = launched and rendered a window). The compiler stops at the first module that fails, so '
             'error counts are for the modules it reached.\n')
    w.append('## Apps\n')
    hdr = '| App | Format | App stage |' + (' Before |' if baseline else '') + \
          ' Errors (app) | Local packages built | Deps built | Next blocker |'
    w.append(hdr)
    w.append('|' + '---|' * (hdr.count('|') - 1))
    for a in apps:
        u = units.get('app:' + a['name'])
        locals_ = [units[k] for k in a['units'] if k.startswith('local:') and k in units]
        deps = [units[k] for k in a['units'] if k.startswith('dep:') and k in units]
        okl = sum(1 for x in locals_ if x['stage'] in ('runs', 'launch'))
        okd = sum(1 for x in deps if x['stage'] in ('runs', 'launch'))
        stage = STAGE_LABEL[u['stage']] if u else 'not run'
        before = ''
        if baseline:
            b = baseline.get('units', {}).get('app:' + a['name'])
            before = ' %s (%d) |' % (STAGE_LABEL[b['stage']], nerrors(b)) if b else ' — |'
        nerr = nerrors(u) if u else 0
        blocker = ''
        if u:
            if u['errors']:
                blocker = max(u['message_counts'].items(), key=lambda kv: kv[1])[0]
            else:
                blocker = u.get('blocker', '')
        blocker = blocker.replace('|', '\\|')[:140]
        w.append('| %s | %s | **%s** |%s %d | %s | %s | %s |' % (
            a['name'], a.get('format', ''), stage, before, nerr,
            '%d/%d' % (okl, len(locals_)) if locals_ else '—', '%d/%d' % (okd, len(deps)) if deps else '—', blocker))
    w.append('')

    allu = list(units.values())
    stage_counts = collections.Counter(u['stage'] for u in allu)
    w.append('Units by stage: ' + ', '.join('%s %d' % (STAGE_LABEL[s], stage_counts[s]) for s in STAGES if stage_counts[s]) + '.\n')

    # Errors by category, per app (all its units).
    w.append('## Errors by category\n')
    w.append('| App | ' + ' | '.join(CATEGORIES) + ' |')
    w.append('|---|' + '---|' * len(CATEGORIES))
    for a in apps:
        c = collections.Counter()
        for k in a['units']:
            if k in units:
                c.update(units[k].get('categories', {}))
        w.append('| %s | %s |' % (a['name'], ' | '.join(str(c[x]) if c[x] else '' for x in CATEGORIES)))
    w.append('')

    # Missing APIs by apps affected.
    by_name = collections.defaultdict(lambda: {'apps': set(), 'n': 0})
    by_msg = collections.defaultdict(lambda: {'apps': set(), 'n': 0})
    for a in apps:
        for k in a['units']:
            u = units.get(k, {})
            for n, c in u.get('missing_counts', {}).items():
                by_name[n]['apps'].add(a['name'])
                by_name[n]['n'] += c
            for m, c in u.get('message_counts', {}).items():
                by_msg[m]['apps'].add(a['name'])
                by_msg[m]['n'] += c
    w.append('## Missing APIs (from compile errors), by apps affected\n')
    w.append('| # | Name | Apps | Errors | Apps affected |')
    w.append('|---|---|---|---|---|')
    ranked = sorted(by_name.items(), key=lambda kv: (-len(kv[1]['apps']), -kv[1]['n'], kv[0]))
    for i, (n, v) in enumerate(ranked[:80], 1):
        w.append('| %d | `%s` | %d | %d | %s |' % (i, n, len(v['apps']), v['n'], ', '.join(sorted(v['apps']))))
    w.append('')
    w.append('## Top errors\n')
    w.append('| Error | Apps | Count |')
    w.append('|---|---|---|')
    for m, v in sorted(by_msg.items(), key=lambda kv: (-len(kv[1]['apps']), -kv[1]['n']))[:40]:
        w.append('| %s | %d | %d |' % (m.replace('|', '\\|')[:160], len(v['apps']), v['n']))
    w.append('')

    w.append('## Units\n')
    w.append('| Unit | Kind | Stage | Errors | By category | Used by | Seconds | First error / blocker |')
    w.append('|---|---|---|---|---|---|---|---|')
    for k in sorted(units, key=lambda k: (k.split(':')[0] != 'app', k)):
        u = units[k]
        first = (u['errors'][0]['msg'] if u['errors'] else u.get('blocker', '')).replace('|', '\\|')[:120]
        cats = ', '.join('%s %d' % kv for kv in summarize(u).items())
        used = ', '.join(sorted(u.get('apps', []))) if u['kind'] == 'dep' else ''
        w.append('| %s | %s | %s | %d | %s | %s | %s | %s |' % (
            u['name'], u['kind'], STAGE_LABEL[u['stage']], nerrors(u), cats, used, u.get('build_seconds', ''), first))
    w.append('')
    return '\n'.join(w) + '\n'


def main():
    ap = argparse.ArgumentParser()
    scratch_default = os.environ.get('RUNWAY_CORPUS_DIR') or os.path.expanduser('~/.cache/runway-corpus/apps')
    ap.add_argument('--corpus', default=scratch_default)
    ap.add_argument('--deps', default=None)
    ap.add_argument('--only', default=None, help='comma-separated app names (or unit names)')
    ap.add_argument('--units', default='app,local,dep')
    ap.add_argument('--no-launch', action='store_true')
    ap.add_argument('--keep-builds', action='store_true')
    ap.add_argument('--report-only', action='store_true')
    ap.add_argument('--baseline', default=os.path.join(HERE, 'scoreboard.baseline.json'))
    ap.add_argument('--timeout', type=int, default=3600)
    ap.add_argument('--out', default=os.path.join(HERE, 'scoreboard'))
    ap.add_argument('--logs', default=None)
    args = ap.parse_args()
    deps_root = args.deps or os.environ.get('RUNWAY_CORPUS_DEPS') or os.path.join(os.path.dirname(args.corpus.rstrip('/')), 'deps')
    work = os.path.join(os.path.dirname(args.corpus.rstrip('/')), 'scoreboard')
    args.logs = args.logs or os.path.join(work, 'logs')
    args.deps_root = deps_root
    shots = os.path.join(work, 'shots')

    meta = load_json(os.path.join(HERE, 'apps.json'))['apps']
    report = load_json(os.path.join(HERE, 'report.json'), {})
    rapps = {a['name']: a for a in report.get('apps', [])}
    board = load_json(args.out + '.json', {'units': {}})
    kinds = set(args.units.split(','))
    only = set(args.only.split(',')) if args.only else None
    deps = dep_units(report, deps_root)

    apps, todo = [], []
    for app in meta:
        ra = rapps.get(app['name'], {})
        root = app_root(app, args.corpus)
        keys = []
        for kind, name, path in units_for(app, ra, args.corpus, deps_root):
            keys.append(kind + ':' + name)
            if os.path.isdir(path):
                todo.append((kind, name, path, {app['name']}))
        for dname, d in sorted(deps.items()):
            if app['name'] in d['apps']:
                keys.append('dep:' + dname)
        apps.append({'name': app['name'], 'format': ra.get('primary_format', app.get('project_type', '')),
                     'units': keys, 'present': os.path.isdir(root)})
    for dname, d in sorted(deps.items()):
        todo.append(('dep', dname, d['path'], d['apps']))

    if not args.report_only:
        tool = runway_tool()
        for kind, name, path, users in todo:
            if kind not in kinds:
                continue
            if only and not (only & users or name in only):
                continue
            res = score_unit(tool, kind, name, path, args, shots)
            res['apps'] = sorted(users)
            board['units'][kind + ':' + name] = res
            board['generated'] = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds')
            write(board, apps, args)
    write(board, apps, args)


def write(board, apps, args):
    board['apps'] = apps
    board['generated'] = board.get('generated') or datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds')
    rc, out, _ = run(['git', 'rev-parse', '--short', 'HEAD'], cwd=RUNWAY)
    board['commit'] = out.strip() if rc == 0 else '?'
    for u in board['units'].values():
        u.pop('launch_tail_full', None)
    with open(args.out + '.json', 'w') as f:
        json.dump(board, f, indent=1, sort_keys=True)
    baseline = load_json(args.baseline) if args.baseline and os.path.exists(args.baseline) else None
    with open(args.out + '.md', 'w') as f:
        f.write(render(board, baseline))


if __name__ == '__main__':
    main()
