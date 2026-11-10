import policy from '../../../Sources/CodexTokenBar/Resources/model-cost-order.json' with {type:'json'};
import {modelPresentationIdentity} from './modelPresentationIdentity';
import {claudeModelIdentity} from '../components/claudeModelPresentation';
import {isReferenceOnlyModelUsage,type FloatingModelUsageItem} from '../floating/floatingModelUsage';

export const costModelColumns=policy.columns;
export interface CostModelGroup {
 id:string; label:string; items:FloatingModelUsageItem[]; isSecondary:boolean; visibleLimit?:number;
}
/** Display only: preserve all source IDs, token counts and already-priced amounts. */
export function costModelIdentity(id:string):string {
 let raw=id.split('|').at(-1)??id;
 if(claudeModelIdentity(raw)&&!raw.startsWith('claude-'))raw='claude-'+raw;
 return modelPresentationIdentity(raw).key.replace(/(?:-fast)?(?::free)?$/,'');
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
export function orderedCostGroups(items:FloatingModelUsageItem[]):CostModelGroup[] {
 const active=items.filter(x=>Number.isFinite(x.tokens)&&x.tokens>0);
 const grouped=new Map<string,FloatingModelUsageItem[]>();
 for(const item of active.filter(x=>x.key!=='unknown-models')){
  const id=client(item.key),rows=grouped.get(id)??[];rows.push(item);grouped.set(id,rows);
 }
 const clients=[...policy.clients.map(c=>c.id),...[...grouped.keys()].filter(id=>!policy.clients.some(c=>c.id===id)).sort(lexical)];
 const primary:CostModelGroup[]=[],other:CostModelGroup[]=[];
 for(const id of clients){
  const rows=grouped.get(id);if(!rows?.length)continue;
  const rule=policy.clients.find(c=>c.id===id),preferred=rule?.preferred??[],label=rule?.title??id;
  const top=rows.filter(isFeaturedCostCandidate).sort((a,b)=>before(a,b,preferred)).slice(0,policy.columns);
  const selected=new Set(top.map(x=>x.key));
  const remaining=rows.filter(x=>!selected.has(x.key)).sort((a,b)=>{
   const ac=isFeaturedCostCandidate(a),bc=isFeaturedCostCandidate(b);
   return ac!==bc?(ac?-1:1):before(a,b,preferred);
  });
  if(top.length)primary.push({id:'client:'+id,label,items:top,isSecondary:false});
  if(remaining.length)other.push({id:'other:'+id,label,items:remaining,isSecondary:true,visibleLimit:policy.otherVisibleLimit});
 }
 const unknown=active.filter(x=>x.key==='unknown-models');
 if(unknown.length)other.push({id:'unknown-models',label:'未知模型',items:unknown,isSecondary:true});
 return [...primary,...other];
}
