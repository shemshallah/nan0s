/* smp_tramp.S - minimal AP startup trampoline for the x86_64 S1 SMP slice.
 *
 * This blob is linked at physical 0x8000 and copied there by the BSP.  An AP
 * wakes from INIT/SIPI in real mode with CS:IP = vector<<12:0, which is
 * exactly _start.  The BSP fills the boot block at SME_BOOT (0x9000) before
 * each SIPI:
 *
 *   +0  cr3 (low 32 bits; the page-table root is below 4 GiB)
 *   +8  stack top (64-bit)
 *   +16 C entry point (64-bit, ap_main)
 *   +24 cpu index (64-bit)
 *
 * The trampoline only wants the shared identity map created by s1_boot.S.
 * It deliberately does not touch the BSP's stack, GDT or IDT.  IF stays
 * clear until ap_main enables interrupts after installing the IDT.
 *
 * Build: tools/nansmp_gate.sh (standalone link at 0x8000).
 */
.equ SME_BOOT, 0x9000
.equ SME_REAL_STACK, 0x7000

.code16
.globl _start
_start:
    cli
    cld
    xor %ax, %ax
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %ss
    mov $SME_REAL_STACK, %sp
    lgdt gdtr
    mov %cr0, %eax
    or $1, %eax                 /* PE */
    mov %eax, %cr0
    ljmp $0x18, $pm32

.code32
pm32:
    mov $0x20, %ax
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %ss
    mov %ax, %fs
    mov %ax, %gs

    mov $SME_BOOT, %ebx
    mov 0(%ebx), %eax
    mov %eax, %cr3
    mov %cr4, %eax
    or $0x620, %eax             /* PAE | OSFXSR | OSXMMEXCPT */
    mov %eax, %cr4

    mov $0xC0000080, %ecx
    rdmsr
    or $0x100, %eax             /* EFER.LME */
    wrmsr

    mov %cr0, %eax
    or $0x80000001, %eax        /* PG | PE (PE is already set) */
    mov %eax, %cr0
    ljmp $0x08, $lm64

.code64
lm64:
    mov $0x10, %ax
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %ss
    mov %ax, %fs
    mov %ax, %gs

    mov $SME_BOOT, %rbx
    mov 8(%rbx), %rsp
    mov 24(%rbx), %rdi          /* cpu index, SysV first argument */
    mov 16(%rbx), %rax          /* C entry */
    xor %rbp, %rbp
    call *%rax

1:
    cli
    hlt
    jmp 1b

.align 8
gdt:
    .quad 0
    .quad 0x00AF9A000000FFFF    /* 0x08 64-bit code, DPL0 */
    .quad 0x00AF92000000FFFF    /* 0x10 64-bit data, DPL0 */
    .quad 0x00CF9A000000FFFF    /* 0x18 32-bit code, DPL0 */
    .quad 0x00CF92000000FFFF    /* 0x20 32-bit data, DPL0 */
gdt_end:
gdtr:
    .word gdt_end - gdt - 1
    .long gdt
