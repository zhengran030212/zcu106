#!/usr/bin/env python3
"""Genesis-nonce self-test for the PS MMIO backend.

Stop before any write if the ABI register is not the documented value.
On the 32-bit HPM0 bitstream, unaligned writes stalled the PS master.
"""
import json
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "host"))
from btc_lottery.backend import MmioBackend
from btc_lottery.bitcoin import DIFF1_TARGET, Work

HEADER = bytes.fromhex(
    "01000000"
    + "00" * 32
    + "3ba3edfd7a7b12b27ac72c3e67768f617fc81bc3888a51323a9fb8aa4b1e5e4a"
    + "29ab5f49ffff001d1dac2b7c"
)
GENESIS_NONCE = 2083236893


def main():
    hw = MmioBackend()
    try:
        if hw.read(4) != 0x00010000:
            raise RuntimeError("ABI register is not 0x00010000; refusing to write AXI")
        rounds = hw.read(0x14)
        if rounds not in (1, 2, 4):
            raise RuntimeError("rounds register is %s; refusing to write AXI" % rounds)
        work = Work(0x73544654, "genesis-selftest", "", "495fab29", HEADER[:76], DIFF1_TARGET, DIFF1_TARGET)
        hw.load(work, start_nonce=2083236890)
        found = None
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and found is None:
            for tag, nonce in hw.results():
                digest = work.digest(nonce)
                if tag != work.tag or int.from_bytes(digest, "little") > work.network_target:
                    raise RuntimeError("candidate failed hashlib check: nonce=%s" % nonce)
                if nonce == GENESIS_NONCE:
                    found = digest
            time.sleep(0.01)
        if found is None:
            raise TimeoutError("PL did not return the genesis nonce")
        before = hw.stats()["hashes"]
        begin = time.monotonic()
        time.sleep(2)
        after = hw.stats()["hashes"]
        elapsed = time.monotonic() - begin
        rate = (after - before) / elapsed
        if rate <= 0:
            raise RuntimeError("completed-hash counter is not advancing")
        report = {
            "passed": True,
            "lanes": hw.lanes,
            "rounds": rounds,
            "genesis_nonce": GENESIS_NONCE,
            "genesis_hash": found[::-1].hex(),
            "completed_hashes": after - before,
            "elapsed_seconds": elapsed,
            "hashes_per_second": rate,
        }
        path = ROOT / "build" / "hardware-selftest.json"
        path.parent.mkdir(exist_ok=True)
        path.write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(report, indent=2))
    finally:
        hw.stop()
        hw.close()


if __name__ == "__main__":
    main()
