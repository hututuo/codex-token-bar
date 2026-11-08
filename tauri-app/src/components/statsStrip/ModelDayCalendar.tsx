import {QuotaCycleCalendar,localDayKey} from './QuotaCycleCalendar';
export {localDayKey} from './QuotaCycleCalendar';
export function modelDayBounds(key:string):{startUnix:number;endUnix:number}|null {
  if(!/^\d{4}-\d{2}-\d{2}$/.test(key))return null;
  const [year,month,day]=key.split('-').map(Number),start=new Date(year,month-1,day);
  if(localDayKey(start)!==key)return null;
  const end=new Date(year,month-1,day+1);
  return {startUnix:start.getTime()/1000,endUnix:end.getTime()/1000};
}
export function ModelDayCalendar({selected,onSelect,now=new Date()}:{selected:string|null;onSelect:(key:string)=>void;now?:Date}) {
  const bounds=selected?modelDayBounds(selected):null;
  return <QuotaCycleCalendar daySelection={{
    selected:bounds?new Date(bounds.startUnix*1000):null,
    onSelect:date=>onSelect(localDayKey(date)),now,
  }}/>;
}
