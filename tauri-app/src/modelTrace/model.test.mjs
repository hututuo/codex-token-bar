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
  assert.equal(summarize([]).state,'empty');
  assert.equal(summarize([{status:'interrupted'}]).state,'other');
  assert.equal(summarize([{status:'interrupted'}]).ratio,'暂无可判定记录');
});
test('calendar colors show each present result category equally, including other results', () => {
  const statuses=['candidate_matches','candidate_differs','sampling_failed'];
  const colors=['var(--green)','var(--orange)','var(--muted)'];
  for(let mask=0;mask<8;mask++) {
    const runs=statuses.filter((_,i)=>mask&(1<<i)).map(status=>({status}));
    const present=colors.filter((_,i)=>mask&(1<<i));
    const view=dayPresentation(runs);
    for(const color of colors) assert.equal(view.background.includes(color),present.includes(color));
    assert.equal(view.background.includes('linear-gradient'),present.length>1);
    if(present.length<=1) assert.equal(view.background,present[0]??'var(--heatmap-empty)');
    // Repeated rounds do not hide a less frequent category in a tiny date cell.
    assert.equal(dayPresentation([...runs,...runs.slice(0,1)]).background,view.background);
  }
  for(const status of ['sampling_failed','cancelled','interrupted','missed','reference_missing','inconclusive']) {
    assert.equal(dayPresentation([{status:'candidate_matches'},{status}]).background,'linear-gradient(135deg,var(--green) 0% 50%,var(--muted) 50% 100%)');
  }
});
test('sidebar opens model detection and all active phases prevent another plan', () => {
  const action={type:'open',tab:'modelTrace',section:'top'};
  assert.ok(isSidebarAction(action));
  assert.equal(sidebarReducer(initialSidebarState,action).tab,'modelTrace');
  assert.equal(sidebarReducer(initialSidebarState,action).mode,'detail');
  for(const status of ['waiting','running','cancelling']) assert.ok(activePlan({status}));
  for(const status of ['completed','cancelled','failed']) assert.ok(!activePlan({status}));
});
