; ncc #if/#elif expression gate. The parser handles integer and character
; constants, object-like macro values, defined(), parentheses, the full
; binary operator set, unary ! ~ + -, and ?: at the outermost level.
; Execution is raw NaN16.
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
.str "#if 1 + 2 * 3 == 7\nint a=1;\n#else\nint a=0;\n#endif\n#if (1 << 4) == 16\nint b=1;\n#else\nint b=0;\n#endif\n#if (16 >> 2) == 4\nint c=1;\n#else\nint c=0;\n#endif\n#if (5 & 3) == 1\nint d=1;\n#else\nint d=0;\n#endif\n#if (5 | 2) == 7\nint e=1;\n#else\nint e=0;\n#endif\n#if (5 ^ 1) == 4\nint f=1;\n#else\nint f=0;\n#endif\n#if -1 < 0\nint g=1;\n#else\nint g=0;\n#endif\n#if ~0 == -1\nint h=1;\n#else\nint h=0;\n#endif\n#if 10 / 3 == 3\nint i=1;\n#else\nint i=0;\n#endif\n#if 10 % 3 == 1\nint j=1;\n#else\nint j=0;\n#endif\n#if defined(A) || defined(B)\nint k=0;\n#else\nint k=1;\n#endif\n#if defined (UNDEFINED_NAME)\nint l=1;\n#else\nint l=0;\n#endif\n#if UNDEFINED_NAME == 0\nint m=1;\n#else\nint m=0;\n#endif\n#if 0\n#elif 1\nint n=1;\n#else\nint n=0;\n#endif\n#if 0\n# if 1\nint bad=1;\n# endif\n#else\nint o=1;\n#endif\n#if (1 ? 2 : 3) == 2\nint p=1;\n#else\nint p=0;\n#endif\n#if (0 ? 2 : 3) == 3\nint q=1;\n#else\nint q=0;\n#endif\n#if (0 ? 1 : (2 ? 3 : 4)) == 3\nint r=1;\n#else\nint r=0;\n#endif\n#if (1 ? (0 ? 5 : 6) : 7) == 6\nint s=1;\n#else\nint s=0;\n#endif\nint main(){ printf(\"%d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d\\n\",a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,p,q,r,s); return 0; }\n"
