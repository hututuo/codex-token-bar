/** Colors/grouping never alter accounting model IDs or prices. */
import bundled from "../../../Vendor/AgentSpeed/spec/assets/prices.json" with { type: "json" };

export const claudeFamilies = ["fable", "opus", "sonnet", "haiku"] as const;
type ClaudeFamily = typeof claudeFamilies[number];
export interface ClaudeCatalogModel { readonly id: string; readonly version: readonly number[] }

function compareVersions(a:readonly number[],b:readonly number[]) {
  for(let i=0;i<Math.max(a.length,b.length);i++){const n=(a[i]??0)-(b[i]??0);if(n)return n;}
  return 0;
}

export function claudeModelIdentity(raw:string) {
  const model=raw.split("|").at(-1)!.toLowerCase().replaceAll("_","-");
  for(const family of claudeFamilies) {
    const match=model.match(new RegExp(`(?:^|[^a-z])${family}(?:[- ]*([0-9]{1,2})(?![0-9])(?:[.\\- ]([0-9]{1,2})(?![0-9]))?)?(?:$|[^a-z])`));
    if(!match)continue;
    let version=match.slice(1).filter(Boolean).map(Number);
    if(!version.length){const old=model.match(new RegExp(`claude-([0-9]{1,2})[.\\-]([0-9]{1,2})-${family}`));if(old)version=old.slice(1).map(Number);}
    return {family,version,label:family[0].toUpperCase()+family.slice(1)+(version.length?" "+version.join("."):"")};
  }
  return null;
}

/** Newest current Anthropic catalog model IDs bundled with this build. Read-only local metadata. */
export const claudeNewestCatalogModelsByFamily: Readonly<Partial<Record<ClaudeFamily,ClaudeCatalogModel>>> = (()=>{
  const newest:Partial<Record<ClaudeFamily,ClaudeCatalogModel>>={};
  const models=bundled.models as {id:string;provider:string;status:string}[];
  for(const model of models) {
    if(model.provider!=="anthropic"||model.status!=="current")continue;
    const parsed=claudeModelIdentity(model.id);
    if(!parsed||!parsed.version.length)continue;
    const family=parsed.family as ClaudeFamily,previous=newest[family];
    if(!previous||compareVersions(previous.version,parsed.version)<0) newest[family]=Object.freeze({id:model.id,version:Object.freeze([...parsed.version])});
  }
  return Object.freeze(newest);
})();

export function claudeModelGroups<T extends {key:string}>(items:T[],client:string) {
  const ids=new Map(items.map(item=>[item.key,claudeModelIdentity(item.key)]));
  const latest=new Map<string,number[]>(Object.entries(claudeNewestCatalogModelsByFamily).flatMap(([family,model])=>model?[[family,model.version] as [string,number[]]]:[]));
  for(const id of ids.values())if(id?.version.length&&(!latest.has(id.family)||compareVersions(id.version,latest.get(id.family)!)>0))latest.set(id.family,id.version);
  const top=items.filter(item=>{const id=ids.get(item.key);return !!id?.version.length&&compareVersions(id.version,latest.get(id.family)!)===0;});
  const selected=new Set(top.map(x=>x.key));
  const groups:{id:string;label:string;items:T[]}[]=[];
  if(top.length)groups.push({id:client+":latest",label:"Claude 最新",items:top.sort((a,b)=>claudeFamilies.indexOf(ids.get(a.key)!.family)-claudeFamilies.indexOf(ids.get(b.key)!.family))});
  for(const family of claudeFamilies){const rows=items.filter(item=>!selected.has(item.key)&&ids.get(item.key)?.family===family);if(rows.length)groups.push({id:client+":"+family,label:family[0].toUpperCase()+family.slice(1),items:rows});}
  const other=items.filter(item=>!ids.get(item.key));if(other.length)groups.push({id:client+":other",label:"Claude 其他",items:other});
  return groups;
}
