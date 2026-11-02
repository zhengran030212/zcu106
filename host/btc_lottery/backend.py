import mmap
import os
import struct
import socket

class MmioBackend:
    """Run on the ZCU106 PS Linux after loading the matching PL bitstream."""
    def __init__(self,base=0xA0000000,device="/dev/mem"):
        self.fd=os.open(device,os.O_RDWR|os.O_SYNC)
        try: self.mem=mmap.mmap(self.fd,4096,offset=base)
        except BaseException:
            os.close(self.fd); raise
        self.check_signature()

    def check_signature(self):
        if self.read(0)!=0x42544331:
            self.close(); raise RuntimeError("BTC1 accelerator signature missing; check bitstream and AXI base")
        if self.read(4)!=0x00010000:
            self.close(); raise RuntimeError("unsupported accelerator register ABI")
        self.lanes=self.read(0x10)
        if not 1<=self.lanes<=32:
            self.close(); raise RuntimeError("invalid accelerator lane count")
        self.stop()

    def read(self,off): return struct.unpack_from("<I",self.mem,off)[0]
    def write(self,off,value): struct.pack_into("<I",self.mem,off,value)

    def stop(self): self.write(8,2)

    def load(self,work,start_nonce=0):
        self.stop()
        for i,v in enumerate(work.midstate): self.write(0x40+4*i,v)
        for i,v in enumerate(work.tail): self.write(0x60+4*i,v)
        for i in range(8): self.write(0x80+4*i,(work.hardware_target>>(i*32))&0xFFFFFFFF)
        self.write(0x18,work.tag); self.write(0x1C,start_nonce); self.write(8,1)

    def results(self):
        out=[]
        for lane in range(self.lanes):
            self.write(0x28,lane)
            # A bounded drain keeps the network reader responsive at tiny test difficulties.
            for _ in range(8):
                if self.read(0x2C)==0: break
                nonce,tag=self.read(0x30),self.read(0x34)
                self.write(0x38,1)
                out.append((tag,nonce))
        return out

    def stats(self):
        low=self.read(0x20); high=self.read(0x24)
        return {"hashes":(high<<32)|low,"exhausted":bool(self.read(0xC)&2)}

    def close(self):
        self.mem.close(); os.close(self.fd)


class OpenOcdBackend(MmioBackend):
    """Use the ZynqMP AXI MEM-AP over local USB JTAG; no PS OS is required."""
    def __init__(self,base=0xA0000000,host="127.0.0.1",port=6666,verify_signature=True):
        self.base=base
        self.sock=socket.create_connection((host,port),timeout=10)
        self.rpc("targets uscale.axi")
        if verify_signature: self.check_signature()

    def rpc(self,command):
        # Tcl snippets contain only our commands and integer register values.
        wrapped="if {[catch {"+command+"} btc_rpc_result]} {format {ERROR:%s} $btc_rpc_result} else {set btc_rpc_result}"
        self.sock.sendall(wrapped.encode()+b"\x1a")
        data=bytearray()
        while not data.endswith(b"\x1a"):
            chunk=self.sock.recv(4096)
            if not chunk: raise ConnectionError("OpenOCD disconnected")
            data.extend(chunk)
            if len(data)>1048576: raise RuntimeError("oversize OpenOCD response")
        result=data[:-1].decode().strip()
        if result.startswith("ERROR:"): raise OSError(result)
        return result

    def read(self,off): return int(self.rpc("read_memory 0x%x 32 1"%(self.base+off)),0)
    def write(self,off,value): self.rpc("write_memory 0x%x 32 {0x%x}"%(self.base+off,value))
    def write_words(self,off,values):
        self.rpc("write_memory 0x%x 32 {%s}"%(self.base+off," ".join("0x%x"%v for v in values)))

    def load(self,work,start_nonce=0):
        self.stop()
        self.write_words(0x40,work.midstate)
        self.write_words(0x60,work.tail)
        self.write_words(0x80,[(work.hardware_target>>(32*i))&0xFFFFFFFF for i in range(8)])
        self.write_words(0x18,[work.tag,start_nonce]); self.write(8,1)

    def stats(self):
        low,high=(int(x,0) for x in self.rpc("read_memory 0x%x 32 2"%(self.base+0x20)).split())
        return {"hashes":(high<<32)|low,"exhausted":bool(self.read(0xC)&2)}

    def close(self): self.sock.close()


class CpuBackend:
    """Explicit diagnostic backend only; never presented as FPGA hashrate."""
    lanes=0
    def __init__(self,batch=256):
        self.work=None; self.nonce=0; self.hashes=0; self.batch=batch
    def stop(self): self.work=None
    def load(self,work,start_nonce=0): self.work=work; self.nonce=start_nonce
    def results(self):
        out=[]
        if self.work:
            end=min(1<<32,self.nonce+self.batch)
            for n in range(self.nonce,end):
                if int.from_bytes(self.work.digest(n),"little")<=self.work.hardware_target:
                    out.append((self.work.tag,n))
            self.hashes+=end-self.nonce; self.nonce=end
        return out
    def stats(self): return {"hashes":self.hashes,"exhausted":self.nonce==(1<<32)}
    def close(self): pass
