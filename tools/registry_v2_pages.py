"""Render one bounded V2 registry projection as static pages.

No application service, source-host request, or package execution is needed.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
from datetime import datetime, timedelta
from html import escape
import hashlib
from pathlib import Path
import re

from count_format import count_html
import package_activity
import package_pages as shared
import registry
import registry_v2_site as projection
import target_metadata


POLICY = 'asm-deliveries-v2'
SOURCE = 'asm-delivery-events'


def _instant(value):
    return datetime.fromisoformat(value.replace('Z', '+00:00'))


def _stamp(value):
    return value.isoformat(timespec='seconds').replace('+00:00', 'Z')


def _active(package):
    return next((release for release in package['versions']
                 if release['version'] == package['latest'] and not release['yanked'] and not release['revoked']), None)


def _count(value):
    return 'Unavailable' if value is None else count_html(value, lower_bound=True)


def _total(values):
    return None if any(value is None for value in values) else sum(values)


def catalog_stats(catalog):
    releases = [release for package in catalog['packages'] for release in package['versions']]
    artifacts = [artifact for release in releases for artifact in release['artifacts']]
    return {'packages': len(catalog['packages']), 'releases': len(releases), 'files': len(artifacts),
            'targets': len({artifact['target'] for artifact in artifacts})}


def discovery_snapshot(catalog, observation):
    """Join public identities to observed counts without inventing release dates."""
    observed = projection.observations(catalog, observation)
    end = observed['coverage_end']
    rows = [{'name': package['name'], 'package_id': package['package_id'], 'first_published_at': None,
             'last_published_at': None, 'publication_source': 'asm-v2',
             'downloads_30d': observed['counts'][package['package_id']], 'downloads_30d_exact': False,
             'downloads_30d_coverage': 'unavailable' if end is None else 'lower-bound'}
            for package in catalog['packages']]
    active = {package['name'] for package in catalog['packages'] if _active(package)}
    return {'schema': 2, 'registry_id': catalog['registry_id'], 'policy': POLICY, 'source': SOURCE,
            'observed_at': end, 'publication_observed_at': None, 'stale': observed['stale'], 'refresh_error': None,
            'collection_started_at': observed['collection_started_at'],
            'window': {'days': 30, 'start': _stamp(_instant(end) - timedelta(days=30)) if end else None,
                       'end': end, 'basis': 'rolling-observation'},
            'coverage': {'start': observed['collection_started_at'], 'end': end, 'complete': False},
            'packages': rows, 'categories': [], 'feeds': {'new': [], 'updated': [],
            'popular': [row['name'] for row in sorted(rows, key=lambda row: (-(row['downloads_30d'] or 0), row['name']))
                        if row['name'] in active and row['downloads_30d'] is not None and row['downloads_30d'] > 0]}}


def activity_snapshot(catalog, observation, package=None, release=None):
    """Retain gaps; normalized sender logs do not establish observed seconds."""
    end = observation['coverage_end']
    if release is not None:
        total = observation['release_counts'][release['release_id']]
    elif package is not None:
        total = observation['counts'][package['package_id']]
    else:
        total = _total(list(observation['counts'].values())) if end else None
    result = {'schema': 2, 'registry_id': catalog['registry_id'], 'policy': POLICY, 'source': SOURCE,
              'package_id': package['package_id'] if package else None,
              'release_id': release['release_id'] if release else None,
              'name': package['name'] if package else None, 'version': release['version'] if release else None,
              'observed_at': end, 'collection_started_at': observation['collection_started_at'],
              'stale': observation['stale'], 'total': total, 'complete': False,
              'window': {'days': 30, 'start': None, 'end': end, 'basis': 'rolling-observation'}, 'days': []}
    if end is None:
        return result
    stop = _instant(end)
    start = stop - timedelta(days=30)
    result['window']['start'] = _stamp(start)
    counts = {}
    for row in observation['daily_counts']:
        if package is not None and row['package_id'] != package['package_id']:
            continue
        if release is not None and row['release_id'] != release['release_id']:
            continue
        counts[row['date']] = counts.get(row['date'], 0) + row['count']
    day = start.replace(hour=0, minute=0, second=0, microsecond=0)
    while day <= stop:
        left, right = max(start, day), min(stop, day + timedelta(days=1))
        count = counts.get(day.date().isoformat())
        result['days'].append({'date': day.date().isoformat(), 'start': _stamp(left), 'end': _stamp(right),
                               'count': count, 'coverage': 'partial' if count is not None else 'unavailable',
                               'observed_seconds': 0})
        day += timedelta(days=1)
    registry.require(sum(row['count'] or 0 for row in result['days']) == total,
                     'V2 daily counts differ from the selected total')
    return result


def _activity(data, prefix):
    scope = (data['name'] + ('@' + data['version'] if data['version'] else '')) if data['name'] else 'All packages · All versions'
    body = '<section id="activity" class="package-section package-activity"><h2>Download activity</h2><p><code>' + escape(scope) + '</code></p>'
    if data['total'] is None:
        body += '<p class="package-activity-state">Download activity is unavailable. Missing observations do not establish zero downloads.</p>'
    else:
        if data['total'] == 0:
            body += '<p class="package-activity-total">Collecting downloads</p><p>No completed downloads were recorded in the observed part of this window.</p>'
        else:
            body += '<p class="package-activity-total">' + _count(data['total']) + ' downloads</p><p>Observed minimum · Last 30 days.</p>'
        body += '<p>Coverage is incomplete.</p>'
        body += '<p class="package-note">Reporting cutoff: ' + escape(data['observed_at']) + '. Collection started ' + escape(data['collection_started_at']) + '.</p>'
        if data['total']:
            body += package_activity._chart(data['days'])
        body += package_activity._table(data['days'])
    if data['stale']:
        body += '<p class="package-note">These observations are stale. The latest activity may be missing.</p>'
    body += '<p class="package-note">Counts describe completed sender responses, not verified downloads, installations, people, quality, or safety. Unreported sources are excluded.</p>'
    body += '<p>' + shared._anchor('How counts work', prefix + 'discovery/') + '</p></section>'
    return body


def _command(value, identifier, label='Fetch this file'):
    return ('<div class="command-block"><div class="command-block-heading"><span>' + label + '</span>'
            '<button class="copy-button" type="button" data-copy="' + identifier + '" hidden>Copy</button></div>'
            '<pre tabindex="0"><code id="' + identifier + '">' + escape(value) + '</code></pre></div>')


def _state(release):
    return 'Revoked release' if release['revoked'] else 'Yanked release' if release['yanked'] else 'Active release'


def _release_route(package, release):
    return 'registry/v2/releases/' + package['package_id'] + '/' + release['release_id'] + '.json'


def _files(catalog, package, release, prefix):
    available = not release['yanked'] and not release['revoked']
    artifacts = release['artifacts']
    targets = sorted({item['target'] for item in artifacts})
    architectures = sorted({item['isa'] for item in artifacts})
    kinds = sorted({item['kind'] for item in artifacts})
    options = lambda values: ''.join('<option value="' + escape(value, quote=True) + '">' + escape(value) + '</option>' for value in values)
    body = ('<form class="package-filter-form" hidden><div class="package-file-filter"><label for="artifact-kind">Format</label>'
            '<select id="artifact-kind"><option value="">All formats</option>' + options(kinds) + '</select></div>'
            '<div class="package-file-filter"><label for="artifact-architecture">Architecture</label><select id="artifact-architecture">'
            '<option value="">All architectures</option>' + options(architectures) + '</select></div>'
            '<div class="package-file-filter"><label for="artifact-target">Target</label><select id="artifact-target"><option value="">All targets</option>'
            + options(targets) + '</select></div><button class="reset-search" type="button" data-clear-artifact-filters>Clear file filters</button></form>')
    body += '<p id="artifact-filter-status" role="status" aria-live="polite">' + str(len(artifacts)) + ' release files shown.</p><div class="package-artifacts">'
    for artifact in artifacts:
        kind, target = artifact['kind'], artifact['target']
        identifier = 'fetch-' + kind + '-' + target
        command = projection.fetch_command(catalog, package, release, artifact) if available else None
        label = 'Executable' if kind == 'executable' else 'Source archive'
        facts = [('Target', target), ('Instruction set', artifact['isa']), ('Operating system', artifact['os']),
                 ('ABI', artifact['abi']), ('CPU features', ', '.join(artifact['cpu_features']) or 'None declared'),
                 ('Format', artifact['format']), ('Size', str(artifact['bytes']) + ' bytes')]
        body += '<article class="package-artifact" data-artifact-kind="' + kind + '" data-artifact-target="' + target + '" data-artifact-architecture="' + artifact['isa'] + '"'
        if command:
            body += ' data-fetch-command="' + escape(command, quote=True) + '"'
        body += '><header><h3>' + label + '</h3><code>' + artifact['sha256'] + '</code></header>' + shared._facts(facts, 'package-artifact-facts')
        body += '<p class="package-digest"><span>SHA-256</span><code>' + artifact['sha256'] + '</code></p>'
        if available and release['evidence']['artifacts'] == 'validated':
            body += '<p class="package-artifact-action">' + shared._anchor('Download ' + label.lower(), artifact['url']) + '</p>'
        else:
            body += '<p class="package-note">' + ('Selection is unavailable for this release.' if not available else 'Artifact byte check: Not run. Use the native fetch command to verify selected bytes.') + '</p>'
        if command:
            body += _command(command, identifier)
        body += '</article>'
    return body + '</div><p class="package-artifact-empty" hidden role="status">No files match. Clear the file filters.</p>'


def _listing(packages, prefix):
    rows = []
    for package in packages:
        release = _active(package)
        href = prefix + shared.package_route(package['name'])
        rows.append('<li class="package-catalog-item"><div class="package-result-heading">' + shared._anchor(package['name'], href, package=True, attrs=' class="package-catalog-name"')
                    + (shared._anchor(release['version'], prefix + shared.package_route(package['name'], release['version']), package=True, attrs=' class="package-version"') if release else '<span class="package-version">No active release</span>') + '</div><p>'
                    + escape(release['summary'] if release else package['summary']) + '</p></li>')
    return '<ul class="package-catalog">' + ''.join(rows) + '</ul>' if rows else '<p class="package-empty">No active packages match this selection.</p>'


def _package(catalog, package, release, observation, *, exact):
    route = shared.package_route(package['name'], release['version'] if exact else None)
    prefix = '../' * route.count('/')
    title = package['name'] + ('@' + release['version'] if exact else '')
    body = '<nav class="package-breadcrumbs" aria-label="Breadcrumb"><ol><li>' + shared._anchor('Back to search', prefix + 'index.html#catalog', attrs=' data-back-to-search')
    body += '</li><li>' + shared._anchor('Packages', prefix + 'packages/', package=True) + '</li></ol></nav>'
    body += '<header class="package-heading"><div class="package-title-row"><h1 class="package-identity">' + escape(title) + '</h1><p class="package-release-label">'
    body += _state(release) if release else 'No active release'
    body += '</p></div><p class="package-summary">' + escape(release['summary'] if release else package['summary']) + '</p>'
    body += shared._facts([('Version', release['version'] if release else 'No active release'), ('Package ID', package['package_id'])]
                          + ([('License', release['license']), ('Release ID', release['release_id'])] if release else []), 'package-facts') + '</header>'
    body += '<nav class="package-section-nav" aria-label="Package sections">' + ''.join(shared._anchor(label, '#' + key) for key, label in
              (('use', 'Use'), ('readme', 'Readme'), ('files', 'Files'), ('evidence', 'Evidence'), ('versions', 'Versions'), ('activity', 'Downloads'))) + '</nav>'
    body += '<div class="package-layout"><div class="package-primary"><section id="use" class="package-section"><h2>Use this package</h2>'
    if release and not release['yanked'] and not release['revoked']:
        body += '<p>Build the V2 preview with <code>make registry-cli</code> on Linux x86-64, Linux ARM64, or Apple Silicon macOS 15 or later. Use that binary as <code>asm</code> for these commands.</p><p>Install curl, gzip, and the host hash tool before fetching. Provision the registry root through an independent trusted channel.</p>'
        body += '<p>Replace the root, private state, and output paths before use. Fetch verifies selected bytes and does not execute the package.</p>'
        if len(release['artifacts']) == 1:
            artifact = release['artifacts'][0]
            command = projection.fetch_command(catalog, package, release, artifact)
            body += '<div data-selected-fetch><span data-selected-fetch-label>' + escape(artifact['target']) + '</span>' + _command(command, 'selected-fetch-command') + '</div>'
            body += '<p data-fetch-selection hidden>Choose a release file below.</p>'
        else:
            body += '<p data-fetch-selection>Choose a release file below. Each file includes its exact fetch command.</p><div data-selected-fetch hidden><span data-selected-fetch-label></span>' + _command('', 'selected-fetch-command') + '</div>'
    else:
        body += '<p>Fetch commands and download links are unavailable. Inspect the retained version history.</p>'
    body += '</section><section id="readme" class="package-section"><h2>Readme</h2><p>The README is not rendered in this projection. Inspect the source archive metadata in the release record. Fetch a declared source selection to read its documentation.</p></section>'
    body += '<section id="files" class="package-section"><h2>Files</h2>' + (_files(catalog, package, release, prefix) if release else '<p>Select an exact release from the version history.</p>') + '</section>'
    body += '<section id="evidence" class="package-section"><h2>Release evidence</h2>'
    if release:
        body += shared._facts([(label, shared._evidence_label(release['evidence'][key])) for key, label in shared.EVIDENCE.items()], 'package-evidence-list')
    body += '<p class="package-note">This is an operator-selected distribution projection. The native CLI authenticates current metadata and checks artifact bytes. Metadata checks do not establish publisher identity, provenance, or general safety.</p></section>'
    body += '<section id="versions" class="package-section"><h2>Versions</h2><ul class="package-history">'
    for version in sorted(package['versions'], key=lambda item: registry.version_tuple(item['version']), reverse=True):
        body += '<li>' + shared._anchor(version['version'], prefix + shared.package_route(package['name'], version['version']), package=True) + ' · ' + _state(version) + '</li>'
    body += '</ul></section>' + _activity(activity_snapshot(catalog, observation, package, release if exact else None), prefix) + '</div><aside class="package-sidebar"><section class="package-section"><h2>Source</h2>'
    if release:
        source = release['source']
        if source.get('repository'):
            body += '<p>' + shared._anchor('Source repository', source['repository']) + '</p><p class="package-note">This source locator is descriptive. It does not authenticate the publisher.</p>'
        else:
            body += '<p>Source repository not supplied.</p>'
        body += shared._facts([('Source commit', source['commit']['algorithm'] + ':' + source['commit']['digest']), ('Source path', source['path']), ('Manifest SHA-256', release['manifest_sha256'])], 'package-source-facts')
        body += '<p>' + shared._anchor('Release record (JSON)', prefix + _release_route(package, release)) + '</p>'
    else:
        body += '<p>Select an exact release to inspect its source facts.</p>'
    return body + '<p class="package-note">The namespace is a package name prefix, not an authenticated publisher profile.</p></section></aside></div>'


def _stats(catalog, observed):
    counts = catalog_stats(catalog)
    body = '<header class="package-heading"><h1>Stats</h1><p>V2 registry size and observed sender transfers.</p></header><dl class="registry-totals">'
    for key, label in (('packages', 'Registered packages'), ('releases', 'Retained releases')):
        body += '<div class="registry-total"><dt>' + label + '</dt><dd>' + count_html(counts[key]) + '</dd></div>'
    retained = _total(list(observed['retained_counts'].values())) if observed['coverage_end'] else None
    body += '<div class="registry-total"><dt>Observed downloads</dt><dd>' + _count(retained) + '<span class="registry-total-note">Since collection began</span></dd></div></dl>'
    body += shared._facts([('Release files', str(counts['files'])), ('Package targets', str(counts['targets']))], 'package-facts')
    body += '<p class="package-note">Missing collection history does not establish zero downloads. Coverage is incomplete, including measured zero.</p>'
    if observed['coverage_end']:
        body += '<p class="package-note">Collection started ' + escape(observed['collection_started_at']) + '. Reported through ' + escape(observed['coverage_end']) + '.</p>'
    body += '<section class="package-section"><h2>Most downloaded since collection began</h2><ol class="registry-ranking">'
    for package in sorted(catalog['packages'], key=lambda item: (-(observed['retained_counts'][item['package_id']] or 0), item['name'])):
        number = observed['retained_counts'][package['package_id']]
        if number is not None and number > 0:
            body += '<li class="registry-ranking-item">' + shared._anchor(package['name'], '../' + shared.package_route(package['name']), package=True) + '<span>' + _count(number) + ' transfers</span></li>'
    body += '</ol><p class="package-note">Missing reports can affect relative order.</p></section>'
    body += '<details class="registry-definition"><summary>Measurement scope</summary><p>Counts include complete public HTTP 200 GET responses with the declared full byte length. They exclude classified bots, internal traffic, partial responses, and unreported mirrors or cache hits.</p><p>They do not measure verification, installations, people, quality, or safety. Unattributed tagged requests are separate diagnostics.</p></details>'
    body += '<p>' + shared._anchor('Statistics data (JSON)', '../registry/v2/stats.json') + ' · ' + shared._anchor('How counts work', '../discovery/') + '</p>'
    return body + _activity(activity_snapshot(catalog, observed), '../')


def _home_discovery(content, catalog, snapshot):
    packages = {package['name']: package for package in catalog['packages']}
    for key, title in (('new', 'New packages'), ('popular', 'Most downloaded'), ('updated', 'Recently updated')):
        caption = 'Last 30 days' if key == 'popular' else 'Publication dates unavailable'
        body = '<section class="discovery-group" data-discovery-feed="' + key + '" aria-labelledby="browse-' + key + '"><div class="discovery-group-header"><div class="discovery-group-heading"><h3 id="browse-' + key + '">' + title + '</h3>'
        body += shared._anchor('View all', 'browse/' + key + '/', attrs=' class="discovery-more" aria-label="View all ' + title.lower() + '"')
        body += '</div><p class="discovery-group-caption">' + caption + '</p></div>'
        names = snapshot['feeds'][key][:5]
        if names:
            body += '<ul class="discovery-items">'
            facts = {row['name']: row for row in snapshot['packages']}
            for name in names:
                package, count = packages[name], facts[name]['downloads_30d']
                targets = ' · '.join(_active(package)['artifacts'][index]['target'] for index in range(len(_active(package)['artifacts'])))
                body += '<li><a class="discovery-item" data-package-link href="' + shared.package_route(name) + '"><span class="discovery-name">' + escape(name) + '</span><span class="discovery-signal">' + _count(count) + (' download' if count == 1 else ' downloads') + '</span><span class="discovery-summary">' + escape(package['summary']) + '</span><span class="discovery-targets">' + escape(targets) + '</span></a></li>'
            body += '</ul><p class="discovery-group-note">Coverage is incomplete. Reported through ' + escape(snapshot['observed_at']) + '.</p>'
        else:
            note = 'Download counts are unavailable or no positive transfers were recorded.' if key == 'popular' else 'Publication dates are unavailable in this V2 profile.'
            body += '<p class="discovery-group-note">' + note + '</p>'
        body += '</section>'
        content = re.sub(r'<section class="discovery-group" data-discovery-feed="' + key + r'".*?</section>', lambda match: body, content, count=1, flags=re.S)
    state = ('Download observations are unavailable.' if snapshot['observed_at'] is None else 'Download observations are stale.' if snapshot['stale'] else 'Coverage is incomplete.')
    content = re.sub(r'<p class="discovery-state">.*?</p>', lambda match: '<p class="discovery-state">' + state + '</p>', content, count=1, flags=re.S)
    return content


def write_pages(stage: Path, catalog: dict, observation: dict) -> list[str]:
    """Write views and public derived JSON from one validated V2 projection."""
    observed = projection.observations(catalog, observation)
    snapshot = discovery_snapshot(catalog, observed)
    home = stage / 'index.html'
    content = home.read_text()
    content = re.sub(r'<body\b(?:\s+data-registry-version="2")?', '<body data-registry-version="2"', content, count=1)
    content = content.replace('registry/v1/index.json', 'registry/v2/index.json')
    content = content.replace('First GitHub release', 'Publication dates unavailable').replace('Latest GitHub release', 'Publication dates unavailable')
    for key, value in catalog_stats(catalog).items():
        content = re.sub(r'(<dd data-catalog-stat="' + key + r'">).*?(</dd>)', lambda match: match[1] + count_html(value) + match[2], content, flags=re.S)
    content = _home_discovery(content, catalog, snapshot)
    registry.write_atomic(home, content.encode())
    chrome = shared._chrome(stage)
    routes = []
    def write(route, title, description, body, *, active='Explore', missing=False):
        html = shared._page(route, title, description, body, chrome, active_nav=active, missing=missing)
        html = html.replace('<body class="package-page">', '<body class="package-page" data-registry-version="2">', 1)
        registry.write_atomic(stage / route / 'index.html' if route.endswith('/') else stage / route, html.encode())
        routes.append(route)
    for package in catalog['packages']:
        for release in package['versions']:
            envelope = {'schema': 2, 'registry_id': catalog['registry_id'], 'package_id': package['package_id'],
                        'release_id': release['release_id'], 'manifest_sha256': release['manifest_sha256'], 'publication': release['publication']}
            raw = registry.json_bytes(envelope)
            registry.require(hashlib.sha256(raw).hexdigest() == release['envelope_sha256'], 'V2 release envelope changed before rendering')
            registry.write_atomic(stage / _release_route(package, release), raw)
            route = shared.package_route(package['name'], release['version'])
            write(route, package['name'] + '@' + release['version'], release['summary'], _package(catalog, package, release, observed, exact=True))
            registry.write_atomic(stage / ('registry/v2/activity/' + package['name'] + '/' + release['version'] + '.json'), registry.json_bytes(activity_snapshot(catalog, observed, package, release)))
        route = shared.package_route(package['name'])
        write(route, package['name'], package['summary'], _package(catalog, package, _active(package), observed, exact=False))
        registry.write_atomic(stage / ('registry/v2/activity/' + package['name'] + '.json'), registry.json_bytes(activity_snapshot(catalog, observed, package)))
    for owner in sorted({package['name'].split('/')[0] for package in catalog['packages']}):
        write('packages/' + owner + '/', owner + ' packages', 'Packages in the declared namespace.', '<header class="package-heading"><h1>' + escape(owner) + '</h1></header>' + _listing([package for package in catalog['packages'] if package['name'].split('/')[0] == owner], '../../'))
    write('packages/', 'Assembly packages', 'Browse V2 package records and exact releases.', '<header class="package-heading"><h1>Assembly packages</h1><p>Inspect package records, exact targets, and release evidence.</p></header>' + _listing(catalog['packages'], '../'))
    registry.write_atomic(stage / 'registry/v2/discovery.json', registry.json_bytes(snapshot))
    retained = {'scope': 'since-collection', 'total': _total(list(observed['retained_counts'].values())) if observed['coverage_end'] else None,
                'complete': False, 'stale': observed['stale'], 'collection_started_at': observed['collection_started_at'],
                'observed_at': observed['coverage_end'], 'counts': observed['retained_counts'], 'release_counts': observed['retained_release_counts']}
    measurement = {'profile': observed['reporting'], 'sources': observed['sources'], 'deduplication': 'source-request-id',
                   'reported_through': observed['coverage_end'], 'unattributed_requests': observed['unattributed_requests'],
                   'retained_unattributed_requests': observed['retained_unattributed_requests']}
    registry.write_atomic(stage / 'registry/v2/stats.json', registry.json_bytes({'schema': 2, 'registry_id': catalog['registry_id'], 'catalog': catalog_stats(catalog), 'transfers': retained, 'measurement': measurement, 'activity': activity_snapshot(catalog, observed)}))
    write('stats/', 'Stats', 'V2 catalog and sender observations.', _stats(catalog, observed), active='Stats')
    popular = [package for name in snapshot['feeds']['popular'] for package in catalog['packages'] if package['name'] == name]
    body = '<header class="package-heading"><h1>Most downloaded</h1><p>Observed minimum · Last 30 days. Missing reporting can affect order.</p></header>'
    body += _listing(popular, '../../') if popular else '<p>Download counts are unavailable or no positive transfers were recorded. Missing observations do not establish zero downloads.</p>'
    write('browse/popular/', 'Most downloaded', 'V2 observed transfers in the last thirty days.', body)
    for key, label in (('new', 'New packages'), ('updated', 'Recently updated')):
        write('browse/' + key + '/', label, 'Publication dates are unavailable.', '<header class="package-heading"><h1>' + label + '</h1></header><p>Publication dates are unavailable in this V2 distribution profile. Import, signing, and build times are not release dates.</p><p>' + shared._anchor('Browse all packages', '../../packages/') + '</p>')
    directory = '<header class="package-heading"><h1>Browse by architecture</h1><p>Architecture does not establish operating system, ABI, CPU feature, or CLI host compatibility.</p></header><ul>'
    for key, label in target_metadata.ARCHITECTURES.items():
        selected = [package for package in catalog['packages'] if _active(package) and any(item['isa'] == key for item in _active(package)['artifacts'])]
        directory += '<li>' + shared._anchor(label + ' (' + key + ')', key + '/') + ' · ' + count_html(len(selected)) + ' packages</li>'
        write('browse/architectures/' + key + '/', label + ' packages', 'Explicit active V2 artifact architecture.', '<header class="package-heading"><h1>' + label + ' packages</h1></header>' + _listing(selected, '../../../'))
    write('browse/architectures/', 'Browse by architecture', 'Explicit active V2 artifact architectures.', directory + '</ul>')
    write('browse/categories/', 'Browse by purpose', 'Purpose metadata is unavailable.', '<header class="package-heading"><h1>Browse by purpose</h1></header><p>This V2 profile supplies no reviewed purpose categories.</p><p>' + shared._anchor('Browse all packages', '../../packages/') + '</p>')
    write('explore/', 'Explore', 'Explore V2 packages and their observed transfers.', '<header class="package-heading"><h1>Explore</h1><p>Find exact releases and inspect their available information.</p></header><ul>' + ''.join('<li>' + shared._anchor(label, '../' + route) + '</li>' for route, label in (('packages/', 'All packages'), ('browse/popular/', 'Most downloaded in the last 30 days'), ('browse/architectures/', 'Browse by architecture'), ('browse/categories/', 'Browse by purpose'), ('browse/new/', 'New packages'), ('browse/updated/', 'Recently updated'), ('stats/', 'Stats'))) + '</ul>')
    write('discovery/', 'How counts work', 'V2 sender observations and coverage limits.', '<header class="package-heading"><h1>How counts work</h1></header><p>V2 counts describe complete public HTTP 200 GET responses with the declared full artifact length. They do not establish client verification, installation, or unique people.</p><p>The public selection tag binds registry, package, release, target, and kind to the immutable blob digest. Identical bytes do not share package credit.</p><p>Imports deduplicate source and request identity. Repeated full transfers remain separate observations. HEAD, ranges, conditional replies, redirects, failed or interrupted transfers, and classified bots or internal traffic do not count.</p><p>Coverage is incomplete. Unreported sources and cache hits remain unknown. Use one reporting layer per delivery path to avoid double counting.</p><p>Unknown counts remain unavailable. An observed zero covers only its reported source and interval. The ≥ symbol means an observed minimum.</p><p>Statistics refresh independently from artifact delivery. Exact native downloads authenticate current policy even when the website projection is old.</p>')
    write('404.html', 'Page not found', 'The requested page was not found.', '<section class="package-empty"><h1>Page not found</h1><p>Check the address or browse available packages.</p>' + shared._anchor('Browse packages', '/packages/', package=True) + '</section>', missing=True)
    return routes
