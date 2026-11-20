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
.str "struct S { int a; int b; };\nunion U { int i; char c[4]; };\nvoid mod(struct S s){ s.a=99; }\nstruct S add(struct S a, struct S b){ struct S r; r.a=a.a+b.a; r.b=a.b+b.b; return r; }\nunion U mku(int v){ union U u; u.i=v; return u; }\nint getu(union U u){ return u.i; }\nint main(void){\n struct S x; x.a=1; x.b=2; mod(x); print_int(x.a); putchar(10);\n struct S y=add(x, x); print_int(y.a*10+y.b); putchar(10);\n print_int(getu(mku(1234))); putchar(10);\n struct S z; z=x; print_int(z.a+z.b); putchar(10);\n return 0;\n}\n"
