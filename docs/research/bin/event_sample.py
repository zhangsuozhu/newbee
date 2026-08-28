import json, sys
want = sys.argv[2].split(',')
shown = {w: 0 for w in want}
with open(sys.argv[1]) as f:
    for line in f:
        try: ev = json.loads(line)
        except: continue
        t = ev.get('topic')
        if t in want and shown[t] < 3:
            print('=== %s ===' % t)
            print(json.dumps(ev, ensure_ascii=False)[:600])
            shown[t] += 1
