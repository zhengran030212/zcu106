#!/bin/sh
# Load BTC lottery bitstream into PL and run the miner.
# Run as: sudo ./load_and_mine.sh        (ubuntu / ubuntu on first login)
set -e
cd "$(dirname "$0")"

FWDIR=/lib/firmware
BITBIN=btc_lottery.bin
mkdir -p "$FWDIR"
cp "$BITBIN" "$FWDIR/"

if command -v fpgautil >/dev/null 2>&1; then
  echo "[*] loading via fpgautil"
  fpgautil -b "$FWDIR/$BITBIN"
else
  echo "[*] fpgautil not found, using fpga_manager sysfs"
  echo 0 > /sys/class/fpga_manager/fpga0/flags 2>/dev/null || true
  echo "$BITBIN" > /sys/class/fpga_manager/fpga0/firmware
fi
sleep 1
echo "[*] FPGA state: $(cat /sys/class/fpga_manager/fpga0/state 2>/dev/null || echo n/a)"

# Signature check via /dev/mem
python3 - <<'PY'
import mmap,os,struct
fd=os.open("/dev/mem",os.O_RDWR|os.O_SYNC)
m=mmap.mmap(fd,4096,offset=0xA0000000)
sig=struct.unpack_from("<I",m,0)[0]
print("[*] signature @0xA0000000 = 0x%08X"%sig)
assert sig==0x42544331, "signature mismatch — bitstream or AXI path wrong"
print("[+] BTC1 accelerator live, lanes=%d"%struct.unpack_from("<I",m,0x10)[0])
PY

echo "[*] starting miner..."
exec python3 -m btc_lottery --config miner.json --backend mmio
