#!/usr/bin/env python3
"""Build in the existing Vivado container without copying any SSH credentials."""
import argparse
import shlex
import subprocess
import tarfile
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("--host",default="azureuser@20.121.112.247")
    p.add_argument("--key",type=Path,default=Path.home()/"Desktop/azure_build.pem")
    p.add_argument("--remote-dir",default="/home/azureuser/btc-lottery")
    p.add_argument("--image",default="aperloff/vivado-docker:sl7_vivado2019.1_x11")
    p.add_argument("--lanes",type=int,default=1)
    p.add_argument("--rounds",type=int,choices=(1,2,4),default=2)
    p.add_argument("--mhz",type=int,default=100)
    p.add_argument("--fetch-only",action="store_true")
    args=p.parse_args()
    if not 1<=args.lanes<=4 or not 10<=args.mhz<=250: p.error("invalid lane count or clock")
    key=str(args.key.expanduser().resolve())
    opts=["-i",key,"-o","IdentitiesOnly=yes","-o","BatchMode=yes","-o","ServerAliveInterval=30","-o","ServerAliveCountMax=240"]
    def remote(command): subprocess.run(["ssh",*opts,args.host,command],check=True)
    label=f"zcu106_l{args.lanes}_r{args.rounds}_{args.mhz}"
    build=ROOT/"build";build.mkdir(exist_ok=True)
    remote_dir=shlex.quote(args.remote_dir)
    if not args.fetch_only:
        archive=build/"source.tar.gz"
        def safe(info):
            path=Path(info.name)
            if "__pycache__" in path.parts or path.suffix in (".pem",".key",".pyc") or path.name=="local.json": return None
            return info
        with tarfile.open(archive,"w:gz") as tar:
            for name in ("rtl","host","tests","sim","scripts","config","docs","README.md","Makefile",".gitignore"):
                path=ROOT/name
                if path.exists(): tar.add(path,arcname=name,filter=safe)
        remote("mkdir -p "+remote_dir)
        subprocess.run(["scp",*opts,str(archive),args.host+":"+args.remote_dir+"/source.tar.gz"],check=True)
        container_cmd=("source /opt/Xilinx/Vivado/2019.1/settings64.sh && "
            "vivado -mode batch -nojournal -log /work/build/vivado.log "
            f"-source /work/scripts/build_zcu106.tcl -tclargs {args.lanes} {args.rounds} {args.mhz}")
        docker=("docker run --rm --name btc-lottery-build --user \"$(id -u):$(id -g)\" "
            "--volume "+shlex.quote(args.remote_dir+":/work")+" --workdir /work --entrypoint /bin/bash "
            +shlex.quote(args.image)+" -lc "+shlex.quote(container_cmd))
        remote("cd "+remote_dir+" && tar xzf source.tar.gz && mkdir -p build && "+docker)
    target=build/label;target.mkdir(exist_ok=True)
    for name in ("btc_lottery.bit","btc_lottery.bin","btc_lottery.hwh","timing.rpt","utilization.rpt","drc.rpt"):
        subprocess.run(["scp",*opts,args.host+":"+args.remote_dir+"/build/"+label+"/"+name,str(target/name)],check=True)
    source=args.remote_dir+"/build/"+label+"/btc_lottery.srcs/sources_1/bd/system/ip/system_ps_0/psu_init.tcl"
    subprocess.run(["scp",*opts,args.host+":"+source,str(target/"psu_init.tcl")],check=True)
    print("Artifacts:",target)

if __name__=="__main__": main()
