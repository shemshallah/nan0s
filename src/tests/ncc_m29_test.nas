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
.str "void h(int s){ printf(\"sig %d\",s); putchar(10); }\nint main(void){ signal(SIGINT,h); raise(SIGINT); raise(SIGTERM); return 0; }\n"
