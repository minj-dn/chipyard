#!/usr/bin/env bash
# Dual-boot simulation test: builds everything, then runs both boot paths on
# DualBootRocketConfig (Verilator). Prints "== both paths passed" on success.
#
#   source env.sh && tests/dualboot/run.sh
#   SKIP_SD=1   tests/dualboot/run.sh   # bare-metal path only
#   SKIP_BARE=1 tests/dualboot/run.sh   # SD path only
#
# Needs pyserial (uart_tsi_dual.py).
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
HERE=$ROOT/tests/dualboot
B=$HERE/build
CONFIG=DualBootRocketConfig
SIM=$ROOT/sims/verilator/simulator-chipyard.harness-$CONFIG
mkdir -p "$B"

python3 -c 'import serial' 2>/dev/null || { echo "pyserial missing: pip install pyserial"; exit 2; }

echo "== SD payload and image"
riscv64-unknown-elf-gcc -march=rv64ima_zicsr -mabi=lp64 -nostdlib -nostartfiles -Wl,-Ttext=0x80000000 \
  -o "$B/sdpayload.elf" "$HERE/sdpayload.S"
riscv64-unknown-elf-objcopy -O binary "$B/sdpayload.elf" "$B/sdpayload.bin"
python3 "$HERE/mk_sdimage.py" "$B/sdpayload.bin" "$B/sdimage.hex"

echo "== bare-metal test program (hello)"
cmake -S "$ROOT/tests" -B "$B/cmake" >/dev/null
cmake --build "$B/cmake" --target hello -j8 >/dev/null

echo "== simulator ($CONFIG)"
make -C "$ROOT/sims/verilator" CONFIG=$CONFIG -j"$(nproc)" >"$B/sim-build.log" 2>&1 \
  || { echo "simulator build failed; see $B/sim-build.log"; exit 1; }

rc=0
if [ -z "${SKIP_BARE:-}" ]; then
  echo "== path A: bare-metal (UART-TSI load + MSIP)"
  python3 "$HERE/test_dualboot.py" bare "$SIM" "$B/sdimage.hex" "$B/cmake/hello.riscv" \
    --workdir "$B/run-bare" || rc=1
fi
if [ -z "${SKIP_SD:-}" ]; then
  echo "== path B: SD (--boot-linux, gate check)"
  python3 "$HERE/test_dualboot.py" sd "$SIM" "$B/sdimage.hex" --workdir "$B/run-sd" || rc=1
fi

if [ $rc -eq 0 ] && [ -z "${SKIP_BARE:-}${SKIP_SD:-}" ]; then
  echo "== both paths passed"
fi
exit $rc
