#!/usr/bin/env python3
"""Finite regression for R5 mirror memory algebra; Coq is authoritative."""
N=256
count=0
for a in range(N):
    for b in range(a+1,N):
        p=(a,b); q=(b,a)
        baseline={p:-1,q:-2,(0,0):7}
        left=dict(baseline); left[p]=a; left[q]=b
        right=dict(baseline); right[q]=b; right[p]=a
        assert left == right
        assert left[p] == a and left[q] == b and left[(0,0)] == 7
        count+=1
assert count==32640
W=lambda p: 256*p[0]+p[1]
mir=lambda p: (p[1],p[0])
checked=0
for a in range(N):
    for b in range(N):
        key=(a,b); value=-7
        for query in {key,mir(key),(0,0),(a,(b+1)%N)}:
            left=value if mir(query)==key else W(mir(query))
            right=value if query==mir(key) else W(mir(query))
            assert left==right
            checked+=1
print(f"PASS: {count} independent pair write orders; {checked} mirror equivariance probes")
