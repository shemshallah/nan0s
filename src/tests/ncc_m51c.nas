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
.str "void h1(void){ puts(\"h1\"); } int main(void){ atexit(h1); puts(\"main\"); _Exit(0); puts(\"after\"); return 0; }\n"
