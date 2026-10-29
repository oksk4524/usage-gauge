'use strict';
// v5 tests: calmer first screen. LIMITS: the fake DOM does not parse HTML, lay out, scroll or measure anything.
// It checks generated markup/strings and event wiring only. Real layout, overflow and focus need a browser.
module.exports = async function({assert, fs, vm, core, build, sampleBase}) {
  const dayL=(from,n,f)=>Array.from({length:n},(_,i)=>({date:new Date(Date.parse(from+'T00:00:00Z')+i*86400000).toISOString().slice(0,10),...f(i)}));
  const obs=v=>({tokens:v,input:v-8,output:3,cacheRead:4,cacheCreate:null,reasoning:null,records:1,coverageStatus:'observed'});
  const mk=(id,provider,source,days,extra={})=>({id,provider,source,scope:'this_device',capturedAt:'2026-10-29T01:00:00Z',latestCompleteDate:'2026-10-29',semantics:{totalRule:'input_plus_output_plus_cache_read',inputIncludesCache:false,outputIncludesReasoning:true,cacheReadIncludedInTotal:true,verified:'source_fields'},coverage:{status:'complete_for_selected_source',comparisonSafe:true,missingDates:[],issues:[]},days,breakdowns:{project:[],session:[],model:[],attribution:[]},activity:[],...extra});
  // complete dataset whose newest day is partial: the total must still say "partial"
  const dayData=dayL('2026-10-01',29,i=>obs(20+i));dayData[28]={...dayData[28],coverageStatus:'partial'};
  const claude=mk('c1','claude','claude_cli',dayData);
  const stale=mk('g1','grok','grok_usage_json',dayL('2026-09-01',20,()=>obs(5)));   // last record 2026-09-20: nothing in the last 7 days
  const unkCov=mk('u1','codex','codex_server',dayL('2026-10-20',10,()=>obs(7)),{coverage:{}});
  const lim=(provider,window,rem,extra={})=>({provider,window,unit:'percent',status:'observed',remainingPercent:rem,capturedAt:'2026-10-29T01:00:00Z',source:'test_probe',...extra});
  const S={schemaVersion:'1.0',snapshotId:'v5',generatedAt:'2026-10-29T02:00:00Z',timezone:'Asia/Seoul',period:{from:'2026-09-01',to:'2026-10-29'},datasets:[claude,stale,unkCov],limits:[lim('claude','5h',96),lim('claude','7d',3,{resetAt:'2026-11-02T03:00:00Z'}),lim('grok','7d',50)],costs:{status:'unavailable'},outcomes:{status:'unavailable'}};
  const K=core(S);
  const html=build(sampleBase,S),sc=html.match(/<script>([\s\S]*)<\/script>/)[1];
  function env({width,host}={}){
    const nd=new Map(),ls={};
    const nn=id=>{if(!nd.has(id))nd.set(id,{innerHTML:'',textContent:'',hidden:false,open:false,dataset:{},className:'',setAttribute(){},focus(){},showModal(){this.open=true;},close(){this.open=false;}});return nd.get(id);};
    nn('#chart-host').clientWidth=host;
    // The fake DOM does not parse HTML: mirror the chart block that render() puts in #view into #chart-host (as check-v4 does).
    {const v=nn('#view');let cur='';Object.defineProperty(v,'innerHTML',{get(){return cur;},set(x){cur=x;const i=x.indexOf('<div id="chart-host">'),j=x.indexOf('</div></div><div class="usage-foot">');nn('#chart-host').innerHTML=i>=0&&j>i?x.slice(i+21,j):'';}});}
    const doc={documentElement:{lang:'ko',dataset:{},clientWidth:width},title:'',activeElement:null,querySelector:nn,querySelectorAll(){return[];},addEventListener(n,f){ls[n]=f;}};
    vm.runInNewContext(sc,{document:doc,Intl,Date,Map,Set,console});
    const clk=(ds={},id='')=>ls.click({target:{closest(){return {dataset:ds,id,getAttribute(){return null;}};}}});
    return {doc,ls,nn,clk,chg:(id,value)=>ls.change({target:{id,value}}),view:()=>nn('#view').innerHTML,body:()=>nn('#dialog-body').innerHTML};
  }
  const text=h=>h.replace(/<svg[\s\S]*?<\/svg>/g,' ').replace(/<[^>]+>/g,' ').replace(/\s+/g,' ').trim();
  // --- 1) first screen carries no long explanation or detail lines (desktop and mobile, KO and EN)
  for(const [label,opt] of [['desktop',{host:700}],['mobile',{width:390,host:340}]]){
    const e=env(opt);
    for(const lang of ['ko','en']){
      e.clk({lang});let v=e.view();const tx=text(v);
      for(const bad of ['정확한 합계','Exact total','기록일 평균','Per recorded day','최신 기록일','Latest recorded day','집계 규칙','Counting rule','출처별 확인 상태','Source status','전체 출처 보기','View all sources','주의','일부 기록만 더한 값','This total uses partial','캐시 읽기','Cache read','token-parts','source-summary','quota-alert','scope-line','exact-latest','기록 기준','Collected'])
        assert.ok(!v.includes(bad)&&!tx.includes(bad),label+' '+lang+' overview must not show: '+bad);
      assert.ok(tx.length<420,label+' '+lang+' overview text stays short ('+tx.length+')');
      assert.ok(!e.nn('#controls').innerHTML.includes('수집:')&&!e.nn('#controls').innerHTML.includes('Collected:')&&!e.nn('#controls').innerHTML.includes('id="coverage"'));
      assert.equal(e.nn('#scope-button').hidden,true,'scope button is not repeated on overview');
      assert.ok(v.includes('data-usage="1"'),'single details entry');
      assert.equal((v.match(/data-usage=/g)||[]).length,1);
      assert.ok(e.nn('#footer').innerHTML.length<220&&!/위젯|widget/i.test(e.nn('#footer').innerHTML),'footer has no implementation notes');
    }
    e.clk({lang:'ko'});
  }
  // --- 2) partial is decided from the rows, not only from the dataset status; unknown coverage and no-record states stay visible
  {
    const e=env({host:700});
    assert.equal(claude.coverage.status,'complete_for_selected_source');
    assert.ok(e.view().includes('class="partial-chip">일부 기록<'),'dataset complete but newest day partial -> chip next to the number');
    assert.ok(e.view().indexOf('main-value')<e.view().indexOf('partial-chip')&&e.view().indexOf('partial-chip')<e.view().indexOf('period-caption'));
    e.clk({lang:'en'});assert.ok(e.view().includes('class="partial-chip">Partial<'));e.clk({lang:'ko'});
    e.clk({period:'30d'});e.clk({usage:'1'});assert.ok(e.body().includes('일부 기록만 더한 값이에요'),'partial explanation moved to details');e.clk({},'dialog-close');
    // dataset with unknown coverage
    e.clk({provider:'codex'});assert.ok(e.view().includes('범위 미확인'));
    // stale: nothing recorded in the period -> no number is invented, no zero, last record date and a way forward
    e.clk({provider:'grok'});const v=e.view();
    assert.ok(v.includes('is-unavailable')&&v.includes('확인 불가')&&!/main-value num"[^>]*>0</.test(v));
    assert.ok(v.includes('사용량이 0이라는 뜻은 아니에요')&&v.includes('data-period="last30"')&&!v.includes('class="partial-chip"'));
    assert.ok(K.sum(K.days(stale,'7d'))===null);
  }
  // --- 3) every removed number is reachable in details with the same value (no new summing rule)
  {
    const e=env({host:700});e.clk({period:'30d'});
    const rows=K.days(claude,'30d'),total=K.sum(rows),known=rows.filter(r=>typeof r.tokens==='number');
    e.clk({usage:'1'});const b=e.body();
    assert.ok(b.includes('<dt>정확한 합계</dt><dd><strong class="num">'+total.toLocaleString('ko-KR')+'</strong>'));
    assert.ok(b.includes('data-copy="total"')&&b.includes('data-text="'+total+'"'));
    assert.ok(b.includes('<dt>기록일 평균</dt>')&&b.includes('<dt>최신 기록일</dt>')&&b.includes('<dt>기록된 날</dt><dd class="num">'+known.length+' / '+rows.length+'</dd>'));
    for(const [k,name] of [['input','입력'],['cacheRead','캐시 읽기'],['cacheCreate','캐시 생성'],['output','출력'],['reasoning','추론']]){
      const sum=K.sum(rows,k);const m=b.match(new RegExp('<dt>'+name+'</dt><dd class="num">([^<]*(?:<span class="na"[\\s\\S]*?</span></span>)?)'));assert.ok(m,name);
      if(sum===null)assert.ok(m[1].includes('class="na"'),name+' unknown is not zero');else assert.ok(m[1].startsWith(sum.toLocaleString('ko-KR')),name);
    }
    assert.ok(b.includes('전체 토큰 = 입력 + 출력 + 캐시 읽기')&&b.includes('합계에 포함'));
    assert.ok(b.includes('기록 없음은 0이 아니에요')&&b.includes('출처 3개')&&b.includes('서로 다른 출처는 합산하지 않아요'));
    assert.ok(b.includes('data-view="records"')&&b.includes('data-view="sources"'));
    assert.ok(b.includes('출처와 수집 범위')&&b.includes('수집 시각')&&b.includes('마지막 사용 이벤트'),'source details are inside usage details');
    // scale lives in details and still works
    assert.ok(b.includes('id="scale"')&&!e.view().includes('id="scale"'));
    e.chg('scale','log');assert.ok(e.body().includes('<option value="log" selected>'));
    // switching to another page closes the modal
    e.clk({view:'records'});assert.equal(e.nn('#detail-dialog').open,false);
    e.clk({view:'overview'});e.clk({lang:'en'});e.clk({usage:'1'});assert.ok(e.body().includes('Exact total')&&e.body().includes('Latest recorded day')&&e.body().includes('Token parts'));e.clk({},'dialog-close');
  }
  // --- 4) remaining quota panel
  {
    const e=env({host:700});let v=e.view();
    const panel=v.slice(v.indexOf('id="quota-panel"'));
    assert.ok(panel.includes('남은 한도')&&panel.includes('저장된 값 / ')&&/경과/.test(panel));
    assert.equal((panel.match(/class="quota-row"/g)||[]).length,2);
    assert.ok(!panel.includes('provider-logo'),'no provider logo repeated per row');
    assert.ok(!panel.includes('계정 한도')&&!panel.includes('합산하지 않아요')&&!panel.includes('강조해요'),'no explanatory prose in the panel');
    assert.equal((panel.match(/quota-value num warning/g)||[]).length,1);assert.ok(panel.includes('track warning')&&!panel.includes('5% 이하'));
    assert.ok(/<div class="quota-value num">96%/.test(panel)&&panel.includes('style="width:96%"'));
    assert.ok(/초기화 [^<]+/.test(panel),'short reset time when known');
    assert.ok(!panel.includes('확인:')&&!panel.includes('2026'),'exact timestamps and year are not on the first screen');
    e.clk({usage:'1'});const b=e.body();
    assert.ok(/확인: [^<]*2026[^<]*경과/.test(b)&&b.includes('초기화: ')&&b.includes('출처: test_probe')&&b.includes('실시간 상태나 예측이 아니고'));e.clk({},'dialog-close');
    // no limit for the service: one line only
    const e2=env({host:700});e2.clk({provider:'codex'});v=e2.view();const p2=v.slice(v.indexOf('id="quota-panel"'));
    assert.ok(p2.includes('한도 미확인')&&!p2.includes('quota-row')&&!p2.includes('track')&&!p2.includes('저장된 값'));
    e2.clk({lang:'en'});assert.ok(e2.view().includes('Limit unknown')&&e2.view().includes('Remaining quota'));
  }
  // --- 5) chart: no sideways scrolling needed on mobile; current page vs whole period is short and unambiguous
  for(const w of [200,240,320,340,390]){
    const e=env({width:w+50,host:w});
    for(const p of ['7d','30d','all']){
      e.clk({period:p});const h=e.nn('#chart-host').innerHTML;
      assert.ok(h.includes('<svg class="chart" width="'+w+'"')&&h.includes('style="width:100%')&&!h.includes('scroll-hint')&&!/min-width:\s*[1-9]/.test(h),'w'+w+' '+p+' fits host');
      const vb=h.match(/viewBox="0 0 (\d+) /);assert.equal(Number(vb[1]),w);
      assert.ok(!h.includes('chart-note')||h.includes('위 합계는 전체'));
    }
    e.clk({period:'30d'});assert.ok(e.nn('#chart-host').innerHTML.includes('전체 30일 중 7일')&&e.nn('#chart-host').innerHTML.includes('위 합계는 전체 30일'));
    assert.ok(e.nn('#chart-host').innerHTML.includes('data-chart-page="older"')&&e.nn('#chart-host').innerHTML.includes('data-chart-page="newer"'));
    assert.ok(!e.nn('#chart-host').innerHTML.includes('class="legend"'),'no cryptic legend');assert.ok(e.nn('#chart-host').innerHTML.includes('data-display=')&&e.nn('#chart-host').innerHTML.includes('is-selected'),'selected bar and readable value are linked');
  }
  {
    const e=env({width:390,host:340});e.clk({lang:'en'});e.clk({period:'30d'});
    assert.ok(e.nn('#chart-host').innerHTML.includes('Showing 7 of 30 days')&&e.nn('#chart-host').innerHTML.includes('Total above: all 30 days'));
    assert.ok(!/Select a bar or use the arrow keys|Scroll sideways/.test(e.view()));
    assert.ok((e.view().includes('Daily usage')||e.view().includes('Daily new tokens'))&&!e.view().includes('Select a bar for its value'),'show a named chart and actual value instead of instructions');
    for(let i=0;i<4;i++)e.clk({chartPage:'older'});
    assert.ok(e.nn('#chart-host').innerHTML.includes('class="missing-label"')&&!e.nn('#chart-host').innerHTML.includes('<path class="missing"'),'missing records use words, not cryptic marks');
  }
  // Every recorded bar has an always-visible amount; missing dates never receive a zero label.
  {
    const e=env({width:320,host:250});
    assert.equal((e.nn('#chart-host').innerHTML.match(/class="bar-value"/g)||[]).length,7);
    assert.ok(e.nn('#chart-host').innerHTML.includes('>44</text>'));   // new tokens: 48 total minus 4 cache re-read
    assert.ok(e.view().includes('class="chart-unit">토큰</span>')&&e.view().includes('class="chart-readout sr"'));
    assert.equal((e.nn('#chart-host').innerHTML.match(/class="chart-date"/g)||[]).length,7);
    assert.ok(!/class="bar-value"[^>]*>[\s\S]*?<tspan/.test(e.nn('#chart-host').innerHTML));
    e.clk({period:'30d'});for(let i=0;i<4;i++)e.clk({chartPage:'older'});
    const h=e.nn('#chart-host').innerHTML;
    assert.equal((h.match(/class="bar-value"/g)||[]).length,1);
    assert.ok(h.includes('class="missing-label"')&&!h.includes('>0</text></g>'));
  }
  // Immediate hover, tap and keyboard tooltip; no native delayed title or full-column highlight.
  {
    const e=env({width:390,host:340}),tip=e.nn('#chart-tooltip'),area=e.nn('.chart-area');
    Object.assign(tip,{hidden:true,style:{},offsetWidth:180,offsetHeight:60});
    Object.assign(area,{clientWidth:260,getBoundingClientRect:()=>({left:100,top:100})});
    const g={dataset:{date:'2026-10-29',readout:'full accessible value',display:'10월 29일 / 48 토큰 / 일부 기록'},attrs:{},setAttribute(k,v){this.attrs[k]=v;},getBoundingClientRect:()=>({left:340,top:180,width:20,height:80}),contains(x){return x===this;}};
    const target={closest:()=>g};
    e.ls.pointerover({target,pointerType:'mouse'});
    assert.equal(tip.hidden,false);assert.equal(tip.textContent,'10월 29일\n48 토큰\n일부 기록');assert.equal(tip.style.left,'76px');assert.equal(g.attrs['aria-describedby'],'chart-tooltip');
    e.ls.pointerout({target,relatedTarget:null});assert.equal(tip.hidden,true);
    e.ls.pointerover({target,pointerType:'touch'});assert.equal(tip.hidden,true,'touch panning must not open a tooltip');
    e.ls.click({target});assert.equal(tip.hidden,false,'tap/click opens the value');
    e.ls.scroll();assert.equal(tip.hidden,true);
    e.ls.focusin({target:g});assert.equal(tip.hidden,false);
    e.ls.keydown({key:'Escape',target:g});assert.equal(tip.hidden,true);
    assert.ok(!e.nn('#chart-host').innerHTML.includes('<title>'),'no second delayed browser tooltip');
  }
  // --- 6) CSS and markup guards: the shared mobile controls grid, no hidden-overflow hacks, tabular figures, no fixed chart height tricks added
  {
    const css=fs.readFileSync(require('node:path').join(__dirname,'v2.css'),'utf8'),v5=css.slice(css.indexOf('/* v5:'));
    assert.ok(v5.length>200&&!/overflow-x\s*:\s*(hidden|clip)|scrollbar-width\s*:\s*none|::-webkit-scrollbar\s*\{[^}]*(?:display\s*:\s*none|width\s*:\s*0(?:px)?[;}])|[{;]min-width:\s*[1-9]\d{2}px/.test(v5));
    assert.ok(/\.source-controls\.v5\{display:grid;grid-template-columns:minmax\(0,1fr\) minmax\(0,1fr\)/.test(v5)&&/font-variant-numeric:tabular-nums/.test(v5));
    assert.ok(!/\.usage-panel\{[^}]*(?:^|[^-])height:\d/.test(v5),'no fixed height on the usage panel');
    assert.ok(css.includes('.chart .bar.partial{fill:var(--bar);stroke:none;stroke-dasharray:none}'),'partial records use solid measured bars, not dotted outlines');
    assert.ok(css.includes('.chart g.is-selected .bar{fill:var(--brand)}'),'selection has a visible matching highlight');
    assert.ok(!css.includes('.chart g.is-selected .hit')&&!css.includes('.chart g:focus-visible .hit'),'hit target must not look like another data bar');
    const scrollCss=css.split('/* Mobile vertical scrollbar:')[1];
    assert.ok(scrollCss.includes('@media (max-width:820px) and (forced-colors:none)'),'custom scrollbar is mobile-only and respects high contrast');
    assert.ok(scrollCss.includes('width:4px')&&scrollCss.includes('min-height:32px')&&scrollCss.includes('scrollbar-width:thin'),'scrollbar remains visible and usable');
    assert.ok(!/overflow\s*:|touch-action\s*:|scrollbar-width\s*:\s*none/.test(scrollCss),'native content scrolling is untouched');
  }
  // --- 7) other screens keep their own focus and the AI screen is still separate
  {
    const e=env({host:700});
    e.clk({view:'ai'});assert.equal(e.nn('#controls').hidden,true);assert.ok(e.view().includes('id="cmd-cli"')&&e.view().includes('날짜와 사용량이 해당 서비스'));
    e.clk({view:'sources'});assert.ok(e.view().includes('전체 출처 목록 3개')&&e.nn('#scope-button').hidden===false);
    e.clk({},'scope-button');assert.equal(e.nn('#detail-dialog').open,true);assert.ok(!e.body().includes('id="scale"'),'source detail dialog is unchanged');e.clk({},'dialog-close');
  }
};
