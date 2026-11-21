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
.str "int main(void){\n printf(\"%.4f %.4f %.4f %.4f\\n\",exp2(3.0),log2(8.0),log1p(1.0),expm1(1.0));\n printf(\"%.4f %.4f %.4f %.4f\\n\",hypot(3.0,4.0),cbrt(27.0),sinh(1.0),cosh(1.0));\n printf(\"%.4f %.4f %.4f\\n\",asinh(1.0),acosh(2.0),atanh(0.5));\n printf(\"%.2f %.2f %.2f %.2f\\n\",trunc(-2.7),round(2.5),round(-2.5),rint(3.4));\n printf(\"%.2f %.2f %.2f\\n\",copysign(3.0,-1.0),fdim(5.0,2.0),fma(2.0,3.0,4.0));\n float ip=0; float fr=modf(3.75,&ip);\n printf(\"%.2f %.2f\\n\",fr,ip);\n printf(\"%.2f %.2f %.2f\\n\",ldexp(1.5,3),scalbn(2.0,4),remainder(7.0,2.0));\n return 0;\n}\n"
