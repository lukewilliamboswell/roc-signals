import json,sys
d=json.load(open(sys.argv[1]))
want=sys.argv[2:] or None
print(d['outcome'], d.get('baseline_status'))
for ex in d['examples']:
    obs = ex.get('observations') or (ex.get('diagnostics') or {}).get('regions') or []
    print('==',ex['name'],ex['outcome'])
    for o in obs:
        if o['name']=='$property': continue
        if want and o['name'] not in want: continue
        s=o['stats']; print('  %-24s allocs=%6d bytes=%11d'%(o['name'],s['allocs'],s['requested_bytes']))
