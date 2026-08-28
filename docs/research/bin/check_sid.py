import json, sys
counts = {'turn_end': [0,0], 'tool_error':[0,0], 'prompt_injection':[0,0], 'usage':[0,0], 'goal_done':[0,0]}
samples = {}
with open(sys.argv[1]) as f:
    for line in f:
        try: ev = json.loads(line)
        except: continue
        t = ev.get('topic')
        if t in counts:
            # 检查顶层或 data 里有 session_id
            has = ('session_id' in ev) or ('session_id' in ev.get('data', {}))
            # payload 是 map 时也可能有
            p = ev.get('data', {}).get('payload')
            if isinstance(p, dict) and 'session_id' in p: has = True
            if isinstance(p, list) and len(p)>1 and isinstance(p[1], dict) and 'session_id' in p[1]: has = True
            counts[t][0 if has else 1] += 1
            if t not in samples: samples[t] = list(ev.keys()), list(ev.get('data',{}).keys())
for t, (with_sid, without_sid) in counts.items():
    print('%s: with_sid=%d without_sid=%d keys=%s' % (t, with_sid, without_sid, samples.get(t)))
