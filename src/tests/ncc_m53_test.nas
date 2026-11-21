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
.str "int main(void){\n FILE *f=fopen(\"/fp1\",\"w\"); fputs(\"abcdef\",f); fclose(f);\n f=fopen(\"/fp1\",\"r\"); char b[4]={0}; fgets(b,4,f);\n long p; fgetpos(f,&p);\n char c=fgetc(f);\n fsetpos(f,&p);\n char d=fgetc(f);\n printf(\"%s %ld %c %c\\n\",b,p,c,d);\n fclose(f);\n f=freopen(\"/fp1\",\"r\",stdin);\n char e[8]={0}; fgets(e,8,f);\n printf(\"%s\\n\",e);\n return 0;\n}\n"
