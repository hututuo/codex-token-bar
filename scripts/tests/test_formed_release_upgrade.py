import importlib.util
import json
from pathlib import Path
import shutil
import sqlite3
import sys
import tempfile
import unittest
from unittest.mock import patch

scripts = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(scripts))
import check_formed_release_upgrade as probe

class FormedEvidenceTests(unittest.TestCase):
    FAKE_REOPEN_CANDIDATE = '''import json, os, sqlite3, sys
mode, call_log, root, phase = sys.argv[1:]
from pathlib import Path
root = Path(root)
with open(call_log, "a", encoding="utf-8") as output:
    output.write(str(os.getpid()) + "\\n")
calls = len(Path(call_log).read_text(encoding="utf-8").splitlines())
(root / "support/codex-ledger-snapshots/existing.sqlite-wal").write_text(str(calls), encoding="utf-8")
if mode == "backup" and calls == 2:
    (root / "support/codex-ledger-snapshots/new-attempt.sqlite").write_text("new backup", encoding="utf-8")
if mode == "attempt" and calls == 2:
    connection = sqlite3.connect(root / "support/codex-ledger.sqlite")
    connection.execute("INSERT INTO tb_container_meta VALUES (?, ?)", ("migration_pending_store_v1:synthetic-attempt", "new"))
    connection.commit()
    connection.close()
report = {"status":"PASS", "phase":phase, "producerVersion":"0.9.8", "scenario":root.name,
    "cfgTest":False, "totals":[162,310], "oldTypedProofsPreserved":True,
    "crashWALPreserved":True, "rawDisappearanceRetainsHistory":True,
    "oldBPreserved":root.name == "committed"}
print("TOKENBAR_FORMED_REPORT " + json.dumps(report, separators=(",", ":")))
'''

    def disposable_recovery_root(self, parent, scenario):
        root = parent / scenario
        root.mkdir()
        (root / '.formed-release-fixture').write_text('synthetic-only-v1\n', encoding='utf-8')
        support = root / 'support'; support.mkdir()
        database = support / 'codex-ledger.sqlite'
        connection = sqlite3.connect(database)
        connection.executescript('''
            CREATE TABLE tb_container_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE tb_legacy_inputs(source_path TEXT PRIMARY KEY, logical_path TEXT, store_id TEXT,
                module TEXT, source_digest TEXT, backup_path TEXT, retired INTEGER);
            CREATE TABLE tb_store_imports(store_id TEXT, source_digest TEXT, schema_digest TEXT,
                row_count INTEGER, rows_digest TEXT, backup_path TEXT, imported_at REAL);
            CREATE TABLE tb_stores(store_id TEXT PRIMARY KEY, module TEXT, source_identity TEXT,
                logical_path TEXT, state TEXT, user_version INTEGER);
            INSERT INTO tb_container_meta VALUES ('migration_snapshot_history_v1:store:old', 'frozen-proof');
            INSERT INTO tb_container_meta VALUES ('legacy_exact_migration_v1:store', 'preserved-proof');
            INSERT INTO tb_legacy_inputs VALUES ('synthetic-source.sqlite', 'exact/synthetic', 'store', 'exact', 'digest', 'backup.sqlite', 0);
            INSERT INTO tb_store_imports VALUES ('store', 'digest', 'schema', 1, 'rows', 'backup.sqlite', 1.0);
            INSERT INTO tb_stores VALUES ('store', 'exact', 'identity', 'exact/synthetic', 'ready', 1);
        ''')
        connection.commit(); connection.close()

        route_backups = support / 'codex-ledger-snapshots'
        route_backups.mkdir()
        (route_backups / 'existing.sqlite').write_text('frozen route snapshot', encoding='utf-8')
        (route_backups / 'existing.sqlite-wal').write_text('volatile sidecar', encoding='utf-8')

        pool_backup = support / 'ledger-migration-backups/structural-stage-pool-rust-v1/image'
        pool_backup.mkdir(parents=True)
        (pool_backup / 'snapshot.sqlite').write_text('pre-pool snapshot', encoding='utf-8')
        (pool_backup.parent / 'receipt.json').write_text('{"format":1}', encoding='utf-8')

        schema11 = support / 'exact-token-index'
        schema11.mkdir()
        (schema11 / 'index.sqlite3.schema11-candidate').write_text('candidate', encoding='utf-8')
        (schema11 / 'index.sqlite3.schema11-rollback').write_text('rollback', encoding='utf-8')
        (schema11 / 'index.sqlite3.schema11-migration.json').write_text('{"phase":"retained"}', encoding='utf-8')
        return root

    def report(self, **changes):
        value = dict(status='PASS', phase='resume', producerVersion='0.9.8', scenario='committed',
            cfgTest=False, totals=[162, 310], oldTypedProofsPreserved=True, crashWALPreserved=True,
            rawDisappearanceRetainsHistory=True, oldBPreserved=True)
        value.update(changes)
        return probe.PREFIX + json.dumps(value)

    def test_proof_requires_actual_release_and_every_preservation_property(self):
        self.assertEqual(probe.parse_report(self.report(), 'resume', '0.9.8', 'committed')['totals'], [162,310])
        for field, value in [('cfgTest', True), ('totals', [155,310]), ('producerVersion','0.9.7'),
                             ('oldTypedProofsPreserved',False), ('oldBPreserved',False),
                             ('crashWALPreserved',False), ('rawDisappearanceRetainsHistory',False)]:
            with self.subTest(field=field), self.assertRaises(ValueError):
                probe.parse_report(self.report(**{field:value}), 'resume', '0.9.8', 'committed')

    def test_numeric_boolean_substitutes_and_malformed_proofs_cannot_pass(self):
        for field, value in [('cfgTest', 0), ('oldTypedProofsPreserved', 1),
                             ('crashWALPreserved', 1), ('oldBPreserved', 1),
                             ('rawDisappearanceRetainsHistory', 1), ('totals', [162.0, 310])]:
            with self.subTest(field=field), self.assertRaises(ValueError):
                probe.parse_report(self.report(**{field: value}), 'resume', '0.9.8', 'committed')
        for payload in ('null', '[]', 'true'):
            with self.subTest(payload=payload), self.assertRaises(ValueError):
                probe.parse_report(probe.PREFIX + payload, 'resume', '0.9.8', 'committed')

    def test_no_duplicate_or_absent_proof_can_pass(self):
        for text in ('', self.report()+'\n'+self.report()):
            with self.assertRaises(ValueError):
                probe.parse_report(text, 'resume', '0.9.8', 'committed')

    def test_wrong_tag_cannot_silently_test_another_release(self):
        with patch.object(probe.subprocess, 'check_output', return_value='0'*40+'\n'):
            with self.assertRaises(ValueError): probe.pinned_revision(Path('.'), '0.9.8')

    def test_archive_refuses_existing_destination(self):
        with tempfile.TemporaryDirectory() as root:
            with self.assertRaises(ValueError): probe.inject(Path('.'), '0'*40, Path(root))

    def test_injection_is_additive_and_production_paths_are_explicit(self):
        self.assertEqual(len(probe.OVERRIDES), 5)
        source=(scripts/'fixtures/formed_release_probe.rs').read_text()
        self.assertIn('route::bootstrap()',source)
        self.assertIn('std::process::exit(86)',source)
        self.assertIn('Container::snapshot_digest_path',source)
        self.assertIn('actual.schema_digest,actual.rows_digest',source)
        self.assertIn('fs::canonicalize',source)
        self.assertNotIn('std::env::set_var',source)
        self.assertNotIn('#[cfg(test)]',source)
        self.assertEqual(set(probe.INJECTION),{'tauri-app/src-tauri/src/lib.rs','tauri-app/src-tauri/Cargo.toml',
            'tauri-app/src-tauri/src/formed_release_probe.rs','tauri-app/src-tauri/examples/formed-release-probe.rs'})

    def test_execution_cannot_ignore_exit_status(self):
        with tempfile.TemporaryDirectory() as root:
            log=Path(root)/'log'
            with self.assertRaises(RuntimeError):
                probe.execute([sys.executable,'-c','raise SystemExit(3)'],Path(root),{},log)
            self.assertTrue(log.is_file())

    def test_consecutive_temp_sources_do_not_reuse_old_permission_paths(self):
        with tempfile.TemporaryDirectory() as root:
            repository = Path(root) / 'repo'; repository.mkdir()
            target = repository / 'tauri-app/src-tauri/target'
            plugin_stale = target / 'debug/build/tauri-plugin-updater-stale/build-script-output.txt'
            plugin_stale.parent.mkdir(parents=True)
            stale_path = r'C:\Windows\Temp\previous-source\vendor\tauri-plugin-updater\permissions\autogenerated\commands\check.toml'
            plugin_stale.write_text(stale_path, encoding='utf-8')
            main_stale = target / 'debug/build/codex-token-bar-stale/build-script-build'
            main_stale.parent.mkdir(parents=True)
            main_stale.write_text('previous main build script', encoding='utf-8')
            wry_stale = target / 'debug/build/wry-stale/build-script-output.txt'
            wry_stale.parent.mkdir(parents=True)
            wry_stale.write_text('previous local path dependency output', encoding='utf-8')
            dependency_output = target / 'debug/build/tauri-build-dependency/output'
            dependency_output.parent.mkdir(parents=True)
            dependency_output.write_text('downloaded dependency output', encoding='utf-8')

            sources = [Path(root) / name for name in ('source-one', 'source-two')]
            for source in sources:
                manifest = source / 'tauri-app/src-tauri/Cargo.toml'
                manifest.parent.mkdir(parents=True)
                manifest.write_text(
                    '[package]\nname = "codex-token-bar"\n\n'
                    '[patch.crates-io]\n'
                    'tauri-plugin-updater = { path = "vendor/tauri-plugin-updater" }\n'
                    'wry = { path = "vendor/wry" }\n', encoding='utf-8')
                for path, package in (('vendor/tauri-plugin-updater', 'tauri-plugin-updater'),
                    ('vendor/wry', 'wry')):
                    crate_manifest = source / 'tauri-app/src-tauri' / path / 'Cargo.toml'
                    crate_manifest.parent.mkdir(parents=True)
                    crate_manifest.write_text(f'[package]\nname = "{package}"\n', encoding='utf-8')
            env = {'CARGO_TARGET_DIR': str(target)}
            calls = []
            cleaned_packages = []

            def fake_execute(command, cwd, child_env, log, expected=0, timeout=1800):
                calls.append(command)
                log.write_text('simulated cargo output\n', encoding='utf-8')
                if command[1] == 'clean':
                    package = command[command.index('--package') + 1]
                    cleaned_packages.append(package)
                    self.assertEqual(Path(command[command.index('--target-dir') + 1]), target.resolve())
                    for directory in (target / 'debug/build', target / 'debug/.fingerprint'):
                        for entry in directory.glob(package + '-*') if directory.exists() else ():
                            if entry.is_dir():
                                shutil.rmtree(entry)
                            else:
                                entry.unlink()
                elif command[1] == 'build':
                    build_root = target / 'debug/build'
                    existing_plugin_outputs = list(build_root.glob(
                        'tauri-plugin-updater-*/build-script-output.txt')) if build_root.exists() else []
                    if not existing_plugin_outputs:
                        manifest = Path(command[command.index('--manifest-path') + 1])
                        permission_path = manifest.parent / 'vendor/tauri-plugin-updater/permissions/autogenerated/commands/check.toml'
                        output = build_root / 'tauri-plugin-updater-current/build-script-output.txt'
                        output.parent.mkdir(parents=True, exist_ok=True)
                        output.write_text(str(permission_path), encoding='utf-8')
                else:
                    self.fail(f'unexpected cargo command: {command}')
                return 'simulated cargo output'

            with patch.object(probe, 'execute', side_effect=fake_execute):
                for index, source in enumerate(sources):
                    probe.build_probe(repository, source, env, Path(root) / f'build-{index}.log')
                    cached_output = target / 'debug/build/tauri-plugin-updater-current/build-script-output.txt'
                    current_permission = source / 'tauri-app/src-tauri/vendor/tauri-plugin-updater/permissions/autogenerated/commands/check.toml'
                    self.assertEqual(cached_output.read_text(encoding='utf-8'), str(current_permission))
                    self.assertNotIn(str(sources[1-index]), cached_output.read_text(encoding='utf-8'))
                    self.assertTrue(dependency_output.is_file())
                    self.assertFalse(plugin_stale.exists())
                    self.assertFalse(main_stale.exists())
                    self.assertFalse(wry_stale.exists())

            expected_packages = [probe.PROBE_PACKAGE, 'tauri-plugin-updater', 'wry']
            self.assertEqual(cleaned_packages, expected_packages * 2)
            self.assertEqual([call[1] for call in calls], ['clean', 'clean', 'clean', 'build'] * 2)
            expected_manifests = [str(source / 'tauri-app/src-tauri/Cargo.toml') for source in sources]
            self.assertEqual([call[call.index('--manifest-path') + 1] for call in calls],
                [expected_manifests[0]] * 4 + [expected_manifests[1]] * 4)

    def test_local_patch_package_paths_must_stay_readable_and_inside_archive(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            source = root / 'source'; source.mkdir()
            outside = root / 'outside'; outside.mkdir()
            (outside / 'Cargo.toml').write_text('[package]\nname = "escaped"\n', encoding='utf-8')
            manifest = source / 'tauri-app/src-tauri/Cargo.toml'
            manifest.parent.mkdir(parents=True)
            manifest.write_text('[package]\nname = "codex-token-bar"\n\n'
                '[patch.crates-io]\nescaped = { path = "../../../outside" }\n', encoding='utf-8')
            with self.assertRaises(ValueError):
                probe.local_patch_packages(source, manifest)

            manifest.write_text('[package]\nname = "codex-token-bar"\n\n'
                '[patch.crates-io]\nmissing = { path = "vendor/missing" }\n', encoding='utf-8')
            with self.assertRaises(ValueError):
                probe.local_patch_packages(source, manifest)

    def test_three_independent_reopens_preserve_owned_materials_for_both_scenarios(self):
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary).resolve()
            script = parent / 'candidate.py'
            script.write_text(self.FAKE_REOPEN_CANDIDATE, encoding='utf-8')
            logs = parent / 'logs'; logs.mkdir()
            repository = Path(__file__).resolve().parents[2]
            env = probe.probe_environment(parent)
            for scenario in ('committed', 'interrupted'):
                with self.subTest(scenario=scenario):
                    root = self.disposable_recovery_root(parent, scenario)
                    call_log = parent / f'{scenario}-pids.txt'
                    proofs, evidence = probe.run_candidate_reopens(
                        [sys.executable, str(script), 'stable', str(call_log)], repository, root, parent,
                        env, logs, '0.9.8', scenario)
                    self.assertEqual([proof['reopenOrdinal'] for proof in proofs], [1, 2, 3])
                    self.assertTrue(all(proof['recoveryMaterialsRetained'] for proof in proofs))
                    self.assertFalse(evidence['mtimeCompared'])
                    self.assertEqual(len(evidence['passes']), 3)
                    self.assertTrue(all(passed['independentCandidateProcess'] for passed in evidence['passes']))
                    manifest_paths = {entry['path'] for entry in evidence['baselineAfterResume']['files']}
                    self.assertIn('support/codex-ledger-snapshots/existing.sqlite', manifest_paths)
                    self.assertIn('support/ledger-migration-backups/structural-stage-pool-rust-v1/receipt.json', manifest_paths)
                    self.assertIn('support/exact-token-index/index.sqlite3.schema11-candidate', manifest_paths)
                    self.assertFalse(any(path.endswith('-wal') for path in manifest_paths))
                    pids = call_log.read_text(encoding='utf-8').splitlines()
                    self.assertEqual(len(pids), 3)
                    self.assertEqual(len(set(pids)), 3)

    def test_new_backup_or_migration_attempt_fails_reopen_gate(self):
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary).resolve()
            script = parent / 'candidate.py'
            script.write_text(self.FAKE_REOPEN_CANDIDATE, encoding='utf-8')
            logs = parent / 'logs'; logs.mkdir()
            repository = Path(__file__).resolve().parents[2]
            env = probe.probe_environment(parent)
            for mode in ('backup', 'attempt'):
                with self.subTest(mode=mode):
                    scenario_parent = parent / mode
                    scenario_parent.mkdir()
                    root = self.disposable_recovery_root(scenario_parent, 'committed')
                    call_log = parent / f'{mode}-pids.txt'
                    with self.assertRaisesRegex(ValueError, 'Independent reopen 2 changed recovery materials'):
                        probe.run_candidate_reopens(
                            [sys.executable, str(script), mode, str(call_log)], repository, root, scenario_parent,
                            env, logs, '0.9.8', 'committed')
                    self.assertEqual(len(call_log.read_text(encoding='utf-8').splitlines()), 2)

    def test_runner_temp_in_home_falls_back_without_weakening_native_isolation(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root).resolve()
            home = root / "home"; home.mkdir()
            runner = home / "work-temp"; runner.mkdir()
            external = root / "os-temp"; external.mkdir()
            self.assertEqual(probe.external_temporary_base([runner, external], home), external)
            for candidate in (home, runner, root, root / "missing"):
                with self.subTest(path=candidate), self.assertRaises(ValueError):
                    probe.external_temporary_base([candidate], home)
            environment = probe.probe_environment(external)
            self.assertTrue(all(environment[key] == str(external) for key in ("TMPDIR", "TMP", "TEMP")))

    @unittest.skipIf(sys.platform == "win32", "unprivileged Windows symlink creation not required")
    def test_temp_symlink_cannot_disguise_a_real_home(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root).resolve(); home = root / "home"; home.mkdir()
            alias = root / "not-home"; alias.symlink_to(home, target_is_directory=True)
            with self.assertRaises(ValueError): probe.external_temporary_base([alias], home)
