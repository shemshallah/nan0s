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
.str "int main(void){\n printf(\"%.4f %.4f %.4f\\n\",tgamma(5.0),tgamma(0.5),tgamma(-0.5));\n printf(\"%.4f %.4f\\n\",lgamma(5.0),lgamma(0.5));\n lgamma(-0.5); printf(\"%d\\n\",signgam);\n lgamma(0.5); printf(\"%d\\n\",signgam);\n printf(\"%d\\n\",iface_version());\n return 0;\n}\n"
