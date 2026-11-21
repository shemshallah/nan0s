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
.str "int k;\nint main(){\n float A=0,B=0,i,j,z[1760];\n char b[1760];\n printf(\"\\x1b[2J\");\n for(;;){\n  memset(b,32,1760);\n  memset(z,0,7040);\n  for(j=0;6.28>j;j+=0.07)\n   for(i=0;6.28>i;i+=0.02){\n    float c=sin(i),d=cos(j),e=sin(A),f=sin(j),g=cos(A),h=d+2,D=1/(c*h*e+f*g+5),l=cos(i),m=cos(B),n=sin(B),t=c*h*g-f*e;\n    int x=40+30*D*(l*h*m-t*n),y=12+15*D*(l*h*n+t*m),o=x+80*y,N=8*((f*e-c*d*g)*m-c*d*e-f*g-l*d*n);\n    if(22>y&&y>0&&x>0&&80>x&&D>z[o]){z[o]=D;b[o]=\".,-~:;=!*#$@\"[N>0?N:0];}\n   }\n  printf(\"\\x1b[H\");\n  for(k=0;1761>k;k++) putchar(k%80?b[k]:10);\n  A+=0.04; B+=0.02;\n }\n}\n"
