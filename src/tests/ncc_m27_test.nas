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
.str "#include <stdio.h>\n#include <string.h>\nint main(void){\n struct tm t;\n t.tm_year=124;t.tm_mon=0;t.tm_mday=2;t.tm_hour=3;t.tm_min=4;t.tm_sec=5;\n t.tm_wday=2;t.tm_yday=1;t.tm_isdst=0;\n char b[80];\n int n=strftime(b,80,\"%Y-%m-%d %H:%M:%S %a %A %b %B %j %p %%\",&t);\n printf(\"%d:%s\\n\",n,b);\n char tmp[32]; tmpnam(tmp); puts(tmp);\n FILE *f=tmpfile(); fputs(\"hi there\",f); rewind(f);\n char s[16]; fgets(s,16,f); puts(s); fclose(f);\n wchar_t a[8],c[8]; a[0]=104;a[1]=105;a[2]=0;\n printf(\"%d \",wcslen(a));\n wcscpy(c,a); c[2]=33;c[3]=0; printf(\"%d \",wcscmp(a,c));\n c[2]=0; printf(\"%d \",wcscmp(a,c));\n wcscat(c,a); printf(\"%d\\n\",wcslen(c));\n return 0;\n}\n"
