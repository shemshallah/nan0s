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
.str "struct S { int a; int b[]; };\n_Static_assert(sizeof(int)==4, \"int\");\n_Static_assert(_Alignof(double)==4, \"align\");\n_Static_assert(sizeof(struct S)==4, \"fam\");\nstruct T { char c; _Static_assert(sizeof(short)==2, \"member\"); int x; };\n_Alignas(64) int g;\n_Noreturn void noret(void) { }\n_Atomic int ai;\n_Thread_local int tl;\nint sum(int *a, int n){ int s=0, i; for(i=0;i<n;i++) s+=a[i]; return s; }\nint main(void){\n  _Static_assert((2+3)*4==20, \"expr\");\n  _Alignas(16) int x;\n  wchar_t w[] = L\"hi\";\n  printf(\"%d %d %d %d\\n\", (int)_Alignof(int), (int)_Alignof(char), (int)_Alignof(long long), (int)_Alignof(struct S));\n  printf(\"%d %d %d\\n\", (int)&g & 63, (int)&x & 15, (int)sizeof(struct T));\n  printf(\"%d %d %d %d\\n\", _Generic(1,int:1,char:2,default:3), _Generic((char)1,int:1,char:2,default:3), _Generic(1LL,long long:4,default:3), _Generic(&x,int*:5,default:3));\n  printf(\"%d %d %d %d\\n\", (int)sizeof(struct S), ai, tl, (int)sizeof w);\n  int a=(int){7}; int *p=(int[]){1,2,3};\n  struct T t=(struct T){.x=9};\n  printf(\"%d %d %d %d %d\\n\", a,p[2],t.c,t.x,((struct T){.c=4,.x=5}).x);\n  printf(\"%d %d %d\\n\", sum((int[]){4,5,6},3), (int)(L'A'), (int)(L'\\n'));\n  return 0;\n}\n"
