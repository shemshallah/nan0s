/* e820probe.S - minimal real-mode E820 probe, prints over COM1.
 * 'Y' if the first call succeeds, 'N' on failure; then the entry count as
 * two hex digits and the first entry's base/len/type.
 */
.code16
.globl _start
_start:
    cli
    xor %ax, %ax
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %ss
    mov $0x7C00, %sp
    sti

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

    mov $0x600, %di
    xor %si, %si
    xor %ebx, %ebx
1:
    mov $0xE820, %eax
    mov $0x534D4150, %edx
    mov $24, %ecx
    int $0x15
    jc fail
    cmp $0x534D4150, %eax
    jne fail
    inc %si
    add $24, %di
    test %ebx, %ebx
    jz done
    cmp $40, %si
    jb 1b
done:
    xor %ax, %ax
    mov %ax, %ds
    mov %ax, %es
    mov $'Y', %al
    call putc
    mov %si, %ax
    call puthex16
    mov $0x600, %bx
    mov 0(%bx), %ax
    call puthex16
    mov 2(%bx), %ax
    call puthex16
    mov 4(%bx), %ax
    call puthex16
    mov 6(%bx), %ax
    call puthex16
    mov 8(%bx), %ax
    call puthex16
    mov 10(%bx), %ax
    call puthex16
    mov 12(%bx), %ax
    call puthex16
    mov 14(%bx), %ax
    call puthex16
    mov 16(%bx), %ax
    call puthex16
    mov $'\n', %al
    call putc
    hlt
fail:
    mov $'N', %al
    call putc
    mov $'\n', %al
    call putc
    hlt

putc:
    mov $0x3F8, %dx
    out %al, %dx
    ret

puthex16:
    push %ax
    push %bx
    mov $4, %cx
2:
    rol $4, %ax
    mov %al, %bl
    and $0x0F, %bl
    cmp $10, %bl
    jb 3f
    add $('A' - 10), %bl
    jmp 4f
3:
    add $'0', %bl
4:
    mov $0x3F8, %dx
    mov %bl, %al
    out %al, %dx
    dec %cx
    jnz 2b
    pop %bx
    pop %ax
    ret

.org 510
.word 0xAA55
