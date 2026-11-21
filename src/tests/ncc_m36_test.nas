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
.str "struct S{int a,b;};\nint ga[]={1,2,3};\nint main(void){\n int a[]={4,5,6};\n struct S s[]={{7,8},{9,10}};\n wchar_t w[]={65,66,0};\n int d[]={[4]=1};\n printf(\"%d %d %d\\n\",(int)sizeof(a),a[0],a[2]);\n printf(\"%d %d %d\\n\",(int)sizeof(s),s[0].a,s[1].b);\n printf(\"%d %d %d %d\\n\",(int)sizeof(ga),ga[2],(int)sizeof(w),w[1]);\n printf(\"%d %d\\n\",(int)sizeof(d),d[4]);\n return 0;\n}\n"
