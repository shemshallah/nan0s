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
.str "int main(void) {\n  printf(\"%.6g %.3g %.2g %.10g\\n\", 123.456, 0.0001234, 12345678.0, 0.5);\n  printf(\"%g %G %#g\\n\", 0.00001234, 1.5e-5, 1.5);\n  printf(\"%#.3g [%8.3g] [%-8.3g]\\n\", 1.5, 12.3456, 12.3456);\n  printf(\"%g %g %g %g\\n\", 1e10, 1.5e-5, 2E3, 0.25);\n  return 0;\n}\n"
