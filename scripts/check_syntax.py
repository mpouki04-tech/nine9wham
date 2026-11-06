import io
import sys

if len(sys.argv) != 2:
    print("usage: check_syntax.py <fichier.m>")
    sys.exit(2)

path = sys.argv[1]
src = io.open(path, encoding="utf-8", errors="replace").read()

i = 0
n = len(src)
line = 1
stack = []
pairs = {")": "(", "]": "[", "}": "{"}
in_line_c = in_block_c = in_str = in_chr = False

while i < n:
    c = src[i]
    nxt = src[i + 1] if i + 1 < n else ""
    if c == "\n":
        line += 1
    if in_line_c:
        if c == "\n":
            in_line_c = False
        i += 1
        continue
    if in_block_c:
        if c == "*" and nxt == "/":
            in_block_c = False
            i += 2
            continue
        i += 1
        continue
    if in_str:
        if c == "\\":
            i += 2
            continue
        if c == '"':
            in_str = False
        i += 1
        continue
    if in_chr:
        if c == "\\":
            i += 2
            continue
        if c == "'":
            in_chr = False
        i += 1
        continue
    if c == "/" and nxt == "/":
        in_line_c = True
        i += 2
        continue
    if c == "/" and nxt == "*":
        in_block_c = True
        i += 2
        continue
    if c == '"':
        in_str = True
        i += 1
        continue
    if c == "'":
        in_chr = True
        i += 1
        continue
    if c in "{([":
        stack.append((c, line))
    elif c in "})]":
        if not stack:
            print("EXTRA %s ligne %d" % (c, line))
            sys.exit(1)
        o, l = stack.pop()
        if o != pairs[c]:
            print("MISMATCH open %s ligne %d close %s ligne %d" % (o, l, c, line))
            sys.exit(1)
    i += 1

if stack:
    print("remaining open: %d" % len(stack))
    for o, l in stack[-10:]:
        print("  unclosed %s ligne %d" % (o, l))
    sys.exit(1)

print("OK: syntaxe equilibree")
