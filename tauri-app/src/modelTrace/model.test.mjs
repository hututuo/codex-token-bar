import test from 'node:test';
import assert from 'node:assert/strict';
import {topCandidates, summarize, dayPresentation, percent, activePlan} from './model.ts';
import {sidebarReducer, initialSidebarState, isSidebarAction} from '../quota-sidebar/model.ts';

test('top 3 and 5 retain full-bank probabilities and do not mutate the input', () => {
  const candidates = Array.from({length:17}, (_,i) => ({model:`model-${i}`, probability:(i+1)/153}));
  const before = structuredClone(candidates);
  assert.equal(topCandidates(candidates,3).length,3);
  assert.equal(topCandidates(candidates,5).length,5);
  assert.equal(topCandidates(candidates,3)[0].probability,17/153);
  assert.deepEqual(candidates,before);
  assert.equal(percent(0.00001),'<0.01%');
  assert.equal(percent(NaN),'—');
});
test('calendar excludes failed, cancelled and missing rounds from its denominator', () => {
  const runs=['candidate_matches','candidate_matches','candidate_differs','sampling_failed','cancelled','missed'].map(status=>({status}));
  const summary=summarize(runs);
  assert.equal(summary.ratio,'2/3 = 66.7%');
  assert.equal(summary.other,3);
  assert.equal(summary.state,'mixed');
  assert.match(dayPresentation(runs).background,/linear-gradient/);
  assert.equal(dayPresentation(runs).className,'modeltrace-day-warning');
  assert.equal(summarize([]).state,'empty');
  assert.equal(summarize([{status:'interrupted'}]).state,'other');
  assert.equal(summarize([{status:'interrupted'}]).ratio,'暂无可判定记录');
});
test('sidebar opens model detection and all active phases prevent another plan', () => {
  const action={type:'open',tab:'modelTrace',section:'top'};
  assert.ok(isSidebarAction(action));
  assert.equal(sidebarReducer(initialSidebarState,action).tab,'modelTrace');
  assert.equal(sidebarReducer(initialSidebarState,action).mode,'detail');
  for(const status of ['waiting','running','cancelling']) assert.ok(activePlan({status}));
  for(const status of ['completed','cancelled','failed']) assert.ok(!activePlan({status}));
});
