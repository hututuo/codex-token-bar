import policy from "../../../Sources/CodexTokenBar/Resources/model-presentation-policy.json" with {type:"json"};
import names from "../../../Sources/CodexTokenBar/Resources/model-display-names.json" with {type:"json"};
import prices from "../../../Vendor/AgentSpeed/spec/assets/prices.json" with {type:"json"};

/** Display grouping only. Prices, ledger keys and historical periods use raw IDs. */
export interface ModelPresentationIdentity {key:string;label:string;kind:string}
const normalize=(raw:string)=>raw.trim().toLowerCase().replaceAll("_","-");
function stripModifiers(raw:string):string {
 let key=raw;
 for(const prefix of Object.keys(policy.modifiers).sort()) if(key.startsWith(prefix)){
  const suffixes=policy.modifiers[prefix as keyof typeof policy.modifiers];let suffix:string|undefined;
  while((suffix=suffixes.find(s=>key.endsWith(s))))key=key.slice(0,-suffix.length);
  break;
 }
 return key;
}
function shape(raw:string):string {
 let key=stripModifiers(normalize(raw).replaceAll(" ","-").replaceAll("(","").replaceAll(")",""));
 if(key.startsWith("claude-"))key=key.replaceAll(".","-").replace(/-[0-9]{8}$/,"");
 return key;
}
const aliases=new Map<string,string>(),ambiguous=new Set<string>();
for(const model of prices.models as {id:string;name:string;aliases?:string[]}[])for(const raw of [model.id,model.name,...(model.aliases??[])]){
 if(shape(raw)!==shape(model.id))continue;
 const key=normalize(raw);if(policy.ambiguous.includes(key)||ambiguous.has(key))continue;
 const old=aliases.get(key);if(old&&old!==model.id){aliases.delete(key);ambiguous.add(key);}else aliases.set(key,model.id);
}
export function modelPresentationIdentity(raw:string|null|undefined):ModelPresentationIdentity {
 const original=(raw??"").trim();let key=normalize(original);
 key=(policy.billingAliases as Record<string,string>)[key]??key;
 if(policy.missing.includes(key))return {key:"unknown",label:"未报告模型",kind:"unreported"};
 if(policy.ambiguous.includes(key))return {key:"gpt-5.6-generic",label:"5.6（未分型）",kind:"ambiguous"};
 const routing=(policy.routingLabels as Record<string,string>)[key];if(routing)return {key,label:routing,kind:"routing"};
 const source=(policy.sourceLabels as Record<string,string>)[key];if(source)return {key,label:source,kind:"source"};
 function known(value:string,suffix=""):ModelPresentationIdentity|null {
  const id=aliases.get(value),label=id?(names.names as Record<string,string>)[id]:undefined;
  return id&&label?{key:id+suffix,label:label+(suffix.includes("-fast")?" Fast":"")+(suffix.includes(":free")?" Free":""),kind:"known"}:null;
 }
 let hit=known(key);if(hit)return hit;
 const prefix=policy.wrappers.find(p=>key.startsWith(p));if(prefix)key=key.slice(prefix.length);
 key=(policy.billingAliases as Record<string,string>)[key]??key;
 for(const region of prices.normalize.bedrockRegions)if(key.startsWith(region+".")){
  const rest=key.slice(region.length+1);if(prices.normalize.bedrockVendors.some(v=>rest.startsWith(v+".")))key=rest;break;
 }
 for(const vendor of prices.normalize.bedrockVendors)if(key.startsWith(vendor+".")){
  key=key.slice(vendor.length+1).replace(/-v[0-9]+(?::[0-9]+)?$/,"");break;
 }
 let suffix="";const free=[":free","-free"].find(s=>key.endsWith(s));if(free){key=key.slice(0,-free.length);suffix=":free";}
 if(key.endsWith("-fast")){key=key.slice(0,-5);suffix="-fast"+suffix;}
 hit=known(key,suffix);if(hit)return hit;
 key=stripModifiers(key);hit=known(key,suffix);if(hit)return hit;
 if(key.startsWith("claude-"))key=key.replaceAll(".","-");
 hit=known(key,suffix);if(hit)return hit;
 const scalars=[...original];
 const invalid=scalars.length>160||scalars.some(ch=>{
  const value=ch.codePointAt(0)!;
  return policy.unsafeScalarRanges.some(([lo,hi])=>lo<=value&&value<=hi);
 })||/[{}]/u.test(original);
 return {key:original,label:invalid?"异常模型标识":original,kind:invalid?"invalid":"unknown"};
}
export function modelPresentationDetail(raw:string):string {
 return modelPresentationIdentity(raw).kind==="invalid"?"异常标识已隐藏；原始账目保留":raw.trim();
}
