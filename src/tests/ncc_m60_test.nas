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
.str "struct tv{int s,us;};\nstruct it{struct tv i; struct tv v;};\nint hit=0;\nvoid h(int s){hit=1;}\nint main(void){\n signal(14,h);\n struct it t={{0,0},{0,200000}};\n struct it o;\n int r=setitimer(0,&t,&o);\n printf(\"%d %d %d\\n\",r,o.v.s,o.v.us);\n while(!hit){}\n printf(\"%d\\n\",hit);\n struct it g; getitimer(0,&g);\n printf(\"%d %d\\n\",g.v.s,g.v.us);\n return 0;\n}\n"
