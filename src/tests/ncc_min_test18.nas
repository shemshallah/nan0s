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
.str "int main(void){ printf(\"%g %g %g %g\\n\", 1e10, 1.5e-5, 2E3, 0.25); return 0; }"
