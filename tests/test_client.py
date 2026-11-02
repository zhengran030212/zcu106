import asyncio
import json
import unittest
from pathlib import Path
from btc_lottery.bitcoin import difficulty_target
from btc_lottery.client import StratumClient

class FakeWriter:
    def __init__(self): self.messages=[]
    def write(self,data): self.messages.append(json.loads(data))
    async def drain(self): pass

class FakeBackend:
    def __init__(self): self.loads=[]; self.stops=0; self.queue=[]
    def load(self,w): self.loads.append(w)
    def stop(self): self.stops+=1; self.queue=[]
    def results(self):
        out=self.queue; self.queue=[]; return out

class ClientTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        config=json.loads((Path(__file__).parents[1]/"config/miner.json").read_text())
        self.hw=FakeBackend(); self.c=StratumClient(config,self.hw)
        self.c.reset_session(); self.c.writer=FakeWriter()
        self.notify=["j",bytes(range(32)).hex(),"01","02",[],"20000000","1d00ffff","65000000",True]

    async def ready(self,difficulty=1):
        self.c.pending[1]="mining.subscribe"
        await self.c.message({"id":1,"result":[[],"aabb",4],"error":None})
        await self.c.message({"method":"mining.set_difficulty","params":[difficulty]})
        await self.c.message({"method":"mining.notify","params":self.notify})
        self.assertFalse(self.hw.loads)  # No hashing before authorization.
        self.c.pending[2]="mining.authorize"
        await self.c.message({"id":2,"result":True,"error":None})

    async def test_next_job_difficulty_and_clean_jobs(self):
        await self.ready(2)
        old=self.hw.loads[-1]
        self.assertEqual(old.share_target,difficulty_target(2))
        await self.c.message({"method":"mining.set_difficulty","params":[4]})
        self.assertEqual(self.c.work.share_target,difficulty_target(2))
        new=list(self.notify); new[0]="j2";new[8]=False
        await self.c.message({"method":"mining.notify","params":new})
        self.assertEqual(self.c.work.share_target,difficulty_target(4))
        self.assertIn(old.tag,self.c.works)
        new[0]="j3";new[8]=True
        await self.c.message({"method":"mining.notify","params":new})
        self.assertNotIn(old.tag,self.c.works)
        self.assertEqual(len(self.c.works),1)

    async def test_submit_is_independently_verified(self):
        await self.ready("1e-30")
        work=self.c.work
        self.hw.queue=[(work.tag,0x12345678)]
        await self.c.drain_results()
        submit=self.c.writer.messages[-1]
        self.assertEqual(submit["method"],"mining.submit")
        self.assertEqual(submit["params"][1:],["j",work.extranonce2,"65000000","12345678"])
        await self.c.message({"id":submit["id"],"result":True,"error":None})
        self.assertEqual(self.c.accepted,1)

    async def test_reject_false_hardware_result(self):
        await self.ready(1e20)
        self.hw.queue=[(self.c.work.tag,0)]
        with self.assertRaises(RuntimeError): await self.c.drain_results()

    async def test_extranonce_change_stops_and_waits_for_notify(self):
        await self.ready()
        await self.c.message({"method":"mining.set_extranonce","params":["ccdd",8]})
        self.assertIsNone(self.c.work)
        self.assertFalse(self.c.works)
        self.assertIsNone(self.c.job)
        await self.c.message({"method":"mining.notify","params":self.notify})
        self.assertEqual(len(self.c.work.extranonce2),16)

    async def test_rejected_authorization(self):
        self.c.pending[2]="mining.authorize"
        with self.assertRaises(ConnectionError):
            await self.c.message({"id":2,"result":False,"error":[24,"bad user",None]})
        self.assertFalse(self.hw.loads)

if __name__=="__main__": unittest.main()
