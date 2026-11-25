; ndbg_badop_cart.nas - one legal-head word with an illegal payload op (0x7F).
; The resident step core must log a typed bad-op record instead of dying.
.org 8192
JMP @main
main:
MOVI r13,1
.raw FFF8_7F000000_F8FF
HALT
