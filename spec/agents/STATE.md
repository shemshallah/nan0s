# Frontier agent state

Dispatch cap: 2 agents at a time.
Slot A: nsecure (F9)  session ses_de46e3bf1ffej5rWdiGp4d3Rg4
Slot B: nattn   (F7b) session ses_de454c0caffeY04PX4KKTFyjkr
Completed: F3 nnuma 01f36fe; F1 smpblock 9985ea4; F2 nansched 49905d8;
           F4 ncscale ef07f18; F5 nagent 1f8db01; F6 nkv a5d7a30;
           F8 nreplay 7029529; F7 partial 5e13def (GGUF/tokenizer/GEMV/token gate).
Started: 2026-11-26
Loop: background-result returns or 30-minute automation tick. When both
slots have passing reports: commit, mark F items, then dispatch the next two
open items from spec/MASTER_TASKLIST.md.
Rules: raw .nas/.nan product only; zero C outside src/tests; two agents max.
Automation: aut_21b3164ea001zKdsRpkr9gJMq2 (30 min, expires 2026-11-27T04:09-08:00)
