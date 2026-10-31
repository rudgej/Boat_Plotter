from PIL import Image
from collections import deque

src = "/usr/share/plymouth/themes/fairline/logo.png"
im = Image.open(src).convert("RGBA")
W, H = im.size
px = im.load()

# Flood-fill from the image edges: turn the connected near-white background
# transparent. Navy shield/wordmark (dark) blocks the flood, so the white
# stripes inside the shield survive.
q = deque()
seen = set()
for x in range(W):
    q.append((x, 0)); q.append((x, H - 1))
for y in range(H):
    q.append((0, y)); q.append((W - 1, y))

while q:
    x, y = q.popleft()
    if x < 0 or y < 0 or x >= W or y >= H:
        continue
    if (x, y) in seen:
        continue
    seen.add((x, y))
    r, g, b, a = px[x, y]
    if r > 235 and g > 235 and b > 235:   # near-white background
        px[x, y] = (r, g, b, 0)
        q.append((x + 1, y)); q.append((x - 1, y))
        q.append((x, y + 1)); q.append((x, y - 1))

im.save(src)
print("transparent done:", im.size)
