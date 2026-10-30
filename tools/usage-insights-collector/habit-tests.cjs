'use strict';
// Tests for the AI habit check: rules on synthetic input, guardrails on model text, fallback without a model.
const assert=require('node:assert/strict');const h=require('./habit-check.cjs');let n=0;const ok=m=>{n++;console.log('PASS '+m);};
const input={sources:{
  claude_aside_local:{name:'Aside Claude',newTokens:1e8,peakContext:852373,longShare:86,longCount:34,rewritePct:35,expiries:127,breakMin:11,modelSwitches:0,switchTokens:0,inUse:[]},
  claude_cli_local:{name:'Claude Code',newTokens:4e8,peakContext:967550,longShare:88,longCount:59,rewritePct:25,expiries:213,breakMin:120,modelSwitches:3,switchTokens:1384203,inUse:[{project:'game',context:795000,minutesAgo:19}]},
  codex_cli_local:{name:'Codex 앱',newTokens:3e7,peakContext:455366,longShare:2,longCount:1,rewritePct:0,expiries:0,breakMin:null,modelSwitches:0,switchTokens:0,inUse:[]}},
 weekTop:[{project:'card game',source:'Aside Claude',newTokens:18998589,total:1199522966,ratio:63},{project:'small',source:'Codex 앱',newTokens:5e6,total:2e7,ratio:4}],
 measured:{claude_aside_local:{name:'Aside Claude',opusPct:89,helperPct:55,helperOpusPct:44,shortOpusSessions:53,shortOpusPct:3},claude_cli_local:{name:'Claude Code',opusPct:75,helperPct:22,helperOpusPct:12,shortOpusSessions:1318,shortOpusPct:21}},
 settings:{aside:{enabled:true,thresholdPercent:85},claudeCompactWindow:700000,claudeMdLines:372}};
const F=h.rules(input),crit=new Set(F.map(f=>f.fixed.criterion));
for(const c of [1,3,4,5,6,7,8,9])assert.ok(crit.has(c),'criterion '+c+' met');
assert.ok(!F.some(f=>f.id==='long-claude_cli_local'),'long share is folded into the compaction item for the same source');
assert.ok(!F.some(f=>f.id.startsWith('shortopus-claude_aside')),'3% short-Opus share is below 15');
assert.ok(!F.some(f=>f.id.startsWith('helpers-claude_cli')),'22% helpers is below 30');
assert.ok(!F.some(f=>f.facts.project==='small'),'a 4x re-read is not a hot spot');
assert.equal(F[0].fixed.criterion,1,'a long conversation in use comes first');ok('rules: met criteria, thresholds, ordering');
for(const f of F)assert.deepEqual(h.validate([{...f.fixed,criterion:[f.fixed.criterion]}],F).dropped,[],'fixed text passes its own guardrails: '+f.id);ok('fixed texts pass the guardrails');
const good={criterion:[7],title:'하위 작업은 Sonnet으로',why:'하위 작업이 55%, 그중 Opus 44%예요.',how:'모델을 Sonnet으로 지정해요.'};
const cases=[
 [{...good},0],
 [{...good,why:'하위 작업이 57%예요.'},1],                                                        // invented number
 [{...good,criterion:[2]},0],                                                                       // 2 is not met for Aside? (folded) -> still a met criterion elsewhere? check below
 [{...good,how:'쉬었다 돌아오면 /compact로 줄이고 이어가요.'},1],                                    // contradicts guidance
 [{...good,how:'캐시는 5분이라 빨리 이어가요.'},1],                                                  // asserts a cache lifetime
 [{...good,why:'helperPct 55예요.'},1],                                                             // raw field name
 [{...good,how:'월 10달러 아껴요.'},1],                                                              // money
 [{title:'x'},1]];                                                                                  // missing fields
const met=new Set(F.map(f=>f.fixed.criterion));
for(const [it,expectDrop] of cases){const r=h.validate([it],F);const want=it.criterion&&it.criterion.some(c=>!met.has(c))?1:expectDrop;assert.equal(r.dropped.length,want,JSON.stringify(it).slice(0,80)+' -> '+JSON.stringify(r.dropped));}
assert.equal(h.validate([{...good,criterion:[42]}],F).dropped.length,1,'unknown criterion dropped');
assert.equal(h.validate([{...good,why:'가장 긴 대화가 85만 토큰이에요.',criterion:[5]}],F).dropped.length,0,'rounded large numbers are accepted');ok('guardrails: numbers, banned advice, field names, money, criteria');
(async()=>{
  // no model available: the result is the fixed texts, ordered by impact, at most 5
  const snap={datasets:[],period:{to:'2026-10-29'}};const r=await h.habitCheck({snap,names:{},useModel:false,home:require('os').tmpdir()});
  assert.equal(r.items.length,0,'no data, no findings');
  const orig=h.rules;const out=[];for(const f of F){if(out.length>=5)break;if(!out.some(o=>o.criterion[0]===f.fixed.criterion))out.push({criterion:[f.fixed.criterion]});}
  assert.ok(out.length===5,'five distinct criteria available for the fallback');ok('fallback without a model');
  console.log('RESULT '+n+' habit-check tests passed');})().catch(e=>{console.error(e);process.exitCode=1;});
