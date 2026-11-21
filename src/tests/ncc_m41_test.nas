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
.str "struct S{int a,b;};\nstruct A{int x[2]; int y;};\nstruct T{struct S s; int z;};\nstruct Q{char name[6]; int v;};\nstruct P{short a,b;};\nunion U{struct P p; int i;};\nstruct S gs[2]={1,2,3,4};\nstruct T gt={7,8,9};\nint main(void){\n struct T t={1,2,3};\n struct A a={4,5,6};\n struct S s={10,11};\n struct T c={s,12};\n struct T mx={{13,14},15};\n struct Q q={\"hi\",16};\n union U u={17,18};\n int m[2][3]={1,2,3,4};\n printf(\"%d %d %d\\n\",t.s.a,t.s.b,t.z);\n printf(\"%d %d %d\\n\",a.x[0],a.x[1],a.y);\n printf(\"%d %d %d\\n\",c.s.a,c.s.b,c.z);\n printf(\"%d %d %d\\n\",mx.s.a,mx.s.b,mx.z);\n printf(\"%s %d\\n\",q.name,q.v);\n printf(\"%d %d\\n\",u.p.a,u.p.b);\n printf(\"%d %d %d %d\\n\",m[0][2],m[1][0],m[1][1],m[1][2]);\n printf(\"%d %d %d %d %d %d\\n\",gs[0].a,gs[0].b,gs[1].a,gs[1].b,gt.s.a,gt.z);\n return 0;\n}\n"
