/* raw64_smp_body.S - F15 raw 64-bit product runtime: boot/page-table/AP/block.
 *
 * Linked with src/native64/s1_boot.S (the proven 32-bit -> long-mode entry and
 * identity map).  This body defines s1_main in assembly only; no C, no libc,
 * no compiler runtime is linked.  The AP trampoline is src/native64/smp_tramp.S
 * and the executed block is the NaN translator's emitted bytes (.incbin from
 * the gate).  The substrate here never decodes a NaN instruction: it only
 * builds page roots, starts the AP through INIT-SIPI-SIPI, calls the emitted
 * bytes under per-core CR3 roots, and reads the architectural state back.
 *
 * Expected COM1 transcript:
 *   NAN64 RAW SMP x86_64
 *   RAW64 cpus=2
 *   RAW64 core0 r1=00000011 slot=00000011 done=00000011
 *   RAW64 core1 r1=00000021 slot=00000021 done=00000021
 *   RAW64 PASS
 */
.equ G,                 0x200000
.equ BLOCK_ADDR,        0x51000
.equ ROOT_BASE,         0x38000
.equ ROOT_SIZE,         0x4000
.equ STATE_BASE,        0x70000
.equ STATE_SIZE,        0x1000
.equ TRAMP_CODE,        0x8000
.equ TRAMP_DATA,        0x9000
.equ AP_STACK_BASE,     0x300000
.equ AP_STACK_SIZE,     0x10000
.equ LAPIC_FALLBACK,    0xFEE00000
.equ IA32_APIC_BASE,    0x1B
.equ VEC_SPUR,          0xFF

.section .data
.align 8
lapic_base:
    .quad LAPIC_FALLBACK
cpu_count:
    .long 0
cpu_ids:
    .fill 16, 1, 0
ap_online:
    .fill 16, 1, 0
ap_finished:
    .fill 16, 1, 0

.section .text
.globl s1_main
s1_main:
    cli
    cld
    call serial_init
    lea msg_banner(%rip), %rdi
    call puts

    call lapic_map
    call lapic_init
    call madt_cpus
    call block_copy

    lea msg_cpus(%rip), %rdi
    call puts
    mov cpu_count(%rip), %eax
    call putdec
    call putnl
    cmpl $2, cpu_count(%rip)
    jne .Lfail

    /* Two private state pages and two 4-level roots. */
    xor %ebx, %ebx
.Lstate_loop:
    mov $STATE_BASE, %edi
    mov %ebx, %eax
    shl $12, %rax
    add %rax, %rdi
    mov %ebx, %esi
    call state_init
    mov $ROOT_BASE, %edi
    mov %ebx, %eax
    shl $14, %rax
    add %rax, %rdi
    mov $STATE_BASE, %esi
    mov %ebx, %eax
    shl $12, %rax
    add %rax, %rsi
    call root_build
    inc %ebx
    cmp $2, %ebx
    jb .Lstate_loop

    /* Copy the raw AP trampoline and start CPU 1. */
    call tramp_copy
    mov $1, %edi
    call start_ap
    test %eax, %eax
    jz .Lfail

    /* CPU0 runs the same immutable block under its own root. */
    mov $ROOT_BASE, %rax
    mov %rax, %cr3
    call BLOCK_ADDR
    movb $1, ap_finished(%rip)

    /* Wait for the AP block completion. */
    mov $200000000, %ecx
.Lwait_ap:
    cmpb $0, ap_finished+1(%rip)
    jne .Lap_done
    pause
    dec %ecx
    jnz .Lwait_ap
    jmp .Lfail
.Lap_done:

    /* Read core0 and core1 r1 from their private state roots. */
    mov $ROOT_BASE, %rax
    mov %rax, %cr3
    mov 0x50004, %eax
    mov %eax, %r8d
    mov $ROOT_BASE+ROOT_SIZE, %rax
    mov %rax, %cr3
    mov 0x50004, %eax
    mov %eax, %r9d
    mov $ROOT_BASE, %rax
    mov %rax, %cr3

    /* Shared guest words: r2 wrote word 0x100+ci, r3 wrote word 0x200+ci. */
    mov G+0x800, %rax
    shr $16, %rax
    mov %eax, %r10d
    mov G+0x808, %rax
    shr $16, %rax
    mov %eax, %r11d
    mov G+0x1000, %rax
    shr $16, %rax
    mov %eax, %r12d
    mov G+0x1008, %rax
    shr $16, %rax
    mov %eax, %r13d

    lea msg_core0(%rip), %rdi
    call puts
    mov %r8d, %eax
    call puthex
    lea msg_slot(%rip), %rdi
    call puts
    mov %r10d, %eax
    call puthex
    lea msg_done(%rip), %rdi
    call puts
    mov %r12d, %eax
    call puthex
    call putnl

    lea msg_core1(%rip), %rdi
    call puts
    mov %r9d, %eax
    call puthex
    lea msg_slot(%rip), %rdi
    call puts
    mov %r11d, %eax
    call puthex
    lea msg_done(%rip), %rdi
    call puts
    mov %r13d, %eax
    call puthex
    call putnl

    cmpl $0x11, %r8d
    jne .Lfail
    cmpl $0x21, %r9d
    jne .Lfail
    cmpl $0x11, %r10d
    jne .Lfail
    cmpl $0x11, %r12d
    jne .Lfail
    cmpl $0x21, %r11d
    jne .Lfail
    cmpl $0x21, %r13d
    jne .Lfail

    lea msg_pass(%rip), %rdi
    call puts
    mov $0x10, %al
    out %al, $0xF4
    cli
1:  hlt
    jmp 1b

.Lfail:
    lea msg_fail(%rip), %rdi
    call puts
    mov $0x11, %al
    out %al, $0xF4
    cli
1:  hlt
    jmp 1b

/* ---------------------------------------------------------------- COM1 */
serial_init:
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
    ret

putc:
    push %rax
    push %rdx
    mov $0x3FD, %dx
1:  in %dx, %al
    test $0x20, %al
    jz 1b
    pop %rdx
    pop %rax
    mov $0x3F8, %dx
    out %al, %dx
    ret

puts:
    push %rdi
    push %rax
1:  movb (%rdi), %al
    test %al, %al
    jz 2f
    call putc
    inc %rdi
    jmp 1b
2:  pop %rax
    pop %rdi
    ret

putnl:
    mov $10, %al
    call putc
    ret

puthex:
    push %rbx
    mov %eax, %ebx
    mov $8, %ecx
1:  rol $4, %ebx
    mov %bl, %al
    and $15, %al
    cmp $10, %al
    jb 2f
    add $('a'-10), %al
    jmp 3f
2:  add $'0', %al
3:  call putc
    dec %ecx
    jnz 1b
    pop %rbx
    ret

putdec:
    push %rbx
    push %rcx
    mov %eax, %ebx
    mov $10, %ecx
    xor %edx, %edx
    mov %ebx, %eax
    div %ecx
    test %eax, %eax
    jz 2f
    push %rdx
    call putdec
    pop %rdx
2:  mov %edx, %eax
    add $'0', %al
    call putc
    pop %rcx
    pop %rbx
    ret

/* ---------------------------------------------------------------- LAPIC */
lapic_map:
    /* s1_boot.S: PML4 0x30000, PDPT 0x31000, PD0 0x32000, spare 0x33000. */
    movq $0x33003, 0x31018        /* PDPT[3] -> PD3 */
    movl $0xFEE00083, %eax
    movq %rax, 0x33FB8           /* PD3[503] = 0xFEE00000 | P|RW|PS */
    mov $0xFEE00000, %rax
    invlpg (%rax)
    ret

lapic_init:
    mov $IA32_APIC_BASE, %ecx
    rdmsr
    mov %eax, %ebx
    and $0xFFFFF000, %ebx        /* MMIO base, low 12 bits ignored */
    mov %rbx, lapic_base(%rip)
    and $0xFFFFF000, %eax
    or $0x800, %eax              /* APIC global enable */
    wrmsr
    mov lapic_base(%rip), %rdi
    movl $0x1FF, 0xF0(%rdi)      /* SVR: enable, spurious 0xFF */
    movl $0, 0x80(%rdi)          /* TPR */
    movl $0, 0xB0(%rdi)          /* EOI */
    ret

lapic_write:                     /* edi=offset, eax=value */
    mov lapic_base(%rip), %rdx
    mov %eax, (%rdx,%rdi)
    ret

lapic_read:                      /* edi=offset -> eax */
    mov lapic_base(%rip), %rdx
    mov (%rdx,%rdi), %eax
    ret

/* ------------------------------------------------------------- ACPI MADT */
madt_cpus:
    /* Find RSDP in the BIOS area. */
    mov $0xE0000, %rbx
.Lrsdp_loop:
    movabs $0x2052545020445352, %rax   /* "RSD PTR " */
    cmpq %rax, (%rbx)
    je .Lrsdp_found
    add $16, %rbx
    cmp $0x100000, %rbx
    jb .Lrsdp_loop
    mov $0x80000, %rbx
.Lrsdp_loop2:
    movabs $0x2052545020445352, %rax
    cmpq %rax, (%rbx)
    je .Lrsdp_found
    add $16, %rbx
    cmp $0xA0000, %rbx
    jb .Lrsdp_loop2
    jmp .Lmadt_fallback

.Lrsdp_found:
    /* RSDT pointer at RSDP+16; XSDT is at +24 for rev>=2 but RSDT is present. */
    mov 16(%rbx), %ebx
    test %ebx, %ebx
    jz .Lmadt_fallback
    cmpl $0x54445352, (%rbx)          /* "RSDT" */
    jne .Lmadt_fallback
    mov 4(%rbx), %ecx                /* length */
    cmp $0x100000, %ecx
    ja .Lmadt_fallback
    mov $36, %esi
.Lrsdt_scan:
    cmp %ecx, %esi
    jae .Lmadt_fallback
    mov (%rbx,%rsi), %edi
    test %edi, %edi
    jz .Lrsdt_next
    cmpl $0x43495041, (%rdi)         /* "APIC" */
    je .Lmadt_parse
.Lrsdt_next:
    add $4, %esi
    jmp .Lrsdt_scan

.Lmadt_parse:
    mov 4(%rdi), %ecx                /* MADT length */
    cmp $0x100000, %ecx
    ja .Lmadt_fallback
    mov $44, %esi
    xor %r8d, %r8d                   /* cpu count */
.Lmadt_entry:
    lea 2(%rsi), %eax
    cmp %ecx, %eax
    ja .Lmadt_done
    movzbl (%rdi,%rsi), %eax         /* type */
    movzbl 1(%rdi,%rsi), %edx        /* length */
    cmp $2, %edx
    jb .Lmadt_done
    test %eax, %eax
    jnz .Lmadt_next
    cmp $8, %edx
    jb .Lmadt_next
    movzwl 4(%rdi,%rsi), %eax        /* flags */
    test $1, %eax
    jz .Lmadt_next
    movzbl 3(%rdi,%rsi), %eax        /* APIC id */
    cmp $16, %r8d
    jae .Lmadt_next
    lea cpu_ids(%rip), %r9
    mov %al, (%r9,%r8)
    inc %r8d
.Lmadt_next:
    add %edx, %esi
    jmp .Lmadt_entry
.Lmadt_done:
    test %r8d, %r8d
    jz .Lmadt_fallback
    mov %r8d, cpu_count(%rip)
    /* Move the BSP to slot 0. */
    mov $1, %eax
    cpuid
    shr $24, %ebx
    xor %esi, %esi
.Lbsp_find:
    cmp %r8d, %esi
    jae .Lbsp_ok
    lea cpu_ids(%rip), %r9
    movzbl (%r9,%rsi), %eax
    cmp %ebx, %eax
    je .Lbsp_swap
    inc %esi
    jmp .Lbsp_find
.Lbsp_swap:
    test %esi, %esi
    jz .Lbsp_ok
    lea cpu_ids(%rip), %r9
    movzbl (%r9), %edx
    mov %al, (%r9)
    mov %dl, (%r9,%rsi)
.Lbsp_ok:
    ret

.Lmadt_fallback:
    movl $1, cpu_count(%rip)
    mov $1, %eax
    cpuid
    shr $24, %ebx
    mov %bl, cpu_ids(%rip)
    ret

/* --------------------------------------------------------------- page roots */
root_build:                      /* rdi=root, rsi=state_phys */
    push %rdi
    mov $ROOT_SIZE/8, %rcx
    xor %eax, %eax
    rep stosq
    pop %rdi
    lea 0x1000(%rdi), %r8
    lea 0x2000(%rdi), %r9
    lea 0x3000(%rdi), %r10
    mov %r8, (%rdi)              /* PML4[0] -> PDPT */
    orq $3, (%rdi)
    mov %r9, (%r8)               /* PDPT[0] -> PD */
    orq $3, (%r8)
    movq $0x33003, 0x18(%r8)     /* PDPT[3] -> shared LAPIC PD */
    mov %r10, (%r9)              /* PD[0] -> PT */
    orq $3, (%r9)
    /* PD[1..511] = 2 MiB identity pages. */
    mov $1, %rcx
.Lpd_loop:
    mov %rcx, %rax
    shl $21, %rax
    or $0x83, %rax
    mov %rax, (%r9,%rcx,8)
    inc %rcx
    cmp $512, %rcx
    jb .Lpd_loop
    /* PT[0..511] = 4 KiB identity pages, then 0x50000 -> state. */
    xor %ecx, %ecx
.Lpt_loop:
    mov %rcx, %rax
    shl $12, %rax
    or $3, %rax
    mov %rax, (%r10,%rcx,8)
    inc %rcx
    cmp $512, %rcx
    jb .Lpt_loop
    mov %rsi, %rax
    or $3, %rax
    mov %rax, 0x50*8(%r10)       /* VA 0x50000 -> private state page */
    ret

state_init:                      /* rdi=state, esi=cpu */
    push %rdi
    mov $STATE_SIZE/8, %rcx
    xor %eax, %eax
    rep stosq
    pop %rdi
    mov %esi, %eax
    shl $4, %eax
    add $0x10, %eax
    mov %eax, 4(%rdi)            /* r1 */
    mov %esi, %eax
    add $0x100, %eax
    mov %eax, 8(%rdi)            /* r2 */
    mov %esi, %eax
    add $0x200, %eax
    mov %eax, 12(%rdi)           /* r3 */
    movl $0, 0x400(%rdi)         /* FLAGM */
    movl $0x1FFFFF, 0x404(%rdi)  /* memory mask */
    ret

/* ------------------------------------------------------------- AP startup */
tramp_copy:
    lea tramp_blob(%rip), %rsi
    lea tramp_blob_end(%rip), %rcx
    sub %rsi, %rcx
    mov $TRAMP_CODE, %rdi
1:  test %rcx, %rcx
    jz 2f
    movb (%rsi), %al
    movb %al, (%rdi)
    inc %rsi
    inc %rdi
    dec %rcx
    jmp 1b
2:  ret

start_ap:                        /* edi=cpu index -> eax=1 success */
    push %rbx
    push %r12
    mov %edi, %r12d
    /* boot block: cr3, stack, entry, cpu index */
    mov $ROOT_BASE, %rax
    mov %r12d, %ecx
    shl $14, %rcx
    add %rcx, %rax
    mov %rax, TRAMP_DATA+0
    mov $AP_STACK_BASE, %rax
    mov %r12d, %ecx
    shl $16, %rcx
    add %rcx, %rax
    add $0xF000, %rax
    mov %rax, TRAMP_DATA+8
    lea ap_entry(%rip), %rax
    mov %rax, TRAMP_DATA+16
    mov %r12, TRAMP_DATA+24
    mfence

    lea cpu_ids(%rip), %r9
    movzbl (%r9,%r12), %ebx
    /* INIT */
    mov %ebx, %eax
    shl $24, %eax
    mov $0x310, %edi
    call lapic_write
    mov $0x4500, %eax
    mov $0x300, %edi
    call lapic_write
    mov $2000000, %ecx
1:  pause
    dec %ecx
    jnz 1b
    /* SIPI twice */
    mov %ebx, %eax
    shl $24, %eax
    mov $0x310, %edi
    call lapic_write
    mov $0x4608, %eax            /* vector 0x08 (0x8000 >> 12) */
    mov $0x300, %edi
    call lapic_write
    mov $200000, %ecx
1:  pause
    dec %ecx
    jnz 1b
    mov %ebx, %eax
    shl $24, %eax
    mov $0x310, %edi
    call lapic_write
    mov $0x4608, %eax
    mov $0x300, %edi
    call lapic_write

    mov $200000000, %ecx
1:  lea ap_online(%rip), %r9
    cmpb $0, (%r9,%r12)
    jne 2f
    pause
    dec %ecx
    jnz 1b
    xor %eax, %eax
    jmp 3f
2:  mov $1, %eax
3:  pop %r12
    pop %rbx
    ret

block_copy:
    lea block0(%rip), %rsi
    lea block0_end(%rip), %rcx
    sub %rsi, %rcx
    mov $BLOCK_ADDR, %rdi
1:  test %rcx, %rcx
    jz 2f
    movb (%rsi), %al
    movb %al, (%rdi)
    inc %rsi
    inc %rdi
    dec %rcx
    jmp 1b
2:  ret

.globl ap_entry
ap_entry:                        /* rdi=cpu index; SysV from smp_tramp.S */
    push %rdi
    lea ap_online(%rip), %rax
    movb $1, (%rax,%rdi)
    mov $ROOT_BASE, %rax
    mov %edi, %ecx
    shl $14, %rcx
    add %rcx, %rax
    mov %rax, %cr3
    call BLOCK_ADDR
    pop %rdi
    lea ap_finished(%rip), %rax
    movb $1, (%rax,%rdi)
1:  cli
    hlt
    jmp 1b

/* --------------------------------------------------------------- messages */
.section .rodata
msg_banner:  .asciz "NAN64 RAW SMP x86_64\n"
msg_cpus:    .asciz "RAW64 cpus="
msg_core0:   .asciz "RAW64 core0 r1="
msg_core1:   .asciz "RAW64 core1 r1="
msg_slot:    .asciz " slot="
msg_done:    .asciz " done="
msg_pass:    .asciz "RAW64 PASS\n"
msg_fail:    .asciz "RAW64 FAIL\n"
