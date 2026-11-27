# nhost_bundle.awk - build the nhost disk bundle for a source tree.
# Usage: awk -f tools/nhost_bundle.awk -v MAIN=src/gui/gui_sched_boot.nas > bundle.txt
# Emits ;@MAIN plus one ;@FILE marker and the full text per reachable .include.
# nhost expands the includes itself; this only supplies the file set.
function norm(p,  n,a,i,k,s) {
  n = split(p, a, "/"); k = 0
  for (i = 1; i <= n; i++) {
    if (a[i] == "" || a[i] == ".") continue
    if (a[i] == "..") { if (k > 0) k--; continue }
    a[++k] = a[i]
  }
  s = ""
  for (i = 1; i <= k; i++) s = s (i > 1 ? "/" : "") a[i]
  return s
}
function dirof(p,  i) { i = match(p, /\/[^\/]*$/); return i ? substr(p, 1, i) : "" }
function flat(path,  line,s,q,c,i,cut,inc,d,n,incs) {
  path = norm(path)
  if (path in seen) return
  seen[path] = 1
  print ";@FILE " path
  d = dirof(path)
  n = 0
  while ((getline line < path) > 0) {
    sub(/\r$/, "", line)
    print line
    q = 0; cut = length(line) + 1
    for (i = 1; i <= length(line); i++) {
      c = substr(line, i, 1)
      if (c == "\"") q = !q
      else if (c == "\\" && q) i++
      else if (c == ";" && !q) { cut = i; break }
    }
    s = substr(line, 1, cut - 1)
    sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s)
    if (s ~ /^\.include[ \t]+"/) {
      inc = s
      sub(/^\.include[ \t]+"/, "", inc)
      sub(/".*$/, "", inc)
      incs[++n] = d inc
    }
  }
  close(path)
  # Emit the whole parent before its includes: nhost's directory uses the
  # next ;@FILE marker as the end of a file's byte range.
  for (i = 1; i <= n; i++) flat(incs[i])
}
BEGIN { print ";@MAIN " norm(MAIN); flat(MAIN) }
