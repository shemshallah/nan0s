; ncc DP4B builtin gate: the C front end emits ISA 0x4A for dp4b(a,b).
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
.str "int main(void){\n printf(\"%08X\\n\", dp4b(0x04030201u,0x08070605u));\n printf(\"%08X\\n\", dp4b(0xFCFDFEFFu,0x04030201u));\n printf(\"%08X\\n\", dp4b(0x7F7F7F7Fu,0x7F7F7F7Fu));\n printf(\"%08X\\n\", dp4b(0x80808080u,0x80808080u));\n printf(\"%08X\\n\", dp4b(0x00000080u,0x00000001u));\n printf(\"%08X\\n\", dp4b(0x01020304u,0u));\n return 0;\n}\n"
