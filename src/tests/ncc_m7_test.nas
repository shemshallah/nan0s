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
.str "struct P { int x; char c; int y; };\nunion U { int i; char b[4]; };\nstruct P g = {7,'Q',9};\nint main(void){\n int x=1;\n { int x=2; printf(\"%d \",x); }\n printf(\"%d \",x);\n { { int x=3; printf(\"%d \",x); } printf(\"%d \",x); }\n printf(\"\\n\");\n struct P a = {1,'A',2};\n union U u = {66};\n struct P b = {0,'Z',0};\n b = a;\n printf(\"%d %c %d %d %c %d %d\\n\", a.x,a.c,a.y,g.x,g.c,g.y,u.i);\n printf(\"%d %c %d\\n\", b.x,b.c,b.y);\n a.x = 9; b = a; printf(\"%d %c %d\\n\", b.x,b.c,b.y);\n return 0;\n}\n"
