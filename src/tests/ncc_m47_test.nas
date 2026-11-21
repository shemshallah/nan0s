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
.str "#include <stdio.h>\n#include <stdarg.h>\nint vp(const char *f,...){ va_list ap; va_start(ap,f); int n=vprintf(f,ap); va_end(ap); return n; }\nint vs(char *d,const char *f,...){ va_list ap; va_start(ap,f); int n=vsprintf(d,f,ap); va_end(ap); return n; }\nint vn(char *d,int z,const char *f,...){ va_list ap; va_start(ap,f); int n=vsnprintf(d,z,f,ap); va_end(ap); return n; }\nint vf(FILE *fp,const char *f,...){ va_list ap; va_start(ap,f); int n=vfprintf(fp,f,ap); va_end(ap); return n; }\nint main(void){\n int n=vp(\"[%d %s %*d %.2f]\\n\",42,\"ok\",5,7,3.14159);\n printf(\"n=%d\\n\",n);\n char b[64]; int m=vs(b,\"%lld/%x\",1234567890123LL,255);\n printf(\"%s|%d\\n\",b,m);\n char c[8]; int k=vn(c,8,\"%s-%d\",\"abcdef\",42);\n printf(\"%s|%d\\n\",c,k);\n FILE *f=fopen(\"/vlog\",\"w\"); int q=vf(f,\"%d+%d=%d\",2,3,5); fclose(f);\n f=fopen(\"/vlog\",\"r\"); char d[32]; fgets(d,32,f);\n printf(\"%s|%d\\n\",d,q);\n printf(\"[%*d][%.*f]\\n\",6,42,3,2.71828);\n return 0;\n}\n"
