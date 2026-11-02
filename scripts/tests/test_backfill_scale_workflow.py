import ast
import json
from pathlib import Path
import re
import subprocess
from types import SimpleNamespace
import unittest

ROOT = Path(__file__).resolve().parents[2]
CI_PATH = ROOT / '.github/workflows/ci.yml'
SCALE_PATH = ROOT / '.github/workflows/backfill-scale.yml'


def load_workflow(path):
    # Psych is Ruby's standard YAML parser on the hosted runners. YAML 1.1 treats
    # the GitHub Actions key `on` as boolean true, so normalize it before JSON.
    script = r'''require "yaml"; require "json"
doc = YAML.safe_load_file(ARGV.fetch(0), aliases: true)
doc["on"] = doc.delete(true) if doc.key?(true)
puts JSON.generate(doc)
'''
    result = subprocess.run(
        ['ruby', '-e', script, str(path)],
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(result.stdout)


def evaluate_expression(expression, *, event_name='workflow_dispatch', inputs=None, results=None):
    expression = expression.strip()
    if expression.startswith('${{') and expression.endswith('}}'):
        expression = expression[3:-2].strip()
    expression = expression.replace('&&', ' and ').replace('||', ' or ')
    expression = re.sub(r'!(?!=)', ' not ', expression)
    expression = expression.replace('needs.formed-upgrade', 'needs.formed_upgrade')
    expression = expression.replace('needs.windows-updater', 'needs.windows_updater')
    expression = expression.strip()
    inputs = inputs or {}
    results = results or {}
    input_values = {
        'scale': False,
        'scale_only': False,
        'formed_only': False,
        'formed_release': '',
        'formed_platform': 'all',
    }
    input_values.update(inputs)
    need_values = {
        key.replace('-', '_'): SimpleNamespace(result=value)
        for key, value in results.items()
    }
    scope = {
        '__builtins__': {},
        'github': SimpleNamespace(event_name=event_name),
        'inputs': SimpleNamespace(**input_values),
        'needs': SimpleNamespace(**need_values),
        'always': lambda: True,
    }
    return eval(compile(ast.parse(expression, mode='eval'), '<workflow-expression>', 'eval'), scope)


class BackfillScaleWorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ci = load_workflow(CI_PATH)
        cls.scale = load_workflow(SCALE_PATH)

    def test_yaml_dispatch_options_and_read_only_permissions_are_real_fields(self):
        ci_triggers = self.ci['on']
        dispatch = ci_triggers['workflow_dispatch']['inputs']
        for name in ('scale', 'scale_only'):
            with self.subTest(name=name):
                self.assertEqual(dispatch[name]['type'], 'boolean')
                self.assertIs(dispatch[name]['default'], False)
        self.assertEqual(self.ci['permissions'], {'contents': 'read'})

        scale_triggers = self.scale['on']
        self.assertIn('workflow_dispatch', scale_triggers)
        self.assertIn('workflow_call', scale_triggers)
        self.assertEqual(self.scale['permissions'], {'contents': 'read'})
        self.assertEqual(scale_triggers['workflow_dispatch']['inputs']['source_sha']['type'], 'string')
        self.assertEqual(scale_triggers['workflow_call']['inputs']['source_sha']['type'], 'string')

    def test_scale_only_skips_standard_jobs_and_never_emits_full_ci_evidence(self):
        jobs = self.ci['jobs']
        for name in ('frontend', 'swift', 'native', 'windows-updater'):
            with self.subTest(job=name):
                self.assertEqual(jobs[name]['if'], '${{ !inputs.formed_only && !inputs.scale_only }}')
                self.assertEqual(jobs[name]['needs'], 'source')
        self.assertEqual(
            jobs['formed-upgrade']['if'],
            "${{ github.event_name == 'workflow_dispatch' && inputs.formed_release != '' }}",
            'The established formed-release dispatch condition remains intact',
        )
        self.assertEqual(
            jobs['scale']['if'],
            "${{ github.event_name == 'workflow_dispatch' && (inputs.scale || inputs.scale_only) }}",
        )
        self.assertEqual(jobs['scale']['uses'], './.github/workflows/backfill-scale.yml')
        self.assertEqual(jobs['scale']['with']['source_sha'], '${{ needs.source.outputs.sha }}')

        # Exercise the parsed job expressions against the intended dispatch modes.
        for options, expected_standard, expected_scale in (
            ({}, True, False),
            ({'scale': True}, True, True),
            ({'scale_only': True}, False, True),
            ({'formed_only': True}, False, False),
        ):
            with self.subTest(options=options):
                standard = evaluate_expression(jobs['frontend']['if'], inputs=options)
                scale = evaluate_expression(jobs['scale']['if'], inputs=options)
                self.assertEqual(standard, expected_standard)
                self.assertEqual(scale, expected_scale)

        evidence = jobs['evidence']
        self.assertIn('scale', evidence['needs'])
        self.assertIn('formed-upgrade', evidence['needs'])
        self.assertIn('!inputs.scale_only', evidence['if'])
        passing = {
            'source': 'success', 'frontend': 'success', 'swift': 'success', 'native': 'success',
            'windows-updater': 'success', 'formed-upgrade': 'skipped', 'scale': 'skipped',
        }
        self.assertTrue(evaluate_expression(evidence['if'], results=passing))
        self.assertFalse(evaluate_expression(
            evidence['if'], inputs={'scale_only': True},
            results={**passing, 'frontend': 'skipped', 'swift': 'skipped', 'native': 'skipped',
                     'windows-updater': 'skipped', 'scale': 'success'},
        ))
        self.assertFalse(evaluate_expression(
            evidence['if'], inputs={'scale': True}, results={**passing, 'scale': 'failure'}
        ))

    def test_exact_sha_is_checked_and_the_same_resolved_sha_flows_to_scale(self):
        source = self.ci['jobs']['source']
        resolve = next(step for step in source['steps'] if step.get('id') == 'resolve')
        self.assertEqual(source['outputs']['sha'], '${{ steps.resolve.outputs.sha }}')
        self.assertEqual(resolve['env']['SOURCE_SHA'], '${{ inputs.source_sha || github.sha }}')
        self.assertIn('[[ "$SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]] ||', resolve['run'])
        self.assertIn('scale_only requires scale=true', resolve['run'])

        scale_resolve = self.scale['jobs']['resolve']
        step = next(item for item in scale_resolve['steps'] if item.get('id') == 'resolve')
        self.assertEqual(scale_resolve['outputs']['sha'], '${{ steps.resolve.outputs.sha }}')
        self.assertEqual(step['env']['SOURCE_SHA'], '${{ inputs.source_sha || github.sha }}')
        self.assertIn('[[ "$SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]] ||', step['run'])
        checkout = next(item for item in self.scale['jobs']['scale']['steps'] if item.get('uses', '').startswith('actions/checkout@'))
        self.assertEqual(checkout['with']['ref'], '${{ needs.resolve.outputs.sha }}')
        self.assertIs(checkout['with']['persist-credentials'], False)
        self.assertIs(checkout['with']['lfs'], False)
        verify = next(item for item in self.scale['jobs']['scale']['steps'] if item.get('name') == 'Verify checked-out source identity')
        self.assertIn('git rev-parse HEAD', verify['run'])
        self.assertIn('actual_sha" == "$SOURCE_SHA"', verify['run'])

    def test_scale_workflow_runs_all_real_sizes_on_pinned_mac_toolchain_with_existing_budgets(self):
        job = self.scale['jobs']['scale']
        self.assertEqual(job['runs-on'], 'macos-26')
        self.assertEqual(job['timeout-minutes'], 90)
        self.assertNotIn('strategy', job, 'The scale sizes run serially in one job')
        self.assertEqual(job['env']['SOURCE_SHA'], '${{ needs.resolve.outputs.sha }}')
        self.assertEqual(self.scale['env']['DEVELOPER_DIR'], '/Applications/Xcode_26.6.app/Contents/Developer')
        self.assertEqual(self.scale['env']['GIT_LFS_SKIP_SMUDGE'], '1')

        steps = job['steps']
        node = next(item for item in steps if item.get('uses', '').startswith('actions/setup-node@'))
        self.assertEqual(node['with']['node-version'], '24')
        cache = next(item for item in steps if item.get('name') == 'Swift dependency cache')
        self.assertEqual(cache['uses'], 'actions/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9')
        self.assertEqual(cache['with']['key'], "swift-deps-${{ runner.os }}-${{ runner.arch }}-${{ hashFiles('Package.resolved') }}-v1")
        self.assertIn('.build/artifacts', cache['with']['path'])
        self.assertIn('.build/checkouts', cache['with']['path'])
        self.assertIn('.build/repositories', cache['with']['path'])

        lfs = next(item for item in steps if item.get('name') == 'Prepare Git LFS inputs')
        self.assertIn('git-lfs', lfs['run'])
        self.assertIn('scripts/prepare_tiktoken_lfs.sh', lfs['run'])
        toolchain = next(item for item in steps if item.get('name') == 'Record hosted toolchain')
        self.assertIn('sw_vers', toolchain['run'])
        self.assertIn('expected_xcode=26.6', toolchain['run'])
        self.assertIn('swift --version', toolchain['run'])
        self.assertIn('xcodebuild -version', toolchain['run'])
        self.assertIn('node --version', toolchain['run'])

        run = next(item for item in steps if item.get('name') == 'Run actual Swift backfill sizes')
        for expected in (
            '--sizes 13 128 512 4124', '--timeout 1200', '--max-progress-gap 30',
            '--max-backfill-seconds 600', '--output backfill-scale-results',
            'scripts/check_backfill_scale.py',
        ):
            with self.subTest(argument=expected):
                self.assertIn(expected, run['run'])
        self.assertNotIn('cargo ', run['run'])

    def test_scale_evidence_is_failure_safe_and_not_a_release_or_installer_job(self):
        jobs = self.scale['jobs']
        self.assertEqual(set(jobs), {'resolve', 'scale'})
        steps = jobs['scale']['steps']
        initializer = next(item for item in steps if item.get('name') == 'Initialize failure-safe evidence envelope')
        checkout_index = next(index for index, item in enumerate(steps) if item.get('uses', '').startswith('actions/checkout@'))
        initialize_index = steps.index(initializer)
        self.assertLess(checkout_index, initialize_index)
        self.assertEqual(initializer['if'], 'always()')
        self.assertIn('requested_source_sha', initializer['run'])
        self.assertIn('status=RUNNING', initializer['run'])
        upload = next(item for item in steps if item.get('name') == 'Upload scale evidence')
        seal = next(item for item in steps if item.get('name') == 'Seal evidence outcome')
        self.assertEqual(seal['if'], 'always()')
        self.assertEqual(seal['env']['JOB_STATUS'], '${{ job.status }}')
        self.assertIn('mkdir -p backfill-scale-evidence', seal['run'])
        self.assertEqual(upload['if'], 'always()')
        self.assertTrue(upload['uses'].startswith('actions/upload-artifact@'))
        self.assertIn('backfill-scale-evidence/', upload['with']['path'])
        self.assertIn('backfill-scale-results/', upload['with']['path'])
        self.assertEqual(upload['with']['if-no-files-found'], 'warn')
        self.assertIn('${{ needs.resolve.outputs.sha }}', upload['with']['name'])
        self.assertEqual(self.scale['concurrency']['cancel-in-progress'], False)
        self.assertIn('backfill-scale-', self.scale['concurrency']['group'])
        self.assertNotIn('sign', self.scale['jobs'])
        self.assertNotIn('publish', self.scale['jobs'])
        self.assertFalse(any('secrets' in str(step).lower() for step in steps))

    def test_scale_concurrency_is_separate_from_standard_and_formed_ci_runs(self):
        ci_group = self.ci['concurrency']['group']
        self.assertIn('inputs.formed_release', ci_group)
        self.assertIn('inputs.formed_platform', ci_group)
        self.assertIn("'scale-only'", ci_group)
        self.assertIn("'scale'", ci_group)
        self.assertIn("'standard'", ci_group)
        self.assertFalse(self.ci['concurrency']['cancel-in-progress'])
        scale_group = self.scale['concurrency']['group']
        self.assertIn('backfill-scale-', scale_group)
        self.assertNotEqual(ci_group, scale_group)


if __name__ == '__main__':
    unittest.main()
