import policy from '../../../Sources/CodexTokenBar/Resources/model-cost-order.json' with {type:'json'};
import {modelPresentationIdentity} from './modelPresentationIdentity';
import {claudeModelIdentity} from '../components/claudeModelPresentation';
import {isReferenceOnlyModelUsage,type FloatingModelUsageItem} from '../floating/floatingModelUsage';
import {modelUsageColor} from '../components/modelUsagePresentation';

export const costModelColumns=policy.columns;
export interface CostModelGroup {
 id:string; label:string; items:FloatingModelUsageItem[]; isSecondary:boolean; visibleLimit?:number;
}
function modelIdentity(id:string) {
 let raw=id.split('|').at(-1)??id;
 if(claudeModelIdentity(raw)&&!raw.startsWith('claude-'))raw='claude-'+raw;
 return modelPresentationIdentity(raw);
}
/** Ordering only; merging keeps fast/free variants and source attribution. */
export function costModelIdentity(id:string):string {
 return modelIdentity(id).key.replace(/(?:-fast)?(?::free)?$/,'');
}
const client=(id:string)=>id.includes('|')?id.split('|')[0]:'codex';
const lexical=(a:string,b:string)=>a<b?-1:a>b?1:0;
const rank=(values:readonly string[],value:string)=>{const i=values.indexOf(value);return i<0?Number.MAX_SAFE_INTEGER:i;};
export function isFeaturedCostCandidate(item:FloatingModelUsageItem):boolean {
 if(isReferenceOnlyModelUsage(item))return false;
 const key=costModelIdentity(item.key);
 if(!['known','source'].includes(modelPresentationIdentity(key).kind)||policy.otherPatterns.some(p=>new RegExp(p).test(key)))return false;
 const generation=policy.generations.find(g=>key.startsWith(g.prefix));
 if(!generation)return true;
 const match=key.match(new RegExp(generation.pattern));if(!match)return false;
 const version=[Number(match[1]),Number(match[2]??0)];
 for(let i=0;i<2;i++){const delta=version[i]-(generation.minimum[i]??0);if(delta)return delta>0;}
 return true;
}
function before(a:FloatingModelUsageItem,b:FloatingModelUsageItem,preferred:readonly string[]):number {
 const priority=rank(preferred,costModelIdentity(a.key))-rank(preferred,costModelIdentity(b.key));
 if(priority)return priority;
 if(isReferenceOnlyModelUsage(a)!==isReferenceOnlyModelUsage(b))return isReferenceOnlyModelUsage(a)?1:-1;
 if(a.tokens!==b.tokens)return b.tokens-a.tokens;
 const version=(key:string)=>(costModelIdentity(key).match(/\d+/g)??[]).map(Number).filter(n=>n<1000);
 const av=version(a.key),bv=version(b.key);
 for(let i=0;i<Math.max(av.length,bv.length);i++){const delta=(bv[i]??0)-(av[i]??0);if(delta)return delta;}
 return lexical(a.key,b.key);
}
function mergeSources(rows:FloatingModelUsageItem[],rule:typeof policy.clients[number]):FloatingModelUsageItem[] {
 if(rule.sources.length<2)return rows;
 const models=new Map<string,FloatingModelUsageItem[]>();
 for(const row of rows){
  const key=isReferenceOnlyModelUsage(row)?row.key:modelIdentity(row.key).key;
  const current=models.get(key)??[];current.push(row);models.set(key,current);
 }
 return [...models.values()].map(values=>{
  const sorted=[...values].sort((a,b)=>lexical(a.key,b.key));
  if(sorted.length===1)return sorted[0];
  const model=modelIdentity(sorted[0].key),known=sorted.flatMap(row=>{
   const cost=row.knownPartialCostUSD??row.costUSD;return cost==null?[]:[cost];
  });
  const subtotal=known.length?known.reduce((a,b)=>a+b,0):null;
  const complete=sorted.every(row=>row.costUSD!==null&&row.knownPartialCostUSD==null);
  return {key:rule.id+'|'+model.key,label:model.label,tokens:sorted.reduce((sum,row)=>sum+row.tokens,0),
   share:sorted.reduce((sum,row)=>sum+row.share,0),costUSD:complete?subtotal:null,
   knownPartialCostUSD:complete?null:subtotal,usesIndependentQuota:false,referenceCostUSD:null,color:sorted[0].color,
   sourceModels:[...new Set(sorted.flatMap(row=>row.sourceModels?.length?row.sourceModels:[row.key.split('|').at(-1)!]))].sort(lexical),
   sourceClients:[...new Set(sorted.flatMap(row=>row.sourceClients?.length?row.sourceClients:[client(row.key)]))].sort(lexical)};
 });
}
export function orderedCostGroups(items:FloatingModelUsageItem[]):CostModelGroup[] {
 const available=items.filter(x=>Number.isFinite(x.tokens)&&x.tokens>=0&&!x.isCatalogPlaceholder);
 const grouped=new Map<string,FloatingModelUsageItem[]>();
 for(const item of available.filter(x=>x.key!=='unknown-models')){
  const id=policy.clients.find(rule=>rule.sources.includes(client(item.key)))?.id??client(item.key);
  const rows=grouped.get(id)??[];rows.push(item);grouped.set(id,rows);
 }
 const clients=[...policy.clients.map(c=>c.id),...[...grouped.keys()].filter(id=>!policy.clients.some(c=>c.id===id)).sort(lexical)];
 const primary:CostModelGroup[]=[],other:CostModelGroup[]=[];
 for(const id of clients){
  const sourceRows=grouped.get(id);if(!sourceRows?.length)continue;
  const rule=policy.clients.find(c=>c.id===id),preferred=rule?.preferred??[],label=rule?.title??id;
  const used=sourceRows.filter(row=>row.tokens>0),rows=rule?mergeSources(used,rule):used;
  const sorted=[...rows].sort((a,b)=>{
   const ac=isFeaturedCostCandidate(a),bc=isFeaturedCostCandidate(b);
   return ac!==bc?(ac?-1:1):before(a,b,preferred);
  });
  const sourceClients=[...new Set(sourceRows.flatMap(row=>row.sourceClients?.length?row.sourceClients:[client(row.key)]))].sort(lexical);
  const top:FloatingModelUsageItem[]=preferred.slice(0,policy.columns).map(model=>
   sorted.find(row=>modelIdentity(row.key).key===model&&!isReferenceOnlyModelUsage(row))??
   sorted.find(row=>costModelIdentity(row.key)===model&&!isReferenceOnlyModelUsage(row))??{
    key:id+'|'+model,label:modelIdentity(model).label,tokens:0,share:0,costUSD:0,usesIndependentQuota:false,
    referenceCostUSD:null,color:modelUsageColor(model),sourceClients,isCatalogPlaceholder:true,
   });
  if(top.length<policy.columns){
   const chosen=new Set(top.map(row=>row.key));
   top.push(...sorted.filter(row=>isFeaturedCostCandidate(row)&&!chosen.has(row.key)).slice(0,policy.columns-top.length));
  }
  const selected=new Set(top.map(x=>x.key)),remaining=sorted.filter(x=>!selected.has(x.key));
  if(top.length)primary.push({id:'client:'+id,label,items:[...top,...remaining],isSecondary:false,visibleLimit:policy.columns});
  else if(remaining.length)other.push({id:'other:'+id,label,items:remaining,isSecondary:true,visibleLimit:policy.otherVisibleLimit});
 }
 const unknown=available.filter(x=>x.key==='unknown-models'&&x.tokens>0);
 if(unknown.length)other.push({id:'unknown-models',label:'未知模型',items:unknown,isSecondary:true});
 return [...primary,...other];
}
