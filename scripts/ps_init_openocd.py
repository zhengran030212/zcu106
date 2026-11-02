#!/usr/bin/env python3
"""Apply the generated ZCU106 clock/fabric initialization through AXI MEM-AP.

This USB-JTAG mode needs no DDR, SD-card image, FSBL, or running ARM program.
Use it on an otherwise idle board. Values come from this build's psu_init.tcl.
"""
import argparse
import re
import sys
import time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/"host"))
from btc_lottery.backend import OpenOcdBackend

def operations(text,name):
    match=re.search(r"^set "+re.escape(name)+r" \{\n(.*?)^\}",text,re.M|re.S)
    if not match: raise ValueError("missing generated initialization section: "+name)
    result=[]
    for line in match[1].splitlines():
        line=line.strip()
        if not line or line.startswith("#"): continue
        fields=line.rstrip(";").split()
        if fields[0] not in ("mask_write","mask_poll","mask_delay"):
            raise ValueError("unsupported generated operation: "+line)
        result.append((fields[0],*[int(x,0) for x in fields[1:]]))
    return result

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("psu_init",type=Path)
    p.add_argument("--phase",choices=("clocks","fabric"),required=True)
    args=p.parse_args()
    text=args.psu_init.read_text()
    if args.phase=="clocks":
        groups=[(n,operations(text,n)) for n in ("psu_peripherals_pre_init_data","psu_pll_init_data","psu_clock_init_data")]
        # Release the generated FPD, GPIO and AFI reset bits. Leave unrelated
        # UART, USB, PCIe, SERDES, DDR and MIO setup to their own boot software.
        reset_ops=[op for op in operations(text,"psu_peripherals_init_data")
                   if op[0]=="mask_write" and op[1] in (0xFD1A0100,0xFF5E023C)]
        groups.append(("generated fabric reset release",reset_ops))
    else:
        groups=[(n,operations(text,n)) for n in ("psu_ps_pl_isolation_removal_data","psu_afi_config","psu_ps_pl_reset_config_data")]
    hw=OpenOcdBackend(verify_signature=False)
    try:
        def read(addr): return int(hw.rpc("read_memory 0x%x 32 1"%addr),0)
        for name,ops in groups:
            print(name,flush=True)
            for op in ops:
                mode,addr,*values=op
                if mode=="mask_write":
                    mask,value=values
                    value=((read(addr)&~mask)|(value&mask))&0xFFFFFFFF
                    hw.rpc("write_memory 0x%x 32 {0x%x}"%(addr,value))
                elif mode=="mask_poll":
                    mask=values[0]; expected=values[1] if len(values)>1 else None
                    end=time.monotonic()+3
                    while True:
                        result=read(addr)&mask
                        if (result==expected) if expected is not None else (result!=0): break
                        if time.monotonic()>end: raise TimeoutError("generated mask_poll timed out at 0x%x"%addr)
                        time.sleep(0.001)
                else: time.sleep(values[0]/1000)
        print("PS %s initialization passed"%args.phase)
    finally: hw.close()

if __name__=="__main__": main()
