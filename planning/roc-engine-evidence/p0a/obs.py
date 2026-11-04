import json, sys
for o in json.load(open(sys.argv[1])):
    s = o["stats"]
    print(f'{o["name"]:32} allocs={s["allocs"]:>6} reallocs={s["reallocs"]:>4} bytes={s["requested_bytes"]:>10}')
