; ncc S0 allocator gate: 10,000 random malloc/free/realloc operations.
; Checks 4-byte alignment, no overlap among live blocks, no leaks (all blocks
; freed and followed by a 1.9 MB allocation), full-pattern preservation across
; realloc, calloc zeroing/overflow, and realloc(NULL,n). Compiler + allocator
; are raw NaN16; the C source is embedded below.
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
.str "char *lp[24];\nint ls[24];\nint lt[24];\nint nl;\nunsigned char ref[1024];\nint ov(char *p,int n){ int i; unsigned a=(unsigned)p; for(i=0;i<nl;i++){ unsigned b=(unsigned)lp[i]; if(a < b+(unsigned)ls[i] && b < a+(unsigned)n) return i+1; } return 0; }\nint same(char *p,int n,int t){ memset(ref,t,n); return memcmp(p,(char*)ref,n)==0; }\nint main(void){\n int i,step;\n srand(12345); nl=0;\n for(step=0;step<10000;step++){\n  int op=rand()%10;\n  if((op<6 && nl<24) || nl==0){\n   int sz=rand()%512+1;\n   char *p=malloc(sz);\n   if(!p){ printf(\"malloc fail %d\\n\",step); return 1; }\n   if(((unsigned)p)&3){ printf(\"align %d\\n\",step); return 1; }\n   if(ov(p,sz)){ printf(\"overlap %d\\n\",step); return 1; }\n   int t=rand()%256; memset(p,t,sz);\n   lp[nl]=p; ls[nl]=sz; lt[nl]=t; nl++;\n  } else if(op<9){\n   int j=rand()%nl;\n   if(!same(lp[j],ls[j],lt[j])){ printf(\"corruptB %d\\n\",step); return 1; }\n   free(lp[j]); lp[j]=lp[nl-1]; ls[j]=ls[nl-1]; lt[j]=lt[nl-1]; nl--;\n  } else {\n   int j=rand()%nl;\n   int old=ls[j], t=lt[j]; char *oldp=lp[j];\n   if(!same(oldp,old,t)){ printf(\"corruptC %d\\n\",step); return 1; }\n   int nsz=rand()%1024+1;\n   lp[j]=lp[nl-1]; ls[j]=ls[nl-1]; lt[j]=lt[nl-1]; nl--;\n   char *np=realloc(oldp,nsz);\n   if(!np){ printf(\"realloc fail %d\\n\",step); return 1; }\n   if(((unsigned)np)&3){ printf(\"alignR %d\\n\",step); return 1; }\n   if(ov(np,nsz)){ printf(\"overlapR %d\\n\",step); return 1; }\n   int keep=old<nsz?old:nsz;\n   if(!same(np,keep,t)){ printf(\"preserve %d\\n\",step); return 1; }\n   int nt=rand()%256; memset(np,nt,nsz);\n   lp[nl]=np; ls[nl]=nsz; lt[nl]=nt; nl++;\n  }\n }\n for(i=0;i<nl;i++) if(!same(lp[i],ls[i],lt[i])){ printf(\"final %d\\n\",i); return 1; }\n for(i=0;i<nl;i++) free(lp[i]);\n char *big=malloc(6899992); printf(\"BIG %d\\n\",big!=0);\n free(big);\n char *big2=malloc(6899992); printf(\"REUSE %d\\n\",big2==big);\n free(big2);\n char *z=calloc(100,4); int zok=1; unsigned char *zc=(unsigned char*)z; for(i=0;i<400;i++) if(zc[i]) zok=0; printf(\"CALLOC %d\\n\",zok); free(z);\n printf(\"OVERFLOW %d\\n\",calloc(0x80000000u,4)==0);\n char *r=realloc(0,20); printf(\"RN %d\\n\",r!=0); free(r);\n printf(\"ALLOC PASS\\n\");\n return 0;\n}\n"
