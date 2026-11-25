/* s1_boot.S - 32-bit boot -> x86-64 long mode -> s1_kabi.c.
 *
 * This is the primary-target first S1 slice: the 64-bit C interpreter in
 * s1_kabi.c owns fetch/decode/gate/trap/memory/ports/timer/regions.  The
 * assembly here only builds the identity page tables and enters long mode.
 */
.code32
.globl _start
_start:
    cli
    cld

    /* zero PML4 0x30000, PDPT 0x31000, PD 0x32000, spare 0x33000 */
    mov $0x30000, %edi
    xor %eax, %eax
    mov $(4 * 4096 / 4), %ecx
    rep stosl

    movl $0x31003, 0x30000          /* PML4[0] -> PDPT */
    movl $0x32003, 0x31000          /* PDPT[0] -> PD   */
    mov $0x32000, %edi
    xor %ecx, %ecx
1:
    mov %ecx, %eax
    shl $21, %eax
    or $0x83, %eax                  /* present | rw | 2 MiB */
    mov %eax, (%edi,%ecx,8)
    movl $0, 4(%edi,%ecx,8)
    inc %ecx
    cmp $512, %ecx
    jb 1b

    lgdt gdtr

    mov %cr4, %eax
    or $0x620, %eax                 /* PAE | OSFXSR | OSXMMEXCPT */
    mov %eax, %cr4
    mov $0x30000, %eax
    mov %eax, %cr3

    mov $0xC0000080, %ecx
    rdmsr
    or $0x100, %eax                 /* EFER.LME */
    wrmsr

    mov %cr0, %eax
    and $0xFFFFFFFB, %eax           /* clear EM (SSE is used by C code) */
    or $0x80000002, %eax            /* MP | PG */
    mov %eax, %cr0

    ljmp $0x08, $long_mode

.code64
long_mode:
    mov $0x10, %ax
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %ss
    mov %ax, %fs
    mov %ax, %gs
    mov $0x1F0000, %rsp
    cld

    /* .bss is NOLOAD: zero it before any C static state is used. */
    lea __bss_start(%rip), %rdi
    lea __bss_end(%rip), %rcx
    sub %rdi, %rcx
    xor %eax, %eax
    rep stosb

    call s1_main
2:
    hlt
    jmp 2b

.align 8
gdt:
    .quad 0
    .quad 0x00AF9A000000FFFF         /* 64-bit code, DPL0, L=1 */
    .quad 0x00AF92000000FFFF         /* 64-bit data */
gdt_end:
gdtr:
    .word gdt_end - gdt - 1
    .long gdt
