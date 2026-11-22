; ncc_aligned_test.nas - C11 aligned_alloc on the NaN-native S0 heap.
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
.str "int main(void){\n unsigned char *a=aligned_alloc(64,100);\n unsigned char *b=aligned_alloc(16,3);\n printf(\"%d %d %d\\n\",((unsigned)a)&63,((unsigned)b)&15,a!=0&&b!=0);\n if(!a||!b) return 1;\n a[0]=1; a[99]=2; b[0]=3;\n printf(\"%d %d %d\\n\",a[0],a[99],b[0]);\n free(a); free(b);\n void *c=malloc(100);\n printf(\"%d\\n\",c!=0);\n free(c);\n char *d=aligned_alloc(32,8); d[0]=7; d=realloc(d,16);\n printf(\"%d\\n\",d!=0&&d[0]==7);\n free(d);\n printf(\"ALIGN PASS\\n\");\n return 0;\n}\n"
