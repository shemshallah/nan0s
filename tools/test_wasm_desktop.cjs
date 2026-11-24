'use strict';
// Browser-only acceptance gate: actual v86 WASM boots the full native disk.
const assert = require('node:assert/strict');
const { chromium } = require('playwright');
const fs = require('node:fs');
(async () => {
  const browser = await chromium.launch({headless:true,args:['--no-sandbox']});
  try {
    const page = await browser.newPage({viewport:{width:393,height:852},deviceScaleFactor:1,
      isMobile:true,hasTouch:true});
    const errors=[];
    page.on('pageerror', e => errors.push(String(e)));
    await page.goto('http://127.0.0.1:8765/',{waitUntil:'domcontentloaded'});
    const canvas=page.locator('#screen_container canvas');
    await page.waitForFunction(() => {
      const c=document.querySelector('#screen_container canvas');
      return c && c.width>=640 && c.height>=400 && getComputedStyle(c).display!=='none';
    },{},{timeout:90000});
    await page.waitForFunction(() => document.querySelector('#status').textContent.includes('boot banner'),{},{timeout:90000});
    await page.waitForTimeout(1500);
    const sample=()=>canvas.evaluate(c => {
      const ctx=c.getContext('2d');
      // Guest terminal title + upper body, excluding the clock and pointer.
      return Array.from(ctx.getImageData(65,40,300,115).data);
    });
    const before=await sample();
    const unique=new Set();
    for(let i=0;i<before.length;i+=4)unique.add(before.slice(i,i+3).join(','));
    assert.ok(unique.size>=4,'Guest framebuffer must contain rendered window chrome and text');
    const fit=await canvas.evaluate(c=>({canvas:c.getBoundingClientRect().width,container:c.parentElement.clientWidth}));
    assert.ok(fit.canvas<=fit.container+2,'First graphics frame must fit the phone viewport');
    fs.mkdirSync('browser-evidence',{recursive:true});
    await page.screenshot({path:'browser-evidence/phone-boot.png',fullPage:true});
    // Tapping the host IME must not turn into a guest mouse click or reset.
    await page.locator('#type').tap();
    await page.waitForTimeout(300);
    const after=await sample();
    assert.deepEqual(after,before,'Host IME tap changed stable guest terminal pixels');
    await page.locator('#function-keys button').filter({hasText:/^F1$/}).tap();
    await page.waitForTimeout(600);
    await page.screenshot({path:'browser-evidence/phone-launcher.png',fullPage:true});
    const launcher=await canvas.evaluate(c=>Array.from(c.getContext('2d').getImageData(180,120,640,420).data));
    await page.locator('#function-keys button').filter({hasText:/^F1$/}).tap();
    await page.waitForTimeout(600);
    const closed=await canvas.evaluate(c=>Array.from(c.getContext('2d').getImageData(180,120,640,420).data));
    let changed=0;
    for(let i=0;i<closed.length;i+=4)if(closed[i]!==launcher[i]||closed[i+1]!==launcher[i+1]||closed[i+2]!==launcher[i+2])changed++;
    assert.ok(changed>10000,'Guest F1 launcher did not open and dismiss through mobile controls');
    assert.deepEqual(errors,[],'Unexpected browser runtime error');
    console.log('PASS: real Chromium/v86 WASM mobile boot, fit, stable IME tap, native F1 open/dismiss');
  } finally { await browser.close(); }
})().catch(e=>{console.error(e);process.exitCode=1;});
