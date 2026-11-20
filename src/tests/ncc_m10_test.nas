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
.str "int main(void){\n printf(\"%f %f %.2f %.0f\\n\", 1.5, 3.25, 3.14159, 2.7);\n printf(\"[%5.2f] [%-6.2f] [%.3s] [%5.2s] [%.4d]\\n\", 1.5, 1.5, \"abcdef\", \"xy\", 42);\n printf(\"%f %f %.2f %.0f %f\\n\", -1.5, -0.125, -3.14159, -2.7, 12345.678);\n return 0;\n}\n"
