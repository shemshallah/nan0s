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
.str "const int G=7;\nint other(void){ int x=2; x=3; return x; }\nint main(void){ const int x=1; const int *p=&G; p=&G; printf(\"%d %d %d\",G,x,other()); putchar(10); return 0; }\n"
