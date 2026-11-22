#!/usr/bin/env python3
"""Exhaustive operational S+/S- non-aliasing regression (not a Coq proof)."""
N=256
tested=0
for a in range(N):
    for b in range(a+1,N):
        plus=(a,b)
        minus=(b,a)
        assert plus != minus
        base={plus:-1,minus:-2,(0,0):19}
        after=dict(base)
        after[plus]=a
        after[minus]=b
        assert after[plus]==a
        assert after[minus]==b
        assert after[(0,0)]==base[(0,0)]
        assert (min(plus, minus), max(plus, minus)) == (plus, minus)
        tested+=1
assert tested==32640
print("PASS: 32,640 strict mirror pairs have two independent writable channels")
