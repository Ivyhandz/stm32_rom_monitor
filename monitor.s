/* ============================================================
   STM32F103C8T6 ROM Monitor — pure ARM assembly, bare metal
   Clock: HSI 8 MHz (reset default, no PLL)
   Console: USART1, PA9 = TX, PA10 = RX, 9600 8N1
   ============================================================ */

    .syntax unified
    .cpu    cortex-m3
    .thumb

/* ---------- Peripheral register addresses ---------- */
    .equ RCC_APB2ENR,  0x40021018
    .equ GPIOA_CRH,    0x40010804
    .equ USART1_SR,    0x40013800
    .equ USART1_DR,    0x40013804
    .equ USART1_BRR,   0x40013808
    .equ USART1_CR1,   0x4001380C

/* ============================================================
   Vector table
   ============================================================ */
    .section .isr_vector, "a", %progbits
    .word   _estack             /* 0x00 initial MSP            */
    .word   Reset_Handler       /* 0x04 reset                  */
    .word   Default_Handler     /* NMI                         */
    .word   HardFault_Handler   /* HardFault                   */
    .word   Default_Handler     /* MemManage                   */
    .word   Default_Handler     /* BusFault                    */
    .word   Default_Handler     /* UsageFault                  */
    .word   0
    .word   0
    .word   0
    .word   0
    .word   Default_Handler     /* SVCall                      */
    .word   Default_Handler     /* DebugMon                    */
    .word   0
    .word   Default_Handler     /* PendSV                      */
    .word   Default_Handler     /* SysTick                     */

/* ============================================================
   Reset
   ============================================================ */
    .section .text
    .thumb_func
    .global Reset_Handler
Reset_Handler:
    ldr     r0, =_estack
    mov     sp, r0

    /* zero .bss */
    ldr     r0, =_sbss
    ldr     r1, =_ebss
    movs    r2, #0
1:  cmp     r0, r1
    bge     2f
    str     r2, [r0], #4
    b       1b
2:
    bl      uart_init
    ldr     r0, =msg_banner
    bl      uart_puts

main_loop:
    ldr     r0, =msg_prompt
    bl      uart_puts
    ldr     r0, =line_buf
    movs    r1, #63
    bl      readline
    bl      parse_and_exec
    b       main_loop

    .thumb_func
Default_Handler:
    b       Default_Handler

/* ============================================================
   USART1 initialisation
   ============================================================ */
    .thumb_func
uart_init:
    /* enable GPIOA (bit 2) and USART1 (bit 14) clocks */
    ldr     r0, =RCC_APB2ENR
    ldr     r1, [r0]
    orr     r1, r1, #(1 << 2)
    orr     r1, r1, #(1 << 14)
    str     r1, [r0]

    /* PA9  = alternate function push-pull, 50 MHz -> nibble 0xB
       PA10 = input floating                     -> nibble 0x4
       CRH nibble positions: PA9 = bits 4-7, PA10 = bits 8-11 */
    ldr     r0, =GPIOA_CRH
    ldr     r1, [r0]
    ldr     r2, =0xFFFFF00F
    and     r1, r1, r2
    ldr     r2, =0x000004B0
    orr     r1, r1, r2
    str     r1, [r0]

    /* BRR for 9600 baud @ 8 MHz:
       8000000 / 9600 = 833.33
       mantissa 52 (0x34), fraction 5  ->  (52<<4)|5 = 0x341 */
    ldr     r0, =USART1_BRR
    ldr     r1, =0x341
    str     r1, [r0]

    /* CR1: UE(13) | TE(3) | RE(2) = 0x200C */
    ldr     r0, =USART1_CR1
    ldr     r1, =0x200C
    str     r1, [r0]
    bx      lr

/* ---------- send one char, r0 = char ---------- */
    .thumb_func
uart_putc:
    ldr     r1, =USART1_SR
1:  ldr     r2, [r1]
    tst     r2, #(1 << 7)          /* TXE */
    beq     1b
    ldr     r1, =USART1_DR
    strb    r0, [r1]
    bx      lr

/* ---------- blocking receive, returns char in r0 ---------- */
    .thumb_func
uart_getc:
    ldr     r1, =USART1_SR
1:  ldr     r2, [r1]
    tst     r2, #(1 << 5)          /* RXNE */
    beq     1b
    ldr     r1, =USART1_DR
    ldrb    r0, [r1]
    bx      lr

/* ---------- send null-terminated string, r0 = pointer ---------- */
    .thumb_func
uart_puts:
    push    {r4, lr}
    mov     r4, r0
1:  ldrb    r0, [r4], #1
    cmp     r0, #0
    beq     2f
    bl      uart_putc
    b       1b
2:  pop     {r4, pc}

/* ============================================================
   Hex output
   ============================================================ */
    .thumb_func
print_hex32:
    push    {r4, r5, lr}
    mov     r4, r0
    movs    r5, #28
1:  lsr     r0, r4, r5
    and     r0, r0, #0xF
    cmp     r0, #10
    ite     lt
    addlt   r0, r0, #48            /* '0' */
    addge   r0, r0, #55            /* 'A' - 10 */
    bl      uart_putc
    subs    r5, r5, #4
    bge     1b
    pop     {r4, r5, pc}

    .thumb_func
print_hex8:
    push    {r4, r5, lr}
    mov     r4, r0
    movs    r5, #4
1:  lsr     r0, r4, r5
    and     r0, r0, #0xF
    cmp     r0, #10
    ite     lt
    addlt   r0, r0, #48
    addge   r0, r0, #55
    bl      uart_putc
    subs    r5, r5, #4
    bge     1b
    pop     {r4, r5, pc}

/* ============================================================
   Line input.  r0 = buffer, r1 = max length
   ============================================================ */
    .thumb_func
readline:
    push    {r4, r5, r6, lr}
    mov     r4, r0
    mov     r5, r1
    movs    r6, #0
1:  bl      uart_getc
    cmp     r0, #13                /* CR  */
    beq     4f
    cmp     r0, #10                /* LF  */
    beq     4f
    cmp     r0, #8                 /* BS  */
    beq     2f
    cmp     r0, #127               /* DEL */
    beq     2f
    cmp     r6, r5
    bge     1b
    strb    r0, [r4, r6]
    add     r6, r6, #1
    bl      uart_putc              /* echo */
    b       1b
2:  cmp     r6, #0
    beq     1b
    sub     r6, r6, #1
    movs    r0, #8
    bl      uart_putc
    movs    r0, #32
    bl      uart_putc
    movs    r0, #8
    bl      uart_putc
    b       1b
4:  movs    r0, #0
    strb    r0, [r4, r6]
    ldr     r0, =msg_crlf
    bl      uart_puts
    pop     {r4, r5, r6, pc}

/* ============================================================
   Parsing helpers.  r4 is the cursor into line_buf throughout.
   ============================================================ */
    .thumb_func
skip_spaces:
1:  ldrb    r0, [r4]
    cmp     r0, #32
    bne     2f
    add     r4, r4, #1
    b       1b
2:  bx      lr

/* returns: r0 = value, r1 = number of digits consumed (0 = none) */
    .thumb_func
get_hex:
    push    {r5, r6, lr}
    movs    r5, #0
    movs    r6, #0
1:  ldrb    r0, [r4]
    cmp     r0, #48                /* '0' */
    blt     3f
    cmp     r0, #57                /* '9' */
    bgt     2f
    sub     r0, r0, #48
    b       4f
2:  orr     r0, r0, #0x20          /* fold to lower case */
    cmp     r0, #97                /* 'a' */
    blt     3f
    cmp     r0, #102               /* 'f' */
    bgt     3f
    sub     r0, r0, #87            /* 'a' - 10 */
4:  lsl     r5, r5, #4
    orr     r5, r5, r0
    add     r4, r4, #1
    add     r6, r6, #1
    b       1b
3:  mov     r0, r5
    mov     r1, r6
    pop     {r5, r6, pc}

/* ============================================================
   Command dispatch
   ============================================================ */
    .thumb_func
parse_and_exec:
    push    {r4, r5, r6, r7, lr}
    ldr     r4, =line_buf
    bl      skip_spaces
    ldrb    r0, [r4]
    cmp     r0, #0
    beq     pe_done
    add     r4, r4, #1
    cmp     r0, #'d'
    beq     do_dump
    cmp     r0, #'w'
    beq     do_write_byte
    cmp     r0, #'W'
    beq     do_write_word
    cmp     r0, #'g'
    beq     do_go
    cmp     r0, #'r'
    beq     do_regs
    cmp     r0, #'?'
    beq     do_help
    cmp     r0, #'h'
    beq     do_help
    ldr     r0, =msg_unknown
    bl      uart_puts
pe_done:
    pop     {r4, r5, r6, r7, pc}

err_arg:
    ldr     r0, =msg_badarg
    bl      uart_puts
    b       pe_done

do_help:
    ldr     r0, =msg_help
    bl      uart_puts
    b       pe_done

/* ---------- d <addr> : dump 4 lines of 16 bytes ---------- */
do_dump:
    bl      skip_spaces
    bl      get_hex
    cmp     r1, #0
    beq     err_arg
    bic     r5, r0, #15            /* align down to 16 */
    movs    r6, #4
dump_line:
    mov     r0, r5
    bl      print_hex32
    ldr     r0, =msg_colon
    bl      uart_puts
    movs    r7, #0
1:  ldrb    r0, [r5, r7]
    bl      print_hex8
    movs    r0, #32
    bl      uart_putc
    add     r7, r7, #1
    cmp     r7, #16
    blt     1b
    movs    r0, #'|'
    bl      uart_putc
    movs    r7, #0
2:  ldrb    r0, [r5, r7]
    cmp     r0, #32
    blt     3f
    cmp     r0, #126
    ble     4f
3:  movs    r0, #'.'
4:  bl      uart_putc
    add     r7, r7, #1
    cmp     r7, #16
    blt     2b
    movs    r0, #'|'
    bl      uart_putc
    ldr     r0, =msg_crlf
    bl      uart_puts
    add     r5, r5, #16
    subs    r6, r6, #1
    bne     dump_line
    b       pe_done

/* ---------- w <addr> <byte> ---------- */
do_write_byte:
    bl      skip_spaces
    bl      get_hex
    cmp     r1, #0
    beq     err_arg
    mov     r5, r0
    bl      skip_spaces
    bl      get_hex
    cmp     r1, #0
    beq     err_arg
    strb    r0, [r5]
    ldr     r0, =msg_ok
    bl      uart_puts
    b       pe_done

/* ---------- W <addr> <word> ---------- */
do_write_word:
    bl      skip_spaces
    bl      get_hex
    cmp     r1, #0
    beq     err_arg
    bic     r5, r0, #3             /* force word alignment */
    bl      skip_spaces
    bl      get_hex
    cmp     r1, #0
    beq     err_arg
    str     r0, [r5]
    ldr     r0, =msg_ok
    bl      uart_puts
    b       pe_done

/* ---------- g <addr> ---------- */
do_go:
    bl      skip_spaces
    bl      get_hex
    cmp     r1, #0
    beq     err_arg
    mov     r5, r0
    ldr     r0, =_estack           /* abandon monitor frame, fresh stack */
    mov     sp, r0
    ldr     lr, =go_return
    orr     lr, lr, #1             /* Thumb bit, so user code can bx lr */
    orr     r5, r5, #1             /* Thumb bit on target */
    bx      r5
go_return:
    b       main_loop

/* ---------- r : system registers ---------- */
do_regs:
    ldr     r0, =msg_msp
    bl      uart_puts
    mrs     r0, msp
    bl      print_hex32
    ldr     r0, =msg_crlf
    bl      uart_puts

    ldr     r0, =msg_psp
    bl      uart_puts
    mrs     r0, psp
    bl      print_hex32
    ldr     r0, =msg_crlf
    bl      uart_puts

    ldr     r0, =msg_primask
    bl      uart_puts
    mrs     r0, primask
    bl      print_hex32
    ldr     r0, =msg_crlf
    bl      uart_puts

    ldr     r0, =msg_control
    bl      uart_puts
    mrs     r0, control
    bl      print_hex32
    ldr     r0, =msg_crlf
    bl      uart_puts
    b       pe_done

/* ============================================================
   HardFault handler — the real debugger feature.
   Selects the stack that was active, prints the 8-word
   exception frame, then restarts the monitor prompt.
   ============================================================ */
    .thumb_func
    .global HardFault_Handler
HardFault_Handler:
    tst     lr, #4
    ite     eq
    mrseq   r0, msp
    mrsne   r0, psp
    mov     r4, r0
    ldr     r0, =msg_fault
    bl      uart_puts
    movs    r5, #0
    ldr     r6, =reg_name_tbl
1:  ldr     r0, [r6, r5, lsl #2]
    bl      uart_puts
    ldr     r0, [r4, r5, lsl #2]
    bl      print_hex32
    ldr     r0, =msg_crlf
    bl      uart_puts
    add     r5, r5, #1
    cmp     r5, #8
    blt     1b
    ldr     r0, =_estack
    mov     sp, r0
    b       main_loop

/* ============================================================
   Read-only data
   ============================================================ */
    .section .rodata
    .align  2
reg_name_tbl:
    .word   rn_r0, rn_r1, rn_r2, rn_r3
    .word   rn_r12, rn_lr, rn_pc, rn_psr

rn_r0:   .asciz "R0   = "
rn_r1:   .asciz "R1   = "
rn_r2:   .asciz "R2   = "
rn_r3:   .asciz "R3   = "
rn_r12:  .asciz "R12  = "
rn_lr:   .asciz "LR   = "
rn_pc:   .asciz "PC   = "
rn_psr:  .asciz "xPSR = "

msg_banner:
    .asciz "\r\n=== STM32F103 ROM Monitor v0.1 ===\r\nType ? for help\r\n"
msg_prompt:  .asciz "\r\n> "
msg_crlf:    .asciz "\r\n"
msg_colon:   .asciz ": "
msg_ok:      .asciz "OK\r\n"
msg_badarg:  .asciz "?ARG\r\n"
msg_unknown: .asciz "?CMD\r\n"
msg_fault:   .asciz "\r\n*** HARD FAULT ***\r\n"
msg_msp:     .asciz "MSP     = "
msg_psp:     .asciz "PSP     = "
msg_primask: .asciz "PRIMASK = "
msg_control: .asciz "CONTROL = "
msg_help:
    .asciz "\r\nd <addr>          dump 64 bytes\r\nw <addr> <byte>   write byte\r\nW <addr> <word>   write word\r\ng <addr>          execute at addr\r\nr                 system registers\r\n?                 this help\r\n"

    .align  2

/* ============================================================
   RAM
   ============================================================ */
    .section .bss
    .align  2
line_buf:
    .space  64

    .end