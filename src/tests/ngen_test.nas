; ngen_test.nas - live generation publish/drain/start + epoch fence proof.
;
; Scenario (deterministic, run twice and compared word-for-word):
;   agent 1: start gen1, two in-flight requests, publish gen2, reject a new
;     gen1 admission while draining, admit gen2 immediately, complete both
;     gen1 requests, reject a post-drain gen1 request, auto-drain gen2 while
;     publishing gen3, put two gen3 requests in flight, publish gen4, force-
;     abort gen3, then exercise duplicate/stale/future/bad publish errors.
;   agent 2: independent gen1 drain/start/abort/start cycle and cross-agent
;     future/stale rejection.
;
; Success prints exactly O.  A failed check prints F<3-digit diagnostic> and
; halts.

.equ STK      0x7000
.equ NST1     32
.equ NST2     32
.equ NSNAP    128

; ngen_status output offsets.
.equ ST_CUR       3
.equ ST_EPOCH     4
.equ ST_STATE     5
.equ ST_INFLIGHT  6
.equ ST_SLOTS     7
.equ ST_ACCEPTING 8
.equ ST_DRAINING  9
.equ ST_DRAINED   10
.equ ST_ABORTED   11
.equ ST_ACCEPTED  12
.equ ST_COMPLETED 13
.equ ST_ABORTED_T 14
.equ ST_REJECTED  15
.equ ST_PUBLISH   16
.equ ST_DRAINS    17
.equ ST_STARTS    18
.equ ST_ABORTS    19
.equ ST_FENCES    20
.equ ST_LASTFENCE 21
.equ ST_FENCE     22
.equ ST_DRAINED_T 23
.equ ST_WROOT     24
.equ ST_WGEN      25
.equ ST_KVROOT    26
.equ ST_KVGEN     27
.equ ST_HEAD      28
.equ ST_EVENTS    29
.equ ST_WRAPS     30
.equ ST_LERR      31

.org 0
JMP @main
.include "../lib/ngen.nas"

main:
MOVI r13,1
LA r14,@stack

; ---- run 1
CALL @ngen_init
MOVI r2,0
MOVI r3,1
CALL @chk
CALL @scenario
LA r1,@snapA
CALL @snapshot

; ---- run 2 (identical state from a cold init)
CALL @ngen_init
MOVI r2,0
MOVI r3,2
CALL @chk
CALL @scenario
LA r1,@snapB
CALL @snapshot

; ---- deterministic rerun: every status word, CPU counter and trace tail equal
LA r1,@snapA
LA r2,@snapB
MOVI r3,#NSNAP
CALL @cmpbuf
MOVI r2,0
MOVI r3,3
CALL @chk

MOVI r1,79
PUTC r1
HALT

; ---------------------------------------------------------------------------
scenario:
ST r15,r14,0
ADDI r14,r14,16

; ================= agent 1 =================
MOVI r1,1
MOVI r2,0x1000
MOVI r3,0x2000
CALL @ngen_create
MOVI r2,0
MOVI r3,10
CALL @chk
CALL @q1
MOVI r2,0
MOVI r3,11
CALL @chk
MOVI r2,#ST_CUR
MOVI r3,0
MOVI r4,12
CALL @chkst1
MOVI r2,#ST_EPOCH
MOVI r3,0
MOVI r4,13
CALL @chkst1
MOVI r2,#ST_STATE
MOVI r3,#NG_LIVE
MOVI r4,14
CALL @chkst1
MOVI r2,#ST_WROOT
MOVI r3,0x1000
MOVI r4,15
CALL @chkst1
MOVI r2,#ST_WGEN
MOVI r3,1
MOVI r4,16
CALL @chkst1
MOVI r2,#ST_KVROOT
MOVI r3,0x2000
MOVI r4,17
CALL @chkst1
MOVI r2,#ST_KVGEN
MOVI r3,1
MOVI r4,18
CALL @chkst1
MOVI r2,#ST_EVENTS
MOVI r3,0
MOVI r4,19
CALL @chkst1
MOVI r2,#ST_STARTS
MOVI r3,0
MOVI r4,20
CALL @chkst1
MOVI r2,#ST_ACCEPTING
MOVI r3,0
MOVI r4,21
CALL @chkst1
MOVI r2,#ST_SLOTS
MOVI r3,0
MOVI r4,22
CALL @chkst1

; ---- start generation 1
MOVI r1,1
MOVI r2,1
CALL @ngen_start
MOVI r2,1
MOVI r3,23
CALL @chk
CALL @q1
MOVI r2,0
MOVI r3,24
CALL @chk
MOVI r2,#ST_CUR
MOVI r3,1
MOVI r4,25
CALL @chkst1
MOVI r2,#ST_EPOCH
MOVI r3,1
MOVI r4,26
CALL @chkst1
MOVI r2,#ST_ACCEPTING
MOVI r3,1
MOVI r4,27
CALL @chkst1
MOVI r2,#ST_SLOTS
MOVI r3,1
MOVI r4,28
CALL @chkst1
MOVI r2,#ST_STARTS
MOVI r3,1
MOVI r4,29
CALL @chkst1
MOVI r2,#ST_EVENTS
MOVI r3,1
MOVI r4,30
CALL @chkst1
MOVI r2,1
CALL @qslot1
MOVI r2,0
MOVI r3,31
CALL @chk
MOVI r2,#NG_S_STATE
MOVI r3,#NG_S_CURRENT
MOVI r4,32
CALL @chkslot
MOVI r2,#NG_S_INFLIGHT
MOVI r3,0
MOVI r4,33
CALL @chkslot
MOVI r2,#NG_S_EPOCH
MOVI r3,1
MOVI r4,34
CALL @chkslot

; ---- two in-flight gen1 requests on cpu0 and cpu1
MOVI r1,1
MOVI r2,1
MOVI r3,0
CALL @ngen_enter
MOVI r2,1
MOVI r3,35
CALL @chk
MOVI r1,1
MOVI r2,1
MOVI r3,1
CALL @ngen_enter
MOVI r2,1
MOVI r3,36
CALL @chk
CALL @q1
MOVI r2,#ST_INFLIGHT
MOVI r3,2
MOVI r4,37
CALL @chkst1
MOVI r2,#ST_ACCEPTED
MOVI r3,2
MOVI r4,38
CALL @chkst1
MOVI r2,#ST_EVENTS
MOVI r3,3
MOVI r4,39
CALL @chkst1
MOVI r1,0
CALL @qcpu
MOVI r2,0
MOVI r3,40
CALL @chk
MOVI r2,0
MOVI r3,1
MOVI r4,41
CALL @chkcpu
MOVI r1,1
CALL @qcpu
MOVI r2,0
MOVI r3,1
MOVI r4,42
CALL @chkcpu
MOVI r2,1
CALL @qslot1
MOVI r2,#NG_S_INFLIGHT
MOVI r3,2
MOVI r4,43
CALL @chkslot
MOVI r2,#NG_S_ACCEPTED
MOVI r3,2
MOVI r4,44
CALL @chkslot

; ---- publish generation 2 with a new immutable weight root
MOVI r1,1
MOVI r2,2
MOVI r3,0x3000
MOVI r4,0
CALL @ngen_publish
MOVI r2,2
MOVI r3,45
CALL @chk
CALL @q1
MOVI r2,0
MOVI r3,46
CALL @chk
MOVI r2,#ST_CUR
MOVI r3,2
MOVI r4,47
CALL @chkst1
MOVI r2,#ST_EPOCH
MOVI r3,2
MOVI r4,48
CALL @chkst1
MOVI r2,#ST_ACCEPTING
MOVI r3,1
MOVI r4,49
CALL @chkst1
MOVI r2,#ST_DRAINING
MOVI r3,1
MOVI r4,50
CALL @chkst1
MOVI r2,#ST_DRAINED
MOVI r3,0
MOVI r4,51
CALL @chkst1
MOVI r2,#ST_INFLIGHT
MOVI r3,2
MOVI r4,52
CALL @chkst1
MOVI r2,#ST_PUBLISH
MOVI r3,1
MOVI r4,53
CALL @chkst1
MOVI r2,#ST_DRAINS
MOVI r3,1
MOVI r4,54
CALL @chkst1
MOVI r2,#ST_STARTS
MOVI r3,2
MOVI r4,55
CALL @chkst1
MOVI r2,#ST_EVENTS
MOVI r3,6
MOVI r4,56
CALL @chkst1
MOVI r2,#ST_WROOT
MOVI r3,0x3000
MOVI r4,57
CALL @chkst1
MOVI r2,#ST_WGEN
MOVI r3,2
MOVI r4,58
CALL @chkst1
MOVI r2,#ST_KVROOT
MOVI r3,0x2000
MOVI r4,59
CALL @chkst1
MOVI r2,#ST_KVGEN
MOVI r3,1
MOVI r4,60
CALL @chkst1

; ---- old gen1 is draining with both requests still in flight
MOVI r2,1
CALL @qslot1
MOVI r2,0
MOVI r3,61
CALL @chk
MOVI r2,#NG_S_STATE
MOVI r3,#NG_S_DRAINING
MOVI r4,62
CALL @chkslot
MOVI r2,#NG_S_INFLIGHT
MOVI r3,2
MOVI r4,63
CALL @chkslot
MOVI r2,#NG_S_EPOCH
MOVI r3,2
MOVI r4,64
CALL @chkslot
MOVI r2,#NG_S_COMPLETED
MOVI r3,0
MOVI r4,65
CALL @chkslot

; ---- gen2 is current immediately
MOVI r2,2
CALL @qslot1
MOVI r2,0
MOVI r3,66
CALL @chk
MOVI r2,#NG_S_STATE
MOVI r3,#NG_S_CURRENT
MOVI r4,67
CALL @chkslot
MOVI r2,#NG_S_INFLIGHT
MOVI r3,0
MOVI r4,68
CALL @chkslot
MOVI r2,#NG_S_EPOCH
MOVI r3,2
MOVI r4,69
CALL @chkslot

; ---- fence: publish -> drain -> start marked in order
MOVI r1,1
CALL @ngen_fence
MOVI r2,2
MOVI r3,70
CALL @chk
MOVI r1,1
CALL @ngen_fence
MOVI r2,2
MOVI r3,71
CALL @chk
CALL @q1
MOVI r2,#ST_FENCES
MOVI r3,2
MOVI r4,72
CALL @chkst1
MOVI r2,#ST_LASTFENCE
MOVI r3,2
MOVI r4,73
CALL @chkst1
MOVI r2,#ST_FENCE
MOVI r3,7
MOVI r4,74
CALL @chkst1

; ---- trace ordering for the publish transition
MOVI r1,1
MOVI r2,3
LA r3,@tbuf
CALL @ngen_trace
MOVI r2,0
MOVI r3,75
CALL @chk
LA r1,@tbuf
MOVI r2,0
MOVI r3,#NG_T_PUBLISH
MOVI r4,76
CALL @chkrec
LA r1,@tbuf
MOVI r2,1
MOVI r3,2
MOVI r4,77
CALL @chkrec
LA r1,@tbuf
MOVI r2,2
MOVI r3,2
MOVI r4,78
CALL @chkrec
LA r1,@tbuf
MOVI r2,5
MOVI r3,2
MOVI r4,79
CALL @chkrec
MOVI r1,1
MOVI r2,4
LA r3,@tbuf
CALL @ngen_trace
LA r1,@tbuf
MOVI r2,0
MOVI r3,#NG_T_DRAIN
MOVI r4,80
CALL @chkrec
LA r1,@tbuf
MOVI r2,1
MOVI r3,1
MOVI r4,81
CALL @chkrec
LA r1,@tbuf
MOVI r2,5
MOVI r3,2
MOVI r4,82
CALL @chkrec
MOVI r1,1
MOVI r2,5
LA r3,@tbuf
CALL @ngen_trace
LA r1,@tbuf
MOVI r2,0
MOVI r3,#NG_T_START
MOVI r4,83
CALL @chkrec
LA r1,@tbuf
MOVI r2,1
MOVI r3,2
MOVI r4,84
CALL @chkrec
LA r1,@tbuf
MOVI r2,5
MOVI r3,2
MOVI r4,85
CALL @chkrec

; ---- old generation admission rejected while draining, new admitted
MOVI r1,1
MOVI r2,1
MOVI r3,0
CALL @ngen_enter
MOVI r2,0
MOVI r3,86
CALL @chk
MOVI r1,#NG_EDRAIN
MOVI r2,87
CALL @chkerr
MOVI r2,1
CALL @qslot1
MOVI r2,#NG_S_INFLIGHT
MOVI r3,2
MOVI r4,88
CALL @chkslot
CALL @q1
MOVI r2,#ST_REJECTED
MOVI r3,1
MOVI r4,89
CALL @chkst1
MOVI r2,#ST_EVENTS
MOVI r3,7
MOVI r4,90
CALL @chkst1
MOVI r1,0
CALL @qcpu
MOVI r2,1
MOVI r3,1
MOVI r4,91
CALL @chkcpu

MOVI r1,1
MOVI r2,2
MOVI r3,0
CALL @ngen_enter
MOVI r2,2
MOVI r3,92
CALL @chk
MOVI r2,2
CALL @qslot1
MOVI r2,#NG_S_INFLIGHT
MOVI r3,1
MOVI r4,93
CALL @chkslot
MOVI r2,#NG_S_ACCEPTED
MOVI r3,1
MOVI r4,94
CALL @chkslot
CALL @q1
MOVI r2,#ST_INFLIGHT
MOVI r3,3
MOVI r4,95
CALL @chkst1
MOVI r2,#ST_ACCEPTED
MOVI r3,3
MOVI r4,96
CALL @chkst1
MOVI r2,#ST_EVENTS
MOVI r3,8
MOVI r4,97
CALL @chkst1
MOVI r1,0
CALL @qcpu
MOVI r2,0
MOVI r3,2
MOVI r4,98
CALL @chkcpu

; ---- old in-flight requests complete; only then does gen1 close
MOVI r1,1
MOVI r2,1
CALL @ngen_exit
MOVI r2,0
MOVI r3,99
CALL @chk
MOVI r2,1
CALL @qslot1
MOVI r2,#NG_S_INFLIGHT
MOVI r3,1
MOVI r4,100
CALL @chkslot
MOVI r2,#NG_S_COMPLETED
MOVI r3,1
MOVI r4,101
CALL @chkslot
CALL @q1
MOVI r2,#ST_COMPLETED
MOVI r3,1
MOVI r4,102
CALL @chkst1
MOVI r2,#ST_EVENTS
MOVI r3,9
MOVI r4,103
CALL @chkst1

MOVI r1,1
MOVI r2,1
CALL @ngen_exit
MOVI r2,0
MOVI r3,104
CALL @chk
MOVI r2,1
CALL @qslot1
MOVI r2,#NG_S_INFLIGHT
MOVI r3,0
MOVI r4,105
CALL @chkslot
MOVI r2,#NG_S_STATE
MOVI r3,#NG_S_DRAINED
MOVI r4,106
CALL @chkslot
MOVI r2,#NG_S_COMPLETED
MOVI r3,2
MOVI r4,107
CALL @chkslot
CALL @q1
MOVI r2,#ST_COMPLETED
MOVI r3,2
MOVI r4,108
CALL @chkst1
MOVI r2,#ST_DRAINED_T
MOVI r3,1
MOVI r4,109
CALL @chkst1
MOVI r2,#ST_DRAINING
MOVI r3,0
MOVI r4,110
CALL @chkst1
MOVI r2,#ST_DRAINED
MOVI r3,1
MOVI r4,111
CALL @chkst1
MOVI r2,#ST_INFLIGHT
MOVI r3,1
MOVI r4,112
CALL @chkst1
MOVI r2,#ST_EVENTS
MOVI r3,11
MOVI r4,113
CALL @chkst1

; ---- post-drain old-generation request is stale
MOVI r1,1
MOVI r2,1
MOVI r3,1
CALL @ngen_enter
MOVI r2,0
MOVI r3,114
CALL @chk
MOVI r1,#NG_ESTALE
MOVI r2,115
CALL @chkerr
CALL @q1
MOVI r2,#ST_REJECTED
MOVI r3,2
MOVI r4,116
CALL @chkst1
MOVI r2,#ST_EVENTS
MOVI r3,12
MOVI r4,117
CALL @chkst1
MOVI r1,1
CALL @qcpu
MOVI r2,1
MOVI r3,1
MOVI r4,118
CALL @chkcpu

; ---- exit gen2, then publish gen3; gen2 auto-drains
MOVI r1,1
MOVI r2,2
CALL @ngen_exit
MOVI r2,0
MOVI r3,119
CALL @chk
MOVI r1,1
MOVI r2,3
MOVI r3,0x3000
MOVI r4,0x4000
CALL @ngen_publish
MOVI r2,3
MOVI r3,120
CALL @chk
CALL @q1
MOVI r2,#ST_CUR
MOVI r3,3
MOVI r4,121
CALL @chkst1
MOVI r2,#ST_EPOCH
MOVI r3,3
MOVI r4,122
CALL @chkst1
MOVI r2,#ST_DRAINING
MOVI r3,0
MOVI r4,123
CALL @chkst1
MOVI r2,#ST_DRAINED
MOVI r3,2
MOVI r4,124
CALL @chkst1
MOVI r2,#ST_DRAINED_T
MOVI r3,2
MOVI r4,125
CALL @chkst1
MOVI r2,#ST_PUBLISH
MOVI r3,2
MOVI r4,126
CALL @chkst1
MOVI r2,#ST_DRAINS
MOVI r3,2
MOVI r4,127
CALL @chkst1
MOVI r2,#ST_STARTS
MOVI r3,3
MOVI r4,128
CALL @chkst1
MOVI r2,#ST_EVENTS
MOVI r3,17
MOVI r4,129
CALL @chkst1
MOVI r2,#ST_WGEN
MOVI r3,2
MOVI r4,130
CALL @chkst1
MOVI r2,#ST_KVROOT
MOVI r3,0x4000
MOVI r4,131
CALL @chkst1
MOVI r2,#ST_KVGEN
MOVI r3,2
MOVI r4,132
CALL @chkst1
MOVI r2,2
CALL @qslot1
MOVI r2,#NG_S_STATE
MOVI r3,#NG_S_DRAINED
MOVI r4,133
CALL @chkslot
MOVI r2,3
CALL @qslot1
MOVI r2,#NG_S_STATE
MOVI r3,#NG_S_CURRENT
MOVI r4,134
CALL @chkslot
MOVI r1,1
CALL @ngen_fence
MOVI r2,3
MOVI r3,135
CALL @chk

; ---- trace of the auto-drain publish: publish,drain,drained,start
MOVI r1,1
MOVI r2,13
LA r3,@tbuf
CALL @ngen_trace
MOVI r2,0
MOVI r3,136
CALL @chk
LA r1,@tbuf
MOVI r2,0
MOVI r3,#NG_T_PUBLISH
MOVI r4,137
CALL @chkrec
LA r1,@tbuf
MOVI r2,5
MOVI r3,3
MOVI r4,138
CALL @chkrec
MOVI r1,1
MOVI r2,14
LA r3,@tbuf
CALL @ngen_trace
LA r1,@tbuf
MOVI r2,0
MOVI r3,#NG_T_DRAIN
MOVI r4,139
CALL @chkrec
MOVI r1,1
MOVI r2,15
LA r3,@tbuf
CALL @ngen_trace
LA r1,@tbuf
MOVI r2,0
MOVI r3,#NG_T_DRAINED
MOVI r4,140
CALL @chkrec
MOVI r1,1
MOVI r2,16
LA r3,@tbuf
CALL @ngen_trace
LA r1,@tbuf
MOVI r2,0
MOVI r3,#NG_T_START
MOVI r4,141
CALL @chkrec

; ---- two gen3 requests, then publish gen4 leaves them draining
MOVI r1,1
MOVI r2,3
MOVI r3,0
CALL @ngen_enter
MOVI r2,3
MOVI r3,142
CALL @chk
MOVI r1,1
MOVI r2,3
MOVI r3,1
CALL @ngen_enter
MOVI r2,3
MOVI r3,143
CALL @chk
MOVI r1,1
MOVI r2,4
MOVI r3,0
MOVI r4,0
CALL @ngen_publish
MOVI r2,4
MOVI r3,144
CALL @chk
CALL @q1
MOVI r2,#ST_CUR
MOVI r3,4
MOVI r4,145
CALL @chkst1
MOVI r2,#ST_EPOCH
MOVI r3,4
MOVI r4,146
CALL @chkst1
MOVI r2,#ST_DRAINING
MOVI r3,1
MOVI r4,147
CALL @chkst1
MOVI r2,#ST_INFLIGHT
MOVI r3,2
MOVI r4,148
CALL @chkst1
MOVI r2,#ST_PUBLISH
MOVI r3,3
MOVI r4,149
CALL @chkst1
MOVI r2,#ST_DRAINS
MOVI r3,3
MOVI r4,150
CALL @chkst1
MOVI r2,#ST_STARTS
MOVI r3,4
MOVI r4,151
CALL @chkst1
MOVI r2,#ST_EVENTS
MOVI r3,22
MOVI r4,152
CALL @chkst1
MOVI r2,#ST_WGEN
MOVI r3,2
MOVI r4,153
CALL @chkst1
MOVI r2,#ST_KVGEN
MOVI r3,2
MOVI r4,154
CALL @chkst1
MOVI r2,3
CALL @qslot1
MOVI r2,#NG_S_STATE
MOVI r3,#NG_S_DRAINING
MOVI r4,155
CALL @chkslot
MOVI r2,#NG_S_INFLIGHT
MOVI r3,2
MOVI r4,156
CALL @chkslot
MOVI r2,#NG_S_EPOCH
MOVI r3,4
MOVI r4,157
CALL @chkslot
MOVI r1,1
CALL @ngen_fence
MOVI r2,4
MOVI r3,158
CALL @chk

; ---- forced abort of the draining gen3
MOVI r1,1
MOVI r2,3
CALL @ngen_abort
MOVI r2,2
MOVI r3,159
CALL @chk
MOVI r2,3
CALL @qslot1
MOVI r2,#NG_S_STATE
MOVI r3,#NG_S_ABORTED_ST
MOVI r4,160
CALL @chkslot
MOVI r2,#NG_S_INFLIGHT
MOVI r3,0
MOVI r4,161
CALL @chkslot
MOVI r2,#NG_S_ABORTED
MOVI r3,2
MOVI r4,162
CALL @chkslot
MOVI r2,#NG_S_COMPLETED
MOVI r3,0
MOVI r4,163
CALL @chkslot
CALL @q1
MOVI r2,#ST_ABORTED_T
MOVI r3,2
MOVI r4,164
CALL @chkst1
MOVI r2,#ST_ABORTS
MOVI r3,1
MOVI r4,165
CALL @chkst1
MOVI r2,#ST_DRAINING
MOVI r3,0
MOVI r4,166
CALL @chkst1
MOVI r2,#ST_ABORTED
MOVI r3,1
MOVI r4,167
CALL @chkst1
MOVI r2,#ST_INFLIGHT
MOVI r3,0
MOVI r4,168
CALL @chkst1
MOVI r2,#ST_DRAINED_T
MOVI r3,3
MOVI r4,169
CALL @chkst1
MOVI r2,#ST_EVENTS
MOVI r3,24
MOVI r4,170
CALL @chkst1

; ---- abort/exit/enter on a closed generation all fail closed
MOVI r1,1
MOVI r2,3
CALL @ngen_abort
MOVI r2,0
MOVI r3,171
CALL @chk
MOVI r1,#NG_EBUSY
MOVI r2,172
CALL @chkerr
MOVI r1,1
MOVI r2,3
CALL @ngen_exit
MOVI r2,0
MOVI r3,173
CALL @chk
MOVI r1,#NG_ESTALE
MOVI r2,174
CALL @chkerr
MOVI r1,1
MOVI r2,3
MOVI r3,0
CALL @ngen_enter
MOVI r2,0
MOVI r3,175
CALL @chk
MOVI r1,#NG_ESTALE
MOVI r2,176
CALL @chkerr
MOVI r1,1
MOVI r2,2
MOVI r3,0
CALL @ngen_enter
MOVI r2,0
MOVI r3,177
CALL @chk
MOVI r1,#NG_ESTALE
MOVI r2,178
CALL @chkerr

; ---- duplicate, stale, future, zero and missing-agent publish rejections
MOVI r1,1
MOVI r2,4
MOVI r3,0
MOVI r4,0
CALL @ngen_publish
MOVI r2,0
MOVI r3,179
CALL @chk
MOVI r1,#NG_EDUP
MOVI r2,180
CALL @chkerr
MOVI r1,1
MOVI r2,3
MOVI r3,0
MOVI r4,0
CALL @ngen_publish
MOVI r2,0
MOVI r3,181
CALL @chk
MOVI r1,#NG_ESTALE
MOVI r2,182
CALL @chkerr
MOVI r1,1
MOVI r2,6
MOVI r3,0
MOVI r4,0
CALL @ngen_publish
MOVI r2,0
MOVI r3,183
CALL @chk
MOVI r1,#NG_EFUTURE
MOVI r2,184
CALL @chkerr
MOVI r1,1
MOVI r2,0
MOVI r3,0
MOVI r4,0
CALL @ngen_publish
MOVI r2,0
MOVI r3,185
CALL @chk
MOVI r1,#NG_EBAD
MOVI r2,186
CALL @chkerr
MOVI r1,99
MOVI r2,5
MOVI r3,0
MOVI r4,0
CALL @ngen_publish
MOVI r2,0
MOVI r3,187
CALL @chk
MOVI r1,#NG_ENOENT
MOVI r2,188
CALL @chkerr

; ---- agent 1 pre-isolation status
CALL @q1
MOVI r2,#ST_CUR
MOVI r3,4
MOVI r4,189
CALL @chkst1
MOVI r2,#ST_REJECTED
MOVI r3,4
MOVI r4,190
CALL @chkst1
MOVI r2,#ST_EVENTS
MOVI r3,26
MOVI r4,191
CALL @chkst1

; ================= agent 2 (isolation) =================
MOVI r1,2
MOVI r2,0xA000
MOVI r3,0xB000
CALL @ngen_create
MOVI r2,0
MOVI r3,192
CALL @chk
MOVI r1,2
MOVI r2,1
CALL @ngen_start
MOVI r2,1
MOVI r3,193
CALL @chk
CALL @q2
MOVI r2,0
MOVI r3,194
CALL @chk
MOVI r2,#ST_CUR
MOVI r3,1
MOVI r4,195
CALL @chkst2
MOVI r2,#ST_EPOCH
MOVI r3,1
MOVI r4,196
CALL @chkst2
MOVI r2,#ST_WROOT
MOVI r3,0xA000
MOVI r4,197
CALL @chkst2
MOVI r2,#ST_KVROOT
MOVI r3,0xB000
MOVI r4,198
CALL @chkst2

MOVI r1,2
MOVI r2,1
MOVI r3,2
CALL @ngen_enter
MOVI r2,1
MOVI r3,199
CALL @chk
MOVI r1,2
MOVI r2,1
MOVI r3,3
CALL @ngen_enter
MOVI r2,1
MOVI r3,200
CALL @chk

; ---- freeze gen1 explicitly, then old admission fails while it drains
MOVI r1,2
CALL @ngen_drain
MOVI r2,2
MOVI r3,201
CALL @chk
CALL @q2
MOVI r2,#ST_EPOCH
MOVI r3,2
MOVI r4,202
CALL @chkst2
MOVI r2,#ST_ACCEPTING
MOVI r3,0
MOVI r4,203
CALL @chkst2
MOVI r2,#ST_DRAINING
MOVI r3,1
MOVI r4,204
CALL @chkst2
MOVI r2,#ST_EVENTS
MOVI r3,4
MOVI r4,205
CALL @chkst2
MOVI r1,2
CALL @ngen_fence
MOVI r2,0
MOVI r3,206
CALL @chk
MOVI r1,2
MOVI r2,1
MOVI r3,2
CALL @ngen_enter
MOVI r2,0
MOVI r3,207
CALL @chk
MOVI r1,#NG_EDRAIN
MOVI r2,208
CALL @chkerr

MOVI r1,2
MOVI r2,1
CALL @ngen_exit
MOVI r2,0
MOVI r3,209
CALL @chk
MOVI r1,2
MOVI r2,1
CALL @ngen_exit
MOVI r2,0
MOVI r3,210
CALL @chk
CALL @q2
MOVI r2,#ST_DRAINED_T
MOVI r3,1
MOVI r4,211
CALL @chkst2
MOVI r2,#ST_EVENTS
MOVI r3,8
MOVI r4,212
CALL @chkst2
MOVI r1,2
MOVI r2,1
MOVI r3,3
CALL @ngen_enter
MOVI r2,0
MOVI r3,213
CALL @chk
MOVI r1,#NG_ESTALE
MOVI r2,214
CALL @chkerr

; ---- start gen2 after the drained gen1, one request, then forced abort
MOVI r1,2
MOVI r2,2
CALL @ngen_start
MOVI r2,3
MOVI r3,215
CALL @chk
CALL @q2
MOVI r2,#ST_CUR
MOVI r3,2
MOVI r4,216
CALL @chkst2
MOVI r2,#ST_EPOCH
MOVI r3,3
MOVI r4,217
CALL @chkst2
MOVI r2,#ST_ACCEPTING
MOVI r3,1
MOVI r4,218
CALL @chkst2
MOVI r2,#ST_STARTS
MOVI r3,2
MOVI r4,219
CALL @chkst2
MOVI r2,#ST_EVENTS
MOVI r3,10
MOVI r4,220
CALL @chkst2
MOVI r1,2
MOVI r2,2
MOVI r3,0
CALL @ngen_enter
MOVI r2,2
MOVI r3,221
CALL @chk
MOVI r1,2
CALL @ngen_drain
MOVI r2,4
MOVI r3,222
CALL @chk
MOVI r1,2
MOVI r2,2
CALL @ngen_abort
MOVI r2,1
MOVI r3,223
CALL @chk
CALL @q2
MOVI r2,#ST_ABORTED_T
MOVI r3,1
MOVI r4,224
CALL @chkst2
MOVI r2,#ST_ABORTS
MOVI r3,1
MOVI r4,225
CALL @chkst2
MOVI r2,#ST_DRAINED_T
MOVI r3,2
MOVI r4,226
CALL @chkst2
MOVI r2,#ST_EVENTS
MOVI r3,14
MOVI r4,227
CALL @chkst2
MOVI r1,2
MOVI r2,2
MOVI r3,0
CALL @ngen_enter
MOVI r2,0
MOVI r3,228
CALL @chk
MOVI r1,#NG_ESTALE
MOVI r2,229
CALL @chkerr

; ---- start gen3, then cross-agent future/stale isolation
MOVI r1,2
MOVI r2,3
CALL @ngen_start
MOVI r2,5
MOVI r3,230
CALL @chk
MOVI r1,2
MOVI r2,3
MOVI r3,0
CALL @ngen_enter
MOVI r2,3
MOVI r3,231
CALL @chk
MOVI r1,2
MOVI r2,3
CALL @ngen_exit
MOVI r2,0
MOVI r3,232
CALL @chk
MOVI r1,2
MOVI r2,4
MOVI r3,0
CALL @ngen_enter
MOVI r2,0
MOVI r3,233
CALL @chk
MOVI r1,#NG_EFUTURE
MOVI r2,234
CALL @chkerr

MOVI r1,1
MOVI r2,1
MOVI r3,0
CALL @ngen_enter
MOVI r2,0
MOVI r3,235
CALL @chk
MOVI r1,#NG_ESTALE
MOVI r2,236
CALL @chkerr

; ---- final exact agent 1 status (one cross-agent stale rejection added)
CALL @q1
MOVI r2,0
MOVI r3,237
CALL @chk
MOVI r2,#ST_CUR
MOVI r3,4
MOVI r4,238
CALL @chkst1
MOVI r2,#ST_EPOCH
MOVI r3,4
MOVI r4,239
CALL @chkst1
MOVI r2,#ST_STATE
MOVI r3,#NG_LIVE
MOVI r4,240
CALL @chkst1
MOVI r2,#ST_INFLIGHT
MOVI r3,0
MOVI r4,241
CALL @chkst1
MOVI r2,#ST_SLOTS
MOVI r3,4
MOVI r4,242
CALL @chkst1
MOVI r2,#ST_ACCEPTING
MOVI r3,1
MOVI r4,243
CALL @chkst1
MOVI r2,#ST_DRAINING
MOVI r3,0
MOVI r4,244
CALL @chkst1
MOVI r2,#ST_DRAINED
MOVI r3,2
MOVI r4,245
CALL @chkst1
MOVI r2,#ST_ABORTED
MOVI r3,1
MOVI r4,246
CALL @chkst1
MOVI r2,#ST_ACCEPTED
MOVI r3,5
MOVI r4,247
CALL @chkst1
MOVI r2,#ST_COMPLETED
MOVI r3,3
MOVI r4,248
CALL @chkst1
MOVI r2,#ST_ABORTED_T
MOVI r3,2
MOVI r4,249
CALL @chkst1
MOVI r2,#ST_REJECTED
MOVI r3,5
MOVI r4,250
CALL @chkst1
MOVI r2,#ST_PUBLISH
MOVI r3,3
MOVI r4,251
CALL @chkst1
MOVI r2,#ST_DRAINS
MOVI r3,3
MOVI r4,252
CALL @chkst1
MOVI r2,#ST_STARTS
MOVI r3,4
MOVI r4,253
CALL @chkst1
MOVI r2,#ST_ABORTS
MOVI r3,1
MOVI r4,254
CALL @chkst1
MOVI r2,#ST_FENCES
MOVI r3,4
MOVI r4,255
CALL @chkst1
MOVI r2,#ST_LASTFENCE
MOVI r3,4
MOVI r4,256
CALL @chkst1
MOVI r2,#ST_FENCE
MOVI r3,7
MOVI r4,257
CALL @chkst1
MOVI r2,#ST_DRAINED_T
MOVI r3,3
MOVI r4,258
CALL @chkst1
MOVI r2,#ST_WROOT
MOVI r3,0x3000
MOVI r4,259
CALL @chkst1
MOVI r2,#ST_WGEN
MOVI r3,2
MOVI r4,260
CALL @chkst1
MOVI r2,#ST_KVROOT
MOVI r3,0x4000
MOVI r4,261
CALL @chkst1
MOVI r2,#ST_KVGEN
MOVI r3,2
MOVI r4,262
CALL @chkst1
MOVI r2,#ST_EVENTS
MOVI r3,27
MOVI r4,263
CALL @chkst1
MOVI r2,#ST_WRAPS
MOVI r3,19
MOVI r4,264
CALL @chkst1
MOVI r2,#ST_LERR
MOVI r3,#NG_ESTALE
MOVI r4,265
CALL @chkst1

; ---- final exact agent 2 status
CALL @q2
MOVI r2,0
MOVI r3,266
CALL @chk
MOVI r2,#ST_CUR
MOVI r3,3
MOVI r4,267
CALL @chkst2
MOVI r2,#ST_EPOCH
MOVI r3,5
MOVI r4,268
CALL @chkst2
MOVI r2,#ST_STATE
MOVI r3,#NG_LIVE
MOVI r4,269
CALL @chkst2
MOVI r2,#ST_INFLIGHT
MOVI r3,0
MOVI r4,270
CALL @chkst2
MOVI r2,#ST_SLOTS
MOVI r3,3
MOVI r4,271
CALL @chkst2
MOVI r2,#ST_ACCEPTING
MOVI r3,1
MOVI r4,272
CALL @chkst2
MOVI r2,#ST_DRAINING
MOVI r3,0
MOVI r4,273
CALL @chkst2
MOVI r2,#ST_DRAINED
MOVI r3,1
MOVI r4,274
CALL @chkst2
MOVI r2,#ST_ABORTED
MOVI r3,1
MOVI r4,275
CALL @chkst2
MOVI r2,#ST_ACCEPTED
MOVI r3,4
MOVI r4,276
CALL @chkst2
MOVI r2,#ST_COMPLETED
MOVI r3,3
MOVI r4,277
CALL @chkst2
MOVI r2,#ST_ABORTED_T
MOVI r3,1
MOVI r4,278
CALL @chkst2
MOVI r2,#ST_REJECTED
MOVI r3,4
MOVI r4,279
CALL @chkst2
MOVI r2,#ST_PUBLISH
MOVI r3,0
MOVI r4,280
CALL @chkst2
MOVI r2,#ST_DRAINS
MOVI r3,2
MOVI r4,281
CALL @chkst2
MOVI r2,#ST_STARTS
MOVI r3,3
MOVI r4,282
CALL @chkst2
MOVI r2,#ST_ABORTS
MOVI r3,1
MOVI r4,283
CALL @chkst2
MOVI r2,#ST_FENCES
MOVI r3,0
MOVI r4,284
CALL @chkst2
MOVI r2,#ST_FENCE
MOVI r3,4
MOVI r4,285
CALL @chkst2
MOVI r2,#ST_DRAINED_T
MOVI r3,2
MOVI r4,286
CALL @chkst2
MOVI r2,#ST_WROOT
MOVI r3,0xA000
MOVI r4,287
CALL @chkst2
MOVI r2,#ST_WGEN
MOVI r3,1
MOVI r4,288
CALL @chkst2
MOVI r2,#ST_KVROOT
MOVI r3,0xB000
MOVI r4,289
CALL @chkst2
MOVI r2,#ST_KVGEN
MOVI r3,1
MOVI r4,290
CALL @chkst2
MOVI r2,#ST_EVENTS
MOVI r3,19
MOVI r4,291
CALL @chkst2
MOVI r2,#ST_WRAPS
MOVI r3,11
MOVI r4,292
CALL @chkst2
MOVI r2,#ST_LERR
MOVI r3,#NG_EFUTURE
MOVI r4,293
CALL @chkst2

; ---- combined per-CPU counters
MOVI r1,0
CALL @qcpu
MOVI r2,0
MOVI r3,294
CALL @chk
MOVI r2,0
MOVI r3,5
MOVI r4,295
CALL @chkcpu
MOVI r2,1
MOVI r3,6
MOVI r4,296
CALL @chkcpu
MOVI r1,1
CALL @qcpu
MOVI r2,0
MOVI r3,2
MOVI r4,297
CALL @chkcpu
MOVI r2,1
MOVI r3,1
MOVI r4,298
CALL @chkcpu
MOVI r1,2
CALL @qcpu
MOVI r2,0
MOVI r3,1
MOVI r4,299
CALL @chkcpu
MOVI r2,1
MOVI r3,1
MOVI r4,300
CALL @chkcpu
MOVI r1,3
CALL @qcpu
MOVI r2,0
MOVI r3,1
MOVI r4,301
CALL @chkcpu
MOVI r2,1
MOVI r3,1
MOVI r4,302
CALL @chkcpu

; ---- trace tails are exact
MOVI r1,1
MOVI r2,23
LA r3,@tbuf
CALL @ngen_trace
MOVI r2,0
MOVI r3,303
CALL @chk
LA r1,@tbuf
MOVI r2,0
MOVI r3,#NG_T_DRAINED
MOVI r4,304
CALL @chkrec
LA r1,@tbuf
MOVI r2,1
MOVI r3,3
MOVI r4,305
CALL @chkrec
MOVI r1,1
MOVI r2,26
LA r3,@tbuf
CALL @ngen_trace
LA r1,@tbuf
MOVI r2,1
MOVI r3,1
MOVI r4,306
CALL @chkrec
MOVI r1,2
MOVI r2,18
LA r3,@tbuf
CALL @ngen_trace
MOVI r2,0
MOVI r3,307
CALL @chk
LA r1,@tbuf
MOVI r2,0
MOVI r3,#NG_T_REJECT
MOVI r4,308
CALL @chkrec
LA r1,@tbuf
MOVI r2,1
MOVI r3,4
MOVI r4,309
CALL @chkrec
LA r1,@tbuf
MOVI r2,2
MOVI r3,#NG_EFUTURE
MOVI r4,310
CALL @chkrec

; ---- final global errno is the last rejected cross-agent enter
MOVI r1,#NG_ESTALE
MOVI r2,311
CALL @chkerr

ADDI r14,r14,-16
LD r15,r14,0
RET

; ---------------------------------------------------------------------------
; q1/q2 -> fill st1/st2 with ngen_status.
q1:
MOVI r1,1
LA r2,@st1
JMP @ngen_status
q2:
MOVI r1,2
LA r2,@st2
JMP @ngen_status

; qslot1/qslot2 r2=gen -> fill slotbuf.
qslot1:
MOVI r1,1
LA r3,@slotbuf
JMP @ngen_slot
qslot2:
MOVI r1,2
LA r3,@slotbuf
JMP @ngen_slot

; qcpu r1=cpu -> fill cpubuf.
qcpu:
LA r2,@cpubuf
JMP @ngen_cpu

; chkst1 r2=offset r3=expected r4=diag.
chkst1:
ST r15,r14,0
ADDI r14,r14,24
ST r3,r14,1
ST r4,r14,2
LA r1,@st1
LD r3,r14,1
LD r4,r14,2
CALL @chkrec
ADDI r14,r14,-24
LD r15,r14,0
RET

; chkst2 r2=offset r3=expected r4=diag.
chkst2:
ST r15,r14,0
ADDI r14,r14,24
ST r3,r14,1
ST r4,r14,2
LA r1,@st2
LD r3,r14,1
LD r4,r14,2
CALL @chkrec
ADDI r14,r14,-24
LD r15,r14,0
RET

; chkslot r2=offset r3=expected r4=diag.
chkslot:
ST r15,r14,0
ADDI r14,r14,24
ST r3,r14,1
ST r4,r14,2
LA r1,@slotbuf
LD r3,r14,1
LD r4,r14,2
CALL @chkrec
ADDI r14,r14,-24
LD r15,r14,0
RET

; chkcpu r2=offset r3=expected r4=diag.
chkcpu:
ST r15,r14,0
ADDI r14,r14,24
ST r3,r14,1
ST r4,r14,2
LA r1,@cpubuf
LD r3,r14,1
LD r4,r14,2
CALL @chkrec
ADDI r14,r14,-24
LD r15,r14,0
RET

; chkerr r1=expected r2=diag.
chkerr:
ST r15,r14,0
ADDI r14,r14,16
ST r1,r14,1
ST r2,r14,2
CALL @ngen_errno
LD r2,r14,1
LD r3,r14,2
CALL @chk
ADDI r14,r14,-16
LD r15,r14,0
RET

; chk r1=actual r2=expected r3=diagnostic.  Failure prints F=actual,expected,diag.
chk:
CMP r1,r2
JMP[EQ] @chk_ok
ST r15,r14,0
ADDI r14,r14,24
ST r1,r14,1
ST r2,r14,2
ST r3,r14,3
MOVI r1,70
PUTC r1
MOVI r1,61
PUTC r1
LD r1,r14,1
CALL @putdec3
MOVI r1,44
PUTC r1
LD r1,r14,2
CALL @putdec3
MOVI r1,44
PUTC r1
LD r1,r14,3
CALL @putdec3
MOVI r1,10
PUTC r1
HALT
chk_ok:
MOVI r1,0
RET

; chkrec r1=base r2=word offset r3=expected r4=diagnostic.
chkrec:
ST r15,r14,0
ADDI r14,r14,16
ST r4,r14,1
ADD r5,r1,r2
LD r1,r5,0
ADD r2,r3,r0
LD r3,r14,1
CALL @chk
ADDI r14,r14,-16
LD r15,r14,0
RET

; putdec3 r1=0..999 -> three decimal digits.
putdec3:
ST r15,r14,0
ADDI r14,r14,16
ST r1,r14,1
MOVI r2,100
DIVU r3,r1,r2
MOVI r4,48
ADD r3,r3,r4
PUTC r3
LD r1,r14,1
MOVI r2,100
MODU r1,r1,r2
MOVI r2,10
DIVU r3,r1,r2
ADD r3,r3,r4
PUTC r3
MODU r1,r1,r2
ADD r1,r1,r4
PUTC r1
ADDI r14,r14,-16
LD r15,r14,0
RET

; snapshot r1=out(128): status1, status2, cpu0..3, two trace tails.
snapshot:
ST r15,r14,0
ADDI r14,r14,24
ST r1,r14,1
MOVI r1,1
LD r2,r14,1
CALL @ngen_status
LD r2,r14,1
ADDI r2,r2,32
MOVI r1,2
CALL @ngen_status
MOVI r1,0
LD r2,r14,1
ADDI r2,r2,64
CALL @ngen_cpu
MOVI r1,1
LD r2,r14,1
ADDI r2,r2,68
CALL @ngen_cpu
MOVI r1,2
LD r2,r14,1
ADDI r2,r2,72
CALL @ngen_cpu
MOVI r1,3
LD r2,r14,1
ADDI r2,r2,76
CALL @ngen_cpu
MOVI r1,1
MOVI r2,23
LD r3,r14,1
ADDI r3,r3,80
CALL @snap_trace
MOVI r1,2
MOVI r2,15
LD r3,r14,1
ADDI r3,r3,104
CALL @snap_trace
ADDI r14,r14,-24
LD r15,r14,0
RET

; snap_trace r1=agent r2=first index r3=dest; copies 4 entries x 6 words.
snap_trace:
ST r15,r14,0
ADDI r14,r14,32
ST r1,r14,1
ST r2,r14,2
ST r3,r14,3
MOVI r4,4
ST r4,r14,4
snap_t_l:
LD r4,r14,4
CMP r4,r0
JMP[EQ] @snap_t_done
LD r1,r14,1
LD r2,r14,2
LD r3,r14,3
CALL @ngen_trace
LD r4,r14,2
ADDI r4,r4,1
ST r4,r14,2
LD r4,r14,3
ADDI r4,r4,6
ST r4,r14,3
LD r4,r14,4
SUB r4,r4,r13
ST r4,r14,4
JMP @snap_t_l
snap_t_done:
ADDI r14,r14,-32
LD r15,r14,0
RET

; cmpbuf r1=a r2=b r3=words -> 0 equal / 1 different.
cmpbuf:
cmpl:
CMP r3,r0
JMP[EQ] @cmp_ok
LD r4,r1,0
LD r5,r2,0
CMP r4,r5
JMP[NE] @cmp_bad
ADD r1,r1,r13
ADD r2,r2,r13
SUB r3,r3,r13
JMP @cmpl
cmp_bad:
MOVI r1,1
RET
cmp_ok:
MOVI r1,0
RET

; ---------------------------------------------------------------------------
.org 0x7000
stack:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0

.org 0x9000
st1:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
st2:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
slotbuf:
.word 0,0,0,0,0,0,0,0
cpubuf:
.word 0,0,0,0
tbuf:
.word 0,0,0,0,0,0
snapA:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
snapB:
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
.word 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
