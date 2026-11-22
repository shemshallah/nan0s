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
.str "int main(void){\n  char16_t u16[8]; char32_t u32[8];\n  mbstate_t st=0, st2=0;\n  const char *s = \"A\\xC3\\xA9\\xE2\\x82\\xAC\\xF0\\x9F\\x98\\x80\";\n  int i=0; size_t n; char buf[16];\n  while (1) {\n    n = mbrtoc16(&u16[i], s, 4, &st);\n    if (n == 0) break;\n    if (n == (size_t)-1 || n == (size_t)-2) { u16[0]=0xDEAD; break; }\n    if (n == (size_t)-3) { i++; continue; }\n    s += n; i++;\n  }\n  printf(\"%d %x %x %x %x %x\\n\", i, u16[0],u16[1],u16[2],u16[3],u16[4]);\n  s = \"A\\xC3\\xA9\\xE2\\x82\\xAC\\xF0\\x9F\\x98\\x80\"; i=0;\n  while ((n = mbrtoc32(&u32[i], s, 4, &st2)) != 0 && n != (size_t)-1 && n != (size_t)-2) { s += n; i++; }\n  printf(\"%d %x %x %x %x\\n\", i, u32[0],u32[1],u32[2],u32[3]);\n  n = c32rtomb(buf, 0x20AC, &st2); printf(\"%d %d %d %d\\n\", n, (unsigned char)buf[0], (unsigned char)buf[1], (unsigned char)buf[2]);\n  n = c16rtomb(buf, 0xD83D, &st2); printf(\"%d \", n);\n  n = c16rtomb(buf, 0xDE00, &st2); printf(\"%d %d %d %d\\n\", n, (unsigned char)buf[0], (unsigned char)buf[1], (unsigned char)buf[3]);\n  printf(\"%d %d %d\\n\", (int)sizeof(char16_t), (int)sizeof(char32_t), __STDC_UTF_16__ == 1 && __STDC_UTF_32__ == 1);\n  return 0;\n}\n"
