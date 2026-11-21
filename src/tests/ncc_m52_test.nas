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
.str "int vss(const char *s,const char *f,...){ va_list ap; va_start(ap,f); int n=vsscanf(s,f,ap); va_end(ap); return n; }\nint vfs(FILE *fp,const char *f,...){ va_list ap; va_start(ap,f); int n=vfscanf(fp,f,ap); va_end(ap); return n; }\nint vsc(const char *f,...){ va_list ap; va_start(ap,f); int n=vscanf(f,ap); va_end(ap); return n; }\nint main(void){\n int a=0; char b[16]={0};\n int n=vss(\"42 hi\",\"%d %s\",&a,b);\n printf(\"%d %d %s\\n\",n,a,b);\n FILE *f=fopen(\"/vsin\",\"w\"); fputs(\"5 6\",f); fclose(f);\n f=fopen(\"/vsin\",\"r\"); int x=0,y=0;\n int m=vfs(f,\"%d %d\",&x,&y); fclose(f);\n printf(\"%d %d %d\\n\",m,x,y);\n int z=0; char t[8]={0};\n int k=vsc(\"%d %s\",&z,t);\n printf(\"%d %d %s\\n\",k,z,t);\n return 0;\n}\n"
