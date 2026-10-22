import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import ts from 'typescript';
const source=await readFile(new URL('./bodySpeedQuality.ts',import.meta.url),'utf8');
const code=ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.ESNext,target:ts.ScriptTarget.ES2022}}).outputText;
const {bodySpeedQuality,bodyTypeLabel,isBodySample}=await import('data:text/javascript;base64,'+Buffer.from(code).toString('base64'));
const sample=(tokens=500,seconds=10)=>({startedAt:1000,endedAt:1000+seconds,outputTokens:tokens,durationSeconds:seconds,tokensPerSecond:tokens/seconds,confidence:'high',measurementKind:'completed_body',tokenizer:'o200k_base'});
test('one millisecond body cannot enter average even when legacy confidence says high',()=>{assert.equal(bodySpeedQuality(sample(64,.001)).included,false);assert.equal(bodySpeedQuality(sample(64,.001)).reason,'采样时长不超过 0.4 秒');});
test('short text qualifies while delayed and inconsistent measurements stay ineligible',()=>{assert.equal(bodySpeedQuality(sample(50,1)).included,true);assert.equal(bodySpeedQuality(sample(100,100)).included,false);assert.equal(bodySpeedQuality({...sample(),durationSeconds:2}).reason,'数量与计时不一致');assert.equal(bodySpeedQuality({...sample(),networkWarning:'retry'}).included,false);});
test('measurable longer outputs qualify and both assistant message phases are named',()=>{assert.equal(bodySpeedQuality(sample(100,2)).confidence,'medium');assert.equal(bodySpeedQuality(sample()).confidence,'high');assert.equal(bodyTypeLabel({...sample(),bodyPhase:'commentary'}),'中间消息');assert.equal(bodyTypeLabel({...sample(),bodyPhase:'final_answer'}),'最终文本');assert.equal(isBodySample({...sample(),measurementKind:null}),false);});
test('400ms is excluded and 401ms included even at real Unix timestamps and with legacy low confidence',()=>{
    for(const start of [1000,1792581316.123]) for(const ms of [399,400,401]) {
        const s={...sample(20,ms/1000),startedAt:start,endedAt:start+ms/1000,confidence:'low'};
        assert.equal(bodySpeedQuality(s).included,ms>400);
        assert.equal(bodySpeedQuality(s).confidence,ms>400?'medium':'low');
    }
    assert.equal(bodySpeedQuality(sample(12,5)).confidence,'high');
    assert.equal(bodySpeedQuality(sample(700,1)).reason,'速率异常偏高');
});
