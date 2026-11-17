// SD-path payload for the dual-boot simulation test.
//
// sdboot copies this from the SD image to 0x80000000 and jumps here. It
//   1. prints "SD PAYLOAD OK" on the console UART,
//   2. enables console RX and waits for the text "GATE": the host sends a
//      UART-TSI write to `sentinel`, then "GATE". The console UART sees every
//      byte on the shared line, the TSI side should see none (the boot ROM
//      closed the gate). Matching a marker instead of counting bytes skips
//      leftover mailbox requests the host sent just before the gate closed,
//   3. waits a little longer, so a leaked TSI write would have landed,
//   4. prints "GATE OK" if `sentinel` is unchanged, "GATE LEAK" otherwise.
//
// Build: riscv64-unknown-elf-gcc -march=rv64ima_zicsr -mabi=lp64 -nostdlib
//        -nostartfiles -Wl,-Ttext=0x80000000 -o sdpayload.elf sdpayload.S

#define UART_BASE        0x64000000
#define UART_TXFIFO      0x00
#define UART_RXFIFO      0x04
#define UART_RXCTRL      0x0c
#define SENTINEL_INIT    0x5a5a5a5a
#define MARKER           0x45544147  /* "GATE", little-endian */
#define SETTLE_LOOPS     200000

  .option norelax                    // keep .org 0x800 = 0x80000800 exact
  .section .text
  .globl _start
_start:
  li    s0, UART_BASE
  la    a0, msg_ok
  call  puts

  li    t0, 1
  sw    t0, UART_RXCTRL(s0)          // RX enable
  li    s1, 0                        // last 4 bytes received, newest in [31:24]
  li    s2, MARKER
1:
  lw    t0, UART_RXFIFO(s0)
  bltz  t0, 1b                       // bit 31 = empty
  andi  t0, t0, 0xff
  srliw s1, s1, 8
  slliw t0, t0, 24
  or    s1, s1, t0
  slli  s1, s1, 32                   // keep it a zero-extended 32-bit value
  srli  s1, s1, 32
  bne   s1, s2, 1b

  li    t1, SETTLE_LOOPS
2:
  addi  t1, t1, -1
  bnez  t1, 2b

  la    t0, sentinel
  lw    t1, 0(t0)
  li    t2, SENTINEL_INIT
  la    a0, msg_gate_ok
  beq   t1, t2, 3f
  la    a0, msg_gate_leak
3:
  call  puts
4:
  wfi
  j     4b

// a0 = NUL-terminated string
puts:
  lbu   t0, 0(a0)
  beqz  t0, 6f
5:
  lw    t1, UART_TXFIFO(s0)
  bltz  t1, 5b                       // bit 31 = full
  sw    t0, UART_TXFIFO(s0)
  addi  a0, a0, 1
  j     puts
6:
  ret

msg_ok:        .asciz "SD PAYLOAD OK\r\n"
msg_gate_ok:   .asciz "GATE OK\r\n"
msg_gate_leak: .asciz "GATE LEAK\r\n"

  // Fixed address the host writes to: 0x80000800 (test_dualboot.py SENTINEL_ADDR)
  .org 0x800
  .globl sentinel
sentinel:
  .word SENTINEL_INIT
  .word 0
