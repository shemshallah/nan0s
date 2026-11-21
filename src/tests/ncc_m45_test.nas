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
.str "int main(void){\n ungetc(65,stdin);\n putc(getchar(),stdout); putc(10,stdout);\n clearerr(stdin);\n setvbuf(stdout,0,0,0);\n ungetc(66,stdin);\n putc(getc(stdin),stdout); putc(10,stdout);\n putc(getchar(),stdout); putc(10,stdout);\n return 0;\n}\n"
