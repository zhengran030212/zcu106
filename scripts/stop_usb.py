#!/usr/bin/env python3
"""Stop the background controller and its localhost OpenOCD service."""
import contextlib
import os
import signal
import socket
import subprocess
import sys
import time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/"host"))
from btc_lottery.backend import OpenOcdBackend

def main():
    pidfile=ROOT/"build/miner.pid"
    if pidfile.exists():
        pid=int(pidfile.read_text().strip())
        result=subprocess.run(["ps","-p",str(pid),"-o","command="],capture_output=True,text=True)
        if result.returncode==0:
            command=result.stdout
            if "-m btc_lottery" not in command or str(ROOT/"config") not in command:
                raise RuntimeError("PID file does not match this project's miner; refusing to signal it")
            os.kill(pid,signal.SIGINT)
            for _ in range(50):
                try: os.kill(pid,0)
                except ProcessLookupError: break
                time.sleep(0.1)
        pidfile.unlink()
    with contextlib.suppress(OSError):
        hw=OpenOcdBackend();hw.stop();hw.close()
        with socket.create_connection(("127.0.0.1",6666),timeout=3) as s:
            s.sendall(b"shutdown\x1a")
    print("USB lottery miner stopped")

if __name__=="__main__": main()
