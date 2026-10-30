import test from 'node:test';
import assert from 'node:assert/strict';
import {withSsrModules} from '../../test/ssrHarness.mjs';

test('fixed time bounds survive rolling refresh, backwards selection and exact provider alignment',async()=>withSsrModules(async load=>{
 const {EMPTY_QUOTA_SELECTION:empty,clickQuotaSelectionAnchor:click,quotaSelectionIndices:indices}=await load('/src/components/recentUsageChart/selectionAnchors.ts');
 const axis=(times,bucketSeconds=300)=>({bucketSeconds,points:times.map(startUnix=>({startUnix}))});
 const first=axis([0,300,600,900]);
 const selected=click(click(empty,1,first),2,first);
 assert.deepEqual(selected,{startUnix:300,fixedEndUnix:600,bucketSeconds:300});
 assert.deepEqual(indices(selected,axis([300,600,900,1200])),{startIndex:0,fixedEndIndex:1},'Same array length must not silently move the selected dates');
 assert.deepEqual(indices(selected,axis([-300,0,300,600,900])),{startIndex:2,fixedEndIndex:3},'Provider positions must map by dates, not offsets');
 const backwards=click(click(empty,2,first),1,first);
 assert.deepEqual(indices(backwards,axis([300,600,900,1200])),{startIndex:1,fixedEndIndex:0});
 assert.deepEqual(indices(selected,axis([600,900,1200,1500])),{startIndex:null,fixedEndIndex:null},'An expired bound must never clamp to an unrelated bucket');
 assert.deepEqual(indices(selected,axis([0,3600,7200],3600)),{startIndex:null,fixedEndIndex:null},'A changed bucket width requires a new selection');
 assert.deepEqual(click(selected,9,first),selected);
 assert.deepEqual(click(selected,3,first),{startUnix:900,fixedEndUnix:null,bucketSeconds:300});
}));
