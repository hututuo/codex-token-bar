from pathlib import Path
import json,math,datetime
import numpy as np
from PIL import Image,ImageDraw,ImageFont
OUT=Path(__file__).resolve().parent
D=json.loads((OUT/'data.json').read_text());S=1.5;W=3000;H=2700
im=Image.new('RGB',(int(W*S),int(H*S)),'#0f141c');dr=ImageDraw.Draw(im)
FONT='/System/Library/Fonts/Supplemental/Arial Unicode.ttf';BOLD='/System/Library/Fonts/STHeiti Medium.ttc'
FG='#f0f5fc';MUTED='#a7b4c7';ORANGE='#f48650';BLUE='#78c8ff';GRID='#293340';CARD='#171f2b';BAND='#4e3b35';ZONE='#1c3041'
def font(n,b=False):return ImageFont.truetype(BOLD if b else FONT,int(n*S))
def text(x,y,t,n=24,c=FG,b=False,anchor=None):dr.text((int(x*S),int(y*S)),str(t),font=font(n,b),fill=c,anchor=anchor)
def rect(v,c,r=0):
 v=[int(x*S) for x in v]
 if r:dr.rounded_rectangle(v,int(r*S),fill=c)
 else:dr.rectangle(v,fill=c)
def line(p,c,w=2):dr.line([(int(x*S),int(y*S)) for x,y in p],fill=c,width=max(1,int(w*S)),joint='curve')
def dot(x,y,r,c):dr.ellipse([int((x-r)*S),int((y-r)*S),int((x+r)*S),int((y+r)*S)],fill=c)
def wrap(t,x,y,w,n=23,c=MUTED,lh=34):
 cur=''; yy=y
 for ch in t:
  if ch=='\n' or dr.textlength(cur+ch,font=font(n))>w*S:
   text(x,yy,cur,n,c);cur='' if ch=='\n' else ch;yy+=lh
  else:cur+=ch
 if cur:text(x,yy,cur,n,c)
 return yy+lh
TZ=datetime.timezone(datetime.timedelta(hours=8))
def tm(t,date=False,secs=False):return datetime.datetime.fromtimestamp(t,TZ).strftime('%m/%d %H:%M:%S' if date and secs else '%m/%d %H:%M' if date else '%H:%M:%S' if secs else '%H:%M')
def wt(rr):return sum(r['tokens'] for r in rr)/sum(r['seconds'] for r in rr)
def good(rr,n=3):return len(rr)>=n and sum(r['n'] for r in rr)>=6

def runs(rr):
 out=[]
 for r in rr:
  if not out or r['t']-out[-1][-1]['t']>900:out.append([])
  out[-1].append(r)
 return out

def roll(rr):
 out=[]
 for run in runs(rr):
  z=[]
  for r in run:
   win=[p for p in run if abs(p['t']-r['t'])<=900]
   z.append({'t':r['t']+150,'v':wt(win) if good(win) else None,'full':r['t']-run[0]['t']>=900 and run[-1]['t']-r['t']>=900})
  out.append(z)
 return out

def phases(rr):
 out=[]
 def cost(q):
  m=wt(q);return sum(x['seconds']*(x['tps']-m)**2 for x in q)
 for run in runs(rr):
  n=len(run)
  # For multi-hour previews require 30 min and at least six nonempty buckets.
  def eligible(q):return good(q,6) and q[-1]['t']-q[0]['t']+300>=1800
  if not eligible(run):out.append({'rows':run,'ok':False,'v':wt(run)});continue
  penalty=max(1,cost(run)/n)*math.log(n)
  dp=[float('inf')]*(n+1);dp[0]=-penalty;path=[None]*(n+1)
  for j in range(6,n+1):
   for i in range(0,j-5):
    if not eligible(run[i:j]):continue
    v=dp[i]+cost(run[i:j])+penalty
    if v<dp[j]:dp[j]=v;path[j]=i
  if path[n] is None:groups=[run]
  else:
   groups=[];j=n
   while j:
    i=path[j];groups.append(run[i:j]);j=i
   groups=groups[::-1]
  if any(abs(wt(b)/wt(a)-1)<.10 for a,b in zip(groups,groups[1:])):groups=[run]
  out.extend({'rows':q,'ok':True,'v':wt(q)} for q in groups)
 return out

def distributions(rr):
 bins={}
 for r in rr:bins.setdefault(r['t']//1800*1800,[]).append(r)
 return [dict(t=t,rows=q,ok=good(q),q=np.percentile([r['tps'] for r in q],[25,50,75]).tolist()) for t,q in sorted(bins.items())]

for w in D['windows']:
 w['rolling']=roll(w['records']);w['phases']=phases(w['records']);w['distribution']=distributions(w['records'])
 print(w['id'],'phases',[(tm(x['rows'][0]['t']),round(x['v'],1),x['ok']) for x in w['phases']])

text(60,38,'额度重置前后 · 真实长时段对比',48,FG,True)
text(60,107,'保留 ① 长窗口走势 / ② 分段均速 / ③ 分布带；三列使用相同时间范围、相同 Y 轴。',26,MUTED)
text(2940,45,'6.1 Sol · 正文 TPS',30,ORANGE,True,anchor='ra')
rect((60,160,2940,268),'#1c2a39',16)
text(86,181,'蓝线 = 首次观测到额度回升',27,BLUE,True)
text(665,181,'蓝色阴影 = 保留的前后额度记录之间，实际重置时刻只能落在此区间。',25)
text(86,226,'测速来自本机正文记录；无逐样本账户字段。时间对齐不代表速度变化由额度重置造成，空档也不代表速度为 0。',23,MUTED)
X=[60,1032,2004];CW=936
for x,title,desc in zip(X,['① 30 分钟长窗口走势','② 分段均速 + 候选转折','③ 30 分钟分布带'],['中心滚动加权均速；边缘窗口用虚线','至少 30 分钟 / 6 桶，差值至少 10%','五分钟桶 TPS 的 P25–P75 + 中位线']):
 text(x+20,310,title,32,ORANGE,True);text(x+20,358,desc,23,MUTED)

ROW=[415,1112,1809];RH=655

# Axes and markers shared by all schemes.
def axes(w,x,y,lo,hi):
 L=x+73;T=y+42;RW=CW-104;GH=285
 def xy(t,v):return L+(t-w['start'])/(w['end']-w['start'])*RW,T+(hi-v)/(hi-lo)*GH
 # uncertain interval of actual quota reset
 a=max(w['start'],w['reset']['previous_at']);b=w['reset']['observed_at']
 xa,_=xy(a,lo);xb,_=xy(b,lo);rect((xa,T,xb,T+GH),ZONE)
 step=10 if hi-lo<70 else 20
 tick=math.ceil(lo/step)*step
 while tick<hi:
  px,py=xy(w['start'],tick);line([(px,py),(L+RW,py)],GRID,1);text(L-13,py-13,str(tick),19,MUTED,anchor='ra');tick+=step
 # absolute clock, no compression; four or five labels.
 count=4
 for k in range(count+1):
  t=w['start']+(w['end']-w['start'])*k/count;px,_=xy(t,lo)
  text(px,T+GH+17,tm(t),20,MUTED,anchor='ma')
 text(L,T-26,'tok/s',18,MUTED)
 return xy,(L,T,RW,GH)

def marker(w,xy,box):
 px,_=xy(w['reset']['observed_at'],0);L,T,RW,GH=box
 line([(px,T),(px,T+GH)],BLUE,3)
 label=tm(w['reset']['observed_at'],secs=True)+'  观测回升'
 # blue label always inside panel
 labelx=min(max(px+12,L),L+RW-265)
 text(labelx,T-32,label,22,BLUE,True)

results=[]
for idx,w in enumerate(D['windows']):
 y=ROW[idx];stats=w['stats'];b,a=stats['before'],stats['after'];reset=w['reset']
 # per-row Y range from displayed summaries, not from excluded raw outliers. All three match.
 vals=[r['v'] for run in w['rolling'] for r in run if r['v'] is not None]+[p['v'] for p in w['phases'] if p['ok']]+[v for p in w['distribution'] if p['ok'] for v in p['q']]
 lo=max(1,math.floor((min(vals)-6)/5)*5);hi=math.ceil((max(vals)+6)/5)*5
 rect((60,y,2940,y+RH),CARD,16)
 date=tm(reset['observed_at'],True).split()[0]
 text(86,y+20,f'{w["id"]}  {date} 重置附近',30,FG,True)
 text(540,y+25,tm(w['start'],True)+' — '+tm(w['end'],True),27,FG)
 text(2920,y+25,f'{stats["bucket_count"]} 桶 / {stats["sample_count"]} 段正文',26,MUTED,anchor='ra')
 if idx==0:
  summary=f'全窗前 / 后加权均速：{b["tps"]:.1f} → {a["tps"]:.1f} tok/s（{(a["tps"]/b["tps"]-1)*100:+.1f}%）；前 {b["samples"]} 段、后 {a["samples"]} 段。全窗平均接近，不支持笼统说“重置后明显变慢”。'
 elif idx==1:
  summary=f'重置附近缺测。已测样本前 {b["samples"]} 段 {b["tps"]:.1f}、后 {a["samples"]} 段 {a["tps"]:.1f} tok/s；两侧不相邻，不能识别重置时的瞬时变化。'
 else:
  summary=f'已测样本前 {b["samples"]} 段 {b["tps"]:.1f}、后 {a["samples"]} 段 {a["tps"]:.1f} tok/s；最近一段仍在持续采集，重置附近存在空档。'
 text(86,y+72,summary,24,MUTED)
 plots_y=y+137
 for j,x in enumerate(X):
  xy,box=axes(w,x,plots_y,lo,hi)
  if j==0:
   for run in w['rolling']:
    for p,q in zip(run,run[1:]):
     if p['v'] is None or q['v'] is None:continue
     pxy=xy(p['t'],p['v']);qxy=xy(q['t'],q['v'])
     if p['full'] and q['full']:line([pxy,qxy],ORANGE,4)
     else:
      for k in range(0,8,2):line([(pxy[0]+(qxy[0]-pxy[0])*k/8,pxy[1]+(qxy[1]-pxy[1])*k/8),(pxy[0]+(qxy[0]-pxy[0])*(k+1)/8,pxy[1]+(qxy[1]-pxy[1])*(k+1)/8)],'#bc815e',3)
    for p in run:
     if p['v'] is not None:dot(*xy(p['t'],p['v']),3,ORANGE)
  elif j==1:
   prev=None
   for p in w['phases']:
    rr=p['rows'];s=rr[0]['t'];e=rr[-1]['t']+300
    if not p['ok']:
     # Sparse islands remain visible as ticks, without a misleading stage mean.
     for r in rr:
      px,py=xy(r['t']+150,lo);rect((px-2,py+1,px+2,py+8),'#657388')
     prev=None;continue
    x1,py=xy(s,p['v']);x2,_=xy(e,p['v']);rect((x1,py-5,x2,py+5),ORANGE,4)
    text((x1+x2)/2,py-32,f'{p["v"]:.1f}',23,ORANGE,True,anchor='ma')
    if prev and s==prev['rows'][-1]['t']+300:
     old=prev['v'];oldx,oldy=xy(s,old);line([(oldx,oldy),(x1,py)],'#996b53',2)
     label=f'{(p["v"]/old-1)*100:+.0f}% · {tm(s)}'
     text(x1+8,max(box[1]+12,min(py,oldy)+12),label,19,MUTED)
    prev=p
  else:
   for p in w['distribution']:
    if not p['ok']:continue
    q1,med,q3=p['q'];x1,y1=xy(max(w['start'],p['t']),q1);x2,y3=xy(min(w['end'],p['t']+1800),q3);_,ym=xy(p['t'],med)
    rect((x1+2,y3,x2-2,max(y3+2,y1)),BAND,4);line([(x1+2,ym),(x2-2,ym)],ORANGE,4)
  # Coverage strip shows all original nonempty buckets and marks sparse islands.
  for r in w['records']:
   px,py=xy(r['t'],lo);qx,_=xy(r['t']+300,lo);rect((px,py+11,max(px+2,qx),py+16),'#586779')
  marker(w,xy,box)
  if j<2:line([(x+CW+18,y+132),(x+CW+18,y+510)],GRID,1)
 # Explanations beneath chart panels, accurately reflects available evidence.
 notes=[
 ['能看到多段升降，但整体前后约 36 tok/s。空档和局部反弹都保留，未强行拟合下降。','候选分段由速度数据独立计算；橙色分段边界与蓝色额度观测线可以不重合。','看典型速度和波动范围。带宽反映桶间差异；不是置信区间，不能代替加权均速。'],
 ['前后是两个分开的采样小岛。中间没有速度线，不能把两端连接成“重置后变快”。','没有满足持续性门槛的段就不画均值台阶；底部仍标出原始采样覆盖。','后半段典型值约 52 tok/s；样本集中在半小时内，不能推广为整晚速度。'],
 ['空白区间真实存在；最后 10 段不等于重置后整个时段的连续测速。','短小采样岛没有足够持续性，不输出假转折时间。','只有样本够的区块有色带，少量尾部样本不包装成稳定阶段。']][idx]
 for j,x in enumerate(X):wrap(notes[j],x+32,y+523,CW-64,23,MUTED,33)
 quota=f'额度原始行 {reset["row_ids"][0]} → {reset["row_ids"][1]}：{reset["previous_used"]}% → {reset["used"]}% 已用；保留记录区间 {tm(reset["previous_at"],True,True)} — {tm(reset["observed_at"],True,True)}（CST）。'
 text(86,y+610,quota,21,BLUE)
 results.append(dict(id=w['id'],y_limits=[lo,hi],phases=[dict(start=p['rows'][0]['t'],end=p['rows'][-1]['t']+300,tps=p['v'],supported=p['ok'],bucket_count=len(p['rows'])) for p in w['phases']]))

rect((60,2525,2940,2660),'#1c2a39',16)
text(86,2543,'重置时间来源：quota-history.sqlite / quota_snapshots.created_at + seven_day_used_percent；已核对同一稳定账户身份。',24,FG)
text(86,2584,'10/24 04:28 是“下次重置时间”校正，已用仍为 0%，不是另一次重置。正文速度来自 speed_5m / speed_sample_ids。',23,MUTED)
text(86,2621,'底部灰色短刻度 = 原始有数据的五分钟桶。短缺口最多容许 15 分钟；长空档断开。仅生成预览，未改产品代码或正式应用。',23,MUTED)
im.save(OUT/'comparison.png',optimize=True)
for i,y in enumerate(ROW):
 # Each detail retains title/legend/column titles and one row for comfortable zoom.
 detail=Image.new('RGB',(int(W*S),int(1180*S)),'#0f141c')
 detail.paste(im.crop((0,0,int(W*S),int(400*S))),(0,0))
 detail.paste(im.crop((0,int(y*S),int(W*S),int((y+RH+5)*S))),(0,int(410*S)))
 detail.paste(im.crop((0,int(2520*S),int(W*S),int(2610*S))),(0,int(1080*S)))
 detail.save(OUT/f'window-{D["windows"][i]["id"]}.png',optimize=True)
(OUT/'derived.json').write_text(json.dumps(results,ensure_ascii=False,indent=2))
print('PNG saved',OUT/'comparison.png')
