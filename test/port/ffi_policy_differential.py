#!/usr/bin/env python3
"""Compare Zig and Cyna FFI policy validation and error precedence."""
import sys
import json,tempfile,pathlib,subprocess
forms=[]
decl='double sqrt(double x); void fill(uint8_t *data, size_t len);'
for strategy in [None,'runtime-default','relative-first','system-first','bad','',0,True,[],{}]:
 for paths in [None,[],['/tmp'],[3],['/tmp',2],[],{},'x']:
  search={}
  if strategy is not None:search['strategy']=strategy
  if paths is not None:search['paths']=paths
  forms.append({'search':search})
for returns in [None,{}, {'kind':'handle'}, {'kind':'handle','type':'Foo'}, {'kind':'value'}, {'out':'x'},{'out':'data'},{'type':'Foo'},{'kind':'handle','out':'data'}]:
 if returns is not None:forms.append({'functions':{'sqrt':{'returns':returns}}})
for errors in [None,{}, {'kind':'status'},{'kind':'null'},{'kind':'sentinel'},{'kind':'bad'},{'ok':0},{'value':-1},{'code':'x'},{'message':'bad'},{'message':{'from':'sqrt'}},{'message':{'from':'missing'}},{'message':{'from':'fill','arg':'data'}},{'message':{'from':'fill','arg':'missing'}}]:
 if errors is not None:forms.append({'functions':{'sqrt':{'errors':errors}}})
for pointer in ['data','len','missing']:
 for length in ['data','len','missing']:
  for element in ['u8','f64','bad',None]:
   for direction in [None,'in','out','inout','bad']:
    b={'length':length}
    if element is not None:b['element']=element
    if direction is not None:b['direction']=direction
    forms.append({'functions':{'fill':{'buffers':{pointer:b}}}})
with tempfile.TemporaryDirectory() as d:
 p=pathlib.Path(d)/'p.ts';p.write_text("import {prepareNative} from 'std:ffi/c/native';const cases="+json.dumps(forms)+";for(let i=0;i<cases.length;i++){try{console.log(i,JSON.stringify(prepareNative('m',"+json.dumps(decl)+",cases[i])))}catch(e){console.log(i,e.name,e.code,e.message)}}")
 outs=[]
 for exe in (str(pathlib.Path(sys.argv[1]).resolve()), str(pathlib.Path(sys.argv[2]).resolve())):
  r=subprocess.run([exe,str(p)],capture_output=True,text=True,timeout=20);outs.append((r.returncode,r.stdout.splitlines(),r.stderr))
 diff=[(i,forms[i],a,b) for i,(a,b) in enumerate(zip(outs[0][1],outs[1][1])) if a!=b]
 assert outs[0] == outs[1], diff[:22]
 print(f'FFI policies: {len(forms)} Zig/Cyna forms matched')
