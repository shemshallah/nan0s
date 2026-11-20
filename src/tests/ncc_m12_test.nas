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
.str "struct S { int a; int b; };\nint f(int n, ...){ va_list ap; va_start(ap,n); int a=va_arg(ap,int); va_end(ap); return a; }\nint sum(int n, ...){ va_list ap; va_start(ap,n); int s=0; int i; for(i=0;i<n;i++) s+=va_arg(ap,int); va_end(ap); return s; }\nint mix(int n, ...){ va_list ap; va_start(ap,n); int s=va_arg(ap,int); char c=(char)va_arg(ap,int); double d=va_arg(ap,double); va_end(ap); printf(\"%d %c %d\\n\", s, c, (int)(d*10)); return s+n; }\nint ssum(int n, ...){ va_list ap; va_start(ap,n); int t=0; int i; for(i=0;i<n;i++){ struct S s=va_arg(ap,struct S); t+=s.a+s.b; } va_end(ap); return t; }\nint main(void){\n print_int(f(1,42)); putchar(10);\n print_int(sum(4,1,2,3,4)); putchar(10);\n print_int(sum(3,-1,5,6)); putchar(10);\n print_int(mix(1,7,65,2.5)); putchar(10);\n struct S x; x.a=3; x.b=4; print_int(ssum(2,x,x)); putchar(10);\n return 0;\n}\n"
