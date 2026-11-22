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

    /* zero PML4 0x30000, PDPT 0x31000, PD0 0x32000, PD1 0x33000,
       PT 0x34000, and the data page 0x35000 */
    mov $0x30000, %edi
    xor %eax, %eax
    mov $(6 * 4096 / 4), %ecx
    rep stosl

    /* PML4[0] -> PDPT */
    movl $0x31003, 0x30000
    /* PDPT[0] -> PD0 (identity 0..1GiB), PDPT[1] -> PD1 */
    movl $0x32003, 0x31000
    movl $0x33003, 0x31008
    /* PD0[i] = i*2MiB | present|rw|ps */
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
    /* PD1[0] -> PT; PT[0] -> physical 0x35000.
       This maps VA 0x40000000 through PML4/PDPT/PD/PT non-identically. */
    movl $0x34003, 0x33000
    movl $0x35003, 0x34000

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
    call print
    /* copy the second banner through the non-identity mapping at 1 GiB */
    lea high_msg(%rip), %rsi
    mov $0x40000000, %rdi
5:
    lodsb
    stosb
    test %al, %al
    jnz 5b
    mov $0x40000000, %rsi
    call print
    cli
4:
    hlt
    jmp 4b

/* RSI = NUL-terminated string; clobbers AL and DX */
print:
    lodsb
    test %al, %al
    jz 9f
    mov $0x3F8, %dx
    out %al, %dx
    jmp print
9:
    ret

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
high_msg:
    .asciz "NAN0S MMAP64 OK\n"
