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
.str "int main(void){ struct lconv *lc = localeconv(); printf(\"%d %d %d\\n\", (int)lc, (int)lc->decimal_point, (int)&lc->decimal_point); char *p = lc->decimal_point; printf(\"%c%c\\n\", p[0], p[1]); return 0; }\n"
