/* s1_bootsec.S - minimal 512-byte floppy boot fixture for tools/kabi64_gate.sh.
 *
 * Loads 128 sectors (64 KiB) from LBA 1 to 0x10000 with BIOS INT 13h CHS,
 * enables A20, enters flat 32-bit protected mode and jumps to the S1 image.
 * It is deliberately independent of the museum image and tools/mkall.sh.
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
    cld
    sti
    mov %dl, drive

    mov $1, %ax
    mov %ax, lba
    movw $128, count
    mov $0x1000, %ax
    mov %ax, %es

load_loop:
    mov lba, %ax
    xor %dx, %dx
    mov $18, %bx
    div %bx                     /* ax=track, dx=sector-1 */
    inc %dl
    mov %dl, sec
    xor %dx, %dx
    mov $2, %bx
    div %bx                     /* ax=cylinder, dx=head */
    mov %dl, head
    mov %al, cyl
    mov cyl, %ch
    mov sec, %cl
    mov head, %dh
    mov drive, %dl
    mov $0x0201, %ax            /* read one sector */
    xor %bx, %bx
    int $0x13
    jc fail
    mov %es, %ax
    add $0x20, %ax              /* next 512-byte paragraph */
    mov %ax, %es
    incw lba
    decw count
    jnz load_loop

    /* fast A20 */
    in $0x92, %al
    or $2, %al
    out %al, $0x92

    lgdt gdtr
    mov %cr0, %eax
    or $1, %eax
    mov %eax, %cr0
    .byte 0x66, 0xEA            /* ljmp $0x08,$pm (32-bit offset) */
    .long pm
    .word 0x08

fail:
    cli
    hlt
    jmp fail

.code32
pm:
    mov $0x10, %ax
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %ss
    mov %ax, %fs
    mov %ax, %gs
    mov $0x7C00, %esp
    mov $0x10000, %eax
    jmp *%eax

.align 8
gdt:
    .quad 0
    .quad 0x00CF9A000000FFFF
    .quad 0x00CF92000000FFFF
gdt_end:
gdtr:
    .word gdt_end - gdt - 1
    .long gdt

drive:  .byte 0
lba:    .word 0
count:  .word 0
sec:    .byte 0
head:   .byte 0
cyl:    .byte 0

.org 510
.word 0xAA55
