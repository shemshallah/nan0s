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
.str "#include <stdatomic.h>\n#include <fenv.h>\n#include <threads.h>\nstatic int work(void *p){ return *(int*)p + 1; }\nstatic int once_body(void){ return 9; }\nint main(void){\n  atomic_int x = 0; atomic_flag fl = ATOMIC_FLAG_INIT;\n  atomic_store(&x, 41);\n  int a = atomic_load(&x);\n  int b = atomic_fetch_add(&x, 1);\n  int c = atomic_exchange(&x, 7);\n  int e = 7, d = atomic_compare_exchange_strong(&x, &e, 99);\n  printf(\"%d %d %d %d %d %d %d\\n\", a, b, c, d, atomic_load(&x), e, atomic_is_lock_free(&x));\n  printf(\"%d %d\\n\", atomic_flag_test_and_set(&fl), atomic_flag_test_and_set(&fl));\n  atomic_fetch_or_explicit(&x, 8, memory_order_relaxed);\n  printf(\"%d %d %d\\n\", atomic_load_explicit(&x, memory_order_acquire), memory_order_seq_cst, ATOMIC_FLAG_INIT);\n  printf(\"%d %d %d\\n\", fegetround(), FE_TONEAREST, FE_ALL_EXCEPT);\n  fenv_t env; fexcept_t ex;\n  printf(\"%d %d %d\\n\", fesetround(FE_UPWARD), fegetround(), feclearexcept(FE_ALL_EXCEPT));\n  printf(\"%d %d %d\\n\", fetestexcept(FE_INVALID), fegetenv(&env), feholdexcept(&env));\n  printf(\"%d %d\\n\", feupdateenv(&env), fegetexceptflag(&ex, FE_INVALID));\n  thrd_t t=0; int arg=41, res=0;\n  int r = thrd_create(&t, work, &arg);\n  int j = thrd_join(t, &res);\n  printf(\"%d %d %d %d\\n\", r, j, t, res);\n  mtx_t m; printf(\"%d \", mtx_init(&m, mtx_plain));\n  printf(\"%d \", mtx_lock(&m)); printf(\"%d \", mtx_trylock(&m)); printf(\"%d \", mtx_unlock(&m)); mtx_destroy(&m);\n  cnd_t cd; printf(\"%d \", cnd_init(&cd)); printf(\"%d \", cnd_signal(&cd)); cnd_destroy(&cd);\n  tss_t k; printf(\"%d \", tss_create(&k, 0)); printf(\"%d \", tss_set(k, 5)); printf(\"%d\\n\", tss_get(k));\n  once_flag of = 0; call_once(&of, once_body); printf(\"%d %d\\n\", of, thrd_success);\n  return 0;\n}\n"
