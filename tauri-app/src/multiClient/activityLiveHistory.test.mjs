import test from 'node:test';
import assert from 'node:assert/strict';
import {ActivityLiveHistory,activityLivePaths,liveChartCeiling,MAX_ACTIVITY_LIVE_POINTS} from './activityLiveHistory.ts';
const rates=(client='codex',outputTps=40)=>[{client,model:'gpt-6.1-sol',outputTps}];
test('memory plot admits a client only after its first positive finite speed and retains real idle zeros',()=>{
 const h=new ActivityLiveHistory();h.selectSource('local');
 h.record(100,{codex:true,claudeCode:true},[]);
 h.record(101,{codex:true,claudeCode:true},rates('claudeCode',NaN));
 assert.deepEqual(h.snapshot(101,['codex','claudeCode']),[]);
 h.record(102,{codex:true,claudeCode:true},rates());
 h.record(104,{codex:true,claudeCode:true},[]);
 assert.deepEqual(h.snapshot(104,['codex','claudeCode']).map(r=>[r.client,r.points.map(p=>p.rate)]),[['codex',[40,0]]]);
 h.record(106,{codex:true,claudeCode:true},rates('claudeCode',80));
 assert.deepEqual(h.snapshot(106,['codex','claudeCode']).map(r=>r.client),['claudeCode','codex']);
});
test('three-minute memory stays bounded, rejects duplicate polls and resets on source changes',()=>{
 const h=new ActivityLiveHistory();h.selectSource('first');
 for(let time=0;time<10000;time+=.25)h.record(time,{codex:true},rates());
 const rows=h.snapshot(10000,['codex']);
 assert.ok(rows[0].points.length<=MAX_ACTIVITY_LIVE_POINTS);assert.ok(rows[0].points.every(p=>p.time>=9820));
 const count=rows[0].points.length;h.record(9999,{codex:true},rates());assert.equal(h.snapshot(10000,['codex'])[0].points.length,count);
 assert.deepEqual(h.snapshot(11000,['codex']),[]);assert.deepEqual(h.snapshot(10000,['claudeCode']),[]);
 h.selectSource('second');assert.deepEqual(h.snapshot(10000,['codex']),[]);
});
test('unreadable sources do not create fake zero samples and missing polls split the smooth path',()=>{
 const h=new ActivityLiveHistory();h.record(100,{codex:true},rates());h.record(102,{codex:false},[]);h.record(120,{codex:true},rates());
 assert.deepEqual(h.snapshot(120,['codex'])[0].points.map(p=>p.time),[100,120]);
 const paths=activityLivePaths([{time:100,value:40},{time:102,value:42},{time:120,value:41}],t=>t,v=>100-v,100);
 assert.equal(paths.length,2);assert.match(paths[0].line,/ C/);assert.doesNotMatch(paths[1].line,/ C/);
 assert.equal(liveChartCeiling(50),60);
});

test('sub-second original receipts stay distinct; curve endpoints and extrema remain unchanged',()=>{
 const history=new ActivityLiveHistory();history.record(100,{codex:true},rates('codex',10));history.record(100.5,{codex:true},rates('codex',20));
 assert.deepEqual(history.snapshot(101,['codex'])[0].points.map(p=>p.rate),[10,20]);
 const original=[{time:0,value:5},{time:1,value:60},{time:2,value:10},{time:2.5,value:30},{time:3,value:30}];
 const [{line}]=activityLivePaths(original,t=>t,v=>80-v,80);
 const parts=line.slice(1).split(' C');
 assert.deepEqual(parts[0].split(',').map(Number),[0,75]);
 for(let i=0;i<parts.length-1;i++){
  const c=parts[i+1].split(/[ ,]+/).map(Number),a=original[i],b=original[i+1];
  assert.deepEqual(c.slice(-2),[b.time,80-b.value]);
  for(const value of [c[1],c[3]])assert.ok(value>=Math.min(80-a.value,80-b.value)&&value<=Math.max(80-a.value,80-b.value));
 }
});
