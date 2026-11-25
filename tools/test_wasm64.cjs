'use strict';
const assert=require('node:assert/strict');
const {chromium}=require('playwright');
(async()=>{const b=await chromium.launch({headless:true,args:['--no-sandbox']});try{
const p=await b.newPage({viewport:{width:393,height:852},isMobile:true,hasTouch:true});
p.on('pageerror',e=>console.error(e));
await p.goto('http://127.0.0.1:8765/wasm64.html');
await p.waitForFunction(()=>document.querySelector('#status').textContent.includes('guest desktop running'),{},{timeout:180000});
const c=p.locator('#guest');
await p.waitForTimeout(1500);
const snap=()=>c.evaluate(el=>{const d=el.getContext('2d').getImageData(60,40,560,320).data;let h=2166136261;const colors=new Set();for(let i=0;i<d.length;i+=4){const v=(d[i]<<16)|(d[i+1]<<8)|d[i+2];colors.add(v);h=Math.imul(h^v,16777619);}return [h,colors.size];});
const a=await snap();assert.ok(a[1]>=4,'native GUI needs multiple palette colors');
await p.locator('#type').fill('h');await p.locator('#enter').tap();
await p.waitForTimeout(2000);
const z=await snap();assert.notEqual(z[0],a[0],'native terminal must respond to mailbox input');
await p.screenshot({path:'wasm64-evidence.png',fullPage:true});
console.log('PASS: native x86-64 boot, indexed framebuffer and terminal keyboard in real v86_64 WASM');
}finally{await b.close();}})().catch(e=>{console.error(e);process.exitCode=1;});
