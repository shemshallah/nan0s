# Frontier agent state

Dispatch cap: 2 agents at a time.
Slot A: nagent (F5) session ses_de49d7e40ffetGywV14cFvN4P9
Slot B: nkv    (F6) session ses_de4991ebaffeuHvFX761Qpib6L
Completed: F3 nnuma 01f36fe; F1 smpblock 9985ea4; F2 nansched 49905d8;
           F4 ncscale ef07f18.
Started: 2026-11-26
Loop: background-result returns or 30-minute automation tick. When both
slots have passing reports: commit, mark F items, then dispatch the next two
open items from spec/MASTER_TASKLIST.md.
Rules: raw .nas/.nan product only; zero C outside src/tests; two agents max.
Automation: aut_21b3164ea001zKdsRpkr9gJMq2 (30 min, expires 2026-11-27T04:09-08:00)
