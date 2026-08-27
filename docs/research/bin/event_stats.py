import json, collections, sys
topics = collections.Counter()
n = 0
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if not line: continue
        n += 1
        try: ev = json.loads(line)
        except: continue
        t = ev.get('topic')
        if t is None and isinstance(ev.get('event'), str): t = ev.get('event')
        topics[str(t)] += 1
print('total events:', n)
for t, c in topics.most_common(30): print('  %s: %d' % (t, c))
