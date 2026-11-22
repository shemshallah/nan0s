/* longmode.S - 32-bit protected-mode entry -> x86-64 long mode.
 *
 * The existing boot sector loads this image at 0x10000 and enters flat
 * 32-bit protected mode.  We build identity page tables for the first
 * 1 GiB, enable PAE/LME/paging, load a 64-bit GDT and jump to 64-bit code.
 * The 64-bit stub initializes COM1 and prints a banner.
 */
.code32
.globl _start
_start:
    cli
    cld

    /* zero PML4 (0x30000), PDPT (0x31000), PD (0x32000) */
    mov $0x30000, %edi
    xor %eax, %eax
    mov $(3 * 4096 / 4), %ecx
    rep stosl

    /* PML4[0] -> PDPT */
    movl $0x31003, 0x30000
    /* PDPT[0] -> PD */
    movl $0x32003, 0x31000
    /* PD[i] = i*2MiB | present|rw|ps */
    mov $0x32000, %edi
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

    /* new GDT: null, 64-bit code, 64-bit data */
    lgdt gdtr

    /* PAE + CR3 */
    mov %cr4, %eax
    or $0x20, %eax
    mov %eax, %cr4
    mov $0x30000, %eax
    mov %eax, %cr3

    /* EFER.LME */
    mov $0xC0000080, %ecx
    rdmsr
    or $0x100, %eax
    wrmsr

    /* paging on (PE already on) */
    mov %cr0, %eax
    or $0x80000000, %eax
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

    /* COM1: 115200 8N1, FIFO on */
    mov $0x3F9, %dx
    xor %al, %al
    out %al, %dx
    mov $0x3FB, %dx
    mov $0x80, %al
    out %al, %dx
    mov $0x3F8, %dx
    mov $0x01, %al
    out %al, %dx
    mov $0x3F9, %dx
    xor %al, %al
    out %al, %dx
    mov $0x3FB, %dx
    mov $0x03, %al
    out %al, %dx
    mov $0x3FA, %dx
    mov $0xC7, %al
    out %al, %dx
    mov $0x3FC, %dx
    mov $0x0B, %al
    out %al, %dx

    lea msg(%rip), %rsi
2:
    lodsb
    test %al, %al
    jz 3f
    mov $0x3F8, %dx
    out %al, %dx
    jmp 2b
3:
    cli
4:
    hlt
    jmp 4b

.align 8
gdt:
    .quad 0
    .quad 0x00AF9A000000FFFF   /* 64-bit code, DPL0, L=1 */
    .quad 0x00AF92000000FFFF   /* 64-bit data */
gdt_end:
gdtr:
    .word gdt_end - gdt - 1
    .long gdt

.section .rodata
msg:
    .asciz "NAN0S x86-64 OK\n"
