#!/usr/bin/env python3
"""Static dependency resolution audit, does not import native packages or models."""
import json, os, struct, subprocess, sys
from pathlib import Path
root=Path(sys.argv[1]).resolve()
MAGIC=(b'\xcf\xfa\xed\xfe',b'\xce\xfa\xed\xfe',b'\xca\xfe\xba\xbe',b'\xbe\xba\xfe\xca')
report={'root':str(root),'machoCount':0,'unresolved':[],'externalRpaths':[],'architectures':{},'modelExecuted':False}
def call(*a):return subprocess.run(a,check=True,capture_output=True,text=True).stdout
for p in root.rglob('*'):
 if not p.is_file() or p.is_symlink():continue
 with p.open('rb') as f: magic=f.read(4)
 if magic not in MAGIC:continue
 report['machoCount']+=1
 arch=call('lipo','-archs',str(p)).strip();report['architectures'][str(p.relative_to(root))]=arch
 identifiers={line.strip() for line in call('otool','-D',str(p)).splitlines() if not line.endswith(':') and not line.startswith('Archive')}
 load=call('otool','-l',str(p)).splitlines()
 rpaths=[]
 for i,line in enumerate(load):
  if 'cmd LC_RPATH' in line:
   for n in load[i+1:i+5]:
    if n.strip().startswith('path '):rpaths.append(n.strip().split(' ',2)[1])
 for rp in rpaths:
  if rp.startswith('/') and not rp.startswith('/System/') and not rp.startswith('/usr/lib/'):
   report['externalRpaths'].append({'file':str(p.relative_to(root)),'rpath':rp})
 for line in call('otool','-L',str(p)).splitlines()[1:]:
  if ' (compatibility' not in line:continue
  dep=line.strip().split(' (compatibility')[0]
  if dep in identifiers or dep.startswith(('/System/','/usr/lib/')):continue
  if dep.startswith('@loader_path/'):
   candidate=p.parent/dep[len('@loader_path/'):]
   if candidate.exists():continue
  elif dep.startswith('@rpath/'):
   tail=dep[len('@rpath/'):]
   expanded=[p.parent/rp[len('@loader_path/'):] if rp.startswith('@loader_path/') else p.parent if rp=='@loader_path' else Path(rp) for rp in rpaths]
   if any((rp/tail).exists() and (rp/tail).resolve().is_relative_to(root) for rp in expanded):continue
  elif dep.startswith('@executable_path/'):
   # Framework executable also inherits executable-directory rpaths; require resolution below root.
   if any(c.exists() for c in [p.parent/dep[len('@executable_path/'):],root/'Python.framework/Versions/3.10/Resources/Python.app/Contents/MacOS'/dep[len('@executable_path/'):]]):continue
  elif Path(dep).exists() and Path(dep).resolve().is_relative_to(root):continue
  report['unresolved'].append({'file':str(p.relative_to(root)),'dependency':dep,'rpaths':rpaths})
print(json.dumps(report,ensure_ascii=False,indent=2))
if report['unresolved'] or any('arm64' not in a for a in report['architectures'].values()):raise SystemExit(1)
