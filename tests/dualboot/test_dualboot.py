#!/usr/bin/env python3
"""test_dualboot.py - drive DualBootRocketConfig in Verilator through one boot path.

The simulator's shared UART ends in a pty; the host side is the real
notes/vcu118_port/dual_boot/uart_tsi_dual.py, attached to that pty.

  bare : uart_tsi_dual.py loads ELF over UART-TSI, sets MSIP, serves HTIF.
         Pass: exit code 0 and "Hello world" in its output.
  sd   : uart_tsi_dual.boot_linux() asks for the SD path; the ROM must ack
         (INIT), copy the SD payload (sdpayload.S) and run it. Then a TSI
         write to the payload's sentinel must NOT land (gate closed).
         Pass: "SD PAYLOAD OK", "GATE OK", and SimSDCard saw a slower SCK
         for init (CMD0..CMD16) than for CMD18.

  test_dualboot.py bare SIMULATOR SDIMAGE ELF
  test_dualboot.py sd   SIMULATOR SDIMAGE
"""

import argparse, importlib.util, os, re, shutil, struct, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
UART_TSI_DUAL = os.path.join(HERE, "..", "..", "notes", "vcu118_port", "dual_boot", "uart_tsi_dual.py")
SENTINEL_ADDR = 0x80000800          # sdpayload.S: .org 0x800
PROBE_VALUE = 0x0BADC0DE0BADC0DE
BAUD = 921600                       # a pty ignores it; any standard rate works


def load_uart_tsi_dual():
    spec = importlib.util.spec_from_file_location("uart_tsi_dual", UART_TSI_DUAL)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def start_sim(sim, sdimage, workdir, max_cycles):
    log = open(os.path.join(workdir, "sim.log"), "w")
    # Line-buffer the simulator's stdout so sim.log is readable while it runs
    # and survives the terminate() at the end.
    stdbuf = ["stdbuf", "-oL"] if shutil.which("stdbuf") else []
    cmd = stdbuf + [os.path.abspath(sim), "+permissive", f"+sdcard={os.path.abspath(sdimage)}",
           f"+max-cycles={max_cycles}", "+permissive-off", "none"]
    print("  sim:", " ".join(cmd))
    # A uartpty0 left by an earlier run points at a dead (or reused!) pty.
    link = os.path.join(workdir, "uartpty0")
    if os.path.lexists(link):
        os.remove(link)
    proc = subprocess.Popen(cmd, cwd=workdir, stdout=log, stderr=subprocess.STDOUT)
    t0 = time.time()
    while not os.path.islink(link):
        if proc.poll() is not None:
            raise RuntimeError(f"simulator exited ({proc.returncode}) before opening its pty; see {log.name}")
        if time.time() - t0 > 300:
            raise RuntimeError("no uartpty0 after 300 s")
        time.sleep(0.2)
    pty = os.readlink(link)
    print(f"  board UART = {pty}  (sim log: {log.name})")
    return proc, pty


def read_until(ser, needles, timeout):
    """Echo console bytes until one of `needles` appears; return it (or None)."""
    buf = bytearray()
    t0 = time.time()
    while time.time() - t0 < timeout:
        got = ser.read(256)
        if not got:
            continue
        sys.stdout.write(got.decode("latin1", "replace")); sys.stdout.flush()
        buf += got
        for n in needles:
            if n in buf:
                return n
    return None


def run_bare(pty, elf, timeout):
    cmd = [sys.executable, UART_TSI_DUAL, "--tty", pty, "--baud", str(BAUD),
           "--timeout", str(timeout), elf]
    print("  host:", " ".join(cmd))
    out = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=timeout)
    sys.stdout.write(out.stdout)
    ok = out.returncode == 0 and "Hello world" in out.stdout
    print(f"== bare-metal path {'PASSED' if ok else 'FAILED'} (uart_tsi_dual.py exit {out.returncode})")
    return ok


def run_sd(pty, timeout):
    utd = load_uart_tsi_dual()
    tsi = utd.Tsi(pty, BAUD, timeout=0.2)
    tsi.open()
    with tsi:
        t0 = time.time()
        rc = utd.boot_linux(tsi, utd.BOOT_MAILBOX, boot_timeout=timeout, retry=2.0)
        if rc != 0:
            print("== SD path FAILED: no INIT")
            return False
        print(f"  [test] INIT after {time.time() - t0:.1f} s; waiting for the SD payload")
        hit = read_until(tsi.ser, [b"SD PAYLOAD OK", b"ERROR"], timeout)
        if hit != b"SD PAYLOAD OK":
            print(f"\n== SD path FAILED: {'boot ROM ERROR' if hit else 'no SD PAYLOAD OK'}")
            return False
        print(f"\n  [test] payload up after {time.time() - t0:.1f} s; "
              f"TSI write 0x{PROBE_VALUE:x} -> 0x{SENTINEL_ADDR:x}, then 'GATE'")
        tsi.write_chunk(SENTINEL_ADDR, struct.pack("<Q", PROBE_VALUE))
        tsi.ser.write(b"GATE"); tsi.ser.flush()
        hit = read_until(tsi.ser, [b"GATE OK", b"GATE LEAK"], timeout)
        ok = hit == b"GATE OK"
        print(f"\n== SD path {'PASSED' if ok else 'FAILED'} ({(hit or b'no gate result').decode()})")
        return ok


def check_sck_switch(sim_log):
    """SimSDCard logs each command with the SCK period seen while it arrived.
    Init (CMD0..CMD16) must run on the slow SPI_INIT_CLK, CMD18 on SPI_CLK."""
    periods = {}
    with open(sim_log, errors="replace") as f:
        for line in f:
            m = re.search(r"\[SimSDCard\] (A?CMD)(\d+) arg=\S+ sck_period=(\d+)", line)
            if m:
                print("  " + line.strip())
                periods.setdefault(m.group(1) + m.group(2), int(m.group(3)))
    init = [periods[c] for c in ("CMD0", "CMD8", "ACMD41", "CMD58", "CMD16") if c in periods]
    copy = periods.get("CMD18")
    if not init or copy is None:
        print("== SCK check FAILED: SimSDCard command log missing")
        return False
    ok = min(init) > copy
    print(f"== SCK check {'PASSED' if ok else 'FAILED'}: init {min(init)}-{max(init)} cycles/bit, "
          f"CMD18 {copy} cycles/bit")
    return ok


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("mode", choices=["bare", "sd"])
    ap.add_argument("simulator")
    ap.add_argument("sdimage")
    ap.add_argument("elf", nargs="?")
    ap.add_argument("--timeout", type=float, default=3600, help="seconds per phase (default 3600)")
    ap.add_argument("--max-cycles", type=int, default=2_000_000_000)
    ap.add_argument("--workdir", help="where the simulator runs (default: a new temp dir)")
    a = ap.parse_args()
    if a.mode == "bare" and not a.elf:
        ap.error("bare needs ELF")

    workdir = a.workdir or tempfile.mkdtemp(prefix=f"dualboot-{a.mode}-")
    os.makedirs(workdir, exist_ok=True)
    proc, pty = start_sim(a.simulator, a.sdimage, workdir, a.max_cycles)
    try:
        ok = run_bare(pty, a.elf, a.timeout) if a.mode == "bare" else run_sd(pty, a.timeout)
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
    if a.mode == "sd":
        ok = check_sck_switch(os.path.join(workdir, "sim.log")) and ok
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
