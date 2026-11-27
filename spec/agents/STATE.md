# Frontier agent state

Dispatch cap: 2 agents at a time.
Slot A: nkvgen (F13g) session ses_de3386e37ffeclyJXlRjKwc3To
Slot B: rawsmp (F17)  session ses_de32e3ac8ffeOYFXOdwJrAEaQb
Completed: F1 smpblock 9985ea4; F2 nansched 49905d8; F3 nnuma 01f36fe;
           F4 ncscale ef07f18; F5 nagent 1f8db01; F6 nkv a5d7a30;
           F7 model 5e13def+c141041; F8 nreplay 7029529; F9 nsecure 33f2686;
           F10 naccel c141041; F11 fabric c7daec9; F12 nobs b3bdf75;
           F13a-g in progress; F14 nverify 23bb7dd; F15 product ec6db62.
Started: 2026-11-27
Loop: background-result returns or 30-minute automation tick. When both
slots have passing reports: commit, mark F items, then dispatch the next two
open items from spec/MASTER_TASKLIST.md.
Rules: raw .nas/.nan product only; zero C outside src/tests; two agents max.
Automation: aut_21b3164ea001zKdsRpkr9gJMq2 (30 min, expires 2026-11-27T04:09-08:00)
