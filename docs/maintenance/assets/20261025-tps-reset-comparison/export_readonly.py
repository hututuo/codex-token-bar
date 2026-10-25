import sqlite3,pathlib,datetime,json
out=pathlib.Path(__file__).resolve().parent;out.mkdir(parents=True,exist_ok=True)
root=pathlib.Path('/Users/huyiyang/Library/Application Support/CodexTokenBar');q=sqlite3.connect((root/'quota-history.sqlite').as_uri()+'?mode=ro',uri=True);q.row_factory=sqlite3.Row;s=sqlite3.connect((root/'body-speed-a39064e53a2f4a99dd0882b3.sqlite').as_uri()+'?mode=ro',uri=True)
tz=datetime.timezone(datetime.timedelta(hours=8));now=datetime.datetime.now(tz);end=int(now.timestamp())//300*300
def epoch(v):return datetime.datetime.fromisoformat(v).replace(tzinfo=tz).timestamp()
config=[('A','2026-10-22T20:00','2026-10-23T05:00',64620,64755),('B','2026-10-23T20:30','2026-10-24T08:30',66048,66049),('C','2026-10-25T10:00',None,67391,67392)]
windows=[]
for label,a,b,beforeid,afterid in config:
 pre=q.execute('select * from quota_snapshots where id=?',(beforeid,)).fetchone();post=q.execute('select * from quota_snapshots where id=?',(afterid,)).fetchone()
 ident=['identity_version','home_identity','stable_account_key','identity_plan_type','identity_limit_id']
 assert all(pre[k]==post[k] for k in ident)
 lo=int(epoch(a));hi=int(epoch(b)) if b else end;t=post['created_at']
 rr=s.execute("select bucket_start,model,output_tokens,duration_seconds,sample_count from speed_5m where bucket_start>=? and bucket_start<? order by bucket_start,model",(lo,hi)).fetchall()
 rows=[dict(t=t,model=m,tokens=n,seconds=d,n=k,tps=n/d) for t,m,n,d,k in rr if d>0 and m=='gpt-6.1-sol']
 samples=[dict(end=t,model=m,tokens=n,seconds=d,tps=n/d) for t,m,n,d in s.execute("select ended_at,model,output_tokens,duration_seconds from speed_sample_ids where ended_at>=? and ended_at<? and model='gpt-6.1-sol' and trend_eligible=1 order by ended_at",(lo,hi))]
 def stats(xs):return dict(samples=len(xs),tokens=sum(x['tokens'] for x in xs),seconds=sum(x['seconds'] for x in xs),tps=sum(x['tokens'] for x in xs)/sum(x['seconds'] for x in xs) if xs else None)
 p=[x for x in samples if x['end']<=t];r=[x for x in samples if x['end']-x['seconds']>=t];cross=[x for x in samples if x not in p and x not in r]
 marker=dict(observed_at=post['created_at'],previous_at=pre['created_at'],previous_used=pre['seven_day_used_percent'],used=post['seven_day_used_percent'],row_ids=[beforeid,afterid],source=post['source'],same_stable_identity=True,observed_gap_seconds=post['created_at']-pre['created_at'])
 w=dict(id=label,start=lo,end=hi,reset=marker,records=rows,samples=samples,stats=dict(before=stats(p),after=stats(r),crossing=stats(cross),bucket_count=len(rows),sample_count=len(samples),previous_sample_end=max((x['end'] for x in p),default=None),next_sample_start=min((x['end']-x['seconds'] for x in r),default=None)))
 assert len(samples)==sum(x['n'] for x in rows),(label,len(samples),sum(x['n'] for x in rows))
 windows.append(w)
 print(label,datetime.datetime.fromtimestamp(lo,tz),datetime.datetime.fromtimestamp(hi,tz),w['stats'])
cal=q.execute('select created_at,seven_day_used_percent,seven_day_resets_at from quota_snapshots where id=66050').fetchone()
d=dict(metadata=dict(snapshot_local=now.isoformat(),model='gpt-6.1-sol',speed_source='body-speed-a39064e53a2f4a99dd0882b3.sqlite : speed_5m + speed_sample_ids trend_eligible=1; mode=ro',quota_source='quota-history.sqlite : quota_snapshots; mode=ro',account_scope_note='quota identity matched per reset pair; body speed has no sample-level account attribution; temporal comparison only'),windows=windows,reset_schedule_correction=dict(row_id=66050,observed_at=cal[0],used_percent=cal[1],new_scheduled_reset_at=cal[2],is_actual_reset=False))
(out/'data.json').write_text(json.dumps(d,ensure_ascii=False,indent=2))
