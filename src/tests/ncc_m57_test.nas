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
.str "int main(void){\n printf(\"%.4f %.4f %.4f %.4f\\n\",erf(0.0),erf(1.0),erf(-1.0),erf(0.5));\n printf(\"%.4f %.4f %.4f\\n\",erfc(1.0),erfc(-1.0),erfc(0.0));\n return 0;\n}\n"
