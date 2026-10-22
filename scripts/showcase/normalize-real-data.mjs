import {readFile,writeFile,stat} from 'node:fs/promises';
import {resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {withSsrModules} from '../../tauri-app/src/test/ssrHarness.mjs';

const root=fileURLToPath(new URL('../../',import.meta.url));
const directory=resolve(process.argv[2]);
const data=JSON.parse(await readFile(resolve(directory,'local-statistics-export.json'),'utf8'));
await withSsrModules(async load=>{
  const {normalizeCodexRadarSnapshot}=await load('/src/domain/codexRadar/model.ts');
  const {normalizeCodexCrowdRadarPayload}=await load('/src/api/codexCrowdRadarClient.ts');
  const {bodySpeedQuality}=await load('/src/components/liveRate/bodySpeedQuality.ts');
  const official=normalizeCodexRadarSnapshot(data.officialRadarRaw);
  official.lastSuccessfulRefreshAt=(await stat(resolve(directory,'real-radar-official.json'))).mtime.toISOString();
  data.officialRadar=official;
  data.crowdRadar=normalizeCodexCrowdRadarPayload(data.crowdRadarRaw);
  delete data.officialRadarRaw;delete data.crowdRadarRaw;
  for(const row of data.samples){const quality=bodySpeedQuality(row);row.confidence=quality.confidence;if(!quality.included)row.qualityReason=quality.reason;}
});

// This is the only publication boundary. Reject credentials and raw local data.
const forbidden=/^(?:access_token|refresh_token|id_token|api_key|apiKey|password|authorization|client_secret|backendOrigin|canonicalHome|rollout_path|first_user_message|cwd)$/i;
function inspect(value,path='root'){
  if(Array.isArray(value))value.forEach((entry,index)=>inspect(entry,`${path}[${index}]`));
  else if(value&&typeof value==='object')for(const [key,entry]of Object.entries(value)){
    if(forbidden.test(key))throw Error(`Forbidden publication field: ${path}.${key}`);inspect(entry,`${path}.${key}`);
  }
  else if(typeof value==='string'&&(/\/Users\//.test(value)||/sk-[A-Za-z0-9_-]{24,}/.test(value)||value.includes('<in-app-browser-context')))throw Error(`Private path, raw prompt or credential in ${path}`);
}
inspect(data);
if(data.days.at(-1).tokens!==data.today.totalTokens)throw Error('Daily total mismatch');
if(data.models.reduce((sum,row)=>sum+row.breakdown.totalTokens,0)!==data.today.totalTokens)throw Error('Model total mismatch');
const output=resolve(root,'tauri-app/showcase/real-data.json');
await writeFile(output,JSON.stringify(data)+'\n');
console.log(JSON.stringify({output,capturedAt:data.capturedAt,usageDataUpdatedAt:data.usageDataUpdatedAt,models:data.latestModelSpeeds30m.map(s=>({model:s.model,tps:s.tokensPerSecond})),radarRows:data.crowdRadar.models.length,checks:'PASS'}));
