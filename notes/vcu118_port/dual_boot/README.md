# VCU118 Dual Boot: bare-metal or Linux from one bitstream

With the `GemminiVCU118DualBootConfig` bitstream you can pick bare-metal or Linux from the host after every reset, using one USB cable and no reprogramming.

- **Bare-metal**: the host loads an ELF into DDR over UART-TSI and starts it. Program output comes back to the host over HTIF.
- **Linux**: the host asks the boot ROM to copy the Linux image from the SD card and boot it. After that, the same cable is the Linux console.

[`uart_tsi_dual.py`](uart_tsi_dual.py) is the host-side tool for both paths.

---

## 1. Bitstream

### 1.1 Bitstream file

| Item | Value |
|---|---|
| Config | `chipyard.fpga.vcu118.GemminiVCU118DualBootConfig` ([Configs.scala](../../../fpga/src/main/scala/vcu118/Configs.scala)) |
| Top module | `VCU118FPGATestHarness` (`VCU118FPGATestHarness.bit`) |
| Device | `xcvu9p-flga2104-2L-e` |
| Tested bitstream | 39,595,808 B, SHA-256 `9095d8aa08dbdf640824c8fa8587f76c00d1a7bfa14cde936741a6eb8e02db28` |
| Tools | Vivado 2025.2 |
| Timing | Met. WNS +0.106 ns, WHS +0.009 ns, no failing endpoints |

The test board has this bitstream **programmed into its configuration flash**:
- The FPGA loads it automatically at every power-up. You do not need to program it again after a power cycle.
- After power-up (DONE LED on), the boot ROM is already waiting for the host, so the first run does not need a reset.
- Press CPU_RESET before each run after that (see 2).

### 1.2 Resource utilization

From `obj/report/utilization.txt` (post-route, `report_utilization -hierarchical`). Device totals for the xcvu9p: 1,182,240 LUTs, 2,364,480 FFs, 2,160 block RAM tiles (RAMB36), 960 URAMs, 6,840 DSPs.

| Instance | LUTs | (LUTRAM) | FFs | RAMB36 | RAMB18 | DSP |
|---|---:|---:|---:|---:|---:|---:|
| **Whole design** (`VCU118FPGATestHarness`) | **240,342 (20.3%)** | 9,678 | **106,249 (4.5%)** | 225 | 153 | **230 (3.4%)** |
| SoC (`chiptop0`) | 222,807 | 7,962 | 81,620 | 200 | 152 | 227 |
| └ Gemmini | 172,759 | 2,878 | 60,563 | 64 | 128 | 203 |
| └ Rocket core | 5,708 | 80 | 2,108 | 0 | 0 | 13 |
| └ FPU | 14,070 | 0 | 3,764 | 0 | 0 | 11 |
| └ L1 D-cache | 6,182 | 2,664 | 2,417 | 0 | 0 | 0 |
| └ Frontend (L1 I-cache) | 4,182 | 112 | 3,924 | 0 | 16 | 0 |
| └ L2 (`InclusiveCache`) | 9,089 | 634 | 3,829 | 120 | 8 | 0 |
| DDR4 controller (`mig`) | 17,102 | 1,696 | 23,652 | 25 | 1 | 3 |

- Block RAM: 225 RAMB36 + 153 RAMB18 = 301.5 tiles (14.0%). URAM: 0.
- Gemmini accounts for about 72% of the design's LUTs.

### 1.3 SoC

| Item | Value |
|---|---|
| CPU | Rocket (RV64GC), 1 core |
| Accelerator | Gemmini, `LeanGemminiConfig(defaultConfig)`: 16×16, int8/int32, **WS dataflow only** |
| Clock | 50 MHz on all buses |
| DDR | 2 GB at `0x8000_0000` |
| Console UART | `0x6400_0000`, 921600 baud at reset |
| SPI (SD card) | `0x6400_1000` |
| GPIO | `0x6400_2000`, 1 pin. GPIO[0] closes the TSI gate (see 1.4) |
| UART-TSI | 921600 baud |

### 1.4 Board connections

| Function | Where |
|---|---|
| Console + UART-TSI | On-board USB-UART (CP2105), **Standard COM port**. On Linux this is usually `/dev/ttyUSB1`; `ttyUSB0` is the Enhanced port, which goes to the system controller |
| SD card | Pmod microSD adapter on **PMOD J52**, top row (pin 1 = CS) |
| Reset | **SW5 CPU_RESET**. Do not use PROG; it clears the FPGA |

The console UART and UART-TSI share the one USB-UART:
- The board's RX line feeds both.
- The board's TX line is the logical AND of both, so each idles high.
- When GPIO[0] is driven high, the TSI receiver sees a constant idle line, so it stops listening. This is the *TSI gate*. Out of reset the gate is open.

To find the Standard port on a Linux host:

```bash
for t in /sys/class/tty/ttyUSB*; do echo "$(basename $t): $(cat $t/device/../interface)"; done
```

---

## 2. Boot flow

```
CPU_RESET
  └─ boot ROM (sdboot -DDUALBOOT) clears the mailbox, prints nothing, waits with no timeout
       ├─ MSIP set by the host                 → bare-metal: jump to 0x8000_0000
       └─ mailbox == "LINUXSD!" (from the host) → Linux:
            write ACK → close TSI gate → print INIT → SD init → copy payload → BOOT → jump to 0x8000_0000
```

- **The choice is made once per reset.** Press CPU_RESET before every run, whichever path you take.
- While the ROM waits it must stay silent, because the TX line is shared with TSI responses.
- In both paths the ROM jumps to `0x8000_0000` with `a0 = hartid` and `a1 = DTB` (the DTB is stored in the boot ROM).

### 2.1 Boot ROM parameters

| Parameter | Value |
|---|---|
| Mailbox | `0x8FFF_F800`, 64-bit |
| Linux request magic | `0x4C494E5558534421` (`"LINUXSD!"`) |
| ROM ack | `0x41434B4544545349` (`"ACKEDTSI"`), written back to the mailbox |
| Payload | `PAYLOAD_SIZE_B` = 48 MiB (`0x3000000`), read from **absolute sector 34** into `0x8000_0000` |
| SD init clock (CMD0 to CMD16) | 300 kHz (SPI divisor 82, 301 kHz) |
| SD copy clock (CMD18) | **1 MHz** (SPI divisor 24). Copying 48 MiB takes about 7 minutes |

The copy clock was measured on the board. The ROM was waiting, and the host drove the SPI controller directly over TSI. Reads with CMD18 at sector 34 were checked against CRC16 and against a read at 300 kHz:

| SPI clock | Result |
|---|---|
| 301 kHz to 3.125 MHz | Pass. 3 × 8 sectors per speed; 2.08, 2.5 and 3.125 MHz also passed 2 × 128 sectors |
| 3.57 MHz | Fail: CMD18 returns R1 `0x08` (CRC error) |
| 5 MHz and above | Fail: no response to CMD18 (`sd_cmd: timeout`) |

Faster clocks most likely fail because of delay through the J52 level shifter (U41). 1 MHz leaves a margin of about 3.5× below the first failing speed. An earlier version of this config copied at 12.5 MHz and always failed with `LOADING  sd_cmd: timeout` / `ERROR`.

### 2.2 Console baud rate

The console runs at two different baud rates during one Linux boot:

| Stage | Baud | Why |
|---|---|---|
| Boot ROM (`INIT` ... `BOOT`) | 921600 | UART reset value |
| OpenSBI and early kernel log (earlycon) | 921600 | The DTS UART node has no `clock-frequency`, so OpenSBI keeps the existing divisor |
| From `printk: console [ttySIF0] enabled` onward, including login | **115200** | The Linux SiFive UART driver defaults to 115200 when `console=ttySIF0` gives no rate |

A terminal at 115200 therefore shows `�` characters until the kernel console switches. A terminal at 921600 shows garbage after it switches.

---

## 3. `uart_tsi_dual.py`

This is a portable (Linux/Windows) host for the UART-TSI and HTIF protocols, written in Python with pyserial. It replaces chipyard's Linux-only `uart_tsi` binary, which depends on fesvr. `--boot-linux` is the only addition over [`../uart_tsi.py`](../uart_tsi.py).

```bash
pip install pyserial
```

| Mode | Command | What it does |
|---|---|---|
| Link check | `--read ADDR` | Reads one 32-bit word over TSI and exits. It does not start anything, so it does not use up the boot choice |
| Bare-metal | `<elf>` | Loads the ELF's PT_LOAD segments, zero-fills `.bss`, sets MSIP, then serves HTIF (console output, `exit`) until the program exits |
| Linux | `--boot-linux` | Writes the magic to the mailbox once per second until the console prints `INIT`, then exits. The port then belongs to the console |

| Option | Default | Notes |
|---|---|---|
| `--tty` | (required) | e.g. `/dev/ttyUSB1`, `COM3` |
| `--baud` | 115200 | **Always pass `--baud 921600`** for this bitstream |
| `--timeout` | 10 s | Timeout for each TSI response |
| `--boot-timeout` | 30 s | How long `--boot-linux` keeps asking |
| `--boot-retry` | 1 s | Interval between mailbox writes |
| `--boot-mailbox` | `0x8FFFF800` | Must match `sd.c` |

Exit codes: `0` success, `1` the program exited non-zero, `2` port or response error (or no `INIT`), `130` Ctrl+C.

Close any terminal program (picocom, screen and so on) on the port before you run the script.

---

## 4. Bare-metal test

Two things to know before you start:
- **Build the workloads first, on the host.** The board only runs ELFs that you pass to the script; nothing is stored on the board.
- **One workload per reset.** After a program exits, hart0 does not go back to the boot ROM's wait loop. Press **CPU_RESET** before loading the next workload, or the script fails with `no response from target`.

### 4.1 Build test programs

```bash
source env.sh

# Rocket only
cd tests
cmake -S . -B build -D CMAKE_BUILD_TYPE=Debug
cmake --build build --target hello cpp-hello mt-hello            # build/*.riscv
ls $RISCV/riscv64-unknown-elf/share/riscv-tests/benchmarks/*.riscv  # prebuilt riscv-tests

# Gemmini
cd ../generators/gemmini/software/gemmini-rocc-tests
./build.sh BAREMETAL_ONLY=1        # build/bareMetalC/*-baremetal, build/imagenet/*-baremetal, ...
```

- If linking fails with `cannot open linker script file .../riscv-tests/benchmarks/common/test.ld`, the `riscv-tests` submodule inside gemmini-rocc-tests is empty. Restore it with:
  `git -C generators/gemmini/software/gemmini-rocc-tests/riscv-tests reset --hard HEAD && git -C generators/gemmini/software/gemmini-rocc-tests/riscv-tests submodule update --init`
- Tests must be built with a `gemmini-rocc-tests/include/gemmini_params.h` that matches the bitstream's Gemmini config. For this bitstream the header committed in the gemmini-rocc-tests submodule already matches (DIM 16, 4 banks, ACC_ROWS 1024). Use it as checked out; there is no need to elaborate first.

### 4.2 Run

```bash
T="python3 notes/vcu118_port/dual_boot/uart_tsi_dual.py --tty /dev/ttyUSB1 --baud 921600"

$T --read 0x80000000                       # link check (no reset needed)

# General form: press CPU_RESET, then
$T <workload path>                         # an ELF built in 4.1
```

Examples, one workload per reset:

```bash
$T tests/build/hello.riscv
#   [CPU_RESET]
$T $RISCV/riscv64-unknown-elf/share/riscv-tests/benchmarks/dhrystone.riscv
#   [CPU_RESET]
$T generators/gemmini/software/gemmini-rocc-tests/build/bareMetalC/template-baremetal
```

Expected output:

```text
uart_tsi_dual.py  port /dev/ttyUSB1  921600 baud
  template-baremetal  entry 0x80000000
  segment 0x80000000-0x8000....  ...
  loaded ... in ... s
  waking hart0
  HTIF attached  tohost=0x... fromhost=0x...

<program output>

  exit code 0
```

Notes:
- Pass the ELF itself. Do not pass the `.dump` file or a stripped binary; the script needs the `tohost`/`fromhost` symbols.
- The ELF must start at `0x8000_0000`.
- The Gemmini hardware supports **WS dataflow only**. OS-dataflow tests and `*_spad` tests (external scratchpad) are not expected to pass.

---

## 5. Linux test

### 5.1 SD card

Write the FireMarshal flat image (`*-bin-nodisk-flat`, at most 48 MiB) raw to **partition 1, which must start at sector 34**. Building and writing the image (`gemmini-all`) is described in [`../README.md`](../README.md) sections 7.2 and 7.3. A card that already booted with the earlier single-purpose Linux bitstream works as is.

### 5.2 Boot

```bash
# 1. Press CPU_RESET
# 2. Request the Linux path; the script exits as soon as the ROM prints INIT
python3 notes/vcu118_port/dual_boot/uart_tsi_dual.py --tty /dev/ttyUSB1 --baud 921600 --boot-linux

# 3. Open the console at 115200 (login runs at this rate, see 2.2)
picocom -b 115200 /dev/ttyUSB1
```

- For about the first 7 minutes, `�` characters appear at 115200. They are the ROM's copy spinner and the OpenSBI banner, sent at 921600. This is normal.
- To read the ROM and OpenSBI log, open picocom at 921600 instead. When the text turns to garbage, which happens at the kernel console switch, press **Ctrl-A Ctrl-D** three times to drop to 115200. Ctrl-A Ctrl-U raises the rate again.
- If no prompt appears after the boot finishes, press Enter.
- To exit picocom, press **Ctrl-A** then **Ctrl-X**. Ctrl-C does not exit; it is sent to the board. Exiting does not reset the board, so Linux keeps running and you can reopen the console with the same command. Exit picocom before you run `uart_tsi_dual.py` again.

Expected output, up to the login prompt:

```text
$ python3 notes/vcu118_port/dual_boot/uart_tsi_dual.py --tty /dev/ttyUSB1 --baud 921600 --boot-linux
uart_tsi_dual.py  port /dev/ttyUSB1  921600 baud
  boot ROM took the SD path after ~0 s (1 request)
INIT
CMD0
CMD8
ACMD41

  the line now belongs to the console; open a terminal on the same port

$ picocom -b 115200 /dev/ttyUSB1
picocom v3.1

port is        : /dev/ttyUSB1
flowcontrol    : none
baudrate is    : 115200
...
Type [C-a] [C-h] to see available commands
Terminal ready
�����������������������������������        ← ROM copy spinner + OpenSBI/early kernel log at 921600 (about 7 min)
```

- The script exits as soon as it sees `INIT`. The ROM lines after `INIT` that the script did not read are lost, which is why the output stops at `ACMD41` here.
- The `�` characters are expected (see 2.2). Once the kernel console switches to 115200, the boot log becomes readable and ends at:

```text
Welcome to Buildroot
buildroot login:          ← root / fpga
```

### 5.3 Run Gemmini tests

```sh
cd /root/gemmini
./tiled_matmul_ws-linux; echo rc=$?        # rc=0 → pass

cd /root/imagenet
time ./mobilenet-linux ws conv             # ends with PASS
```

Judge a test only by its exit code. Do not write `./t | grep ...; echo $?`, because in busybox `ash` that `$?` is grep's exit code.

### 5.4 Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `no INIT within 30 s` | The board was not reset, or the ROM already took a path. Press CPU_RESET and retry. Check `--baud 921600` and the port |
| `TimeoutError: no response from target` (any mode) | TSI gate closed by an earlier `--boot-linux`, or no reset since the last run. Press CPU_RESET |
| `INIT` → `sd_cmd: timeout` → `ERROR` right after `CMD0` | No card response: check seating, J52 position and orientation |
| `CMD18` → `LOADING  sd_cmd: timeout` → `ERROR` | SPI copy clock too fast for this card and adapter (see 2.1). Lower `spiClkKHz` and rebuild |
| `CRC mismatch` during `LOADING` | Bad SD write or bad card. Rewrite the card and verify the write with `cmp` |
| Only `�` at 115200 after more than 10 minutes | Press Enter. If still nothing, check at 921600 whether the boot stopped at `ERROR` |
| `/dev/ttyUSB1` gone (inside a devcontainer) | USB re-enumerated, for example after reprogramming. A privileged container does not see hot-plugged devices; reopen the container or run the script on the host |
