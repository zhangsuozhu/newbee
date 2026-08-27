import json, sys
# 解析 events.jsonl，输出 [(topic, normalized_event)] 供 Elixir 消费
out = []
with open(sys.argv[1]) as f:
    for line in f:
        try: ev = json.loads(line)
        except: continue
        topic = ev.get('topic')
        if topic not in ('prompt_injection','rule_hit','tool_error','usage','goal_done','turn_end','final_check_low'):
            continue
        payload = ev.get('data', {}).get('payload')
        # 归一化：Collector 的 event 是 map；payload 是 [name, data] 时取 data
        if isinstance(payload, list) and len(payload) > 1 and isinstance(payload[1], dict):
            event = payload[1]
        elif isinstance(payload, dict):
            event = payload
        else:
            event = {'payload': payload}  # turn_end/tool_error 的 list payload
        out.append({'topic': topic, 'event': event})
json.dump(out, open(sys.argv[2], 'w'), ensure_ascii=False)
print('normalized:', len(out))
