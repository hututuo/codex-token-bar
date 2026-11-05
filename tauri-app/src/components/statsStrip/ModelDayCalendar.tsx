import {useState} from 'react';

export function localDayKey(date:Date):string {
  return `${date.getFullYear()}-${String(date.getMonth()+1).padStart(2,'0')}-${String(date.getDate()).padStart(2,'0')}`;
}
export function modelDayBounds(key:string):{startUnix:number;endUnix:number}|null {
  if(!/^\d{4}-\d{2}-\d{2}$/.test(key))return null;
  const [year,month,day]=key.split('-').map(Number),start=new Date(year,month-1,day);
  if(localDayKey(start)!==key)return null;
  const end=new Date(year,month-1,day+1);
  return {startUnix:start.getTime()/1000,endUnix:end.getTime()/1000};
}
export function ModelDayCalendar({selected,onSelect,now=new Date()}:{selected:string|null;onSelect:(key:string)=>void;now?:Date}) {
  const [month,setMonth]=useState(()=>selected?new Date(modelDayBounds(selected)!.startUnix*1000):now);
  const first=new Date(month.getFullYear(),month.getMonth(),1),offset=(first.getDay()+6)%7;
  const count=Math.ceil((offset+new Date(month.getFullYear(),month.getMonth()+1,0).getDate())/7)*7;
  const today=localDayKey(now),label=first.toLocaleDateString('zh-CN',{year:'numeric',month:'long'});
  return <div className="model-day-calendar" aria-label="单日金额日历">
    <div className="model-day-calendar-heading">
      <button type="button" aria-label="单日日历上个月" onClick={()=>setMonth(new Date(first.getFullYear(),first.getMonth()-1,1))}>‹</button>
      <strong>{label}</strong>
      <button type="button" aria-label="单日日历下个月" disabled={first.getFullYear()===now.getFullYear()&&first.getMonth()===now.getMonth()} onClick={()=>setMonth(new Date(first.getFullYear(),first.getMonth()+1,1))}>›</button>
      <button type="button" onClick={()=>{setMonth(now);onSelect(today);}}>今天</button>
    </div>
    <div className="model-day-calendar-grid">
      {['一','二','三','四','五','六','日'].map(day=><span key={day}>{day}</span>)}
      {Array.from({length:count},(_,i)=>{const day=new Date(first.getFullYear(),first.getMonth(),1+i-offset),key=localDayKey(day);return <button key={key} type="button" aria-label={`${key}的模型金额`} aria-pressed={selected===key} disabled={key>today} className={day.getMonth()!==first.getMonth()?'outside':undefined} onClick={()=>onSelect(key)}>{day.getDate()}</button>;})}
    </div>
    <label className="model-day-calendar-jump">跳转日期 <input type="date" aria-label="选择历史日期" max={today} value={selected??today} onChange={event=>{const key=event.target.value,bounds=modelDayBounds(key);if(bounds&&key<=today){setMonth(new Date(bounds.startUnix*1000));onSelect(key);}}}/></label>
  </div>;
}
