#!/usr/bin/env python3
"""Windows filesystem diagnosis using extracted production path functions.

Leaves identity as its UTF-8 input instead of hashing so differences are
readable. This is not the Container/ledger test; native tests run separately.
Only disposable paths are created, and no user store is opened.
"""
from pathlib import Path
import argparse
import os
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[2]

def generated_probe():
    route = (REPO / 'tauri-app/src-tauri/src/core/business_store_route.rs').read_text(encoding='utf-8')
    compat = (REPO / 'tauri-app/src-tauri/src/core/business_store_route/path_identity.rs').read_text(encoding='utf-8')
    start = route.index('pub(crate) fn source_identity(')
    end = route.index('    let mut digest = Sha256::new();', start)
    legacy = route[start:end].replace('pub(crate) fn source_identity(', 'fn source_identity(', 1)
    legacy += '    Ok(text.to_owned())\n}\n'
    fixture = (REPO / 'tauri-app/src-tauri/src/business_store_fixture.rs').read_text(encoding='utf-8')
    a = fixture.index('fn stage_path(')
    b = fixture.index('fn write_session(', a)
    stage = fixture[a:b].replace('fn stage_path(', 'fn fixture_stage_path(', 1)
    # The probe diagnoses path construction, not SHA-256. Preserve the actual
    # construction code and use a deterministic valid hex digest as input.
    a = stage.index('    let hash = Sha256::digest(')
    b = stage.index('        .collect::<String>();', a) + len('        .collect::<String>();')
    stage = stage[:a] + '    let hash = "a".repeat(64);' + stage[b:]
    chunks = []
    for first, following in [('fn stable_path(', 'fn text('), ('fn text(', 'fn add_spellings('),
                             ('fn add_spellings(', 'fn identities('), ('fn identities(', 'pub(super) fn candidate_parts(')]:
        a = compat.index(first)
        b = compat.index(following, a + len(first))
        chunks.append(compat[a:b].replace('fn identities(', 'pub fn identities(', 1))
    return 'use std::path::{Path,PathBuf};\n' + legacy + stage + '''
mod compat {
use std::path::{Path,PathBuf};
use std::collections::BTreeSet;
use std::ffi::OsString;
fn identity(value: &str) -> String { value.to_owned() }
''' + ''.join(chunks) + '''}
fn main() {
 let stamp=std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
 let root=std::env::temp_dir().join(format!("tokenbar-path-input-probe-{}-{stamp}",std::process::id()));
 assert!(!root.exists());
 let base=root.join("physical"); std::fs::create_dir_all(&base).unwrap();
 let path=base.join("missing/cache/index.sqlite3.staging").join("fixture.sqlite3");
 let legacy=source_identity("exact",&path).unwrap();
 std::fs::create_dir_all(path.parent().unwrap()).unwrap();
 let canonical=std::fs::canonicalize(path.parent().unwrap()).unwrap().join(path.file_name().unwrap());
 let (preferred,aliases)=compat::identities(&canonical).unwrap();
 let matched=aliases.contains(&legacy);
 println!("SOURCE_EXTRACTED_PATH_INPUT_PROBE matched={matched} aliases={}",aliases.len());
 println!("legacy-input={legacy:?} preferred-input={preferred:?} temp-root={:?}",std::env::temp_dir());
 if !matched { for value in aliases { println!("candidate-input={value:?}"); } }
 let extended=std::fs::canonicalize(&root).unwrap();
 let mut extended_ok=true;
 for relative in ["missing/cache/index.sqlite3", "not-created/index.sqlite3.staging/fixture.sqlite3", "runtime-home/.cache/exact-token-index.sqlite3"] {
   let requested=extended.join(relative);
   let result=compat::identities(&requested);
   println!("VERBATIM_MISSING_PATH requested={requested:?} accepted={} result={result:?}",result.is_ok());
   extended_ok &= result.is_ok();
 }
 let fixture_stage=fixture_stage_path(&extended.join("index.sqlite3"),&path).unwrap();
 let fixture_result=compat::identities(&fixture_stage);
 println!("FIXTURE_STAGE_PATH requested={fixture_stage:?} accepted={}",fixture_result.is_ok());
 extended_ok &= fixture_result.is_ok();
 std::fs::remove_dir_all(&root).unwrap();
 if !matched || !extended_ok {std::process::exit(1)}
}
'''

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--emit-only',type=Path)
    args=parser.parse_args()
    source=generated_probe()
    if args.emit_only:
        args.emit_only.write_text(source, encoding='utf-8')
        return
    if os.name != 'nt':
        raise SystemExit('This diagnoses Windows spelling; use --emit-only elsewhere.')
    with tempfile.TemporaryDirectory(prefix='tokenbar-path-compiler-') as directory:
        folder=Path(directory)
        rust=folder/'probe.rs'; rust.write_text(source, encoding='utf-8')
        executable=folder/'probe.exe'
        subprocess.run(['rustc','--edition','2021',str(rust),'-o',str(executable)],check=True)
        subprocess.run([str(executable)],check=True)

if __name__ == '__main__':
    main()
