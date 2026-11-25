/* Select 64-bit only after the real browser acceptance gate publishes its manifest.
 * The original player remains available at ?arch=32. */
(() => {
  if(new URLSearchParams(location.search).get("arch")==="32") return;
  fetch("wasm64/verified.json",{cache:"no-store"}).then(r=>r.ok?r.json():null).then(m=>{
    if(m&&m.arch==="x86_64"&&m.browserGate==="pass")location.replace("wasm64.html");
  }).catch(()=>{});
})();
