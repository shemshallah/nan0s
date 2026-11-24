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
    // Actual touch must drive the guest, not the host DOM. Convert test
    // guest pixels to the current mobile canvas rectangle and tap.
    await canvas.evaluate(c=>c.scrollIntoView({block:'center',inline:'center'}));
    async function tapGuest(x,y) {
      const point=await canvas.evaluate((c,p)=>{
        const b=c.getBoundingClientRect();
        return [b.left+p[0]*b.width/c.width,b.top+p[1]*b.height/c.height];
      },[x,y]);
      await page.touchscreen.tap(point[0],point[1]);
      await page.waitForTimeout(1000);
    }
    async function region(x,y,w,h) {
      return canvas.evaluate((c,p)=>Array.from(c.getContext('2d').getImageData(...p).data),[x,y,w,h]);
    }
    function diff(a,b) {
      let n=0;
      for(let i=0;i<a.length;i+=4)if(a[i]!==b[i]||a[i+1]!==b[i+1]||a[i+2]!==b[i+2])n++;
      return n;
    }
    const terminal=await region(65,57,545,320);
    await tapGuest(560,48);
    const minimized=await region(65,57,545,320);
    assert.ok(diff(terminal,minimized)>10000,'Touch minimize must hide even the only window');
    await tapGuest(190,750);
    const restored=await region(65,57,545,320);
    assert.ok(diff(minimized,restored)>10000,'Touch taskbar must restore minimized terminal');
    await tapGuest(583,48);
    const max=await region(640,60,300,300);
    assert.ok(diff(max,await region(640,60,300,300))<100,'Maximized terminal must remain stable');
    await tapGuest(983,25);
    const normal=await region(640,60,300,300);
    assert.ok(diff(max,normal)>10000,'Touch maximize and restore must change the work area');
    await tapGuest(607,48);
    const gone=await region(65,57,545,320);
    assert.ok(diff(restored,gone)>10000,'Touch X must close terminal');
    await page.waitForTimeout(1300);
    assert.ok(diff(gone,await region(65,57,545,320))<100,'Closed window must not revive');
    // Open Utilities directly through the guest launcher, then verify that
    // a timer changes its numeric fields without disturbing its static area.
    await page.locator('#function-keys button').filter({hasText:/^F1$/}).tap();
    await page.waitForTimeout(800);
    await canvas.evaluate(c=>c.scrollIntoView({block:'center',inline:'center'}));
    await tapGuest(570,410);
    const staticArea=await region(245,63,275,57);
    const live=await region(275,127,300,25);
    await page.waitForTimeout(1600);
    assert.deepEqual(await region(245,63,275,57),staticArea,'Utility timer must preserve static labels');
    assert.ok(diff(live,await region(275,127,300,25))>0,'Utility timer must update live numeric fields');
    // Watch the actual framebuffer at browser animation-frame cadence.
    // The native cursor must remain visible across live-value updates and
    // wallpaper/title pixels must not flash while the timer is running.
    await tapGuest(500,127);
    const temporal=await canvas.evaluate(c=>new Promise((resolve,reject)=>{
      const ctx=c.getContext('2d',{willReadFrequently:true});
      const rect=(x,y,w,h)=>ctx.getImageData(x,y,w,h).data;
      const staticRef=rect(245,63,275,57);
      const wallpaperRef=rect(880,550,80,60);
      const same=(a,b)=>a.length===b.length && a.every((v,i)=>v===b[i]);
      const patch=rect(496,123,21,21);
      const rgb=(p,x,y)=>{const i=(y*21+x)*4;return [p[i],p[i+1],p[i+2]];};
      const bright=v=>v.every(x=>x>200);
      const dark=v=>v.every(x=>x<45);
      let anchor=null;
      for(let y=1;y<=7&&!anchor;y++)for(let x=1;x<=7&&!anchor;x++){
        if(bright(rgb(patch,x+2,y+4))&&bright(rgb(patch,x+3,y+5))&&
           bright(rgb(patch,x+3,y+10))&&dark(rgb(patch,x,y+4))&&
           dark(rgb(patch,x+4,y+4))&&dark(rgb(patch,x+4,y+10)))anchor=[x,y];
      }
      if(!anchor){reject(new Error('Could not locate native cursor over utility field'));return;}
      const points=[];
      for(let y=0;y<13;y++)for(let x=0;x<11;x++){
        if((y<9&&x<=y)||(y>=9&&x>=2&&x<=4))points.push([x,y]);
      }
      const signature=p=>points.flatMap(([x,y])=>rgb(p,anchor[0]+x,anchor[1]+y));
      const initial=signature(patch);
      let frames=0,cursorFlashes=0,staticFlashes=0,wallpaperFlashes=0;
      const started=performance.now();
      function frame(){
        frames++;
        if(!same(signature(rect(496,123,21,21)),initial))cursorFlashes++;
        if(!same(rect(245,63,275,57),staticRef))staticFlashes++;
        if(!same(rect(880,550,80,60),wallpaperRef))wallpaperFlashes++;
        if(performance.now()-started<1800)requestAnimationFrame(frame);
        else resolve({frames,cursorFlashes,staticFlashes,wallpaperFlashes});
      }
      requestAnimationFrame(frame);
    }));
    console.log('Temporal framebuffer evidence:',JSON.stringify(temporal));
    assert.ok(temporal.frames>=20,'Temporal gate must sample multiple browser frames');
    assert.equal(temporal.cursorFlashes,0,'Native cursor flickered over changing values');
    assert.equal(temporal.staticFlashes,0,'Static utility pixels flashed during timer updates');
    assert.equal(temporal.wallpaperFlashes,0,'Unrelated wallpaper flashed during timer updates');
    await page.screenshot({path:'browser-evidence/phone-utilities.png',fullPage:true});
        assert.deepEqual(errors,[],'Unexpected browser runtime error');
    console.log('PASS: real Chromium/v86 WASM mobile boot, fit, stable IME tap, native F1 open/dismiss');
  } finally { await browser.close(); }
})().catch(e=>{console.error(e);process.exitCode=1;});
