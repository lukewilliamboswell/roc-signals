"""timecur_fx.py LOCK CURDIR CASE... -- the current engine's host-bench does not
time `run-effect` steps (effect results are not dispatch-measured), so time
them as a process wall-time difference: the case's spec with and without its
final run-effect, alternated 21 times each, each run under the timing lock.
Reports median(full) - median(prefix). Crude (process noise ~0.1-0.3 ms)."""
import sys, os, subprocess, time, statistics, tempfile
lock, cur = sys.argv[1], sys.argv[2]
for case in sys.argv[3:]:
    spec = open(os.path.join(cur, 'specs', case + '.scm')).read()
    lines = spec.rstrip().rstrip(')').split('\n')
    # the last step is "(run-effect K)"; the prefix drops it and the mark
    assert lines[-1].strip().startswith('(run-effect'), lines[-1]
    prefix = '\n'.join(l for l in lines[:-1] if '(mark-metrics)' not in l) + '))\n'
    full = '\n'.join(l for l in lines if '(mark-metrics)' not in l) + ')))\n'
    d = tempfile.mkdtemp()
    pf, ff = os.path.join(d, 'prefix.scm'), os.path.join(d, 'full.scm')
    open(pf, 'w').write(prefix); open(ff, 'w').write(full)
    t = {'p': [], 'f': []}
    for i in range(22):
        for k, f in (('p', pf), ('f', ff)):
            cmd = ['flock', '-w', '3600', lock, 'python3', '-c',
                   'import subprocess,time,sys;t=time.perf_counter_ns();r=subprocess.run(sys.argv[1:],capture_output=True);print(time.perf_counter_ns()-t, r.returncode)',
                   os.path.join(cur, 'cur'), f]
            out = subprocess.run(cmd, capture_output=True, text=True, timeout=600).stdout.split()
            if out[1] != '0': raise SystemExit(f'{case} {k} failed')
            if i > 0: t[k].append(int(out[0]))
    mp, mf = statistics.median(t['p']), statistics.median(t['f'])
    print(f"cur {os.path.basename(cur):10} {case:18} {(mf - mp) / 1e3:10.1f} us  (wall-time difference; prefix {mp/1e6:.2f} ms, full {mf/1e6:.2f} ms)")
