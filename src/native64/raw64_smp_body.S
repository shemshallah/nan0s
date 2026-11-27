/* raw64_smp_body.S - F17 raw 64-bit product runtime: boot/page-table/AP/block.
 *
 * Linked with src/native64/s1_boot.S (the proven 32-bit -> long-mode entry and
 * identity map).  This body defines s1_main in assembly only; no C, no libc,
 * no compiler runtime is linked.  The AP trampoline is src/native64/smp_tramp.S
 * and the executed block is the NaN translator's emitted bytes (.incbin from
 * the gate).  The substrate here never decodes a NaN instruction: it builds
 * page roots, per-AP GDT/TSS/IST and IDT state, starts every AP through
 * INIT-SIPI-SIPI, calls the emitted bytes under per-core CR3 roots, runs an
 * AP-local LAPIC one-shot timer, and services a reschedule IPI.  Timer, IPI,
 * reschedule and EOI counters are published in a shared per-core table.
 *
 * Expected COM1 transcript (N = 2 or 4):
 *   NAN64 RAW SMP x86_64
 *   RAW64 cpus=N
 *   RAW64 core0 r1=00000011 slot=00000011 done=00000011 timer=1 ipi=1 resched=1 eoi=2 tss=1 ist=1
 *   ...
 *   RAW64 PASS
 */
.equ G,                 0x200000
.equ BLOCK_ADDR,        0x51000
.equ IDT_BASE,          0x54000
.equ GDT_BASE,          0x58000
.equ GDT_STRIDE,        0x2000
.equ CT_BASE,           0x68000
.equ ROOT_BASE,         0x38000
.equ ROOT_SIZE,         0x4000
.equ STATE_BASE,        0x70000
.equ STATE_SIZE,        0x1000
.equ TRAMP_CODE,        0x8000
.equ TRAMP_DATA,        0x9000
.equ CORE_STACK_BASE,   0x100000
.equ CORE_STACK_SIZE,   0x10000
.equ CORE_STACK_TOP,    0xF000
.equ LAPIC_FALLBACK,    0xFEE00000
.equ IA32_APIC_BASE,    0x1B
.equ IA32_GS_BASE,      0xC0000101
.equ VEC_TIMER,         0x40
.equ VEC_IPI,           0x41
.equ VEC_SPUR,          0xFF
.equ MAX_CORES,         4

/* Per-core counter/state table (64 bytes per logical core). */
.equ CT_TIMER,          0
.equ CT_IPI,            4
.equ CT_RESCHED,        8
.equ CT_EOI,            12
.equ CT_SPUR,           16
.equ CT_TSS,            20
.equ CT_IST,            24
.equ CT_BLOCK,          28
.equ CT_ONLINE,         32
.equ CT_APIC,           36
.equ CT_ENTRY,          40
.equ CT_STRIDE,         64

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
.align 8
idtr:
    .word 0x0FFF
    .quad IDT_BASE

.section .text
.globl s1_main
s1_main:
    cli
    cld
    /* Move off the bootstrap stack onto the per-core stack arena. */
    mov $CORE_STACK_BASE+CORE_STACK_TOP, %rsp
    and $-16, %rsp
    call serial_init
    lea msg_banner(%rip), %rdi
    call puts

    call pic_mask
    call lapic_map
    call ioapic_mask_all
    call lapic_init
    call madt_cpus
    call block_copy

    lea msg_cpus(%rip), %rdi
    call puts
    mov cpu_count(%rip), %eax
    call putdec
    call putnl
    mov cpu_count(%rip), %eax
    cmp $2, %eax
    jb .Lfail
    cmp $MAX_CORES, %eax
    ja .Lfail

    /* Build the shared IDT and every per-AP GDT/TSS/IST before any AP runs. */
    call idt_build
    call gdt_build_all

    /* BSP GS base points at logical core 0's counter table. */
    xor %edi, %edi
    call gs_set
    call load_idt
    xor %edi, %edi
    call load_gdt
    movl $1, %gs:CT_TSS
    movl $1, %gs:CT_ONLINE

#ifdef RAW64_FAULT_TEST
    /* Gate-only proof of the #PF/IST1 reporting path: VA 1 GiB is outside
       the PD[0..511] identity window, so this read must raise vector 14 with
       CR2=0x40000000, print the frame and halt. */
    mov 0x40000000, %rax
#endif

    /* One private state page and one 4-level root per logical core. */
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
    cmp cpu_count(%rip), %ebx
    jb .Lstate_loop

    /* Copy the raw AP trampoline and start every AP in turn. */
    call tramp_copy
    mov $1, %ebx
.Lstart_loop:
    cmp cpu_count(%rip), %ebx
    jae .Lstart_done
    mov %ebx, %edi
    call start_ap
    test %eax, %eax
    jz .Lfail
    inc %ebx
    jmp .Lstart_loop
.Lstart_done:

    /* Arm the BSP's one-shot LAPIC timer.  IF stays clear while the block
       runs, so the block is never interrupted. */
    call lapic_timer_start

    /* CPU0 runs the same immutable block under its own root. */
    mov $ROOT_BASE, %rax
    mov %rax, %cr3
    call BLOCK_ADDR
    movl $1, %gs:CT_BLOCK

    /* Wait for every AP to finish the block. */
    mov $200000000, %ecx
.Lwait_ap:
    xor %ebx, %ebx
.Lwait_ap_scan:
    cmp cpu_count(%rip), %ebx
    jae .Lap_done
    test %ebx, %ebx
    jz .Lwait_ap_next
    lea ap_finished(%rip), %rax
    cmpb $0, (%rax,%rbx)
    je .Lwait_ap_spin
.Lwait_ap_next:
    inc %ebx
    jmp .Lwait_ap_scan
.Lwait_ap_spin:
    pause
    dec %ecx
    jnz .Lwait_ap
    jmp .Lfail
.Lap_done:

    /* Interrupts on.  Every core now waits for its one-shot timer and the
       reschedule IPI below. */
    sti

    /* Send one reschedule IPI to every core, including the BSP. */
    xor %ebx, %ebx
.Lipi_loop:
    cmp cpu_count(%rip), %ebx
    jae .Lipi_done
    lea cpu_ids(%rip), %rax
    movzbl (%rax,%rbx), %edi
    mov $VEC_IPI, %esi
    call lapic_send_ipi
    test %eax, %eax
    jz .Lfail
    inc %ebx
    jmp .Lipi_loop
.Lipi_done:

    /* Require exactly one timer interrupt, one IPI, one accepted reschedule
       and two EOIs on every core.  A lost or duplicated interrupt fails. */
    mov $400000000, %ecx
.Lwait_ctr:
    xor %ebx, %ebx
.Lwait_ctr_scan:
    cmp cpu_count(%rip), %ebx
    jae .Lctr_done
    mov %ebx, %eax
    shl $6, %eax
    mov $CT_BASE, %edx
    cmpl $1, CT_TIMER(%rdx,%rax)
    jb .Lctr_spin
    cmpl $1, CT_IPI(%rdx,%rax)
    jb .Lctr_spin
    cmpl $1, CT_RESCHED(%rdx,%rax)
    jb .Lctr_spin
    cmpl $2, CT_EOI(%rdx,%rax)
    jb .Lctr_spin
    inc %ebx
    jmp .Lwait_ctr_scan
.Lctr_spin:
    pause
    dec %ecx
    jnz .Lwait_ctr
    jmp .Lfail
.Lctr_done:

    /* Verify every TSS descriptor and IST1/IST2 stack is really installed. */
    call verify_tss_all
    test %eax, %eax
    jz .Lfail

    /* Publish the exact per-core block and interrupt record. */
    xor %ebx, %ebx
.Lprint_loop:
    cmp cpu_count(%rip), %ebx
    jae .Lprint_done
    mov %ebx, %edi
    call print_core
    inc %ebx
    jmp .Lprint_loop
.Lprint_done:

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

pic_mask:
    mov $0x21, %dx
    mov $0xFF, %al
    out %al, %dx
    mov $0xA1, %dx
    mov $0xFF, %al
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

puthex64:
    push %rax
    shr $32, %rax
    call puthex
    pop %rax
    call puthex
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
    movl $0xFEC00083, %eax
    movq %rax, 0x33FB0           /* PD3[502] = 0xFEC00000 | P|RW|PS */
    mov $0xFEE00000, %rax
    invlpg (%rax)
    mov $0xFEC00000, %rax
    invlpg (%rax)
    ret

ioapic_mask_all:
    /* Legacy IRQ6 (floppy) can be routed to vector 0x0E, which collides with
       #PF.  The LAPIC timer and IPIs do not use the IOAPIC, so mask every
       redirection entry before interrupts are enabled. */
    mov $0xFEC00000, %rdi
    movl $1, (%rdi)              /* IOREGSEL = IOAPICVER */
    movl 0x10(%rdi), %eax
    cmp $0xFFFFFFFF, %eax
    je 2f
    shr $16, %eax
    and $0xFF, %eax
    inc %eax
    mov %eax, %ecx
    xor %ebx, %ebx
1:  mov %ebx, %eax
    shl $1, %eax
    add $0x10, %eax              /* redirection entry low word */
    mov %eax, (%rdi)
    movl $0x00010000, 0x10(%rdi) /* mask bit */
    inc %ebx
    cmp %ecx, %ebx
    jb 1b
2:  ret

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
    movl $0x00010000, 0x350(%rdi) /* LINT0 masked: no legacy ExtINT */
    movl $0x00010000, 0x360(%rdi) /* LINT1 masked */
    ret

lapic_timer_start:
    mov $0x3E0, %edi             /* divide configuration */
    mov $0xB, %eax               /* divide by 1 */
    call lapic_write
    mov $0x320, %edi             /* LVT timer: one-shot, vector 0x40 */
    mov $VEC_TIMER, %eax
    call lapic_write
    mov $0x380, %edi             /* initial count */
    mov $0x10000, %eax
    call lapic_write
    ret

lapic_write:                     /* edi=offset, eax=value */
    mov lapic_base(%rip), %rdx
    mov %eax, (%rdx,%rdi)
    ret

lapic_read:                      /* edi=offset -> eax */
    mov lapic_base(%rip), %rdx
    mov (%rdx,%rdi), %eax
    ret

lapic_send_ipi:                  /* edi=apic id, esi=vector -> eax=1 ok */
    push %rbx
    push %r12
    mov %edi, %ebx
    mov %esi, %r12d
    mov %ebx, %eax
    shl $24, %eax
    mov $0x310, %edi
    call lapic_write
    mov %r12d, %eax
    or $0x4000, %eax             /* fixed delivery, assert */
    mov $0x300, %edi
    call lapic_write
    mov $1000000, %ecx
1:  mov $0x300, %edi
    call lapic_read
    test $0x1000, %eax           /* delivery status */
    jz 2f
    pause
    dec %ecx
    jnz 1b
    xor %eax, %eax
    jmp 3f
2:  mov $1, %eax
3:  pop %r12
    pop %rbx
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

/* --------------------------------------------------------------- GDT/TSS/IDT */
gdt_build_all:
    push %rbx
    xor %ebx, %ebx
.Lg_loop:
    cmp cpu_count(%rip), %ebx
    jae .Lg_done
    mov %ebx, %eax
    shl $13, %eax
    mov $GDT_BASE, %edi
    add %rax, %rdi
    mov $GDT_BASE+0x1000, %esi
    add %rax, %rsi
    mov %ebx, %edx
    call gdt_build
    inc %ebx
    jmp .Lg_loop
.Lg_done:
    pop %rbx
    ret

gdt_build:                       /* rdi=gdt, rsi=tss, edx=cpu */
    push %rdi
    push %rsi
    mov $0x200, %rcx             /* zero 4 KiB GDT page */
    xor %eax, %eax
    rep stosq
    pop %rsi
    pop %rdi

    /* Entries 0/1/2: null, 64-bit code, 64-bit data. */
    movq $0, 0x00(%rdi)
    movabs $0x00AF9A000000FFFF, %rax
    mov %rax, 0x08(%rdi)
    movabs $0x00AF92000000FFFF, %rax
    mov %rax, 0x10(%rdi)

    /* Zero the TSS page, then fill rsp0, IST1, IST2 and the I/O map base. */
    push %rdi
    mov %rsi, %rdi
    mov $0x200, %rcx
    xor %eax, %eax
    rep stosq
    pop %rdi

    mov %edx, %eax
    shl $16, %eax
    add $CORE_STACK_BASE+CORE_STACK_TOP, %eax
    mov %rax, 4(%rsi)            /* rsp0 */
    mov %rax, %rcx
    sub $0x1000, %rcx
    mov %rcx, 0x24(%rsi)         /* IST1 exception stack */
    mov %rax, %rcx
    sub $0x2000, %rcx
    mov %rcx, 0x2C(%rsi)         /* IST2 double-fault stack */
    movw $0x68, 0x64(%rsi)       /* no I/O bitmap */

    /* 64-bit TSS descriptor: base, limit 0x67, type 0x89, DPL0, present. */
    mov %rsi, %rax
    mov %rax, %r8
    and $0xFFFFFF, %r8
    shl $16, %r8
    or $0x67, %r8
    mov $0x89, %r9
    shl $40, %r9
    or %r9, %r8
    mov $0xF, %r9
    shl $48, %r9
    or %r9, %r8
    mov %rax, %r9
    shr $24, %r9
    and $0xFF, %r9
    shl $56, %r9
    or %r9, %r8
    mov %r8, 0x18(%rdi)
    mov %rax, %r9
    shr $32, %r9
    mov %r9, 0x20(%rdi)
    ret

load_gdt:                        /* edi=cpu -> load per-core GDT and ltr */
    mov %edi, %eax
    shl $13, %eax
    add $GDT_BASE, %eax
    sub $16, %rsp
    movw $0x2F, (%rsp)
    mov %rax, 2(%rsp)
    lgdt (%rsp)
    add $16, %rsp
    mov $0x18, %ax
    ltr %ax
    ret

load_idt:
    lidt idtr(%rip)
    ret

idt_build:
    push %rbx
    mov $IDT_BASE, %rdi
    mov $512, %rcx               /* 4096 bytes / 8 */
    xor %eax, %eax
    rep stosq

    /* Every unused vector reports and halts. */
    xor %ebx, %ebx
.Lidt_default:
    mov %ebx, %edi
    lea isr_default(%rip), %rsi
    xor %edx, %edx
    call idt_set
    inc %ebx
    cmp $256, %ebx
    jb .Lidt_default

    /* Exceptions 0..31: IST1, except #DF on IST2. */
    xor %ebx, %ebx
.Lidt_exc:
    lea exc_table(%rip), %rax
    mov (%rax,%rbx,8), %rsi
    mov $1, %edx
    cmp $8, %ebx
    jne 1f
    mov $2, %edx
1:  mov %ebx, %edi
    call idt_set
    inc %ebx
    cmp $32, %ebx
    jb .Lidt_exc

    mov $VEC_TIMER, %edi
    lea isr_timer(%rip), %rsi
    xor %edx, %edx
    call idt_set
    mov $VEC_IPI, %edi
    lea isr_ipi(%rip), %rsi
    xor %edx, %edx
    call idt_set
    mov $VEC_SPUR, %edi
    lea isr_spurious(%rip), %rsi
    xor %edx, %edx
    call idt_set
    pop %rbx
    ret

idt_set:                         /* edi=vector, rsi=handler, edx=ist */
    mov %edi, %eax
    shl $4, %eax
    add $IDT_BASE, %eax
    mov %rsi, %rcx
    and $0xFFFF, %rcx
    mov %rcx, (%rax)
    mov $0x08, %rcx
    shl $16, %rcx
    or %rcx, (%rax)
    mov %rdx, %rcx
    and $7, %rcx
    shl $32, %rcx
    or %rcx, (%rax)
    mov $0x8E, %rcx
    shl $40, %rcx
    or %rcx, (%rax)
    mov %rsi, %rcx
    shr $16, %rcx
    and $0xFFFF, %rcx
    shl $48, %rcx
    or %rcx, (%rax)
    mov %rsi, %rcx
    shr $32, %rcx
    mov %rcx, 8(%rax)
    ret

gs_set:                          /* edi=cpu -> GS base = per-core table */
    mov %edi, %eax
    shl $6, %eax
    add $CT_BASE, %eax
    mov $IA32_GS_BASE, %ecx
    xor %edx, %edx
    wrmsr
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
    mov $CORE_STACK_BASE, %rax
    mov %r12d, %ecx
    shl $16, %rcx
    add %rcx, %rax
    add $CORE_STACK_TOP, %rax
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
    cli
    and $-16, %rsp
    mov %edi, %r12d
    call gs_set
    movl $1, %gs:CT_ONLINE
    movl %r12d, %gs:CT_ENTRY
    lea ap_online(%rip), %rax
    movb $1, (%rax,%r12)
    call load_idt
    mov %r12d, %edi
    call load_gdt
    movl $1, %gs:CT_TSS
    mov %r12d, %eax
    shl $14, %eax
    add $ROOT_BASE, %eax
    mov %rax, %cr3
    call lapic_init
    call lapic_timer_start
    call BLOCK_ADDR
    movl $1, %gs:CT_BLOCK
    movl %gs:CT_ENTRY, %eax
    lea ap_finished(%rip), %rdx
    movb $1, (%rdx,%rax)
    sti
1:  hlt
    jmp 1b

/* --------------------------------------------------------------- IDT stubs */
.macro ISR_SAVE
    push %rax
    push %rbx
    push %rcx
    push %rdx
    push %rsi
    push %rdi
    push %rbp
    push %r8
    push %r9
    push %r10
    push %r11
    push %r12
    push %r13
    push %r14
    push %r15
.endm

.macro ISR_RESTORE
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %r11
    pop %r10
    pop %r9
    pop %r8
    pop %rbp
    pop %rdi
    pop %rsi
    pop %rdx
    pop %rcx
    pop %rbx
    pop %rax
.endm

.macro EXC_STUB_NOERR num
isr_exc_\num:
    pushq $0
    pushq $\num
    jmp exc_common
.endm

.macro EXC_STUB_ERR num
isr_exc_\num:
    pushq $\num
    jmp exc_common
.endm

EXC_STUB_NOERR 0
EXC_STUB_NOERR 1
EXC_STUB_NOERR 2
EXC_STUB_NOERR 3
EXC_STUB_NOERR 4
EXC_STUB_NOERR 5
EXC_STUB_NOERR 6
EXC_STUB_NOERR 7
EXC_STUB_ERR   8
EXC_STUB_NOERR 9
EXC_STUB_ERR   10
EXC_STUB_ERR   11
EXC_STUB_ERR   12
EXC_STUB_ERR   13
EXC_STUB_ERR   14
EXC_STUB_NOERR 15
EXC_STUB_NOERR 16
EXC_STUB_ERR   17
EXC_STUB_NOERR 18
EXC_STUB_NOERR 19
EXC_STUB_NOERR 20
EXC_STUB_ERR   21
EXC_STUB_NOERR 22
EXC_STUB_NOERR 23
EXC_STUB_NOERR 24
EXC_STUB_NOERR 25
EXC_STUB_NOERR 26
EXC_STUB_NOERR 27
EXC_STUB_NOERR 28
EXC_STUB_ERR   29
EXC_STUB_ERR   30
EXC_STUB_NOERR 31

isr_default:
    pushq $0
    pushq $0xFFFF
    jmp exc_common

exc_common:
    mov (%rsp), %edi             /* vector */
    mov 8(%rsp), %esi            /* error code (0 if synthetic) */
    mov 16(%rsp), %rdx           /* saved RIP */
    mov %cr2, %rcx
    call exc_report
    cli
1:  hlt
    jmp 1b

exc_report:                      /* edi=vec, esi=err, rdx=rip, rcx=cr2 */
    push %rbx
    push %r12
    push %r13
    push %r14
    mov %edi, %ebx
    mov %esi, %r12d
    mov %rdx, %r13
    mov %rcx, %r14
    lea msg_exc_vec(%rip), %rdi
    call puts
    mov %ebx, %eax
    call puthex
    lea msg_exc_rip(%rip), %rdi
    call puts
    mov %r13, %rax
    call puthex64
    lea msg_exc_err(%rip), %rdi
    call puts
    mov %r12d, %eax
    call puthex
    lea msg_exc_cr2(%rip), %rdi
    call puts
    mov %r14, %rax
    call puthex64
    call putnl
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    ret

isr_timer:
    ISR_SAVE
    incl %gs:CT_TIMER
    incl %gs:CT_EOI
    mov lapic_base(%rip), %rdx
    movl $0, 0xB0(%rdx)
    ISR_RESTORE
    iretq

isr_ipi:
    ISR_SAVE
    incl %gs:CT_IPI
    incl %gs:CT_RESCHED
    incl %gs:CT_EOI
    mov lapic_base(%rip), %rdx
    movl $0, 0xB0(%rdx)
    ISR_RESTORE
    iretq

isr_spurious:
    incl %gs:CT_SPUR
    iretq

/* --------------------------------------------------------------- reports */
verify_tss_all:                  /* -> eax=1 if every TSS/IST is installed */
    push %rbx
    push %r12
    xor %ebx, %ebx
    mov $1, %r12d
.Lv_loop:
    cmp cpu_count(%rip), %ebx
    jae .Lv_done
    mov %ebx, %eax
    shl $6, %eax
    mov $CT_BASE, %edx
    cmpl $1, CT_TSS(%rdx,%rax)
    jne .Lv_bad

    mov %ebx, %eax
    shl $13, %eax
    add $GDT_BASE, %eax
    mov 24(%rax), %rcx           /* TSS descriptor low qword */
    mov %rcx, %rdx
    shr $40, %rdx
    and $0xFF, %edx
    cmp $0x89, %edx
    je 1f
    cmp $0x8B, %edx              /* ltr marks it busy */
    jne .Lv_bad
1:
    mov %ebx, %eax
    shl $13, %eax
    add $GDT_BASE+0x1000, %eax
    cmpl $0, 4(%rax)             /* rsp0 */
    je .Lv_bad
    cmpl $0, 0x24(%rax)          /* IST1 */
    je .Lv_bad
    cmpl $0, 0x2C(%rax)          /* IST2 */
    je .Lv_bad
    mov %ebx, %eax
    shl $6, %eax
    mov $CT_BASE, %edx
    movl $1, CT_IST(%rdx,%rax)
    inc %ebx
    jmp .Lv_loop
.Lv_bad:
    xor %r12d, %r12d
.Lv_done:
    mov %r12d, %eax
    pop %r12
    pop %rbx
    ret

print_core:                      /* edi=logical core */
    push %rbx
    push %r12
    mov %edi, %ebx

    /* Block r1 lives in the private state page mapped at VA 0x50000. */
    mov $ROOT_BASE, %rax
    mov %ebx, %ecx
    shl $14, %rcx
    add %rcx, %rax
    mov %rax, %cr3
    mov 0x50004, %eax
    mov %eax, %r12d
    mov $ROOT_BASE, %rax
    mov %rax, %cr3

    lea msg_core(%rip), %rdi
    call puts
    mov %ebx, %eax
    call putdec
    lea msg_r1(%rip), %rdi
    call puts
    mov %r12d, %eax
    call puthex

    /* Shared guest words: r2 stored at word 0x100+cpu, r3 at 0x200+cpu. */
    mov $G+0x800, %eax
    mov (%rax,%rbx,8), %rax
    shr $16, %rax
    mov %eax, %r12d
    lea msg_slot(%rip), %rdi
    call puts
    mov %r12d, %eax
    call puthex

    mov $G+0x1000, %eax
    mov (%rax,%rbx,8), %rax
    shr $16, %rax
    mov %eax, %r12d
    lea msg_done(%rip), %rdi
    call puts
    mov %r12d, %eax
    call puthex

    /* Per-core interrupt counters. */
    mov %ebx, %eax
    shl $6, %eax
    mov $CT_BASE, %edx
    mov CT_TIMER(%rdx,%rax), %r12d
    lea msg_timer(%rip), %rdi
    call puts
    mov %r12d, %eax
    call putdec

    mov %ebx, %eax
    shl $6, %eax
    mov $CT_BASE, %edx
    mov CT_IPI(%rdx,%rax), %r12d
    lea msg_ipi(%rip), %rdi
    call puts
    mov %r12d, %eax
    call putdec

    mov %ebx, %eax
    shl $6, %eax
    mov $CT_BASE, %edx
    mov CT_RESCHED(%rdx,%rax), %r12d
    lea msg_resched(%rip), %rdi
    call puts
    mov %r12d, %eax
    call putdec

    mov %ebx, %eax
    shl $6, %eax
    mov $CT_BASE, %edx
    mov CT_EOI(%rdx,%rax), %r12d
    lea msg_eoi(%rip), %rdi
    call puts
    mov %r12d, %eax
    call putdec

    mov %ebx, %eax
    shl $6, %eax
    mov $CT_BASE, %edx
    mov CT_TSS(%rdx,%rax), %r12d
    lea msg_tss(%rip), %rdi
    call puts
    mov %r12d, %eax
    call putdec

    mov %ebx, %eax
    shl $6, %eax
    mov $CT_BASE, %edx
    mov CT_IST(%rdx,%rax), %r12d
    lea msg_ist(%rip), %rdi
    call puts
    mov %r12d, %eax
    call putdec

    call putnl
    pop %r12
    pop %rbx
    ret

/* --------------------------------------------------------------- messages */
.section .rodata
.align 8
exc_table:
    .quad isr_exc_0
    .quad isr_exc_1
    .quad isr_exc_2
    .quad isr_exc_3
    .quad isr_exc_4
    .quad isr_exc_5
    .quad isr_exc_6
    .quad isr_exc_7
    .quad isr_exc_8
    .quad isr_exc_9
    .quad isr_exc_10
    .quad isr_exc_11
    .quad isr_exc_12
    .quad isr_exc_13
    .quad isr_exc_14
    .quad isr_exc_15
    .quad isr_exc_16
    .quad isr_exc_17
    .quad isr_exc_18
    .quad isr_exc_19
    .quad isr_exc_20
    .quad isr_exc_21
    .quad isr_exc_22
    .quad isr_exc_23
    .quad isr_exc_24
    .quad isr_exc_25
    .quad isr_exc_26
    .quad isr_exc_27
    .quad isr_exc_28
    .quad isr_exc_29
    .quad isr_exc_30
    .quad isr_exc_31

msg_banner:   .asciz "NAN64 RAW SMP x86_64\n"
msg_cpus:     .asciz "RAW64 cpus="
msg_core:     .asciz "RAW64 core"
msg_r1:       .asciz " r1="
msg_slot:     .asciz " slot="
msg_done:     .asciz " done="
msg_timer:    .asciz " timer="
msg_ipi:      .asciz " ipi="
msg_resched:  .asciz " resched="
msg_eoi:      .asciz " eoi="
msg_tss:      .asciz " tss="
msg_ist:      .asciz " ist="
msg_pass:     .asciz "RAW64 PASS\n"
msg_fail:     .asciz "RAW64 FAIL\n"
msg_exc_vec:  .asciz "RAW64 EXC vec="
msg_exc_rip:  .asciz " rip="
msg_exc_err:  .asciz " err="
msg_exc_cr2:  .asciz " cr2="
