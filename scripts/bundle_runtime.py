#!/usr/bin/env python3
"""Relocate CPython framework and installed distributions; never loads MLX/models.
Source runtime is an audited local installation, not a copied virtualenv.
"""
import argparse, hashlib, json, os, shutil, subprocess, struct
from pathlib import Path

parser=argparse.ArgumentParser()
parser.add_argument('--python-framework',type=Path,required=True)
parser.add_argument('--site-packages',type=Path,required=True)
parser.add_argument('--mlx-source',type=Path,required=True)
parser.add_argument('--destination',type=Path,default=Path('runtime'))
args=parser.parse_args()
dst=args.destination.resolve(); dst.mkdir(parents=True,exist_ok=True)
ignore=shutil.ignore_patterns('__pycache__','*.pyc','*.pyo','.DS_Store','_CodeSignature','*.a','site-packages','Headers','include','share')
framework=dst/'Python.framework'/'Versions'/'3.10'
shutil.copytree(args.python_framework/'Versions'/'3.10',framework,ignore=ignore,dirs_exist_ok=True,symlinks=False)
site=framework/'lib'/'python3.10'/'site-packages'
shutil.copytree(args.site_packages,site,ignore=shutil.ignore_patterns('__pycache__','*.pyc','*.pyo','.DS_Store','__editable__*','_virtualenv*','*.egg-link'),dirs_exist_ok=True)
shutil.copytree(args.mlx_source/'mlx_audio',site/'mlx_audio',ignore=shutil.ignore_patterns('__pycache__','*.pyc','*.pyo','.DS_Store'),dirs_exist_ok=True)
# Preserve source revision metadata without recording source-machine paths.
for metadata in site.glob('mlx_audio-*.dist-info/direct_url.json'):
 metadata.write_text(json.dumps({'url':'https://github.com/Blaizzy/mlx-audio','vcs_info':{'vcs':'git','commit_id':'364585faa92dbff819583e0e5bf691e256179590'}}))
# Prevent editable finder/venv hook imports and foreign site paths.
for hook in site.glob('*.pth'): hook.unlink()
libs=dst/'Libraries';libs.mkdir(exist_ok=True)
manifest={'kind':'relocated CPython framework plus exact installed package files','modelExecuted':False,'externalLibraries':[],'macho':[],'missing':[]}
source_framework=args.python_framework.resolve()
def macho(p):
 try:
  if not p.is_file():return False
  with p.open('rb') as f: magic=f.read(4)
  return magic in (b'\xcf\xfa\xed\xfe',b'\xce\xfa\xed\xfe',b'\xca\xfe\xba\xbe',b'\xbe\xba\xfe\xca')
 except OSError:return False

def run(*argv): return subprocess.run(argv,check=True,capture_output=True,text=True).stdout

def dep_lines(p):return [line.strip().split(' (compatibility')[0] for line in run('otool','-L',str(p)).splitlines()[1:] if ' (compatibility' in line]

def remap(dep,origin):
 if not dep.startswith('/opt/homebrew/'):return None
 if 'Python.framework/Versions/3.10/' in dep:
  return framework/dep.split('Python.framework/Versions/3.10/',1)[1]
 original=Path(dep).resolve(); target=libs/original.name
 if not original.exists():manifest['missing'].append({'file':str(origin.relative_to(dst)),'dependency':dep});return None
 if not target.exists():
  shutil.copy2(original,target)
  manifest['externalLibraries'].append({'source':str(original).split('/Cellar/',1)[-1],'destination':str(target.relative_to(dst)),'sha256BeforeRelocation':hashlib.sha256(target.read_bytes()).hexdigest()})
  # Preserve Homebrew package license files.
  cellar_parts=original.parts
  if 'Cellar' in cellar_parts:
   idx=cellar_parts.index('Cellar');package_root=Path(*cellar_parts[:idx+3])
   license_dir=dst/'licenses'/cellar_parts[idx+1];license_dir.mkdir(parents=True,exist_ok=True)
   for license_file in package_root.rglob('*'):
    if license_file.is_file() and any(x in license_file.name.lower() for x in ['license','copying','copyright']):
     if license_file.stat().st_size<1000000:shutil.copy2(license_file,license_dir/(str(license_file.relative_to(package_root)).replace('/','__')))
 return target

visited=set()
while True:
 pending=[p for p in dst.rglob('*') if p not in visited and macho(p)]
 if not pending:break
 for p in pending:
  visited.add(p);p.chmod(p.stat().st_mode|0o200)
  identifiers={line.strip() for line in run('otool','-D',str(p)).splitlines() if not line.endswith(':')}
  dependencies=dep_lines(p)
  for dep in dependencies:
   if dep in identifiers:continue
   target=remap(dep,p)
   if not target and dep.startswith('@rpath/') and (p.parent/dep[len('@rpath/'):]).exists():target=p.parent/dep[len('@rpath/'):]
   if target:
    new='@loader_path/'+os.path.relpath(target,p.parent)
    run('install_name_tool','-change',dep,new,str(p))
  if p.name.endswith('.dylib') or p==framework/'Python':
   run('install_name_tool','-id','@loader_path/'+p.name,str(p))
  load=run('otool','-l',str(p)).splitlines()
  for i,line in enumerate(load):
   if 'cmd LC_RPATH' in line:
    for n in load[i+1:i+5]:
     if n.strip().startswith('path '):
      rp=n.strip().split(' ',2)[1]
      if rp.startswith('/') and not rp.startswith(('/System/','/usr/lib/')):run('install_name_tool','-delete_rpath',rp,str(p))
  manifest['macho'].append(str(p.relative_to(dst)))
# Framework aliases used by standard runtime discovery and codesign.
for link,target in [(dst/'Python.framework'/'Versions'/'Current','3.10'),(dst/'Python.framework'/'Python','Versions/Current/Python'),(dst/'Python.framework'/'Resources','Versions/Current/Resources')]:
 if link.is_symlink():link.unlink()
 if not link.exists():link.symlink_to(target)
subprocess.run(['python3',str(Path(__file__).with_name('repair_macho_zerofill.py')),str(dst),'--report',str(dst/'macho-zerofill-repair.json')],check=True)
for p in sorted(visited,key=lambda p:len(p.parts),reverse=True):
 run('codesign','--force','--sign','-',str(p))
# Preserve original framework metadata and resource bundle signatures after relocation.
for bundle in [framework/'Resources'/'Python.app',dst/'Python.framework']:
 if bundle.exists():run('codesign','--force','--sign','-',str(bundle))
manifest['files']=len([p for p in dst.rglob('*') if p.is_file()]);manifest['bytes']=sum(p.stat().st_size for p in dst.rglob('*') if p.is_file())
(dst/'runtime-manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2))
print(json.dumps({k:v for k,v in manifest.items() if k not in ['macho','externalLibraries']},ensure_ascii=False))
if manifest['missing']:raise SystemExit('Missing dynamic libraries')
