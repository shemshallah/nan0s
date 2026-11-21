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
.str "struct S{int a,b;};\nstruct S ga[2]={1,2,3,4};\nint main(void){\n struct S a[2]={5,6,7,8};\n struct S s={9,10};\n printf(\"%d %d %d %d %d %d %d %d %d %d\\n\",\n  a[0].a,a[0].b,a[1].a,a[1].b,s.a,s.b,\n  ga[0].a,ga[0].b,ga[1].a,ga[1].b);\n return 0;\n}\n"
