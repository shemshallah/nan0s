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
.str "#define ADD(a,b) ((a)+(b))\n#define TWICE(x) ADD(x,x)\n#define STR(x) #x\n#define CAT(a,b) a##b\n#define NOP() 7\n#define MULTI(a,b) \\\n  ((a) * (b))\n#define PICK(a,b) b\n#define G(x) H(x)\n#define H(x) ((x)+100)\n#define F(x) ((x)*3)\n#undef F\n#define F(x) ((x)*5)\nint main(void) {\n  int CAT(my,var) = 7;\n  print_int(ADD(20,22)); putchar(10);\n  print_int(TWICE(3)); putchar(10);\n  puts(STR(hi there));\n  print_int(myvar); putchar(10);\n  print_int(NOP()); putchar(10);\n  print_int(MULTI(2,5)); putchar(10);\n  print_int(PICK((1+2),4)); putchar(10);\n  print_int(G(1)); putchar(10);\n  print_int(F(2)); putchar(10);\n  return 0;\n}\n"
