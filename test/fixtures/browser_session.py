import json
import os
import signal
import sys
import time

if os.getpgrp() != os.getpid():
    os.setsid()
signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
count = 0
for line in sys.stdin:
    request = json.loads(line)
    mode = request.get("mode")
    if mode == "crash":
        os._exit(7)
    if mode == "oversize":
        print("x" * 1100000, flush=True)
        continue
    time.sleep(request.get("sleep_ms", 0) / 1000)
    count += 1
    closed = mode == "close"
    result = {"pid": os.getpid(), "count": count, "closed": closed, "text": "x" * request.get("size", 0)}
    print(json.dumps({"ok": True, "result": result}), flush=True)
    if closed:
        break
