/* cache_body.S - native block-cache dispatcher for the NaN core ABI.
 *
 * Boots via QEMU's multiboot loader, builds a 1 GiB identity map, enters
 * long mode and runs the cache blocks emitted by the NaN translator.
 *
 * The cache blocks are 32-bit x86 code that operate directly on the kernel
 * state at 0x8000 (registers), 0x8040 (FLAGM), 0x80C0 (word mask),
 * 0x80D4 (XPC), 0x80D8 (halt) and 0x80DC (trap).  Guest words are at
 * 0x200000; the cache image is loaded at 0x2000000.  The dispatcher never
 * decodes a NaN instruction.
 */
.section .multiboot,"a"
.align 4
.long 0x1BADB002
.long 0
.long -(0x1BADB002)

.equ CACHE_BASE, 0x2000000
.equ CACHE_SLOT, 512
.equ CACHE_N,    2992
.equ MASK_BASE,  0x2176000

.section .text
.code32
.globl _start
_start:
    cli
    cld
    /* Four page-table pages at 0x1000..0x4fff: PML4, PDPT, PD. */
    mov $0x1000, %edi
    xor %eax, %eax
    mov $(4 * 4096 / 4), %ecx
    rep stosl
    movl $0x2003, 0x1000          /* PML4[0] -> PDPT */
    movl $0x83, 0x2000            /* PDPT[0] = 1 GiB identity page at 0 */
    lgdt gdtr
    mov %cr4, %eax
    or $0x20, %eax                /* PAE */
    mov %eax, %cr4
    mov $0x1000, %eax
    mov %eax, %cr3
    mov $0xC0000080, %ecx
    rdmsr
    or $0x100, %eax               /* LME */
    wrmsr
    mov %cr0, %eax
    or $0x80000001, %eax          /* PG | PE */
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

    /* Zero the architectural state at 0x8000..0x80ff. */
    mov $0x8000, %edi
    xor %eax, %eax
    mov $0x40, %ecx
    rep stosl
    movl $0x1FFFFF, 0x80C0        /* word mask: 2 Mi words */
    movl $1, 0x8040               /* FLAGM: kernel reset value */
    movl $0, 0x80D4               /* XPC */
    movl $0, 0x80D8               /* halt */
    movl $0, 0x80DC               /* trap */

    mov $CACHE_BASE, %r15
    mov $MASK_BASE, %r14
cache_loop:
    mov 0x80D8, %eax
    test %eax, %eax
    jnz cache_halt
    mov 0x80D4, %eax
    cmp $CACHE_N, %eax
    jae cache_badpc
    /* Predication: skip unless header mask intersects FLAGM (opcode 0 is
       unconditional and carries mask 0xFF in the table). */
    movzbl (%r14,%rax), %ecx
    cmp $0xFF, %ecx
    je cache_call
    mov 0x8040, %edx
    test %ecx, %edx
    jz cache_skip
cache_call:
    shl $9, %eax
    add %r15, %rax
    call *%rax
    mov 0x80DC, %eax
    test %eax, %eax
    jnz cache_trap
    jmp cache_loop
cache_skip:
    mov 0x80D4, %eax
    inc %eax
    mov %eax, 0x80D4
    jmp cache_loop

cache_halt:
    mov $0x10, %al
    mov $0xF4, %dx
    out %al, %dx
1:  hlt
    jmp 1b

cache_badpc:
    lea badmsg(%rip), %rsi
    call puts
    mov 0x80D4, %edi
    call puthex
    lea nlmsg(%rip), %rsi
    call puts
    jmp fail

cache_trap:
    lea trapmsg(%rip), %rsi
    call puts
    mov 0x80DC, %edi
    call puthex
    lea nlmsg(%rip), %rsi
    call puts
fail:
    mov $0x11, %al
    mov $0xF4, %dx
    out %al, %dx
2:  hlt
    jmp 2b

puts:
    lodsb
    test %al, %al
    jz 3f
    mov $0x3F8, %dx
    out %al, %dx
    jmp puts
3:  ret

puthex:
    mov $8, %ecx
4:
    rol $4, %edi
    mov %di, %ax
    and $0x0F, %al
    cmp $10, %al
    jb 5f
    add $('A' - 10), %al
    jmp 6f
5:
    add $'0', %al
6:
    mov $0x3F8, %dx
    out %al, %dx
    dec %ecx
    jnz 4b
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
badmsg:  .asciz "\n!CACHE pc "
trapmsg: .asciz "\n!CACHE trap "
nlmsg:   .asciz "\n"
