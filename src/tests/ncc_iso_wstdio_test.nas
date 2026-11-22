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
.str "#include <stdarg.h>\nint myvsw(wchar_t *b, size_t n, const wchar_t *f, ...){ va_list ap; va_start(ap,f); int r=vswprintf(b,n,f,ap); va_end(ap); return r; }\nint myvfw(const wchar_t *f, ...){ va_list ap; va_start(ap,f); int r=vfwprintf(stdout,f,ap); va_end(ap); return r; }\nint myvsws(const wchar_t *s, const wchar_t *f, ...){ va_list ap; va_start(ap,f); int r=vswscanf(s,f,ap); va_end(ap); return r; }\nint main(void){\n  wchar_t b[64], c[64], src[] = L\"123 word\";\n  int n = swprintf(b,64,L\"%d %ls\",42,L\"hi\");\n  printf(\"n=%d b=%ls\\n\", n, b);\n  n = myvsw(c,64,L\"%x-%c\",255,'Z');\n  printf(\"n=%d c=%ls\\n\", n, c);\n  fwprintf(stdout,L\"fw %d %s\\n\",7,\"x\");\n  myvfw(L\"vf %d %ls\\n\",9,L\"ok\");\n  int a=0; wchar_t w[16];\n  int r = swscanf(src,L\"%d %ls\",&a,w);\n  printf(\"r=%d a=%d w=%ls\\n\",r,a,w);\n  a=0; w[0]=0;\n  r = myvsws(L\"77 yes\", L\"%d %ls\", &a, w);\n  printf(\"r=%d a=%d w=%ls\\n\",r,a,w);\n  wchar_t lc = L'A'; wchar_t nl = L'\\n';\n  printf(\"%d %d\\n\", (int)lc, (int)nl);\n  return 0;\n}\n"
