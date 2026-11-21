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
.str "int main(void){\n lldiv_t a=lldiv(10LL,3); printf(\"%lld %lld\\n\",a.quot,a.rem);\n lldiv_t b=lldiv(-10LL,3); printf(\"%lld %lld\\n\",b.quot,b.rem);\n lldiv_t c=lldiv(10LL,-3); printf(\"%lld %lld\\n\",c.quot,c.rem);\n lldiv_t d=lldiv(-10LL,-3); printf(\"%lld %lld\\n\",d.quot,d.rem);\n div_t e=div(7,2); ldiv_t f=ldiv(-7,2); lldiv_t g=lldiv(1234567890123LL,7);\n printf(\"%d %d %ld %ld %lld %lld\\n\",e.quot,e.rem,f.quot,f.rem,g.quot,g.rem);\n return 0;\n}\n"
