/* mem64_boot.S - 32-bit entry -> 4/5-level long mode -> mem64_main.
 *
 * The boot map covers the first 1 GiB identity with 2 MiB pages so the C
 * memory layer can allocate its own tables above 0x100000.  If CPUID says
 * LA57 is available, the root is a PML5 and the full 4 PiB physical space is
 * reachable; otherwise the root is a PML4 (48-bit virtual fallback).
 *
 * No host services.  The only fixed structures here are the initial root
 * tables at 0x30000..0x33fff and the stack at 0x7E00000.
 */
.code32
.globl _start
_start:
    cli
    cld

    /* zero the four boot page-table pages */
    mov $0x30000, %edi
    xor %eax, %eax
    mov $(4 * 4096 / 4), %ecx
    rep stosl

    /* CPUID.7.0:ECX[16] = LA57 */
    mov $0, %eax
    cpuid
    cmp $7, %eax
    jb .L4

    mov $7, %eax
    xor %ecx, %ecx
    cpuid
    test $0x10000, %ecx
    jz .L4

    /* 5-level: PML5 0x30000 -> PML4 0x31000 -> PDPT 0x32000 -> PD 0x33000 */
    movl $0x31003, 0x30000
    movl $0x32003, 0x31000
    movl $0x33003, 0x32000
    mov $0x33000, %edi
    xor %ecx, %ecx
1:
    mov %ecx, %eax
    shl $21, %eax
    or $0x83, %eax
    mov %eax, (%edi,%ecx,8)
    movl $0, 4(%edi,%ecx,8)
    inc %ecx
    cmp $512, %ecx
    jb 1b

    mov %cr4, %eax
    or $0x1000, %eax             /* CR4.LA57 */
    or $0x20, %eax               /* CR4.PAE */
    mov %eax, %cr4
    mov $0x30000, %eax
    mov %eax, %cr3
    movl $5, boot_levels
    jmp .Lenable

.L4:
    /* 4-level fallback: PML4 0x30000 -> PDPT 0x31000 -> PD 0x32000 */
    movl $0x31003, 0x30000
    movl $0x32003, 0x31000
    mov $0x32000, %edi
    xor %ecx, %ecx
2:
    mov %ecx, %eax
    shl $21, %eax
    or $0x83, %eax
    mov %eax, (%edi,%ecx,8)
    movl $0, 4(%edi,%ecx,8)
    inc %ecx
    cmp $512, %ecx
    jb 2b

    mov %cr4, %eax
    or $0x20, %eax               /* CR4.PAE */
    mov %eax, %cr4
    mov $0x30000, %eax
    mov %eax, %cr3
    movl $4, boot_levels

.Lenable:
    mov $0xC0000080, %ecx
    rdmsr
    or $0x900, %eax              /* EFER.LME | EFER.NXE */
    wrmsr

    mov %cr0, %eax
    and $0xFFFFFFFB, %eax        /* clear EM */
    or $0x80000002, %eax         /* MP | PG */
    mov %eax, %cr0

    lgdt gdtr
    ljmp $0x08, $long_mode

.code64
long_mode:
    mov $0x10, %ax
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %ss
    mov %ax, %fs
    mov %ax, %gs
    mov $0x7E00000, %rsp
    cld

    lea __bss_start(%rip), %rdi
    lea __bss_end(%rip), %rcx
    sub %rdi, %rcx
    xor %eax, %eax
    rep stosb

    mov $0x30000, %edi
    mov boot_levels(%rip), %esi
    call mem64_main

3:
    hlt
    jmp 3b

.align 8
gdt:
    .quad 0
    .quad 0x00AF9A000000FFFF      /* 64-bit code, DPL0, L=1 */
    .quad 0x00AF92000000FFFF      /* 64-bit data */
gdt_end:
gdtr:
    .word gdt_end - gdt - 1
    .long gdt

.data
.globl boot_levels
boot_levels:
    .long 4
