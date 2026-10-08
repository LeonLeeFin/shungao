#!/usr/bin/env python3
"""Normalize invalid thread-local zero-fill section file offsets in copied arm64 Mach-O.
The zero-fill section has no bytes in the file. Only its offset metadata changes.
Does not modify instruction bytes, system loaders, public packages or security settings.
"""
import argparse,hashlib,json,struct,subprocess
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('root',type=Path);p.add_argument('--report',type=Path,required=True);a=p.parse_args();root=a.root.resolve();changes=[]
for path in root.rglob('*'):
 if not path.is_file() or path.is_symlink():continue
 with path.open('rb') as f:head=f.read(32)
 if len(head)<32 or head[:4]!=b'\xcf\xfa\xed\xfe':continue
 # Thin 64-bit little-endian files; preserve all non-target binaries unchanged.
 ncmds,sizeofcmds=struct.unpack_from('<II',head,16);data=bytearray(path.read_bytes());pos=32;patched=[]
 assert 32+sizeofcmds<=len(data),path
 for _ in range(ncmds):
  cmd,cmdsize=struct.unpack_from('<II',data,pos);assert cmdsize>=8 and pos+cmdsize<=32+sizeofcmds,path
  if cmd==0x19:
   nsects=struct.unpack_from('<I',data,pos+64)[0];assert cmdsize>=72+80*nsects,path
   for i in range(nsects):
    base=pos+72+80*i;offset=struct.unpack_from('<I',data,base+48)[0];flags=struct.unpack_from('<I',data,base+64)[0]
    if flags&0xff==0x12 and offset:
     section=bytes(data[base:base+16]).split(b'\0')[0].decode();patched.append({'section':section,'oldOffset':offset,'newOffset':0});struct.pack_into('<I',data,base+48,0)
  pos+=cmdsize
 if patched:
  before=hashlib.sha256(path.read_bytes()).hexdigest();path.write_bytes(data)
  subprocess.run(['codesign','--force','--sign','-',str(path)],check=True,capture_output=True)
  changes.append({'file':str(path.relative_to(root)),'sections':patched,'originalSHA256':before,'repairedSignedSHA256':hashlib.sha256(path.read_bytes()).hexdigest()})
report={'modelExecuted':False,'systemSecurityModified':False,'instructionBytesChanged':False,'metadataChange':'S_THREAD_LOCAL_ZEROFILL file offset normalized to zero','changes':changes}
a.report.write_text(json.dumps(report,ensure_ascii=False,indent=2));print('Normalized copied Mach-O files:',len(changes))
