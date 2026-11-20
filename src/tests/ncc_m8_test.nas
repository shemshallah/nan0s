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
.str "int main(void){\n float x=1.5,y=2.25,z=x+y;\n printf(\"%d %d %d %d\\n\", (int)x, (int)y, (int)z, (int)(z*2.0));\n float a=1.0; a+=0.5; a*=2.0; printf(\"%d %d %d\\n\", (int)a, (int)(7.5/2.5), (int)-1.5);\n printf(\"%d %d %d %d\\n\", (int)(sin(1.5707963)*1000), (int)(cos(0.0)*1000), (int)(sin(0.0)*1000), (int)(sin(3.1415926)*1000));\n printf(\"%d %d\\n\", 1.5<2.5, 2.5==2.5);\n return 0;\n}\n"
