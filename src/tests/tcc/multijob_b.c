/* Second job: enough code at the same text offsets to expose stale
   relocations from the previous job. */
int main(void)
{
    int i, s = 0;
    for (i = 0; i < 100; i++)
        s += i;
    return s == 4950 ? 42 : 1;
}
