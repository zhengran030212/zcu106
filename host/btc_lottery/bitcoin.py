import hashlib
import struct
from dataclasses import dataclass
from decimal import Decimal

IV = (0x6A09E667,0xBB67AE85,0x3C6EF372,0xA54FF53A,0x510E527F,0x9B05688C,0x1F83D9AB,0x5BE0CD19)
K = tuple(int(x,16) for x in """
428a2f98 71374491 b5c0fbcf e9b5dba5 3956c25b 59f111f1 923f82a4 ab1c5ed5
d807aa98 12835b01 243185be 550c7dc3 72be5d74 80deb1fe 9bdc06a7 c19bf174
e49b69c1 efbe4786 0fc19dc6 240ca1cc 2de92c6f 4a7484aa 5cb0a9dc 76f988da
983e5152 a831c66d b00327c8 bf597fc7 c6e00bf3 d5a79147 06ca6351 14292967
27b70a85 2e1b2138 4d2c6dfc 53380d13 650a7354 766a0abb 81c2c92e 92722c85
a2bfe8a1 a81a664b c24b8b70 c76c51a3 d192e819 d6990624 f40e3585 106aa070
19a4c116 1e376c08 2748774c 34b0bcb5 391c0cb3 4ed8aa4a 5b9cca4f 682e6ff3
748f82ee 78a5636f 84c87814 8cc70208 90befffa a4506ceb bef9a3f7 c67178f2
""".split())
MAX_TARGET = (1 << 256)-1
DIFF1_TARGET = 0xFFFF << (8*(0x1D-3))


def sha256d(data):
    return hashlib.sha256(hashlib.sha256(data).digest()).digest()


def compress(block, state=IV):
    if len(block) != 64:
        raise ValueError("SHA compression requires 64 bytes")
    mask = 0xFFFFFFFF
    def ror(x,n): return ((x>>n)|(x<<(32-n))) & mask
    w=list(struct.unpack(">16I",block))
    for i in range(16,64):
        s0=ror(w[i-15],7)^ror(w[i-15],18)^(w[i-15]>>3)
        s1=ror(w[i-2],17)^ror(w[i-2],19)^(w[i-2]>>10)
        w.append((w[i-16]+s0+w[i-7]+s1)&mask)
    a,b,c,d,e,f,g,h=state
    for i in range(64):
        t1=(h+(ror(e,6)^ror(e,11)^ror(e,25))+((e&f)^((~e)&g))+K[i]+w[i])&mask
        t2=((ror(a,2)^ror(a,13)^ror(a,22))+((a&b)^(a&c)^(b&c)))&mask
        a,b,c,d,e,f,g,h=(t1+t2)&mask,a,b,c,(d+t1)&mask,e,f,g
    return tuple((x+y)&mask for x,y in zip(state,(a,b,c,d,e,f,g,h)))


def compact_target(bits):
    exp, mant=bits>>24,bits&0x7FFFFF
    value=(mant>>(8*(3-exp))) if exp<=3 else (mant<<(8*(exp-3)))
    if bits&0x800000 or not 0<value<=MAX_TARGET:
        raise ValueError("invalid nBits target")
    return value


def difficulty_target(difficulty):
    d=Decimal(str(difficulty))
    if not d.is_finite() or d<=0:
        raise ValueError("difficulty must be positive and finite")
    # Integer rational arithmetic avoids Decimal context rounding at 256 bits.
    num,den=d.as_integer_ratio()
    return min(MAX_TARGET, DIFF1_TARGET*den//num)


def reverse_words(data):
    if len(data)%4: raise ValueError("word-aligned input required")
    return b"".join(data[i:i+4][::-1] for i in range(0,len(data),4))


@dataclass(frozen=True)
class Work:
    tag: int
    job_id: str
    extranonce2: str
    ntime: str
    header76: bytes
    share_target: int
    network_target: int

    @property
    def midstate(self): return compress(self.header76[:64])

    @property
    def tail(self): return struct.unpack(">3I",self.header76[64:76])

    @property
    def hardware_target(self): return max(self.share_target,self.network_target)

    def digest(self,nonce): return sha256d(self.header76+struct.pack("<I",nonce))

    def meets_share(self,nonce): return int.from_bytes(self.digest(nonce),"little")<=self.share_target

    def is_block(self,nonce): return int.from_bytes(self.digest(nonce),"little")<=self.network_target


def make_work(params, extranonce1, extranonce2_size, counter, difficulty, tag):
    if len(params)!=9: raise ValueError("mining.notify must contain 9 fields")
    job_id,prevhash,coinb1,coinb2,branches,version,nbits,ntime,_clean=params
    if not 1<=extranonce2_size<=16: raise ValueError("unsupported extranonce2 size")
    extra2=counter.to_bytes(extranonce2_size,"big").hex()
    merkle=sha256d(bytes.fromhex(coinb1+extranonce1+extra2+coinb2))
    for branch in branches:
        other=bytes.fromhex(branch)
        if len(other)!=32: raise ValueError("invalid merkle branch")
        merkle=sha256d(merkle+other)
    prev=bytes.fromhex(prevhash)
    if len(prev)!=32 or any(len(x)!=8 for x in (version,nbits,ntime)):
        raise ValueError("invalid block-header fields")
    # Stratum V1 prevhash is word-swapped; merkle is the raw SHA256d digest.
    header=(struct.pack("<I",int(version,16))+reverse_words(prev)+merkle
            +struct.pack("<II",int(ntime,16),int(nbits,16)))
    return Work(tag,str(job_id),extra2,ntime,header,difficulty_target(difficulty),compact_target(int(nbits,16)))


def validate_address(address):
    """Mainnet Base58Check or BIP173/BIP350 native SegWit address."""
    if address.lower().startswith("bc1"):
        if address!=address.lower() and address!=address.upper():
            raise ValueError("mixed-case bech32 address")
        address=address.lower()
        alphabet="qpzry9x8gf2tvdw0s3jn54khce6mua7l"
        try: values=[alphabet.index(c) for c in address[3:]]
        except ValueError: raise ValueError("invalid bech32 character") from None
        if not 11<=len(address)<=90 or len(values)<7: raise ValueError("invalid address length")
        hrp="bc"
        chk=1
        for v in [ord(c)>>5 for c in hrp]+[0]+[ord(c)&31 for c in hrp]+values:
            top=chk>>25
            chk=((chk&0x1FFFFFF)<<5)^v
            for i,g in enumerate((0x3b6a57b2,0x26508e6d,0x1ea119fa,0x3d4233dd,0x2a1462b3)):
                if (top>>i)&1: chk^=g
        version=values[0]
        if version>16 or chk!=(1 if version==0 else 0x2BC830A3):
            raise ValueError("invalid bech32/bech32m checksum")
        acc=bits=0
        program=bytearray()
        for v in values[1:-6]:
            acc=(acc<<5)|v; bits+=5
            if bits>=8:
                bits-=8; program.append((acc>>bits)&255)
        if bits>=5 or ((acc<<(8-bits))&255): raise ValueError("invalid witness padding")
        if not 2<=len(program)<=40 or (version==0 and len(program) not in (20,32)):
            raise ValueError("invalid witness program")
    else:
        alphabet="123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
        value=0
        for c in address:
            if c not in alphabet: raise ValueError("invalid Base58 character")
            value=value*58+alphabet.index(c)
        raw=b"\0"*(len(address)-len(address.lstrip("1")))+value.to_bytes((value.bit_length()+7)//8,"big")
        if len(raw)!=25 or raw[0] not in (0,5) or sha256d(raw[:-4])[:4]!=raw[-4:]:
            raise ValueError("invalid mainnet Base58Check address")
    return address
