import re, sys
x = open(sys.argv[1]).read()
x = re.sub(r'<script.*?</script>', ' ', x, flags=re.S)
x = re.sub(r'<style.*?</style>', ' ', x, flags=re.S)
txt = re.sub(r'<[^>]+>', ' ', x)
txt = re.sub(r'\s+', ' ', txt)
open(sys.argv[2], 'w').write(txt)
print(len(txt))
