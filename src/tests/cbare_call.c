/* cbare_call.c - C-port guest calling NaN16 machine services via a table. */
typedef int (*cb_fn)(int);
#define CB_W 0x00C00000u
#define CB_TABLE (CB_W + 7u)
int main(void) {
    volatile unsigned *tab = (volatile unsigned *)((CB_TABLE) * 4u);
    cb_fn svc_putc = (cb_fn)tab[0];
    cb_fn svc_tick = (cb_fn)tab[1];
    svc_putc('N'); svc_putc('a'); svc_putc('N'); svc_putc('\n');
    return svc_tick(0) >= 0 ? 42 : 1;
}
