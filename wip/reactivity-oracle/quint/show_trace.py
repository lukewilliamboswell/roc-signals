#!/usr/bin/env python3
"""Print a Quint ITF trace of effects.qnt or ingress.qnt as one line per step."""
import json, sys

def un(v):
    if isinstance(v, dict):
        if '#bigint' in v: return int(v['#bigint'])
        if '#set' in v: return [un(x) for x in v['#set']]
        if '#map' in v: return {str(un(k)): un(x) for k, x in v['#map']}
        if '#tup' in v: return tuple(un(x) for x in v['#tup'])
        return {k: un(x) for k, x in v.items()}
    if isinstance(v, list): return [un(x) for x in v]
    return v

t = json.load(open(sys.argv[1]))
for i, raw in enumerate(t['states']):
    s = un(raw)
    var = next(v for k, v in s.items() if not k.startswith('mbt::') and k != '#meta')
    picks = {k: v['value'] for k, v in s.get('mbt::nondetPicks', {}).items()
             if isinstance(v, dict) and v.get('tag') == 'Some'}
    print(f"{i}: {s.get('mbt::actionTaken', '?')} {picks}")
    if 'issued' in var:
        e = var
        live = {i: (('orphan@when(' if l['orphan'] else 'site(') + l['holder'] + ')') for i, l in e['live'].items()}
        reqs = {i: f"{r['scope']}#{r['gen']} {r['kind']} v{r['value']} ->{r['tgtScope']}#{r['tgtGen']} {r['fate']}" for i, r in e['reqs'].items()}
        if i == 0: print('     policies', e['pol'])
        print('     alive', [k for k, v in e['alive'].items() if v], 'watch', e['watch'], 'live', live, 'queue', e['queue'])
        print('     reqs', reqs)
        print('     issued/delivered/stale/refused/cancelled/reparented/skipped',
              [e[k] for k in ['issued', 'delivered', 'stale', 'refused', 'cancelled', 'reparented', 'skipped']],
              'violations', e['gViol'])
    else:
        q = var
        ent = lambda en: ('R:' + en['src'] if en['report'] else 'OCC') + f"(first {en['first']}, value {en['seq']}" + (f", epoch {en['epoch']}" if 'epoch' in en else f", at {en['at']}") + (', dead' if en.get('dead') else '') + ')'
        print('     phase', q['phase'], 'epoch', q['epoch'], 'sched', q['sched'], 'due', q['reportDue'], 'poisoned', q['poisoned'])
        print('     queue', [ent(x) for x in q['queue']])
        print('     out  ', [ent(x) for x in q['out']])
