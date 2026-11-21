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
.str "int main(void){\n printf(\"%.4f %.4f %.4f %.4f\\n\",atan(1.0),atan(0.5),atan(2.0),atan(-1.0));\n printf(\"%.4f %.4f %.4f %.4f\\n\",asin(0.5),asin(1.0),acos(0.5),acos(0.0));\n printf(\"%.4f %.4f %.4f %.4f\\n\",atan2(1.0,1.0),atan2(1.0,-1.0),atan2(-1.0,-1.0),atan2(0.0,-1.0));\n return 0;\n}\n"
