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
.str "int fired;\nvoid h(int s){ fired=1; }\nint main(void){\n signal(SIGALRM,h);\n alarm(1);\n int n=0;\n while(!fired){ n++; if(n>1000000) break; }\n printf(\"fired=%d\",fired);\n putchar(10);\n return 0;\n}\n"
