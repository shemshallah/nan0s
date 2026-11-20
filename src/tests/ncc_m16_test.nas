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
.str "int main(void){ char *s=\"hello world\"; printf(\"%d %d %d\\n\", (int)strchr(s,'o')-(int)s, (int)strstr(s,\"world\")-(int)s, (int)strstr(s,\"zzz\")); char *d=strdup(s); printf(\"%s %d\\n\", d, isdigit('7')+isalpha('A')*10+isspace(' ')*100+isupper('Q')*1000+islower('q')*10000); printf(\"%c %c %d %d\\n\", toupper('a'), tolower('Z'), labs(-7), (int)(memmove(s+1,s,5)!=0)); printf(\"%s\\n\", s); srand(1); printf(\"%d %d\\n\", rand()%100, rand()%100); return 0; }\n"
