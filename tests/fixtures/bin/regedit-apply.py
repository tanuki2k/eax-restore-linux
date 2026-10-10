"""Test stand-in for `regedit file.reg`: applies a .reg file to $STUB_PREFIX/user.reg.

Understands what the script writes: [HKEY_CURRENT_USER\\Key] sections, "name"="value"
and @="value" lines, "name"=- (delete value) and [-HKEY_CURRENT_USER\\Key] (delete key).
Output follows Wine's own text layout ("[Key\\\\Path] <time>", doubled backslashes).
"""
import os, re, sys

def load(path):
    keys, order, cur = {}, [], None
    for line in open(path, encoding="utf-8", errors="replace").read().splitlines():
        m = re.match(r'^\[(.*)\](?: \d+)?$', line)
        if m:
            cur = m.group(1); keys.setdefault(cur, {}); order.append(cur) if cur not in order else None
        elif cur is not None and line.startswith(('"', '@')):
            name, _, val = line.partition('=')
            keys[cur][name] = val
    return keys, order

def main(reg):
    prefix = os.environ["STUB_PREFIX"]
    store = os.path.join(prefix, "user.reg")
    header = open(store, encoding="utf-8").read().split("\n\n", 1)[0] + "\n\n"
    keys, order = load(store)
    cur = None
    for raw in open(reg, encoding="utf-8-sig", errors="replace").read().splitlines():
        line = raw.strip().replace("\r", "")
        m = re.match(r'^\[(-?)HKEY_CURRENT_USER\\(.*)\]$', line)
        if m:
            cur = m.group(2).replace("\\", "\\\\")
            if m.group(1):
                for k in [k for k in keys if k.lower() == cur.lower()]:
                    del keys[k]; order.remove(k)
                cur = None
            elif not any(k.lower() == cur.lower() for k in keys):
                keys[cur] = {}; order.append(cur)
            else:
                cur = next(k for k in keys if k.lower() == cur.lower())
        elif cur is not None and (line.startswith('"') or line.startswith('@')):
            name, _, val = line.partition('=')
            if val == '-':
                keys[cur].pop(name, None)
            else:
                keys[cur][name] = val
    with open(store, "w", encoding="utf-8") as f:
        f.write(header)
        for k in order:
            f.write("[%s] 1700000000\n#time=1d9\n" % k)
            for name, val in keys[k].items():
                f.write("%s=%s\n" % (name, val))
            f.write("\n")

main(sys.argv[1])
