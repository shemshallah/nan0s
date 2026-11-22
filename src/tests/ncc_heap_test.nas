; ncc dynamic-VM heap gate: the same C program over different VM sizes.
; The guest C runtime discovers the word count through CPUID 0x4E4D00FF,
; puts an 8 MiB stack at the top of the payload (1 MiB when small) and gives
; the heap everything in between.
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
.str "int main(void){\n char *p=malloc(100000000);\n printf(\"BIG %d\\n\",p!=0);\n if(p){ p[0]=11; p[99999999]=22; printf(\"EDGE %d %d\\n\",p[0],p[99999999]); free(p); }\n char *q=malloc(1000000);\n printf(\"MB %d\\n\",q!=0);\n free(q);\n char *r=malloc(100000000);\n printf(\"REUSE %d\\n\",r==p);\n free(r);\n printf(\"HEAP PASS\\n\");\n return 0;\n}\n"
