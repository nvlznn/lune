# Lune app icon from the same pixel map as GhostView.swift.
BODY = [
    "    OOOOOOOO    ",
    "  OOWWWWWWWWOO  ",
    " OWWWWWWWWWWWWO ",
    " OWWWWWWWWWWWWO ",
    "OWWWWWWWWWWWWWWO",
    "OWWWWWWWWWWWWWWO",
    "OWWWWWWWWWWWWWWO",
    "OWWWWWWWWWWWWWWO",
    "OWWWWWWWWWWWWWWO",
    "OLWWWWWWWWWWWWLO",
    "OLLWWWWWWWWWWLLO",
    "OLLLLLLLLLLLLLLO",
    "OLLLLOLLLLOLLLLO",
    " OOOO OOOO OOOO ",
]
grid = [list(r) for r in BODY]
for row in (5, 6):
    grid[row][5] = "E"; grid[row][10] = "E"

# Black like iOS's own black icons; dark-gray outline, eyes and shading; no ground shadow.
THEMES = {
    "light": dict(bg="#000000", O="#3A3A3C", E="#1C1C1E", W="#F2F2F7", L="#636366"),
    "dark": dict(bg="#000000", O="#3A3A3C", E="#1C1C1E", W="#E5E5EA", L="#5A5A5E"),
    "tinted": dict(bg="#000000", O="#3A3A3A", E="#1C1C1C", W="#F0F0F0", L="#7A7A7A"),
}
CELL = 38
W, H = 16 * CELL, 14 * CELL
OX, OY = (1024 - W) // 2, (1024 - H) // 2

for name, t in THEMES.items():
    rects = []
    for y, row in enumerate(grid):
        for x, p in enumerate(row):
            if p == " ":
                continue
            color = t[p]
            rects.append(f'<rect x="{OX + x*CELL}" y="{OY + y*CELL}" width="{CELL+0.5}" height="{CELL+0.5}" fill="{color}"/>')
    svg = f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024" shape-rendering="crispEdges"><rect width="1024" height="1024" fill="{t["bg"]}"/>{"".join(rects)}</svg>'
    open(f"{name}.svg", "w").write(svg)
print("ok")
