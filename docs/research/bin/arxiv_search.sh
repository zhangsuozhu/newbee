#!/bin/bash
Q=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$1")
M=${2:-20}
curl -sS -m 30 "https://export.arxiv.org/api/query?search_query=$Q&start=0&max_results=$M&sortBy=relevance" \
 | python3 -c "
import sys, re
x = sys.stdin.read()
entries = re.findall(r'<entry>(.*?)</entry>', x, re.S)
for e in entries:
    t = re.search(r'<title>(.*?)</title>', e, re.S)
    i = re.search(r'<id>(.*?)</id>', e, re.S)
    p = re.search(r'<published>(.*?)</published>', e, re.S)
    if t: print(p.group(1)[:10] if p else '', '|', re.sub(r'\s+',' ',t.group(1)).strip(), '|', i.group(1) if i else '')
"
