# Frontier agent state

Dispatch cap: 2 agents at a time.
Slot A: nmanifest (F16) session ses_de2bbb422ffeQehybv6szM9vSm
Slot B: ngold     (F18) session ses_de2f83937ffePirUrkeMd4dZki
Completed: F1 smpblock 9985ea4; F2 nansched 49905d8; F3 nnuma 01f36fe;
           F4 ncscale ef07f18; F5 nagent 1f8db01; F6 nkv a5d7a30;
           F7 model 5e13def+c141041; F8 nreplay 7029529; F9 nsecure 33f2686;
           F10 naccel c141041; F11 fabric c7daec9; F12 nobs b3bdf75;
           F13a npaged 8d78660; F13b nspec 3f24333; F13c nspectree 7afcea8;
           F13d nmoe 7344af2; F13e ngen 30d928e; F13f nsym a1d347b;
           F13g nkvgen e59b36c; F13h nkvtree 8ef3592; F13i nkvdag f656850;
           F14 nverify 23bb7dd; F15 product ec6db62; F17 rawsmp 592df0e.
Started: 2026-11-27
Loop: background-result returns or 30-minute automation tick. When both
slots have passing reports: commit, mark F items, then dispatch the next two
open items from spec/MASTER_TASKLIST.md.
Rules: raw .nas/.nan product only; zero C outside src/tests; two agents max.
Automation: aut_21b3164ea001zKdsRpkr9gJMq2 (30 min, expires 2026-11-27T04:09-08:00)
