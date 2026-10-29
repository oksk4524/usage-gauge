'use strict';
// v4 mobile-structure tests. Synthetic fixtures; a tiny fake DOM exposes clientWidth, chart bars, focus and resize.
module.exports = async function({assert, vm, core, build, sampleBase}) {
  const dayL=(from,n,f)=>Array.from({length:n},(_,i)=>({date:new Date(Date.parse(from+'T00:00:00Z')+i*86400000).toISOString().slice(0,10),...f(i)}));
  const obs=v=>({tokens:v,input:v-8,output:3,cacheRead:4,cacheCreate:null,reasoning:null,records:1,coverageStatus:'observed'});
  const mk=(id,provider,source,days,extra={})=>({id,provider,source,scope:'this_device',capturedAt:'2026-10-29T01:00:00Z',latestCompleteDate:'2026-10-29',semantics:{totalRule:'input_plus_output_plus_cache_read',inputIncludesCache:false,outputIncludesReasoning:true,cacheReadIncludedInTotal:true,verified:'source_fields'},coverage:{status:'partial',comparisonSafe:false,missingDates:[],issues:[]},days,breakdowns:{project:[],session:[],model:[{date:'2026-10-29',id:'gpt-5',label:'gpt-5',totals:{total:10}}],attribution:[]},activity:[{date:'2026-10-29',hour:3,tokens:9,records:1,attribution:'direct'}],...extra});
  const thirty=mk('c1','claude','claude_cli',dayL('2026-10-01',29,i=>obs(20+i)));      // 2026-10-01 .. 10-29
  const year=mk('x1','codex','codex_server',dayL('2026-02-03',269,i=>obs(10+(i%7))),{scope:'account'}); // 9 months
  const S={schemaVersion:'1.0',snapshotId:'v4',generatedAt:'2026-10-29T02:00:00Z',timezone:'Asia/Seoul',period:{from:'2026-02-03',to:'2026-10-29'},datasets:[thirty,year,mk('a1','aside','aside_local',[])],limits:[],costs:{status:'unavailable'},outcomes:{status:'unavailable'}};
  const html=build(sampleBase,S),sc=html.match(/<script>([\s\S]*)<\/script>/)[1];
  function env({width,host}={}){
    const nd=new Map(),ls={},wl={},bars=new Map();
    const doc={documentElement:{lang:'ko',dataset:{},clientWidth:width},title:'',activeElement:null,querySelectorAll(){return[];},addEventListener(n,f){ls[n]=f;}};
    const nn=id=>{if(!nd.has(id)){const o={innerHTML:'',textContent:'',hidden:false,open:false,dataset:{},className:'',setAttribute(){},showModal(){this.open=true;},close(){this.open=false;}};nd.set(id,o);}return nd.get(id);};
    nn('#chart-host').clientWidth=host;
    // The fake DOM does not parse HTML: mirror the chart block that render() puts inside #view into #chart-host.
    { const v=nn('#view');let cur='';Object.defineProperty(v,'innerHTML',{get(){return cur;},set(x){cur=x;const a=x.indexOf('<div id="chart-host">'),b=x.indexOf('</div></div><div class="usage-foot">');nn('#chart-host').innerHTML=a>=0&&b>a?x.slice(a+21,b):'';}}); }
    const barObjs=()=>{const out=[];for(const m of nn('#chart-host').innerHTML.matchAll(/<g tabindex="(-?\d)"[^>]* role="button"[^>]* data-i="(\d+)" data-date="([^"]+)"[^>]* data-readout="([^"]*)"/g)){const key=m[3];if(!bars.has(key))bars.set(key,{dataset:{i:m[2],date:key,readout:m[4]},attrs:{},setAttribute(k,v){this.attrs[k]=v;},focus(){doc.activeElement=this;this.focused=(this.focused||0)+1;}});out.push(bars.get(key));}return out;};
    const chartScroll={scrollWidth:0,clientWidth:0,scrollLeft:0,querySelectorAll(){return barObjs();}};
    doc.querySelector=id=>id==='#chart-scroll'?(nn('#chart-host').innerHTML.includes('id="chart-scroll"')?chartScroll:null):nn(id);
    nn('#chart-host').querySelector=sel=>{const m=sel.match(/data-chart-page="(\w+)"/);if(!m||!nn('#chart-host').innerHTML.includes('data-chart-page="'+m[1]+'"'))return null;return {focus(){doc.activeElement={dataset:{chartPage:m[1]}};}};};
    vm.runInNewContext(sc,{document:doc,Intl,Date,Map,Set,console,window:{addEventListener(n,f){wl[n]=f;},scrollTo(){}}});
    const clk=(ds={},id='')=>ls.click({target:{closest(){return {dataset:ds,id,getAttribute(k){return k==='aria-disabled'&&ds.chartPage&&nn('#chart-host').innerHTML.match(new RegExp('data-chart-page="'+ds.chartPage+'"[^>]*aria-disabled="true"'))?'true':null;}};}}});
    const chg=(id,value)=>ls.change({target:{id,value}});
    const dates=()=>barObjs().map(b=>b.dataset.date);
    return {doc,ls,wl,nn,clk,chg,bars:barObjs,dates,view:()=>nn('#view').innerHTML,host:()=>nn('#chart-host').innerHTML,doc_:doc};
  }
  const disabled=(h,k)=>new RegExp('data-chart-page="'+k+'" aria-disabled="true"').test(h);
  // --- desktop (no clientWidth): old structure stays
  { const e=env({width:undefined,host:700});
    assert.ok(/data-provider="codex"/.test(e.nn('#providers').innerHTML));assert.equal(e.nn('#providers').className,'provider-tabs');
    assert.ok(!e.nn('#providers').innerHTML.includes('provider-select'));
    e.clk({period:'30d'});assert.equal(e.dates().length,30);assert.ok(!e.host().includes('chart-pager'));
    e.clk({view:'records'});assert.ok(e.view().includes('records-table'));assert.ok(!e.view().includes('rec-list'));
    e.clk({view:'sources'});assert.ok(e.view().includes('<table'));
  }
  // --- mobile 390
  { const e=env({width:390,host:340});
    const P=e.nn('#controls');
    // v5: on mobile the service and source selects share one controls grid; the tab strip is hidden
    assert.ok(P.innerHTML.includes('id="provider-select"')&&P.innerHTML.includes('id="dataset"'));assert.ok(!/data-provider=/.test(P.innerHTML));assert.equal(e.nn('#providers').hidden,true);assert.equal(e.nn('#providers').innerHTML,'');
    assert.ok(P.innerHTML.indexOf('provider-select')<P.innerHTML.indexOf('id="dataset"'));
    assert.ok(/<span class="lbl">서비스<\/span>/.test(P.innerHTML));
    // distinct from the page-navigation select
    assert.ok(!P.innerHTML.includes('view-select'));
    assert.ok(!P.innerHTML.includes('수집:')&&!P.innerHTML.includes('id="coverage"'),'v5: collected time and coverage button are not in the shared controls');
    // 7d default fits one page; no pager
    assert.equal(e.dates().length,7);assert.ok(!e.host().includes('chart-pager'));
    // 30d: 30 days -> pages of 7: 7,7,7,7,2
    e.clk({period:'30d'});
    let seen=[...e.dates()];assert.equal(e.dates().length,7);
    assert.equal(e.dates().at(-1),'2026-10-29');
    assert.ok(e.host().includes('전체 30일 중 7일'));assert.ok(e.host().includes('위 합계는 전체 30일'));
    assert.ok(disabled(e.host(),'newer'));assert.ok(!disabled(e.host(),'older'));
    assert.ok(!e.host().includes('min-width:500'));
    for(let i=0;i<4;i++){e.clk({chartPage:'older'});seen=[...e.dates(),...seen];}
    assert.equal(seen.length,30);assert.equal(new Set(seen).size,30);
    assert.deepEqual(seen,['2026-09-30',...thirty.days.map(d=>d.date)]);   // 09-30 has no record but stays as a missing bucket; none dropped
    assert.equal(e.dates().length,2);                           // last page holds the 2 oldest days
    assert.ok(disabled(e.host(),'older'));assert.ok(!disabled(e.host(),'newer'));
    assert.equal(e.doc.activeElement?.dataset.chartPage,'older'); // focus stays on the pager
    e.clk({chartPage:'older'});assert.equal(e.dates().length,2);  // disabled button does nothing
    // period change resets to the newest page
    e.clk({period:'7d'});e.clk({period:'30d'});assert.equal(e.dates().at(-1),'2026-10-29');
    // dataset/provider replacement resets too
    e.clk({chartPage:'older'});assert.notEqual(e.dates().at(-1),'2026-10-29');
    e.chg('dataset','0');assert.equal(e.dates().length,7);
    e.clk({period:'30d'});e.clk({chartPage:'older'});
    e.chg('provider-select','codex');
    assert.ok(e.nn('#controls').innerHTML.includes('value="codex" selected'));
    e.clk({period:'all'});assert.equal(e.dates().at(-1),'2026-10');
    // monthly: 9 months -> 7 + 2, none dropped
    let months=[...e.dates()];assert.equal(months.length,7);assert.ok(e.host().includes('전체 9개월 중 7개월'));
    e.clk({chartPage:'older'});assert.equal(e.dates().length,2);months=[...e.dates(),...months];
    assert.deepEqual(months,['2026-02','2026-03','2026-04','2026-05','2026-06','2026-07','2026-08','2026-09','2026-10']);
    assert.ok(disabled(e.host(),'older'));
    // exact month sums are unchanged: the sum over every month page equals the all-period total
    const total=year.days.reduce((n,d)=>n+d.tokens,0);
    e.clk({usage:'1'});const all=e.nn('#dialog-body').innerHTML.match(/<dt>정확한 합계<\/dt><dd><strong class="num">([\d,]+)/);e.clk({},'dialog-close');
    assert.equal(Number(all[1].replace(/,/g,'')),total);
    // keyboard: ArrowLeft on the first visible bar moves to the earlier page, focuses its last bar
    e.clk({chartPage:'newer'});
    const first=e.bars()[0];e.doc.activeElement=first;
    let prevented=0;e.ls.keydown({target:first,key:'ArrowLeft',preventDefault(){prevented++;}});
    assert.ok(prevented>0);assert.equal(e.doc.activeElement.dataset.date,'2026-03');assert.equal(e.dates().length,2);
    e.ls.keydown({target:e.doc.activeElement,key:'ArrowRight',preventDefault(){}});
    assert.equal(e.dates().length,7);assert.equal(e.doc.activeElement.dataset.date,'2026-04');
    // chart width follows the real host clientWidth: no 280px floor
    e.clk({period:'30d'});
    e.nn('#chart-host').clientWidth=240;e.wl.resize();
    assert.ok(/<svg class="chart" width="240"/.test(e.host()));
    e.nn('#chart-host').clientWidth=200;e.wl.resize();
    assert.ok(/<svg class="chart" width="200"/.test(e.host()));
    // resize keeps the focused bar by date even when it falls on another page
    e.clk({period:'30d'});e.clk({chartPage:'older'});e.clk({chartPage:'older'});
    const mid=e.bars()[3];e.doc.activeElement=mid;const date=mid.dataset.date;
    e.nn('#chart-host').clientWidth=330;e.wl.resize();
    assert.equal(e.doc.activeElement.dataset.date,date);
    // crossing to desktop re-renders tabs and the whole chart
    e.doc.documentElement.clientWidth=1200;e.nn('#chart-host').clientWidth=700;e.wl.resize();
    assert.equal(e.nn('#providers').className,'provider-tabs');assert.ok(!e.host().includes('chart-pager'));assert.equal(e.dates().length,30);
  }
  // --- mobile views: label/value structure, no wide tables, no duplicate ids, actions preserved
  { const e=env({width:390,host:340});
    const ids=h=>[...h.matchAll(/\sid="([^"]+)"/g)].map(m=>m[1]);
    const noDupes=s=>{const a=ids(s);assert.equal(new Set(a).size,a.length,'duplicate ids: '+a);};
    e.clk({view:'records'});e.clk({period:'7d'});
    let v=e.view();assert.ok(!v.includes('<table'));assert.ok(v.includes('class="rec-list"'));
    assert.equal((v.match(/<details class="rec">/g)||[]).length,7);
    assert.equal((v.match(/<dt>입력<\/dt>/g)||[]).length,7);
    for(const k of ['입력','캐시 읽기','캐시 생성','출력','추론'])assert.equal((v.match(new RegExp('<dt>'+k+'</dt>','g'))||[]).length,7);
    assert.ok(/합계에 포함|합계에 미포함/.test(v));                   // role per component stays reachable
    assert.ok(/<dt>캐시 생성<\/dt><dd><span class="na"/.test(v));      // unknown is not zero
    assert.ok(!/<dt>캐시 생성<\/dt><dd>0/.test(v));
    assert.ok(/출력에 포함, 다시 더하지 않음/.test(v));
    noDupes(v+e.nn('#controls').innerHTML+e.nn('#providers').innerHTML);
    e.clk({view:'sources'});v=e.view();
    assert.ok(!v.includes('<table'));assert.equal((v.match(/data-details="/g)||[]).length,3);
    assert.ok(v.includes('class="kv-card"'));noDupes(v);
    e.clk({view:'insights'});v=e.view();
    assert.ok(!v.includes('<table'));assert.ok(v.includes('kv-tokens'));assert.ok(/gpt-5/.test(v));
    e.clk({period:'30d'});v=e.view();assert.ok(!v.includes('<table'));
    e.clk({view:'overview'});v=e.view();
    assert.ok(!v.includes('class="table-wrap"'));assert.ok(!v.includes('<table'));assert.ok(v.includes('data-usage="1"')&&!v.includes('<dt>'),'v5: no label/value lists on first screen');
    e.clk({usage:'1'});{const db=e.nn('#dialog-body').innerHTML;assert.ok(!db.includes('<table'));for(const k of ['입력','캐시 읽기','캐시 생성','출력','추론'])assert.ok(db.includes('<dt>'+k+'</dt>'));noDupes(db+e.nn('#controls').innerHTML);}e.clk({},'dialog-close');
    e.clk({lang:'en'});e.clk({usage:'1'});assert.ok(/<dt>Cache creation<\/dt>/.test(e.nn('#dialog-body').innerHTML));e.clk({},'dialog-close');
    e.clk({period:'30d'});assert.ok(e.host().includes('Showing 7 of 30 days'));assert.ok(e.host().includes('Earlier records'));assert.ok(e.host().includes('Recent records'));assert.ok(e.nn('#controls').innerHTML.includes('<span class="lbl">Service</span>'));
    // hourly view on mobile
    e.clk({view:'insights'});assert.ok(!e.view().includes('<table'));
  }
  // --- no-javascript-visible overflow hacks in the shipped CSS for mobile structure
  const css=require('node:fs').readFileSync(require('node:path').join(__dirname,'v2.css'),'utf8');
  const v4css=css.slice(css.indexOf('/* v4:'));
  assert.ok(!/overflow-x\s*:\s*(hidden|clip)|scrollbar-width\s*:\s*none|::-webkit-scrollbar\s*\{[^}]*(?:display\s*:\s*none|width\s*:\s*0(?:px)?[;}])/.test(v4css));
  assert.ok(!/min-width:\s*280px/.test(html));
};
