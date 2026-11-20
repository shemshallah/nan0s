.org 0
JMP @main
.include "../lib/ncc.nas"
main:
MOVI r13,1
LA r1,@c_src
CALL @ncc_compile
CALL @ncc_run
HALT
c_src:
.str "#define ADD(a,b) ((a)+(b))\nint main(void){ print_int(ADD(20,22)); putchar(10); return 0; }\n"
