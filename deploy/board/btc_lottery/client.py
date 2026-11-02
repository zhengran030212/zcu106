import argparse
import asyncio
import contextlib
import json
import logging
import secrets
import time
from collections import OrderedDict
from pathlib import Path
from urllib.parse import urlparse

from . import __version__
from .backend import CpuBackend, MmioBackend, OpenOcdBackend
from .bitcoin import DIFF1_TARGET, make_work, validate_address

LOG=logging.getLogger("btc-lottery")


class StratumClient:
    def __init__(self,config,backend=None,probe=False):
        self.config=config
        self.backend=backend
        self.probe=probe
        self.username=validate_address(config["address"])+"."+config.get("worker","zcu106")
        self.endpoint=urlparse(config["pool"])
        if self.endpoint.scheme not in ("stratum+tcp","stratum+ssl") or not self.endpoint.hostname or not self.endpoint.port:
            raise ValueError("pool must be stratum+tcp://host:port or stratum+ssl://host:port")
        self.counter_id=0
        self.work_tag=0
        self.best=0.0
        self.accepted=self.rejected=0
        self.probe_done=asyncio.Event()

    def reset_session(self):
        self.pending={}
        self.authorized=False
        self.extra1=None
        self.extra2_size=None
        self.extra2_counter=None
        self.next_difficulty=1
        self.job=None
        self.job_difficulty=1
        self.work=None
        self.works=OrderedDict()
        self.job_time=time.monotonic()

    async def send(self,method,params):
        if len(self.pending)>=128: raise ConnectionError("too many unanswered Stratum requests")
        self.counter_id+=1
        request_id=self.counter_id
        self.pending[request_id]=method
        self.writer.write((json.dumps({"id":request_id,"method":method,"params":params})+"\n").encode())
        await self.writer.drain()
        return request_id

    def dispatch(self):
        if not (self.authorized and self.extra1 is not None and self.job is not None): return
        if self.probe:
            # Building the work checks field encodings even in a no-hashing probe.
            make_work(self.job,self.extra1,self.extra2_size,self.extra2_counter,self.job_difficulty,1)
            LOG.info("probe passed: authorized, valid mining.notify, share_difficulty=%s",self.job_difficulty)
            self.probe_done.set()
            return
        if self.extra2_counter is None or self.extra2_counter>=1<<(8*self.extra2_size):
            raise ConnectionError("extranonce2 exhausted; reconnecting for a fresh subscription")
        self.work_tag=(self.work_tag+1)&0xFFFFFFFF
        if not self.work_tag: raise RuntimeError("work tag exhausted; restart controller")
        work=make_work(self.job,self.extra1,self.extra2_size,self.extra2_counter,self.job_difficulty,self.work_tag)
        self.extra2_counter+=1
        self.backend.load(work)
        self.work=work
        self.works[work.tag]=work
        while len(self.works)>512: self.works.popitem(last=False)
        LOG.info("job=%s tag=%d share_difficulty=%s",work.job_id,work.tag,self.job_difficulty)

    async def message(self,msg):
        if not isinstance(msg,dict): raise ValueError("Stratum message must be an object")
        method=msg.get("method")
        params=msg.get("params",[])
        if method=="mining.set_difficulty":
            # The change applies to the NEXT notify, not existing work.
            from .bitcoin import difficulty_target
            difficulty_target(params[0])
            self.next_difficulty=params[0]
        elif method=="mining.set_extranonce":
            extra1,size=params
            bytes.fromhex(extra1)
            if not isinstance(size,int) or not 1<=size<=16: raise ValueError("invalid extranonce size")
            if self.backend: self.backend.stop()
            self.extra1,self.extra2_size=extra1,size
            self.extra2_counter=secrets.randbits(size*8)
            self.job=None; self.work=None; self.works.clear()
        elif method=="mining.notify":
            if len(params)!=9: raise ValueError("invalid mining.notify")
            if params[8]:
                if self.backend: self.backend.stop()
                self.works.clear(); self.work=None
            elif self.backend:
                # Preserve already-found old-job shares before a normal switch.
                await self.drain_results()
            self.job,self.job_difficulty=params,self.next_difficulty
            self.job_time=time.monotonic()
            self.dispatch()
        elif method=="client.get_version":
            self.writer.write((json.dumps({"id":msg.get("id"),"result":"zcu106-lottery/"+__version__,"error":None})+"\n").encode())
            await self.writer.drain()
        elif method=="client.reconnect":
            raise ConnectionError("pool requested reconnect; using the configured endpoint")
        elif method=="client.show_message":
            LOG.info("pool message: %s",params)
        elif method:
            LOG.debug("ignored extension: %s",method)
        else:
            requested=self.pending.pop(msg.get("id"),None)
            if requested=="mining.subscribe":
                if msg.get("error"): raise ConnectionError("subscription rejected: %r"%msg["error"])
                subscriptions,extra1,size=msg["result"]
                bytes.fromhex(extra1)
                if not isinstance(size,int) or not 1<=size<=16: raise ValueError("invalid extranonce2 size")
                self.extra1,self.extra2_size=extra1,size
                self.extra2_counter=secrets.randbits(size*8)
                self.dispatch()
            elif requested=="mining.authorize":
                if msg.get("error") or msg.get("result") is not True:
                    raise ConnectionError("worker authorization rejected: %r"%msg.get("error"))
                self.authorized=True
                LOG.info("solo worker authorized: %s",self.username)
                await self.send("mining.suggest_difficulty",[self.config.get("suggest_difficulty",1)])
                self.dispatch()
            elif requested=="mining.submit":
                if msg.get("result") is True and not msg.get("error"):
                    self.accepted+=1; LOG.info("share accepted (%d)",self.accepted)
                else:
                    self.rejected+=1; LOG.warning("share rejected: %s",msg.get("error"))

    async def drain_results(self):
        for tag,nonce in self.backend.results():
            work=self.works.get(tag)
            if not work: continue
            digest=work.digest(nonce)
            value=int.from_bytes(digest,"little")
            if value>work.hardware_target:
                raise RuntimeError("FPGA result failed independent CPU SHA256d verification")
            self.best=max(self.best,DIFF1_TARGET/max(value,1))
            if value<=work.network_target:
                LOG.warning("BLOCK CANDIDATE job=%s nonce=%08x hash=%s",work.job_id,nonce,digest[::-1].hex())
            await self.send("mining.submit",[self.username,work.job_id,work.extranonce2,work.ntime,"%08x"%nonce])

    async def read_loop(self):
        while True:
            line=await asyncio.wait_for(self.reader.readline(),timeout=90)
            if not line: raise ConnectionError("pool closed connection")
            if len(line)>262144: raise ValueError("oversize Stratum message")
            await self.message(json.loads(line))

    async def work_loop(self):
        interval=float(self.config.get("poll_seconds",0.01))
        if not 0.001<=interval<=1: raise ValueError("poll_seconds must be between 0.001 and 1")
        last=time.monotonic()
        old=self.backend.stats()["hashes"]
        while True:
            await asyncio.sleep(interval)
            if time.monotonic()-self.job_time>90:
                raise ConnectionError("no fresh mining.notify for 90 seconds")
            if not self.authorized: continue
            await self.drain_results()
            stats=self.backend.stats()
            if stats["exhausted"] and self.work:
                await self.drain_results()
                self.dispatch()
            now=time.monotonic()
            if now-last>=float(self.config.get("stats_seconds",10)):
                rate=((stats["hashes"]-old)&((1<<64)-1))/(now-last)
                LOG.info("%s %.3f MH/s best=%.6g accepted=%d rejected=%d",self.config.get("backend","mmio"),rate/1e6,self.best,self.accepted,self.rejected)
                last,old=now,stats["hashes"]

    async def session(self):
        self.reset_session()
        if self.backend: self.backend.stop()
        self.reader,self.writer=await asyncio.wait_for(asyncio.open_connection(
            self.endpoint.hostname,self.endpoint.port,
            ssl=True if self.endpoint.scheme=="stratum+ssl" else None,limit=262145),timeout=15)
        tasks=[]
        try:
            await self.send("mining.subscribe",["zcu106-lottery/"+__version__])
            await self.send("mining.authorize",[self.username,self.config.get("password","x")])
            tasks=[asyncio.create_task(self.read_loop())]
            if self.probe:
                tasks.append(asyncio.create_task(asyncio.wait_for(self.probe_done.wait(),timeout=30)))
            else: tasks.append(asyncio.create_task(self.work_loop()))
            done,_=await asyncio.wait(tasks,return_when=asyncio.FIRST_COMPLETED)
            for t in done: t.result()
        finally:
            if self.backend: self.backend.stop()
            for t in tasks: t.cancel()
            await asyncio.gather(*tasks,return_exceptions=True)
            self.writer.close()
            with contextlib.suppress(Exception): await self.writer.wait_closed()

    async def run(self):
        delay=1
        while True:
            started=time.monotonic()
            try:
                await self.session()
                if self.probe: return
            except (OSError,ConnectionError,TimeoutError,ValueError,KeyError,IndexError) as exc:
                if self.probe: raise
                LOG.warning("connection interrupted: %s; retry in %ds",exc,delay)
            if time.monotonic()-started>60: delay=1
            await asyncio.sleep(delay)
            delay=min(30,delay*2)


def main():
    parser=argparse.ArgumentParser(description="ZCU106 BTC solo lottery miner")
    parser.add_argument("--config",type=Path,default=Path("config/miner.json"))
    parser.add_argument("--probe",action="store_true",help="subscribe, authorize and validate a job; do not hash")
    parser.add_argument("--backend",choices=("mmio","openocd","cpu"))
    args=parser.parse_args()
    logging.basicConfig(level=logging.INFO,format="%(asctime)s %(levelname)s %(message)s")
    config=json.loads(args.config.read_text())
    if args.backend: config["backend"]=args.backend
    validate_address(config["address"])
    backend=None
    try:
        if not args.probe:
            if config.get("backend","mmio")=="cpu":
                LOG.warning("CPU diagnostic mode: FPGA is NOT being used")
                backend=CpuBackend()
            elif config.get("backend")=="openocd":
                backend=OpenOcdBackend(int(str(config.get("axi_base","0xa0000000")),0),
                    config.get("openocd_host","127.0.0.1"),int(config.get("openocd_port",6666)))
            else: backend=MmioBackend(int(str(config.get("axi_base","0xa0000000")),0))
        asyncio.run(StratumClient(config,backend,probe=args.probe).run())
    except KeyboardInterrupt: pass
    finally:
        if backend:
            backend.stop(); backend.close()

if __name__=="__main__": main()
