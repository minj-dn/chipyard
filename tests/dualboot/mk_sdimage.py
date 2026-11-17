#!/usr/bin/env python3
"""mk_sdimage.py - turn a flat payload into a SimSDCard image ($readmemh).

The image places the payload at the sector sdboot reads from
(BBL_PARTITION_START_SECTOR, 34 by default), one byte per line:

  python3 mk_sdimage.py sdpayload.bin sdimage.hex [--sector 34]
"""

import argparse

SECTOR_BYTES = 512


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("payload", help="flat binary (objcopy -O binary)")
    ap.add_argument("image", help="output hex file for SimSDCard +sdcard=")
    ap.add_argument("--sector", type=int, default=34,
                    help="start sector of the payload (sdboot BBL_PARTITION_START_SECTOR, default 34)")
    a = ap.parse_args()

    with open(a.payload, "rb") as f:
        data = f.read()
    with open(a.image, "w") as f:
        f.write(f"@{a.sector * SECTOR_BYTES:x}\n")
        for b in data:
            f.write(f"{b:02x}\n")
    print(f"{a.image}: {len(data)} B at sector {a.sector} (byte 0x{a.sector * SECTOR_BYTES:x})")


if __name__ == "__main__":
    main()
