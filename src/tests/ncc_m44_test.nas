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
.str "struct F{unsigned a:3;unsigned b:5;signed d:4;};\nstruct Z{unsigned a:3;unsigned :0;unsigned b:5;};\nstruct N{int x; struct F f; int y;};\nstruct F g={9,33,-3};\nint main(void){\n struct F f={1,2,-3};\n f.a+=2; f.b=7;\n struct F *p=&f; p->d=5;\n struct F a[2]={1,2,3,4};\n struct Z z={5,9};\n struct N n={4,{1,2,-3},9};\n printf(\"%d %d %d %d\\n\",(int)sizeof f,f.a,f.b,f.d);\n printf(\"%d %d %d\\n\",g.a,g.b,g.d);\n printf(\"%d %d %d %d %d\\n\",(int)sizeof a,a[0].a,a[0].b,a[1].a,a[1].b);\n printf(\"%d %d %d %d\\n\",(int)sizeof z,z.a,z.b,(int)sizeof n);\n printf(\"%d %d %d %d\\n\",n.x,n.f.a,n.f.b,n.y);\n return 0;\n}\n"
