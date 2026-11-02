from pathlib import Path
import re
import sys
import json
import subprocess
import textwrap
import unittest

scripts = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(scripts))
import check_formed_release_upgrade as probe

WORKFLOW = Path(__file__).resolve().parents[2] / '.github/workflows/formed-release-upgrade.yml'


class FormedReleaseWorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = WORKFLOW.read_text(encoding='utf-8')

    def test_only_manual_or_explicit_reusable_invocation_can_start_the_matrix(self):
        triggers = self.workflow.split('\npermissions:', 1)[0]
        self.assertIn('workflow_dispatch:', triggers)
        self.assertIn('workflow_call:', triggers)
        self.assertNotRegex(triggers, r'(?m)^  (?:push|pull_request|schedule):')
        self.assertRegex(self.workflow, r'(?m)^permissions:\n  contents: read\n')
        self.assertNotRegex(self.workflow, r'(?m)^\s+contents:\s*write\s*$')

    def test_dispatch_covers_each_pinned_release_and_defaults_to_one_small_run(self):
        dispatch = self.workflow.split('  workflow_call:', 1)[0]
        for release in probe.RELEASES:
            self.assertRegex(dispatch, rf'(?m)^          - {re.escape(release)}$')
        self.assertRegex(dispatch, r'(?m)^        default: 0\.9\.8$')
        self.assertRegex(dispatch, r'(?m)^          - all$')
        self.assertIn('max-parallel: 2', self.workflow)
        self.assertIn("'macos': ('macos-26', '/tmp')", self.workflow)
        self.assertIn("'windows': ('windows-2025', r'C:\\Windows\\Temp')", self.workflow)
        self.assertIn("PLATFORM_SELECTION: ${{ inputs.platform || 'macos' }}", self.workflow)

    def test_source_sha_is_exact_and_the_helper_receives_a_historical_release(self):
        self.assertIn('[[ "$SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]] ||', self.workflow)
        self.assertIn('ref: ${{ needs.resolve.outputs.sha }}', self.workflow)
        self.assertIn('test "$(git rev-parse HEAD)" = "$SOURCE_SHA"', self.workflow)
        self.assertIn('git rev-parse "v${RELEASE}^{commit}"', self.workflow)
        self.assertIn('mkdir -p "$ARTIFACT_DIR"', self.workflow)
        self.assertIn('git rev-parse HEAD > "$ARTIFACT_DIR/candidate-sha.txt"', self.workflow)
        self.assertIn('scripts/check_formed_release_upgrade.py --release "$RELEASE" --output "$EVIDENCE_DIR"', self.workflow)
        self.assertIn('scripts/check_formed_release_upgrade.py --release $env:RELEASE --output $env:EVIDENCE_DIR', self.workflow)
        self.assertIn('EVIDENCE_DIR: upgrade-evidence/${{ matrix.release }}-${{ matrix.platform }}/probe', self.workflow)
        self.assertIn('ARTIFACT_DIR: upgrade-evidence/${{ matrix.release }}-${{ matrix.platform }}', self.workflow)

    def test_fixture_temp_and_cargo_target_are_isolated_and_cached(self):
        self.assertIn('TOKENBAR_FIXTURE_TEMP_BASE: ${{ matrix.external_temp }}', self.workflow)
        self.assertIn("'macos': ('macos-26', '/tmp')", self.workflow)
        self.assertIn("r'C:\\Windows\\Temp'", self.workflow)
        self.assertIn('CARGO_TARGET_DIR: ${{ github.workspace }}/tauri-app/src-tauri/target', self.workflow)
        self.assertIn('tauri-app/src-tauri/target', self.workflow)
        self.assertIn('~/.cargo/registry', self.workflow)
        self.assertIn('~/.cargo/git', self.workflow)

    def test_actual_matrix_generator_covers_all_producers_and_rejects_unknown_input(self):
        generator = self.workflow.split("matrix=\"$(python3 - <<'PY'\n", 1)[1].split("\n          PY\n", 1)[0]
        generator = textwrap.dedent(generator)
        def run(release, platform):
            return subprocess.run([sys.executable, '-c', generator], env={
                'RELEASE_SELECTION': release, 'PLATFORM_SELECTION': platform,
            }, capture_output=True, text=True)
        matrix = run('all', 'all')
        self.assertEqual(matrix.returncode, 0, matrix.stderr)
        items = json.loads(matrix.stdout)['include']
        self.assertEqual({(item['release'], item['platform']) for item in items},
                         {(release, platform) for release in probe.RELEASES for platform in ('macos', 'windows')})
        self.assertEqual(len(items), 8)
        single = run('0.9.8', 'macos')
        self.assertEqual(json.loads(single.stdout)['include'], [
            {'release': '0.9.8', 'platform': 'macos', 'runner': 'macos-26', 'external_temp': '/tmp'}])
        self.assertNotEqual(run('0.9.12', 'macos').returncode, 0)
        self.assertNotEqual(run('0.9.8', 'linux').returncode, 0)

    def test_toolchain_evidence_does_not_create_the_probe_output_before_its_no_overwrite_gate(self):
        self.assertIn('tee "$ARTIFACT_DIR/native-toolchain.txt"', self.workflow)
        self.assertNotIn('tee "$EVIDENCE_DIR/', self.workflow)
        self.assertNotIn('mkdir -p "$EVIDENCE_DIR"', self.workflow)

    def test_workflow_has_no_publish_or_secret_surface_and_always_keeps_evidence(self):
        self.assertIn('persist-credentials: false', self.workflow)
        self.assertIn('if: always()', self.workflow)
        self.assertIn('actions/upload-artifact@', self.workflow)
        self.assertIn('path: ${{ env.ARTIFACT_DIR }}/', self.workflow)
        self.assertNotRegex(self.workflow, r'(?i)\b(?:secrets\.|signing|notariz|publish-release|release-upload)')
        self.assertIn('npm ci --registry=https://registry.npmjs.org', self.workflow)
        self.assertIn('npm run build', self.workflow)
        self.assertIn('rustup toolchain install 1.93.1 --profile minimal', self.workflow)


if __name__ == '__main__':
    unittest.main()
