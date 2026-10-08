#!/usr/bin/env python3
"""Compare local model data to pinned HF metadata, then freeze SHA256 data catalog."""
import argparse,hashlib,json,struct
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--models',type=Path,required=True);p.add_argument('--metadata',type=Path,required=True);a=p.parse_args()
models=[];checks=[]
for key,folder,repo,license_id,license_url in [
 ('sensevoice','SenseVoiceSmall','mlx-community/SenseVoiceSmall','FunASR Model License 1.1','https://github.com/modelscope/FunASR/blob/main/MODEL_LICENSE'),
 ('qwen','Qwen3-ASR-1.7B-8bit','mlx-community/Qwen3-ASR-1.7B-8bit','Apache-2.0','https://github.com/QwenLM/Qwen3-ASR/blob/main/LICENSE')]:
 metadata=json.loads((a.metadata/(key+'-hf-revision.json')).read_text());files=[]
 for source in metadata['siblings']:
  name=source['rfilename']
  if name=='.gitattributes':continue
  assert '/' not in name and not name.endswith('.py')
  path=a.models/folder/name
  assert path.is_file(),str(path)
  data=path.read_bytes() if path.stat().st_size<3000000 else None
  sha=hashlib.sha256();git=hashlib.sha1();git.update(f'blob {path.stat().st_size}\0'.encode())
  with path.open('rb') as stream:
   for chunk in iter(lambda:stream.read(8*1024*1024),b''):sha.update(chunk);git.update(chunk)
  local_sha=sha.hexdigest();expected=source.get('lfs',{}).get('sha256')
  matched=path.stat().st_size==source['size'] and (local_sha==expected if expected else git.hexdigest()==source['blobId'])
  checks.append({'model':key,'file':name,'size':path.stat().st_size,'sha256':local_sha,'upstreamMatched':matched})
  assert matched,(folder,name,'does not match pinned revision')
  if name=='model.safetensors':
   with path.open('rb') as stream:header_size=struct.unpack('<Q',stream.read(8))[0];assert header_size<20000000;header=json.loads(stream.read(header_size))
   ends=[v['data_offsets'][1] for k,v in header.items() if k!='__metadata__'];assert 8+header_size+max(ends)==path.stat().st_size
  files.append({'name':name,'size':path.stat().st_size,'sha256':local_sha})
 types=sorted({v['dtype'] for k,v in header.items() if k!='__metadata__'})
 models.append({'tensorDTypes':types,'formatLabel':'MLX · 8bit' if key=='qwen' else 'MLX · '+('/'.join(types)),'id':key,'folder':folder,'repository':repo,'revision':metadata['sha'],'license':license_id,'licenseURL':license_url,'licenseFile':'FunASR-MODEL_LICENSE.txt' if key=='sensevoice' else 'Qwen3-ASR-Apache-2.0.txt','bytes':sum(f['size'] for f in files),'files':files})
Path('model-catalog.json').write_text(json.dumps({'version':1,'models':models},ensure_ascii=False,indent=2))
Path('tests/model-data-static-validation.json').write_text(json.dumps({'modelExecuted':False,'checks':checks,'allMatched':all(x['upstreamMatched'] for x in checks)},ensure_ascii=False,indent=2))
print('All local model bytes match pinned upstream revisions. No inference was executed.')
