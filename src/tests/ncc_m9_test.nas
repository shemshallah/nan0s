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
.str "int add(int a,int b){ return a+b; }\nint mul(int a,int b){ return a*b; }\ntypedef int (*binop)(int,int);\nint apply(binop f,int a,int b){ return f(a,b); }\nint apply2(int (*f)(int,int),int a,int b){ return f(a,b); }\nbinop pick(void){ return add; }\nstruct S { binop f; int n; };\nint (*g)(int,int);\nbinop arr[2];\nint main(void){\n int (*l)(int,int)=mul;\n g=add; print_int(l(20,22)); putchar(10);\n l=g; print_int(g(6,7)); putchar(10);\n print_int(l==add); print_int(l==mul); putchar(10);\n binop p=pick(); print_int(apply(p,1,2)); putchar(10);\n print_int(apply2(mul,3,4)); putchar(10);\n arr[0]=add; print_int(arr[0](2,3)); putchar(10);\n struct S s; s.f=add; s.n=5; print_int(s.f(3,4)); putchar(10);\n int (*r)(int,int)=add; print_int((*r)(4,5)); putchar(10);\n return 0;\n}\n"
