import re, sys
txt = open(sys.argv[1]).read()
kw = sys.argv[2].split(',')
w = int(sys.argv[3]) if len(sys.argv)>3 else 250
seen = 0
for k in kw:
    for m in re.finditer(re.escape(k), txt, re.I):
        s = max(0, m.start()-w); e = min(len(txt), m.end()+w)
        print('>>>', txt[s:e].strip())
        print()
        seen += 1
        if seen > int(sys.argv[4] if len(sys.argv)>4 else 12): sys.exit()
