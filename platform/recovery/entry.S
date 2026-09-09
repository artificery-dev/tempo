/* RAM-only DA stage 2, entered in ARM state at 0x80000000.
 * The diagnostic DTB is at +0x1000; zImage at +0x8000.
 * Refuse unexpected MMU/data-cache state instead of discarding dirty data.
 */
.syntax unified
.arch armv7-a
.arm
.section .text.entry,"ax"
.global _start
_start:
    cpsid aif
    mrc p15, 0, r4, c1, c0, 0
    tst r4, #5
    bne bad_state
    ldr r0, =0x10007000
    ldr r1, =0x22000000
    str r1, [r0]                 /* stop the boot watchdog */
    mov r0, #0
    mcr p15, 0, r0, c7, c5, 0   /* invalidate I-cache */
    mcr p15, 0, r0, c7, c5, 6   /* invalidate branch predictor */
    dsb sy
    isb sy
    ldr r0, =message
    bl puts
    ldr r0, =usb_ready
    bl usb_puts
    mov r0, #0
    mvn r1, #0
    ldr r2, =0x80001000
    ldr r3, =0x80008000
    bx r3
bad_state:
    ldr r0, =error_message
    bl puts
    ldr r0, =usb_error
    bl usb_puts
1:  wfe
    b 1b
/* UART0 retains the preloader's configuration; bounded polling needs no stack. */
puts:
    ldr r5, =0x11002000
2:  ldrb r6, [r0], #1
    cmp r6, #0
    bxeq lr
    mov r7, #0x100000
3:  ldr r8, [r5, #0x14]
    tst r8, #0x20
    bne 4f
    subs r7, r7, #1
    bne 3b
    bx lr
4:  str r6, [r5]
    b 2b
message: .asciz "\r\nTEMPO RAMBOOT: entering Linux\r\n"
error_message: .asciz "\r\nTEMPO RAMBOOT: unexpected MMU/cache state\r\n"

/* DA1's initialized transport vtable, verified in the committed MT6582 agent.
 * The byte-write slot is used for DA1's own upload acknowledgements.
 * Preserve the inherited SRAM stack while calling its Thumb implementation.
 */
usb_puts:
    push {r4, r5, r6, lr}
    mov r4, r0
    ldr r5, =0x20ccb0
5:  ldrb r0, [r4], #1
    cmp r0, #0
    popeq {r4, r5, r6, pc}
    ldr r3, [r5, #16]
    blx r3
    b 5b
usb_ready: .asciz "TRDY"
usb_error: .asciz "TCAC"
