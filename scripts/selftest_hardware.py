#!/usr/bin/env python3
"""Find the Bitcoin genesis golden nonce in PL, then measure completed hashes."""
import json
import struct
import sys
import time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/"host"))
from btc_lottery.backend import OpenOcdBackend
from btc_lottery.bitcoin import Work,DIFF1_TARGET

HEADER=bytes.fromhex("01000000"+"00"*32+"3ba3edfd7a7b12b27ac72c3e67768f617fc81bc3888a51323a9fb8aa4b1e5e4a"+"29ab5f49ffff001d1dac2b7c")

def main():
    hw=OpenOcdBackend()
    work=Work(0x73544654,"genesis-selftest","","495fab29",HEADER[:76],DIFF1_TARGET,DIFF1_TARGET)
    try:
        hw.load(work,start_nonce=2083236890)
        deadline=time.monotonic()+5
        found=False
        while time.monotonic()<deadline and not found:
            for tag,nonce in hw.results():
                if tag!=work.tag or not work.is_block(nonce):
                    raise RuntimeError("PL golden nonce selftest failed")
                if nonce==2083236893: found=True
            time.sleep(0.01)
        if not found: raise TimeoutError("PL did not return the genesis golden nonce")
        before=hw.stats()["hashes"];begin=time.monotonic()
        time.sleep(2)
        after=hw.stats()["hashes"];elapsed=time.monotonic()-begin
        rate=(after-before)/elapsed
        if rate<=0: raise RuntimeError("PL completed-hash counter is not advancing")
        report={"passed":True,"lanes":hw.lanes,"genesis_nonce":2083236893,
                "genesis_hash":work.digest(2083236893)[::-1].hex(),
                "completed_hashes":after-before,"elapsed_seconds":elapsed,"hashes_per_second":rate}
        path=ROOT/"build/hardware-selftest.json";path.write_text(json.dumps(report,indent=2)+"\n")
        print(json.dumps(report,indent=2))
    finally: hw.stop();hw.close()

if __name__=="__main__": main()
