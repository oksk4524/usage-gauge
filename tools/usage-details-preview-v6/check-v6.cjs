'use strict';
// Unit/markup checks only. Quota line wrapping, disclosure state and scroll reset also need browser verification.
module.exports=({assert,fs,vm})=>{
 const path=require('node:path'),src=fs.readFileSync(path.join(__dirname,'client.cjs'),'utf8'),css=fs.readFileSync(path.join(__dirname,'v2.css'),'utf8');
 const line=name=>src.split('\n').find(l=>l.includes('function '+name+'(')).trim();
 const ctx={Intl,lang:'ko',locale:()=> 'ko-KR',mob:()=>false,chartW:757};
 const amount=vm.runInNewContext('('+line('chartAmount')+')',ctx);
 assert.equal(amount(764807),'76.5만');assert.equal(amount(564087),'56.4만');assert.equal(amount(483783),'48.4만');
 assert.equal(amount(144716762),'1.4억');assert.equal(amount(60107633),'6천만');assert.equal(amount(0),'0');assert.notEqual(amount(.0001),'0');
 const per=vm.runInNewContext('('+line('chartPer')+')',ctx);assert.equal(per(30),15);assert.equal(per(7),7);
 ctx.chartW=620;assert.equal(per(30),10);ctx.mob=()=>true;ctx.PER=7;assert.equal(per(30),7);
 assert.ok(/quota-row \.quota-value\{[^}]*white-space:nowrap/.test(css));
 assert.ok(/function openDetails[^\n]*fillDialog\(true\)[^\n]*scrollTop=0[^\n]*showModal\(\)[^\n]*scrollTop=0/.test(src));
 for(const key of ['parts','limits','scale','source'])assert.ok(src.includes('data-detail-group="'+key+'"'));
 assert.ok(src.includes('[data-detail-group][open]'));
 assert.ok(src.includes('records-unsupported')&&src.includes('rows.some(r=>C.number(r[k]))'));
 console.log('PASS v6: distinct small values, adaptive PC capacity, quota nowrap, modal reset and retained disclosures.');
};
