"""V2 static pages retain exact selection and observation boundaries.

SPDX-License-Identifier: AGPL-3.0-or-later
"""
from copy import deepcopy
import hashlib
import re
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
sys.path.insert(0, str(ROOT / 'tests'))
import registry
import registry_v2_site as projection
import registry_v2_pages as pages
import test_registry_v2_stats as stats_fixture


class RegistryV2PageTests(unittest.TestCase):
    def setUp(self):
        self.fixture = stats_fixture.RegistryV2StatsTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        stamp = self.fixture.public.read_object('metadata/1.timestamp.json', 16384)[0]
        self.fixture.public.compare_and_swap('metadata/timestamp.json', stamp, None)
        self.catalog = projection.load_catalog(self.fixture.public, self.fixture.registry_id,
                                               ('https://mirror.example/asm',))
        self.observation = projection.observations(self.catalog, None)
        self.stage = self.fixture.root / 'site'
        shutil.copytree(ROOT / 'site', self.stage)

    def render(self, catalog=None, observation=None):
        return pages.write_pages(self.stage, catalog or self.catalog,
                                 self.observation if observation is None else observation)

    def page(self, name='fixture/one', version='1.0.0'):
        route = 'packages/' + name + ('/' + version if version else '') + '/index.html'
        return (self.stage / route).read_text()

    def test_exact_release_keeps_ids_dimensions_and_native_fetch_without_execution(self):
        routes = self.render()
        html = self.page()
        for text in ('asm registry fetch fixture/one@1.0.0', '--registry-id ' + '1' * 32,
                     '--target x86_64-linux', '--kind source', '--root ', '--state ', '--mirror ', '--output ',
                     'Instruction set', 'Operating system', 'ABI', 'CPU features', 'sysv-amd64', 'None declared'):
            self.assertIn(text, html)
        self.assertIn('packages/fixture/one/1.0.0/', routes)
        self.assertIn('data-registry-version="2"', html)
        self.assertNotIn('asm fetch fixture/one', html)
        self.assertNotIn('asm registry install', html)
        self.assertIn('does not execute', html)
        self.assertIn('data-fetch-command=', html)

    def test_raw_download_requires_actual_artifact_check(self):
        self.render()
        html = self.page()
        self.assertNotIn('Download source archive</a>', html)
        self.assertIn('Not run', html)
        self.catalog['packages'][0]['versions'][0]['evidence']['artifacts'] = 'validated'
        self.render()
        self.assertIn('Download source archive</a>', self.page())

    def test_original_closed_envelope_is_published_without_relabeling(self):
        self.render()
        release = self.catalog['packages'][0]['versions'][0]
        raw = (self.stage / 'registry/v2/releases' / ('2' * 32) / ('3' * 32 + '.json')).read_bytes()
        self.assertEqual(hashlib.sha256(raw).hexdigest(), release['envelope_sha256'])
        self.assertEqual(registry.strict_json(raw), self.fixture.envelopes[0])
        self.assertIn('registry/v2/releases/', self.page())

    def test_omitted_repository_and_untrusted_text_have_useful_fallbacks(self):
        self.catalog['packages'][0]['versions'][0]['summary'] = '<script>source-host()</script>'
        self.render()
        html = self.page()
        self.assertIn('&lt;script&gt;source-host()&lt;/script&gt;', html)
        self.assertNotIn('<script>source-host()', html)
        self.assertIn('Source repository not supplied', html)
        self.assertNotIn('/tree/', html)
        self.assertIn('README', html)
        self.assertIn('source archive', html)

    def test_yanked_and_revoked_retained_pages_have_distinct_states_without_actions(self):
        for state, label in (('yanked', 'Yanked release'), ('revoked', 'Revoked release')):
            with self.subTest(state=state):
                catalog = deepcopy(self.catalog)
                pkg = catalog['packages'][0]
                pkg['latest'] = None
                pkg['targets'] = []
                pkg['versions'][0][state] = True
                self.render(catalog)
                html = self.page()
                self.assertIn(label, html)
                self.assertNotIn('asm registry fetch fixture/one', html)
                self.assertNotIn('Download source archive</a>', html)
                self.assertIn('No active release', self.page(version=None))
                self.assertIn('1.0.0', self.page(version=None))

    def test_unknown_statistics_remain_unavailable_not_zero(self):
        self.render()
        html = (self.stage / 'stats/index.html').read_text()
        self.assertIn('Unavailable', html)
        self.assertIn('does not establish zero', html)
        snapshot = registry.strict_json((self.stage / 'registry/v2/discovery.json').read_bytes())
        self.assertEqual(snapshot['schema'], 2)
        self.assertTrue(all(item['downloads_30d'] is None for item in snapshot['packages']))
        self.assertEqual(snapshot['feeds'], {'new': [], 'popular': [], 'updated': []})

    def test_observed_zero_keeps_the_collecting_state_and_stays_outside_popular(self):
        store = self.fixture.store()
        self.fixture.batch(store, [])
        observed = projection.observations(self.catalog, store.snapshot(at='2026-01-03T00:00:00Z'))
        self.render(observation=observed)
        self.assertIn('Collecting downloads', self.page())
        self.assertIn('No completed downloads were recorded', self.page())
        activity = registry.strict_json((self.stage / 'registry/v2/activity/fixture/one/1.0.0.json').read_bytes())
        self.assertEqual(activity['total'], 0)
        self.assertFalse(activity['complete'])
        snapshot = registry.strict_json((self.stage / 'registry/v2/discovery.json').read_bytes())
        self.assertEqual(snapshot['feeds']['popular'], [])

    def test_actual_observations_reconcile_exact_release_and_package_counts(self):
        store = self.fixture.store()
        self.fixture.batch(store, [self.fixture.event()])
        observed = projection.observations(self.catalog, store.snapshot(at='2026-01-03T00:00:00Z'))
        self.render(observation=observed)
        self.assertIn('Observed minimum', self.page())
        self.assertIn('Daily counts and coverage', self.page())
        self.assertIn('2026-01-02', self.page())
        one = registry.strict_json((self.stage / 'registry/v2/activity/fixture/one/1.0.0.json').read_bytes())
        two = registry.strict_json((self.stage / 'registry/v2/activity/fixture/two/1.0.0.json').read_bytes())
        self.assertEqual(one['total'], 1)
        self.assertEqual(two['total'], 0)
        self.assertEqual(sum(day['count'] or 0 for day in one['days']), 1)
        snapshot = registry.strict_json((self.stage / 'registry/v2/discovery.json').read_bytes())
        self.assertEqual(snapshot['feeds']['popular'], ['fixture/one'])
        self.assertIn('fixture/one', (self.stage / 'browse/popular/index.html').read_text())
        home = (self.stage / 'index.html').read_text()
        popular = home.split('data-discovery-feed="popular"', 1)[1].split('</section>', 1)[0]
        self.assertIn('fixture/one', popular)
        self.assertIn('1 download', re.sub(r'<[^>]+>', '', popular))
        self.assertNotIn('Fully observed', self.page())

    def test_dates_and_purpose_metadata_are_explicitly_unavailable(self):
        self.render()
        for route in ('browse/new/index.html', 'browse/updated/index.html'):
            html = (self.stage / route).read_text()
            self.assertIn('Publication dates are unavailable', html)
            self.assertNotIn('First GitHub release', html)
            self.assertNotIn('datetime="2026-', html)
        self.assertTrue((self.stage / 'browse/categories/index.html').is_file())
        self.assertTrue((self.stage / 'browse/architectures/x86_64/index.html').is_file())
        self.assertTrue((self.stage / 'explore/index.html').is_file())

    def test_history_and_native_catalog_keep_numeric_versions_and_exact_links(self):
        package = self.catalog['packages'][0]
        original = package['versions'][0]
        for version, release_id in (('1.2.0', '6' * 32), ('1.10.0', '7' * 32)):
            release = deepcopy(original)
            release['version'] = release['publication']['version'] = version
            release['release_id'] = release_id
            release['manifest_sha256'] = hashlib.sha256(registry.json_bytes(release['publication'])).hexdigest()
            envelope = {'schema': 2, 'registry_id': self.catalog['registry_id'], 'package_id': package['package_id'],
                        'release_id': release_id, 'manifest_sha256': release['manifest_sha256'], 'publication': release['publication']}
            release['envelope_sha256'] = hashlib.sha256(registry.json_bytes(envelope)).hexdigest()
            release['artifacts'][0]['url'] = release['artifacts'][0]['url'].replace(original['release_id'], release_id)
            package['versions'].append(release)
        package['latest'] = '1.10.0'
        self.render(observation=projection.observations(self.catalog, None))
        html = self.page(version=None).split('id="versions"', 1)[1]
        self.assertLess(html.index('1.10.0'), html.index('1.2.0'))
        self.assertLess(html.index('1.2.0'), html.index('1.0.0'))
        self.assertIn('packages/fixture/one/1.10.0/', (self.stage / 'packages/index.html').read_text())

    def test_homepage_uses_v2_catalog_links_without_v1_fallback(self):
        self.render()
        html = (self.stage / 'index.html').read_text()
        self.assertIn('data-registry-version="2"', html)
        self.assertIn('registry/v2/index.json', html)
        self.assertNotIn('registry/v1/index.json', html)
        self.assertNotIn('First GitHub release', html)
        self.assertNotIn('Latest GitHub release', html)


if __name__ == '__main__':
    unittest.main()
