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
.str "int main(void){\n printf(\"%d %d %d\\n\", (int)(sqrt(9.0)*100), (int)(fabs(-2.5)*10), (int)(pow(2.0,10.0)));\n printf(\"%d %d %d\\n\", (int)(floor(-2.5)*10), (int)(ceil(-2.5)*10), (int)(fmod(7.5,2.0)*10));\n printf(\"%d %d %d\\n\", (int)(exp(0.0)*10), (int)(log(1.0)*10), (int)(fmin(3.5,2.5)*10));\n printf(\"%d %d\\n\", (int)(fmax(3.5,2.5)*10), (int)(tanh(0.0)*10));\n return 0;\n}\n"
