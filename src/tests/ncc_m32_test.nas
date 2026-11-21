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
.str "struct S{int a,b;};\nstruct T{struct S s; int z;};\nstruct T gt={.s={.b=2,.a=1},.z=9};\nint ga[5]={[2]=7,[0]=3};\nstruct S gs[2]={{1,2},{3,4}};\nint main(void){\n struct S s={.b=4,.a=5};\n struct T t={.s={.a=6,.b=7},.z=8};\n int a[5]={[4]=9,[1]=2};\n struct S as[2]={[1].b=7,[0].a=3};\n printf(\"%d %d %d\\n\",s.a,s.b,gt.s.b);\n printf(\"%d %d %d %d %d\\n\",a[0],a[1],a[2],a[4],ga[2]);\n printf(\"%d %d %d %d\\n\",t.s.a,t.s.b,t.z,ga[0]);\n printf(\"%d %d %d %d\\n\",as[0].a,as[1].b,as[1].a,gs[1].b);\n return 0;\n}\n"
