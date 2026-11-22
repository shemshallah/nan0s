/* core64_body.S - native 64-bit substrate for the NaN-coded core.
 *
 * The block64/block64_end symbols are supplied by the generated wrapper
 * (an .incbin of the NaN translator's output).  The substrate only boots
 * long mode, copies the block to 0x51000, zeroes the guest register file at
 * 0x50000, calls the block, and prints r1.  All instruction selection and
 * encoding is done by the NaN translator, not here.
 */
.code32
.globl _start
_start:
    cli
    cld
    /* zero four page-table pages at 0x30000..0x33fff */
    mov $0x30000, %edi
    xor %eax, %eax
    mov $(4 * 4096 / 4), %ecx
    rep stosl
    movl $0x31003, 0x30000
    movl $0x32003, 0x31000
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
    lgdt gdtr
    mov %cr4, %eax
    or $0x620, %eax          /* PAE | OSFXSR | OSXMMEXCPT */
    mov %eax, %cr4
    mov $0x30000, %eax
    mov %eax, %cr3
    mov $0xC0000080, %ecx
    rdmsr
    or $0x100, %eax
    wrmsr
    mov %cr0, %eax
    and $0xFFFFFFFB, %eax    /* clear EM */
    or $0x80000002, %eax     /* PG | MP */
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

    /* COM1 115200 8N1 */
    mov $0x3F9, %dx
    xor %al, %al
    out %al, %dx
    mov $0x3FB, %dx
    mov $0x80, %al
    out %al, %dx
    mov $0x3F8, %dx
    mov $1, %al
    out %al, %dx
    mov $0x3F9, %dx
    xor %al, %al
    out %al, %dx
    mov $0x3FB, %dx
    mov $3, %al
    out %al, %dx
    mov $0x3FA, %dx
    mov $0xC7, %al
    out %al, %dx
    mov $0x3FC, %dx
    mov $0x0B, %al
    out %al, %dx

    /* copy the NaN-emitted block to the executable page */
    lea block64(%rip), %rsi
    mov $0x51000, %rdi
    mov $(block64_end - block64), %rcx
    rep movsb

    /* zero the 16 guest registers, FLAGM and XPC, then call the block */
    mov $0x50000, %rdi
    xor %eax, %eax
    mov $16, %ecx
    rep stosl
    movl $0, 0x50400
    movl $0, 0x50800
    movl $0x1FFFFF, 0x50404
    movq $0x51000, %rax
    call *%rax

    lea coremsg(%rip), %rsi
    call print
    mov 0x50004, %edi
    call print_hex32
    lea xpcmsg(%rip), %rsi
    call print
    mov 0x50800, %edi
    call print_hex32
    mov 0x50C04, %edi
    test %edi, %edi
    jz 8f
    lea trapmsg(%rip), %rsi
    call print
    call print_hex32
8:
    lea okmsg(%rip), %rsi
    call print
    cli
2:
    hlt
    jmp 2b

print:
    lodsb
    test %al, %al
    jz 9f
    mov $0x3F8, %dx
    out %al, %dx
    jmp print
9:
    ret

print_hex32:
    mov $8, %ecx
3:
    rol $4, %edi
    mov %di, %ax
    and $0x0F, %al
    cmp $10, %al
    jb 4f
    add $('A' - 10), %al
    jmp 5f
4:
    add $'0', %al
5:
    mov $0x3F8, %dx
    out %al, %dx
    dec %ecx
    jnz 3b
    ret

.align 8
gdt:
    .quad 0
    .quad 0x00AF9A000000FFFF
    .quad 0x00AF92000000FFFF
gdt_end:
gdtr:
    .word gdt_end - gdt - 1
    .long gdt

.section .rodata
coremsg:
    .asciz "NAN64 CORE "
xpcmsg:
    .asciz " XPC "
trapmsg:
    .asciz " TRAP "
okmsg:
    .asciz " OK\n"
