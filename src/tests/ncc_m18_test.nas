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
.str "int main(void){ printf(\"%e %e %e\\n\", 0.0, 0.000123, 12345678.0); printf(\"[%12.3e] [%-12.3e]\\n\", 1.5, 1.5); printf(\"%.2E\\n\", -0.0625); return 0; }"
