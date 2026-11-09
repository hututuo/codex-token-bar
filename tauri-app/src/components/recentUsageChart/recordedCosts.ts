import type {ClientTrendBucket} from '../../multiClient/multiClientProduct';

/** Numeric adapter only. Existing chart scaling/paths/hover consume this output;
 * quota estimation continues using the separate provider series. */
export function recordedChartCosts(points: readonly {startUnix:number}[], seconds: number,
  external: readonly ClientTrendBucket[] | undefined, provider: readonly number[], includesCodex: boolean) {
  const sums = new Map<number,{cost:number;unknown:number;known:boolean}>();
  for(const row of external ?? []) {
    const key=Math.floor(row.startUnix/seconds);
    const value=sums.get(key)??{cost:0,unknown:0,known:false};
    if(row.apiCostMicroUSD!=null && Number.isFinite(row.apiCostMicroUSD) && row.apiCostMicroUSD>=0) {
      value.cost+=row.apiCostMicroUSD/1_000_000;value.known=true;value.unknown+=row.unpricedRequests??0;
    } else value.unknown+=row.requests;
    sums.set(key,value);
  }
  return points.map((point,index)=>{
    const value=sums.get(Math.floor(point.startUnix/seconds));
    return {cost:(includesCodex?provider[index]??0:0)+(value?.cost??0),
      unknown:value?.unknown??0,known:includesCodex||(value?.known??false)};
  });
}
