# Agent reports

Each frontier-loop agent writes `spec/agents/<agent>.md` with:

- the F item and files changed;
- the exact gate command and transcript;
- any regression gates run;
- 2-4 frontier capability ideas and proposed next directives.

Do not edit another agent's report. Append tasklist directives only through
`tools/tasklist_append.sh` so the insert is serialized.
