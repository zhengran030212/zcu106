import hashlib
import json
import random
import struct
import unittest
from pathlib import Path
from btc_lottery.bitcoin import (IV,MAX_TARGET,DIFF1_TARGET,compress,sha256d,
    compact_target,difficulty_target,make_work,reverse_words,validate_address)

GENESIS=bytes.fromhex(
    "01000000"+"00"*32+
    "3ba3edfd7a7b12b27ac72c3e67768f617fc81bc3888a51323a9fb8aa4b1e5e4a"+
    "29ab5f49ffff001d1dac2b7c")

class BitcoinTests(unittest.TestCase):
    def test_compression_matches_hashlib(self):
        rng=random.Random(42)
        for size in (0,1,3,55,56,63,64,76,80,100,128,512):
            msg=bytes(rng.randrange(256) for _ in range(size))
            padded=msg+b"\x80"+b"\0"*((55-len(msg))%64)+struct.pack(">Q",len(msg)*8)
            state=IV
            for i in range(0,len(padded),64): state=compress(padded[i:i+64],state)
            self.assertEqual(struct.pack(">8I",*state),hashlib.sha256(msg).digest())

    def test_genesis(self):
        self.assertEqual(sha256d(GENESIS)[::-1].hex(),"000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f")
        self.assertLessEqual(int.from_bytes(sha256d(GENESIS),"little"),compact_target(0x1D00FFFF))

    def test_target(self):
        self.assertEqual(compact_target(0x1D00FFFF),DIFF1_TARGET)
        self.assertEqual(difficulty_target(1),DIFF1_TARGET)
        self.assertEqual(difficulty_target("0.5"),DIFF1_TARGET*2)
        self.assertEqual(difficulty_target(3),DIFF1_TARGET//3)
        self.assertEqual(difficulty_target("1e-50"),MAX_TARGET)
        for bad in (0,-1,"NaN","Infinity"):
            with self.assertRaises(ValueError): difficulty_target(bad)
        for bad in (0,0x1D80FFFF,0x2300FFFF):
            with self.assertRaises(ValueError): compact_target(bad)

    def test_stratum_endianness_and_merkle(self):
        # Independent explicit byte sequence: previous-hash words must each be reversed.
        prev=bytes(range(32))
        branch=bytes(range(32,64))
        p=["job",prev.hex(),"010203","aabb",[branch.hex()],"20000001","1d00ffff","65010203",True]
        work=make_work(p,"0a0b",4,7,"2.5",9)
        merkle=sha256d(sha256d(bytes.fromhex("0102030a0b00000007aabb"))+branch)
        expected=(bytes.fromhex("01000020")+bytes.fromhex("03020100070605040b0a09080f0e0d0c13121110171615141b1a19181f1e1d1c")
                  +merkle+bytes.fromhex("03020165ffff001d"))
        self.assertEqual(work.header76,expected)
        self.assertEqual(work.extranonce2,"00000007")
        self.assertEqual(work.midstate,compress(expected[:64]))
        self.assertEqual(work.digest(0x12345678),sha256d(expected+bytes.fromhex("78563412")))

    def test_address(self):
        cfg=json.loads((Path(__file__).parents[1]/"config/miner.json").read_text())
        address=cfg["address"]
        self.assertEqual(validate_address(address),address)
        self.assertEqual(validate_address("1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"),"1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa")
        for bad in (address[:-1]+"q",address[:4].upper()+address[4:],"", "bc1invalid"):
            with self.assertRaises(ValueError): validate_address(bad)

if __name__=="__main__": unittest.main()
