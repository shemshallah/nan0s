/* WASM host adapter only. The x86-64 S1 executes the unmodified NaN ISA;
 * this code transfers physical indexed VRAM and injects raw PS/2 bytes. */
(() => {
"use strict";
const $=id=>document.getElementById(id), canvas=$("guest"), ctx=canvas.getContext("2d",{alpha:false});
const BASE=0x200000+0xE8000*8, VRAM=0x11000000, GUEST=0x4E363447, HOST=0x4E363457;
let vm, ready=false, queue=[], head=0, mirror="", prior=null, frame, palette, tick=0;
const status=s=>$("status").textContent=s;
function word(v){const a=new Uint8Array(8);a.set([0x7f,0xf8]);new DataView(a.buffer).setUint32(2,v>>>0,true);a.set([0xf8,0x7f],6);return a;}
function read(i){const a=vm.read_memory(BASE+i*8,8);return new DataView(a.buffer,a.byteOffset,a.byteLength).getUint32(2,true);}
function write(i,v){vm.write_memory(word(v),BASE+i*8);}
function enqueue(a){if(ready)queue.push(...a);}
function key(k,shift=false,ext=false){const a=[];if(shift)a.push(42);if(ext)a.push(224);a.push(k);if(ext)a.push(224);a.push(k|128);if(shift)a.push(170);enqueue(a);}
const chars={a:30,b:48,c:46,d:32,e:18,f:33,g:34,h:35,i:23,j:36,k:37,l:38,m:50,n:49,o:24,p:25,q:16,r:19,s:31,t:20,u:22,v:47,w:17,x:45,y:21,z:44,"1":2,"2":3,"3":4,"4":5,"5":6,"6":7,"7":8,"8":9,"9":10,"0":11,"-":12,"=":13,"[":26,"]":27,"\\":43,";":39,"'":40,"`":41,",":51,".":52,"/":53," ":57};
const shifted={"!":"1","@":"2","#":"3","$":"4","%":"5","^":"6","&":"7","*":"8","(":"9",")":"0","_":"-","+":"=","{":"[","}":"]","|":"\\",":":";","\"":"'","~":"`","<":",",">":".","?":"/"};
function type(c){if(c==="\n"){key(28);return;} if(c==="\t"){for(let i=0;i<4;i++)key(57);return;}const low=c.toLowerCase(), k=chars[shifted[c]||low];if(k!==undefined)key(k,!!shifted[c]||low!==c);}
function sync(){const v=$("type").value;let i=0;while(i<mirror.length&&i<v.length&&mirror[i]===v[i])i++;for(let j=i;j<mirror.length;j++)key(14);for(const c of v.slice(i))type(c);mirror=v;if(v.includes("\n")){$("type").value=mirror=v.slice(v.lastIndexOf("\n")+1);}}
function enter(){sync();key(28);$("type").value=mirror="";}
$("type").addEventListener("input",sync);
$("type").addEventListener("compositionend",sync);
$("type").addEventListener("beforeinput",e=>{if(e.inputType==="insertLineBreak"||e.inputType==="insertParagraph"){e.preventDefault();enter();}});
$("type").addEventListener("keydown",e=>{e.stopPropagation();if(e.isComposing)return;if(e.key==="Enter"){e.preventDefault();enter();}else if(e.key==="Backspace"&&!mirror){e.preventDefault();key(14);}else if(e.key==="Escape"||e.key==="Tab"){e.preventDefault();key(e.key==="Escape"?1:15);}});
$("clear").onclick=()=>{$("type").value=mirror="";$("type").focus({preventScroll:true});};
$("enter").onclick=enter;
$("restart").onclick=()=>location.reload();
for(const [label,k,ext] of [["Esc",1],["Tab",15],["F1",59],["F2",60],["F3",61],["F5",63],["F6",64],["F7",65],["↑",72,true],["↓",80,true],["←",75,true],["→",77,true]]){const b=document.createElement("button");b.textContent=label;b.disabled=true;b.onclick=()=>key(k,false,!!ext);$("keys").append(b);}
function touch(x,y,button){let w=(button<<24)|(y<<12)|x,a=[224,127];for(let i=6;i>=0;i--)a.push(96+((w>>>(i*4))&15));enqueue(a);}
canvas.addEventListener("pointerdown",e=>{if(!ready)return;e.preventDefault();const b=canvas.getBoundingClientRect(),x=Math.max(0,Math.min(canvas.width-1,Math.floor((e.clientX-b.left)*canvas.width/b.width))),y=Math.max(0,Math.min(canvas.height-1,Math.floor((e.clientY-b.top)*canvas.height/b.height)));touch(x,y,1);touch(x,y,0);});
function pump(){if(!ready)return;const tail=read(2);let count=Math.min(queue.length,256-((head-tail)>>>0));if(count<=0)return;while(count--){write(16+(head&255),queue.shift());head=(head+1)>>>0;}write(3,head);}
function paint(){try{if(!ready){if(read(0)!==GUEST){requestAnimationFrame(paint);return;}head=read(3);write(1,HOST);ready=true;status("x86-64 S1 guest desktop running");for(const b of [$("type"),$("clear"),$("enter"),...$("keys").children])b.disabled=false;}
pump();if(++tick%2===0){const dims=read(4),w=dims>>>16,h=dims&65535;if(w>=320&&h>=200&&w*h<=2000000){if(canvas.width!==w||canvas.height!==h){canvas.width=w;canvas.height=h;frame=null;prior=null;}if(!frame)frame=ctx.createImageData(w,h);const fb=vm.read_memory(VRAM,w*h),p=frame.data;let start=-1;for(let y=0;y<h;y++){let changed=false;for(let x=0;x<w;x++){const i=y*w+x;if(prior&&prior[i]===fb[i])continue;const c=palette[fb[i]],j=i*4;p[j]=c[0];p[j+1]=c[1];p[j+2]=c[2];p[j+3]=255;changed=true;}if(changed&&start<0)start=y;if(!changed&&start>=0){ctx.putImageData(frame,0,0,0,start,w,y-start);start=-1;}}if(start>=0)ctx.putImageData(frame,0,0,0,start,w,h-start);prior=Uint8Array.from(fb);}}requestAnimationFrame(paint);}catch(e){status("S1 transport error: "+e.message);}}
async function start(){try{if(typeof V86!=="function")throw Error("64-bit runtime not published yet");const get=async p=>{const r=await fetch("wasm64/"+p,{cache:"no-store"});if(!r.ok)throw Error(p+" HTTP "+r.status);return r;};const [fda,hda,pal]=await Promise.all([get("boot64.img").then(r=>r.arrayBuffer()),get("system64.img").then(r=>r.arrayBuffer()),get("palette.json").then(r=>r.json())]);palette=pal;vm=new V86({wasm_path:"wasm64/v86.wasm",memory_size:512*1024*1024,vga_memory_size:2*1024*1024,bios:{url:"wasm64/seabios.bin"},vga_bios:{url:"wasm64/vgabios.bin"},fda:{buffer:fda},hda:{buffer:hda},boot_order:0x321,autostart:true,disable_keyboard:true,disable_mouse:true});vm.add_listener("serial0-output-byte",b=>{$("serial").textContent+=String.fromCharCode(b);});vm.add_listener("emulator-ready",()=>{status("64-bit CPU started; waiting for native GUI mailbox…");requestAnimationFrame(paint);});setTimeout(()=>{if(!ready)status("64-bit guest has not reached its GUI mailbox. See serial output.");},90000);}catch(e){status("64-bit boot unavailable: "+e.message);}}
start();
})();
