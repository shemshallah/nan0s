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
.str "#include <stdio.h>\n#include <time.h>\n#include <locale.h>\n#include <signal.h>\n#include <stdlib.h>\nint main(void) {\n  time_t t = 1700000000;\n  struct tm *tm = gmtime(&t);\n  printf(\"%04d-%02d-%02d %02d:%02d:%02d %d %d\\n\", tm->tm_year+1900, tm->tm_mon+1, tm->tm_mday, tm->tm_hour, tm->tm_min, tm->tm_sec, tm->tm_wday, tm->tm_yday);\n  printf(\"%d %d\\n\", (int)mktime(tm), (int)difftime(1700000100, t));\n  printf(\"%s\", asctime(tm));\n  printf(\"%s\", ctime(&t));\n  printf(\"%d %d\\n\", (int)(time(0) > 0), (int)(clock() >= 0));\n  double a = atof(\"3.5\");\n  double c;\n  char *e;\n  c = strtod(\"2.75x\", &e);\n  printf(\"%.2f %.1f %s\\n\", a, c, e);\n  printf(\"%s %d\\n\", setlocale(0, \"C\"), (int)(signal(SIGINT, SIG_IGN) == SIG_DFL));\n  printf(\"%d %d %d %d\\n\", EOF, SEEK_END, CHAR_BIT, (int)SIZE_MAX);\n  return 0;\n}\n"
