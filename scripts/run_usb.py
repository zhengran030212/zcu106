#!/usr/bin/env python3
"""Program, verify and run the USB-JTAG lottery miner with one command."""
import argparse
import contextlib
import fcntl
import os
import shutil
import socket
import subprocess
import sys
import time
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/"host"))
from btc_lottery.backend import OpenOcdBackend

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("--artifacts",type=Path,default=ROOT/"build/zcu106_l1_r2_100")
    p.add_argument("--config",type=Path,default=ROOT/"config/miner.json")
    p.add_argument("--selftest-only",action="store_true")
    p.add_argument("--detach",action="store_true",help="leave miner and local OpenOCD running in background")
    args=p.parse_args()
    artifact=args.artifacts.resolve()
    for name in ("btc_lottery.bit","psu_init.tcl","timing.rpt"):
        if not (artifact/name).is_file(): p.error("missing artifact: "+str(artifact/name))
    ocd=shutil.which("openocd");loader=shutil.which("openFPGALoader")
    if not ocd or not loader: p.error("install openocd and openfpgaloader first")
    build=ROOT/"build";build.mkdir(exist_ok=True)
    lock=open(build/"usb-miner.lock","w")
    try: fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    except BlockingIOError: p.error("another USB miner launcher is running")
    try:
        with socket.create_connection(("127.0.0.1",6666),timeout=0.2):
            p.error("port 6666 is already in use; stop the existing OpenOCD first")
    except OSError: pass
    subprocess.run(["sudo","-v"],check=True)
    process=None
    log=None
    detached=False
    env={**os.environ,"PYTHONPATH":str(ROOT/"host")}
    def stop_ocd():
        nonlocal process,log
        if process is not None:
            if process.poll() is None:
                with contextlib.suppress(OSError):
                    with socket.create_connection(("127.0.0.1",6666),timeout=3) as s:
                        s.sendall(b"shutdown\x1a")
                try: process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    subprocess.run(["sudo","-n","kill","-TERM",str(process.pid)],check=False)
                    process.wait(timeout=5)
            process=None
        if log is not None: log.close();log=None
    def start_ocd():
        nonlocal process,log
        log=open(build/"openocd.log","a")
        process=subprocess.Popen(["sudo","-n","/usr/bin/nohup",ocd,"-f",str(ROOT/"config/zcu106-openocd.cfg")],stdout=log,stderr=subprocess.STDOUT,stdin=subprocess.DEVNULL)
        end=time.monotonic()+20
        while time.monotonic()<end:
            if process.poll() is not None: raise RuntimeError("OpenOCD exited; see build/openocd.log")
            try:
                hw=OpenOcdBackend(verify_signature=False);hw.close();return
            except OSError: time.sleep(0.1)
        raise TimeoutError("OpenOCD did not become ready")
    def helper(name,*extra):
        subprocess.run([sys.executable,str(ROOT/"scripts"/name),*map(str,extra)],cwd=ROOT,env=env,check=True)
    try:
        start_ocd()
        helper("ps_init_openocd.py",artifact/"psu_init.tcl","--phase","clocks")
        stop_ocd()
        subprocess.run(["sudo","-n",loader,"-b","zcu106","--freq","6000000",str(artifact/"btc_lottery.bit")],check=True)
        start_ocd()
        helper("ps_init_openocd.py",artifact/"psu_init.tcl","--phase","fabric")
        helper("selftest_hardware.py")
        if not args.selftest_only:
            command=[sys.executable,"-m","btc_lottery","--config",str(args.config),"--backend","openocd"]
            if args.detach:
                with open(build/"miner.log","a") as miner_log:
                    miner=subprocess.Popen(command,cwd=ROOT,env=env,stdout=miner_log,stderr=subprocess.STDOUT,stdin=subprocess.DEVNULL,start_new_session=True)
                (build/"miner.pid").write_text(str(miner.pid)+"\n")
                detached=True
                print("Miner running in background, PID",miner.pid,"log:",build/"miner.log")
            else:
                subprocess.run(command,cwd=ROOT,env=env,check=True)
    finally:
        if not detached:
            with contextlib.suppress(Exception):
                hw=OpenOcdBackend();hw.stop();hw.close()
            stop_ocd()
        elif log is not None: log.close()
        lock.close()

if __name__=="__main__":
    try: main()
    except KeyboardInterrupt: pass
