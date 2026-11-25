/* First job of the multi-job linker regression: materialise a non-zero
   global pointer address.  Its relocation must not leak into the next
   TCCState compiled in the same process. */
int *mp;

int main(void)
{
    mp = (int *)0x123456;
    return mp == (int *)0x123456 ? 0 : 1;
}
