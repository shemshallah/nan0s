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
.str "struct Inner { int a; int b; };\nstruct P { int x; struct Inner in; int y; };\nstruct A { int v[2][2]; int n; };\nstruct P gp = {1,{2,3},4};\nstruct A ga = {{{1,2},{3,4}},5};\nint main(void){\n struct P q = {1,{2,3},4}; print_int(q.x*1000+q.in.a*100+q.in.b*10+q.y); putchar(10);\n struct A a = {{{1,2},{3,4}},5}; print_int(a.v[0][0]+a.v[0][1]*10+a.v[1][0]*100+a.v[1][1]*1000+a.n*10000); putchar(10);\n struct A b = {{{1},{2,3}},9}; print_int(b.v[0][0]+b.v[0][1]+b.v[1][0]+b.v[1][1]+b.n); putchar(10);\n print_int(gp.x*1000+gp.in.a*100+gp.in.b*10+gp.y); putchar(10);\n print_int(ga.v[0][0]+ga.v[0][1]*10+ga.v[1][0]*100+ga.v[1][1]*1000+ga.n*10000); putchar(10);\n return 0;\n}\n"
