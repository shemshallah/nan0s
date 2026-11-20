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
.str "#include <stdio.h>\nint main(void) {\n  int a=0,b=0; char s[16]; double f=0;\n  int n=sscanf(\"42 -7 hi 3.5\",\"%d %d %15s %f\",&a,&b,s,&f);\n  printf(\"%d: %d %d %s %.2f\\n\",n,a,b,s,f);\n  int h=0; char t[8];\n  int q=sscanf(\"ff 1234\",\"%x %4s\",&h,t);\n  printf(\"%d: %d %s\\n\",q,h,t);\n  FILE *p=fopen(\"/scan.txt\",\"w\"); fputs(\"10 20\",p); fclose(p);\n  p=fopen(\"/scan.txt\",\"r\");\n  int x=0,y=0; int m=fscanf(p,\"%d %d\",&x,&y);\n  printf(\"%d: %d %d\\n\",m,x,y);\n  fclose(p);\n  printf(\"rm=%d\\n\",remove(\"/scan.txt\"));\n  return 0;\n}\n"
