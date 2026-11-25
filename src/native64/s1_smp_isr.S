/* s1_smp_isr.S - interrupt entry stubs for the x86_64 S1 SMP prototype.
 *
 * Only three vectors are live: 0x40 (per-CPU LAPIC timer), 0x41 (cross-CPU
 * reschedule IPI), 0xFF (spurious).  Every other IDT entry points at
 * isr_default, which reports the unexpected vector and halts the CPU.
 *
 * The C handlers are compiled with -mno-sse, so saving the caller-saved GPRs
 * is enough.  The 9 pushes + subq $8 keep the SysV 16-byte call alignment.
 */
.text

.macro ISR_SAVE
    push %rax
    push %rcx
    push %rdx
    push %rsi
    push %rdi
    push %r8
    push %r9
    push %r10
    push %r11
    sub $8, %rsp
.endm

.macro ISR_RESTORE
    add $8, %rsp
    pop %r11
    pop %r10
    pop %r9
    pop %r8
    pop %rdi
    pop %rsi
    pop %rdx
    pop %rcx
    pop %rax
.endm

.globl isr_timer
isr_timer:
    ISR_SAVE
    call smp_timer_isr
    ISR_RESTORE
    iretq

.globl isr_ipi
isr_ipi:
    ISR_SAVE
    call smp_ipi_isr
    ISR_RESTORE
    iretq

.globl isr_spurious
isr_spurious:
    iretq

/* Page fault and double fault push an error code.  Report the saved RIP,
 * error code and CR2 so a bring-up failure is diagnosable on COM1. */
.globl isr_pf
isr_pf:
    ISR_SAVE
    mov 80(%rsp), %rdi          /* error code */
    mov 88(%rsp), %rsi          /* saved RIP */
    mov %cr2, %rdx
    mov $14, %ecx
    call smp_exception_isr
    ISR_RESTORE
    add $8, %rsp
    iretq

.globl isr_df
isr_df:
    ISR_SAVE
    mov 80(%rsp), %rdi
    mov 88(%rsp), %rsi
    mov %cr2, %rdx
    mov $8, %ecx
    call smp_exception_isr
    ISR_RESTORE
    add $8, %rsp
    iretq

.globl isr_default
isr_default:
    ISR_SAVE
    call smp_default_isr
    ISR_RESTORE
    iretq
