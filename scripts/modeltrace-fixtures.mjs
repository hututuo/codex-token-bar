// Regenerate with the pinned ModelTrace checkout; no model calls or private samples.
// node scripts/modeltrace-fixtures.mjs /path/to/ModelTrace
import {readFile,writeFile} from 'node:fs/promises';
import {resolve} from 'node:path';
import {fileURLToPath,pathToFileURL} from 'node:url';
import {execFileSync} from 'node:child_process';
import assert from 'node:assert/strict';
const upstream=resolve(process.argv[2] ?? '');
assert.ok(process.argv[2], 'Pass a ModelTrace checkout path');
assert.equal(execFileSync('git',['rev-parse','HEAD'],{cwd:upstream,encoding:'utf8'}).trim(),'d4131b30243dfa05e70180b5eedde742103f1d73');
const base=fileURLToPath(new URL('../tauri-app/src-tauri/resources/modeltrace/',import.meta.url));
const bank=JSON.parse(await readFile(resolve(base,'unified_bank.json'),'utf8'));
const {analyzeGlobalOutputs}=await import(pathToFileURL(resolve(upstream,'static/fingerprint-core.js')));
const cases=[
 {name:'uniform-cycle',outputs:[0,1,2].map(k=>Array.from({length:300+k},(_,i)=>1+(i*31+k*17)%355))},
 {name:'ordered-blocks',outputs:[0,1,2].map(k=>Array.from({length:307+k*7},(_,i)=>1+(i<90?i%17:(i*13+k*91)%355)))},
 {name:'concentrated',outputs:[0,1,2].map(k=>Array.from({length:292+k},(_,i)=>[7,42,111,233,355][(i+k)%5]))},
 {name:'single-valued',outputs:[0,1,2].map(()=>Array(300).fill(42))}
];
for(const c of cases)c.results=analyzeGlobalOutputs(c.outputs.map(numbers=>({text:JSON.stringify(numbers),expected_count:numbers.length})),bank).results.map(({model,probability,profile_similarity,score})=>({model,probability,profile_similarity,score}));
await writeFile(resolve(base,'scoring-fixtures.json'),JSON.stringify(cases,null,2)+'\n');
console.log('Wrote four synthetic scoring fixtures.');
