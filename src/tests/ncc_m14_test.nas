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
.str "struct F { unsigned a:3; unsigned :2; unsigned b:5; signed d:4; };\nstruct G { unsigned x:3, y:5; };\nstruct F gf = {9,33,-3};\nint main(void){\n struct F f; f.a=9; f.b=33; f.d=-3; print_int(f.a); putchar(32); print_int(f.b); putchar(32); print_int(f.d); putchar(10);\n struct G g; g.x=15; g.y=7; print_int(g.x*10+g.y); putchar(10);\n f.a+=2; print_int(f.a); putchar(10);\n print_int(gf.a); putchar(32); print_int(gf.b); putchar(32); print_int(gf.d); putchar(10);\n printf(\"%d %d\\n\", sizeof(struct F), sizeof(struct G));\n return 0;\n}\n"
