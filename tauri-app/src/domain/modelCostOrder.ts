import policy from '../../../Sources/CodexTokenBar/Resources/model-cost-order.json' with {type:'json'};
import {modelPresentationIdentity} from './modelPresentationIdentity';
import {claudeModelIdentity} from '../components/claudeModelPresentation';
import {isReferenceOnlyModelUsage,type FloatingModelUsageItem} from '../floating/floatingModelUsage';

/** Shared display policy only: preserve every source ID and already-priced row. */
export function costModelIdentity(id:string):string {
 let raw=id.split('|').at(-1)??id;
 if(claudeModelIdentity(raw)&&!raw.startsWith('claude-'))raw='claude-'+raw;
 return modelPresentationIdentity(raw).key.replace(/(?:-fast)?(?::free)?$/,'');
}
export function costModelGroup(item:FloatingModelUsageItem):string {
 if(item.key==='unknown-models')return 'unknown-models';
 if(isReferenceOnlyModelUsage(item))return 'other';
 const key=costModelIdentity(item.key);
 const client=item.key.includes('|')?item.key.split('|')[0]:'';
 const source=policy.sourceGroups.find(rule=>rule.clients.includes(client)
   && !(rule.exceptModels as readonly string[]).includes(key) && rule.patterns.some(pattern=>new RegExp(pattern).test(key)));
 if(source)return source.group;
 return policy.groups.find(g=>(g.models as readonly string[]).includes(key)||g.patterns.some(p=>new RegExp(p).test(key)))?.id??'other';
}
const index=(values:readonly string[],value:string)=>{const i=values.indexOf(value);return i<0?Number.MAX_SAFE_INTEGER:i;};
const lexical=(a:string,b:string)=>a<b?-1:a>b?1:0;
const version=(s:string)=>(s.match(/\d+/g)??[]).map(Number).filter(n=>n<1000);
export function orderedCostGroups(items:FloatingModelUsageItem[]) {
 return policy.groups.flatMap(group=>{
  const rows=items.filter(x=>x.tokens>0&&costModelGroup(x)===group.id).sort((a,b)=>{
   const ak=costModelIdentity(a.key),bk=costModelIdentity(b.key);
   const rank=index(group.models,ak)-index(group.models,bk);if(rank)return rank;
   if(isReferenceOnlyModelUsage(a)!==isReferenceOnlyModelUsage(b))return isReferenceOnlyModelUsage(a)?1:-1;
   const av=version(ak),bv=version(bk);
   for(let i=0;i<Math.max(av.length,bv.length);i++){const d=(bv[i]??0)-(av[i]??0);if(d)return d;}
   const family=(key:string)=>{const i=policy.familyPriority.findIndex(f=>key.includes(f));return i<0?Number.MAX_SAFE_INTEGER:i;};
   return family(ak)-family(bk)||lexical(ak,bk)||index(policy.clientPriority,a.key.split('|')[0])-index(policy.clientPriority,b.key.split('|')[0])||lexical(a.key,b.key);
  });
  return rows.length?[{id:group.id,label:group.title,items:rows}]:[];
 });
}
