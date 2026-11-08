import assert from 'node:assert/strict';
import test from 'node:test';
import cases from '../../../Sources/CodexTokenBar/Resources/model-presentation-cases.json' with {type:'json'};
import {modelPresentationIdentity,modelPresentationDetail} from './modelPresentationIdentity.ts';
test('model presentation uses the shared Swift Rust frontend contract',()=>{
 assert.ok(cases.length>30);
 for(const row of cases)assert.deepEqual(modelPresentationIdentity(row.raw),row.expected,row.raw);
 assert.equal(modelPresentationDetail('bad\u202emodel'),'异常标识已隐藏；原始账目保留');
});
