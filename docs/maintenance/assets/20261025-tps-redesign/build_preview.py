from pathlib import Path
import json, math, statistics, datetime
from PIL import Image,ImageDraw,ImageFont
import numpy as np
OUT=Path(__file__).resolve().parent
D=json.loads((OUT/'data.json').read_text()); R=D['selected_window']['records']; DAY=D['latest_24h']['records']
S=1.5; W,H=3200,2370
im=Image.new('RGB',(int(W*S),int(H*S)), '#0e131b'); dr=ImageDraw.Draw(im)
FONT='/System/Library/Fonts/Supplemental/Arial Unicode.ttf'; FB='/System/Library/Fonts/STHeiti Medium.ttc'
BG='#0e131b'; PANEL='#171e29'; MUTED='#a0aec1'; WHITE='#f0f4fa'; ORANGE='#f48650'; GREEN='#61d5ab'; RED='#ff8e92'; BLUE='#77b9ff'; PURPLE='#bc9afa'; GRID='#2b3442'
def f(sz,b=False):return ImageFont.truetype(FB if b else FONT,int(sz*S))
def text(x,y,t,sz=24,fill=WHITE,b=False,anchor=None):dr.text((int(x*S),int(y*S)),str(t),font=f(sz,b),fill=fill,anchor=anchor)
def rect(box,fill,r=0,outline=None,width=1):
 box=tuple(int(v*S) for v in box)
 if r:dr.rounded_rectangle(box,int(r*S),fill=fill,outline=outline,width=int(width*S))
 else:dr.rectangle(box,fill=fill,outline=outline,width=int(width*S))
def line(points,fill,width=2):dr.line([(int(x*S),int(y*S)) for x,y in points], fill=fill,width=max(1,int(width*S)),joint='curve')
def circle(x,y,r,c,outline=None):dr.ellipse((int((x-r)*S),int((y-r)*S),int((x+r)*S),int((y+r)*S)),fill=c,outline=outline,width=int(2*S))
def wrap(t,x,y,width,sz=24,fill=MUTED,leading=36):
 cur=''; yy=y
 for c in t:
  if c=='\n' or dr.textlength(cur+c,font=f(sz))>width*S:
   text(x,yy,cur,sz,fill); yy+=leading;cur='' if c=='\n' else c
  else:cur+=c
 if cur:text(x,yy,cur,sz,fill)
 return yy+leading
TZ=datetime.timezone(datetime.timedelta(hours=8))
def tm(t,day=False):return datetime.datetime.fromtimestamp(t,TZ).strftime('%m/%d %H:%M' if day else '%H:%M')
def wt(rs):return sum(r['output_tokens'] for r in rs)/sum(r['duration_seconds'] for r in rs)
def suff(rs):return len(rs)>=3 and sum(r['sample_count'] for r in rs)>=6

def runs(rs):
 out=[]
 for r in rs:
  if not out or r['bucket_start_epoch_utc']-out[-1][-1]['bucket_start_epoch_utc']>900:out.append([])
  out[-1].append(r)
 return out

def rolling(rs):
 # Centered 30min weighted local constant fit; >=3 actual buckets and >=6 segments.
 out=[]
 for run in runs(rs):
  rr=[]
  for r in run:
   t=r['bucket_start_epoch_utc']+150
   win=[v for v in run if abs(v['bucket_start_epoch_utc']+150-t)<=900]
   rr.append((t,wt(win) if suff(win) else None,len(win)))
  out.append(rr)
 return out

def phase(rs):
 # Penalized weighted least squares. 15min min duration and >=6 body segments/phase.
 def cost(q):
  m=wt(q);return sum(x['duration_seconds']*(x['tokens_per_second']-m)**2 for x in q)
 out=[]
 for run in runs(rs):
  n=len(run)
  if not suff(run):out.append({'rows':run,'ok':False});continue
  penalty=max(1,cost(run)/n)*math.log(n)
  dp=[float('inf')]*(n+1);dp[0]=-penalty;path=[None]*(n+1)
  for j in range(3,n+1):
   for i in range(0,j-2):
    q=run[i:j]
    if not suff(q) or q[-1]['bucket_start_epoch_utc']-q[0]['bucket_start_epoch_utc']+300<900:continue
    if dp[i]+cost(q)+penalty<dp[j]: dp[j]=dp[i]+cost(q)+penalty;path[j]=i
  if path[n] is None:out.append({'rows':run,'ok':True});continue
  groups=[];j=n
  while j>0:
   i=path[j];groups.append(run[i:j]);j=i
  groups=groups[::-1]
  # Require at least 10% separation; otherwise merge to avoid weak phase claims.
  if any(abs(wt(b)/wt(a)-1)<.10 for a,b in zip(groups,groups[1:])):groups=[run]
  out.extend({'rows':q,'ok':True} for q in groups)
 return out

def blocks(rs,period):
 bins={}
 for r in rs:bins.setdefault(r['bucket_start_epoch_utc']//period*period,[]).append(r)
 return [{'t':t,'rows':v,'mean':wt(v),'ok':suff(v),'q':np.percentile([r['tokens_per_second'] for r in v],[25,50,75]).tolist()} for t,v in sorted(bins.items())]

PH=phase(R); PD=phase(DAY); B=blocks(R,900); BD=blocks(DAY,1800)
print('phases',[(tm(p['rows'][0]['bucket_start_epoch_utc']),round(wt(p['rows']),2),len(p['rows']),p['ok']) for p in PH])
print('daily phases',[(tm(p['rows'][0]['bucket_start_epoch_utc'],True),round(wt(p['rows']),2),len(p['rows']),p['ok']) for p in PD])
print('dayblocks',[(tm(p['t'],True),round(p['mean'],1),p['ok']) for p in BD])

text(65,45,'看清速度的阶段变化',54,WHITE,True)
text(65,119,'同一份真实数据 · 4 种不同表达 · 仅设计预览，未改产品',28,MUTED)
text(3135,53,'6.1 Sol',32,ORANGE,True,anchor='ra')
text(3135,105,'正文 TPS / tok/s',24,MUTED,anchor='ra')
rect((65,174,3135,282),'#202a38',20)
text(92,194,'阅读方式',25,BLUE,True)
text(245,193,'上排：10/22 00:15–01:25，40 段正文；首尾 15 分钟加权均速 48.0 → 41.5（−13.5%）。',26)
text(245,235,'下排：快照前最近 24 小时，33 个有数值的 5 分钟桶、74 段正文。长空白 = 没有测速样本，不是 0。',24,MUTED)

MARGIN=65; GAP=24; CW=(3070-3*GAP)/4; XS=[MARGIN+i*(CW+GAP) for i in range(4)]
COLORS=[ORANGE,BLUE,PURPLE,GREEN]
TITLES=['01  长窗口走势','02  变化分段','03  分布带','04  升降时间卡']
SUB=['看持续方向：30 分钟中心滚动均速','看何时切换：均速阶段 + 候选转折','看稳定程度：典型速度与波动区间','不画折线：直接读速度与升降幅度']
for x,c,title,sub in zip(XS,COLORS,TITLES,SUB):
 rect((x,318,x+CW,2130),PANEL,22)
 rect((x,318,x+CW,326),c,3)
 text(x+25,348,title,34,c,True);text(x+25,400,sub,23,MUTED)
 text(x+25,461,'约 50 → 40 的历史片段',24,WHITE,True)

# Shared chart machinery. Raw connected line intentionally absent; optional details would retain exact buckets.
def chart(x,y,w,h,start,end,lo,hi,ticks,xticks):
 L=x+59;T=y+30;RW=w-85;RH=h-85
 def xy(t,v):return (L+(t-start)/(end-start)*RW,T+(hi-v)/(hi-lo)*RH)
 for v in ticks:
  px,py=xy(start,v);line([(L,py),(L+RW,py)],GRID,1);text(L-10,py-14,f'{v:g}',20,MUTED,anchor='ra')
 for t,label in xticks:
  px,py=xy(t,lo);text(px,T+RH+18,label,19,MUTED,anchor='ma')
 text(L,T-27,'tok/s',18,MUTED)
 return xy,(L,T,RW,RH)

def trend_draw(rs,x,y,w,h,day=False):
 start,end=(D['latest_24h']['start'],D['latest_24h']['end']) if day else (R[0]['bucket_start_epoch_utc'],R[-1]['bucket_start_epoch_utc']+300)
 ticks=[10,30,50] if day else [38,44,50]
 lo,hi=(5,62) if day else (35,55)
 xt=[(start,tm(start)),(start+(end-start)*.5,tm(start+(end-start)*.5)),(end,tm(end))]
 xy,box=chart(x,y,w,h,start,end,lo,hi,ticks,xt)
 for run in rolling(rs):
  pp=[]
  for t,v,n in run:
   if v is None:
    if len(pp)>1:line(pp,COLORS[0],5)
    pp=[]
   else:pp.append(xy(t,v))
  if len(pp)>1:
   # Only complete center windows are solid; edge windows are provisional.
   left=run[0][0]+900;right=run[-1][0]-900
   for a,b in zip(pp,pp[1:]):
    ta=start+(a[0]-box[0])/box[2]*(end-start);tb=start+(b[0]-box[0])/box[2]*(end-start)
    if ta>=left and tb<=right:line([a,b],COLORS[0],5)
    else:
     for k in range(0,10,2):
      line([(a[0]+(b[0]-a[0])*k/10,a[1]+(b[1]-a[1])*k/10),(a[0]+(b[0]-a[0])*(k+1)/10,a[1]+(b[1]-a[1])*(k+1)/10)],'#bd805e',3)
  for t,v,n in run:
   if v is not None:circle(*xy(t,v),3,COLORS[0])
 if day:
  # Coverage strip contains ALL actual bucket coverage, including unsupported singleton bins.
  L,T,RW,RH=box
  for r in rs:
   a,_=xy(r['bucket_start_epoch_utc'],lo);b,_=xy(r['bucket_start_epoch_utc']+300,lo);rect((a,T+RH+3,max(a+2,b),T+RH+8),'#647187')
  text(x+60,y+h-3,'底部短刻度 = 实际有样本；不跨长空档连线',20,MUTED)
 return xy

x=XS[0]
text(x+25,514,'48.0 → 41.5   −13.5%',37,ORANGE,True)
text(x+25,565,'首尾 15 分钟加权值；虚线 = 边缘窗口未满',21,MUTED)
trend_draw(R,x+10,605,CW-20,360)
wrap('把偶发反弹降为次要信息。中心窗口会回看前后各 15 分钟，因此右端要显示“未完整”。',x+25,994,CW-50,23)

# Phase chart
x=XS[1];m1,m2=[wt(p['rows']) for p in PH[:2]]
text(x+25,514,f'{m1:.1f} → {m2:.1f}   {(m2/m1-1)*100:+.1f}%',37,BLUE,True)
text(x+25,565,'00:30 附近出现候选转折（5 分钟分辨率）',21,MUTED)
start=R[0]['bucket_start_epoch_utc'];end=R[-1]['bucket_start_epoch_utc']+300
xy,box=chart(x+10,605,CW-20,360,start,end,35,55,[38,44,50],[(start,'00:15'),(start+1800,'00:45'),(end,'01:25')])
for i,p in enumerate(PH):
 q=p['rows'];a=q[0]['bucket_start_epoch_utc'];b=q[-1]['bucket_start_epoch_utc']+300;m=wt(q)
 xa,ya=xy(a,m);xb,yb=xy(b,m);rect((xa,ya-8,xb,ya+8),BLUE,6)
 text((xa+xb)/2,ya-40,f'{m:.1f}',25,BLUE,True,anchor='ma')
 if i:
  px,_=xy(a,m);line([(px,box[1]+15),(px,box[1]+box[3])],'#637b9b',2)
  text(px+20,box[1]+box[3]-38,'↓10.6% · 00:30 起',24,BLUE,True)
wrap('首尾小窗口与整段分组覆盖的时间不同，所以读数不同。分组边界来自数据拟合，表示候选变化时间。',x+25,994,CW-50,23)

# Distribution per fixed 15min /30min blocks. Empirical bucket distribution, no individual body samples.
def distrib_draw(rs,x,y,w,h,period,day=False):
 start,end=(D['latest_24h']['start'],D['latest_24h']['end']) if day else (R[0]['bucket_start_epoch_utc'],R[-1]['bucket_start_epoch_utc']+300)
 lo,hi=(5,75) if day else (32,58)
 xy,box=chart(x,y,w,h,start,end,lo,hi,[10,40,70] if day else [35,45,55],[(start,tm(start)),((start+end)/2,tm((start+end)/2)),(end,tm(end))])
 for p in blocks(rs,period):
  if not p['ok']:continue
  a=max(start,p['t']);b=min(end,p['t']+period);q1,med,q3=p['q']
  xa,y1=xy(a,q1);xb,y3=xy(b,q3);_,ym=xy(a,med)
  rect((xa+2,y3,xb-2,y1),'#493959',7)
  line([(xa+3,ym),(xb-3,ym)],PURPLE,5)
  if not day:text((xa+xb)/2,ym-32,f'{med:.1f}',23,PURPLE,True,anchor='ma')
 if day:text(x+60,y+h-3,'仅画 ≥3 桶、≥6 段的区块；其余保留在明细',20,MUTED)

x=XS[2];meda=statistics.median([r['tokens_per_second'] for r in R[:3]]);medb=statistics.median([r['tokens_per_second'] for r in R[-3:]])
text(x+25,514,f'{meda:.1f} → {medb:.1f}   {(medb/meda-1)*100:+.1f}%',37,PURPLE,True)
text(x+25,565,'首尾 15 分钟的桶中位数；不是加权均速',21,MUTED)
distrib_draw(R,x+10,605,CW-20,360,900)
wrap('彩带为同一时段 5 分钟桶的 P25–P75，粗线为中位数。带宽一眼看出波动；不是置信区间，也不是逐条正文的分布。',x+25,994,CW-50,23)

# Tile cards no y axis. Clock aligned means; last partial not compared.
def tile(x,y,w,h,label,value,sub,c=GREEN):
 rect((x,y,x+w,y+h),'#202b37',13)
 text(x+20,y+15,label,22,MUTED)
 text(x+20,y+49,value,35,c,True)
 text(x+20,y+h-35,sub,20,MUTED)
x=XS[3]
text(x+25,514,'48.0 → 41.5   −13.5%',37,GREEN,True)
text(x+25,565,'15 分钟一张卡；只比较相邻完整窗口',21,MUTED)
prev=None
for i,p in enumerate(B):
 col=i%2;row=i//2;xx=x+25+col*(CW-35)/2;yy=614+row*158
 complete=p['t']+900<=end
 good=p['ok'] and complete
 lab=tm(p['t'])+'–'+tm(p['t']+900)
 change='起始窗口' if prev is None else f'{(p["mean"]/prev["mean"]-1)*100:+.1f}%  较上一窗'
 if not good:change='末窗未满，不作比较'
 tile(xx,yy,(CW-60)/2,145,lab,f'{p["mean"]:.1f} tok/s',change,GREEN if good else MUTED)
 if good:prev=p
wrap('完整窗口：'+' → '.join(f'{p["mean"]:.1f}' for p in B if p['ok'] and p['t']+900<=end)+'。中途反弹也保留；最后一张是未满窗口。',x+25,1110,CW-50,23)

# daily section
for x in XS:
 line([(x+25,1230),(x+CW-25,1230)],GRID,1)
 text(x+25,1259,'最近 24 小时 · 10/24–10/25',25,WHITE,True)

x=XS[0];text(x+25,1310,'先跌后回升；长空档不推算',31,ORANGE,True)
text(x+25,1361,'13:35 后仅 2 段，不外推为“突然提速”',21,MUTED)
trend_draw(DAY,x+10,1400,CW-20,344,True)
wrap('适合：看连续使用时的缓慢变快 / 变慢。\n不适合：精确定位突然变化；右端会修订。',x+25,1790,CW-50,24)

x=XS[1];text(x+25,1310,'01:45 候选：41.8 → 13.9',31,BLUE,True)
# use actual phases for labels below; check prints before final
qual=[p for p in PD if p['ok']]
for j,p in enumerate(qual):
 if j>=6:break
 q=p['rows'];a=q[0]['bucket_start_epoch_utc'];b=q[-1]['bucket_start_epoch_utc']+300
 yy=1387+j*58
 text(x+25,yy,tm(a,True)+'–'+tm(b),22,MUTED)
 text(x+CW-25,yy,f'{wt(q):.1f} tok/s',29,BLUE,True,anchor='ra')
 if j and q[0]['bucket_start_epoch_utc']==qual[j-1]['rows'][-1]['bucket_start_epoch_utc']+300:
  change=(wt(q)/wt(qual[j-1]['rows'])-1)*100
  text(x+390,yy+5,f'{change:+.1f}%',22,GREEN if change>0 else RED,True)
 line([(x+25,yy+45),(x+CW-25,yy+45)],GRID,1)
text(x+25,1740,'候选仍可能受日志计时异常影响',21,MUTED)
wrap('适合：回答“从多少掉到多少、什么时候”。\n不适合：把每个小起伏都当作新阶段；需证据门槛。',x+25,1790,CW-50,24)

x=XS[2];text(x+25,1310,'同为 40 左右，也有稳与不稳',31,PURPLE,True)
text(x+25,1361,'24 小时用 30 分钟区块，避免稀疏假稳定',21,MUTED)
distrib_draw(DAY,x+10,1400,CW-20,344,1800,True)
wrap('适合：辨别“典型速度变了”还是偶发异常。\n不适合：只想快速读一个结论；需解释色带。',x+25,1790,CW-50,24)

x=XS[3];text(x+25,1310,'12:30 起：21.6 → 40.7',31,GREEN,True)
text(x+25,1361,'相邻 30 分钟窗口 +88.8%；各有 9 段',21,MUTED)
good=[p for p in BD if p['ok']]
for j,p in enumerate(good[-4:]):
 xx=x+25+(j%2)*(CW-35)/2;yy=1405+(j//2)*163
 idx=BD.index(p);prev=BD[idx-1] if idx>0 else None
 change=f'{(p["mean"]/prev["mean"]-1)*100:+.1f}%  较上一窗' if prev and prev['ok'] and p['t']-prev['t']==1800 else '前窗缺样本，不比较'
 tile(xx,yy,(CW-60)/2,150,tm(p['t'],True),f'{p["mean"]:.1f} tok/s',change)
wrap('适合：主页一眼读结论，空档也不误导。\n不适合：观察窗口内细节；变化时间仅到窗口边界。',x+25,1790,CW-50,24)

# shared footnote in each card
for x in XS:
 text(x+25,2030,'主图弱网格 · 单模型独立比较',22,MUTED)
 text(x+25,2070,'详细原始点保留到悬停 / 详情',22,MUTED)
rect((65,2165,3135,2320),'#202b37',20)
text(91,2186,'建议优先看 ④ + ②',30,GREEN,True)
text(480,2187,'用升降卡回答“变了多少”，用候选分段回答“大约何时变”。①作连续走势，③作稳定性详情。',26,WHITE)
text(91,2239,'数值口径不同已逐项标明；长空档不补零、不相连。原始桶极值 2.8–159.5 tok/s 仍保留，不把单段尖峰当趋势。',23,MUTED)
text(91,2277,'本机只读快照 2026-10-25 15:43 CST；未证实与额度重置、服务器拥堵存在因果关系。',23,MUTED)

im.save(OUT/'comparison.png',optimize=True)
for i,x in enumerate(XS):im.crop((int((x-5)*S),int(305*S),int((x+CW+5)*S),int(2140*S))).save(OUT/f'option-{i+1}.png',optimize=True)
metrics={'snapshot':D['metadata'],'history_first15_weighted':wt(R[:3]),'history_last15_weighted':wt(R[-3:]),'history_phases':[{'start':p['rows'][0]['bucket_start_epoch_utc'],'end':p['rows'][-1]['bucket_start_epoch_utc']+300,'tps':wt(p['rows']),'sample_count':sum(v['sample_count'] for v in p['rows']),'supported':p['ok']} for p in PH],'daily_phases':[{'start':p['rows'][0]['bucket_start_epoch_utc'],'end':p['rows'][-1]['bucket_start_epoch_utc']+300,'tps':wt(p['rows']),'sample_count':sum(v['sample_count'] for v in p['rows']),'supported':p['ok']} for p in PD],'daily_blocks':[{k:v for k,v in p.items() if k!='rows'} for p in BD]}
(OUT/'metrics.json').write_text(json.dumps(metrics,ensure_ascii=False,indent=2))
print('saved',OUT/'comparison.png')
