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
.str "#include <stdio.h>\nint main(void) {\n  FILE *f = fopen(\"/tmp.txt\", \"w\");\n  fprintf(f, \"hello %d\\n\", 42);\n  fputs(\"second\\n\", f);\n  fputc('!', f); fputc('\\n', f);\n  fclose(f);\n  f = fopen(\"/tmp.txt\", \"r\");\n  char buf[64];\n  while (fgets(buf, 64, f)) printf(\"R:%s\", buf);\n  printf(\"tell=%d eof=%d\\n\", (int)ftell(f), (int)feof(f));\n  fseek(f, 0, SEEK_SET);\n  printf(\"first=%c\\n\", fgetc(f));\n  fclose(f);\n  rename(\"/tmp.txt\", \"/ren.txt\");\n  FILE *g = fopen(\"/ren.txt\", \"r\");\n  char data[8];\n  int n = fread(data, 1, 5, g);\n  data[n] = 0;\n  printf(\"read=%d %s\\n\", n, data);\n  fclose(g);\n  printf(\"rm=%d\\n\", remove(\"/ren.txt\"));\n  fprintf(stdout, \"out %d\\n\", 7);\n  return 0;\n}\n"
