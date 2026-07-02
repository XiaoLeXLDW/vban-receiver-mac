#!/usr/bin/env python3
import os
import math
import struct
import subprocess
import sys
import zlib
from collections import deque
from pathlib import Path


ROOT = Path.cwd()
RESOURCES = ROOT / "Resources"
SOURCE = RESOURCES / "AppIconSource.png"
TRANSPARENT = RESOURCES / "AppIconTransparent.png"
ICONSET = RESOURCES / "AppIcon.iconset"
ICNS = RESOURCES / "AppIcon.icns"
ICON_IMAGE_SCALE = 0.80
ICON_TILE_INSET = 0.09
ICON_TILE_RADIUS = 0.23

OUTPUTS = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]


def chunk(chunk_type, payload):
    body = chunk_type + payload
    return struct.pack(">I", len(payload)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)


def paeth(left, up, up_left):
    p = left + up - up_left
    pa = abs(p - left)
    pb = abs(p - up)
    pc = abs(p - up_left)
    if pa <= pb and pa <= pc:
        return left
    if pb <= pc:
        return up
    return up_left


def read_png(path):
    data = path.read_bytes()
    if not data.startswith(b"\x89PNG\r\n\x1a\n"):
        raise ValueError(f"{path} is not a PNG")

    offset = 8
    width = height = color_type = bit_depth = interlace = None
    idat = bytearray()

    while offset < len(data):
        length = struct.unpack(">I", data[offset : offset + 4])[0]
        offset += 4
        kind = data[offset : offset + 4]
        offset += 4
        payload = data[offset : offset + length]
        offset += length + 4

        if kind == b"IHDR":
            width, height, bit_depth, color_type, _, _, interlace = struct.unpack(">IIBBBBB", payload)
        elif kind == b"IDAT":
            idat.extend(payload)
        elif kind == b"IEND":
            break

    if bit_depth != 8 or color_type not in (2, 6) or interlace != 0:
        raise ValueError(f"{path} must be 8-bit RGB/RGBA non-interlaced PNG")

    channels = 4 if color_type == 6 else 3
    stride = width * channels
    raw = zlib.decompress(bytes(idat))
    rows = []
    previous = bytearray(stride)
    index = 0

    for _ in range(height):
        filter_type = raw[index]
        index += 1
        row = bytearray(raw[index : index + stride])
        index += stride

        for i in range(stride):
            left = row[i - channels] if i >= channels else 0
            up = previous[i]
            up_left = previous[i - channels] if i >= channels else 0
            if filter_type == 1:
                row[i] = (row[i] + left) & 0xFF
            elif filter_type == 2:
                row[i] = (row[i] + up) & 0xFF
            elif filter_type == 3:
                row[i] = (row[i] + ((left + up) // 2)) & 0xFF
            elif filter_type == 4:
                row[i] = (row[i] + paeth(left, up, up_left)) & 0xFF
            elif filter_type != 0:
                raise ValueError(f"Unsupported PNG filter {filter_type}")

        rows.append(row)
        previous = row

    return width, height, channels, rows


def write_rgba_png(path, width, height, rows):
    raw = bytearray()
    for row in rows:
        raw.append(0)
        raw.extend(row)

    payload = b"".join(
        [
            b"\x89PNG\r\n\x1a\n",
            chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)),
            chunk(b"IDAT", zlib.compress(bytes(raw), 9)),
            chunk(b"IEND", b""),
        ]
    )
    path.write_bytes(payload)


def rgba_rows(width, channels, rows):
    if channels == 4:
        return rows

    converted = []
    for row in rows:
        rgba = bytearray()
        for i in range(0, len(row), channels):
            rgba.extend((row[i], row[i + 1], row[i + 2], 255))
        converted.append(rgba)
    return converted


def pad_to_canvas(path, out_path, canvas_size):
    width, height, channels, rows = read_png(path)
    rows = rgba_rows(width, channels, rows)
    canvas_rows = [bytearray(canvas_size * 4) for _ in range(canvas_size)]
    x_offset = max(0, (canvas_size - width) // 2)
    y_offset = max(0, (canvas_size - height) // 2)

    copy_width = min(width, canvas_size)
    copy_height = min(height, canvas_size)
    for y in range(copy_height):
        source_start = 0
        target_start = x_offset * 4
        byte_count = copy_width * 4
        canvas_rows[y + y_offset][target_start : target_start + byte_count] = rows[y][source_start : source_start + byte_count]

    write_rgba_png(out_path, canvas_size, canvas_size, canvas_rows)


def clamp(value, lower, upper):
    return max(lower, min(upper, value))


def luminance(r, g, b):
    return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255.0


def saturation(r, g, b):
    mn = min(r, g, b) / 255.0
    mx = max(r, g, b) / 255.0
    return mx - mn


def dark_tile_candidate(r, g, b, a):
    if a < 12:
        return False
    return luminance(r, g, b) < 0.26 and saturation(r, g, b) < 0.30


def remove_connected_dark_tile(path, out_path):
    width, height, channels, rows = read_png(path)
    rows = rgba_rows(width, channels, rows)
    visited = [[False] * width for _ in range(height)]
    queue = deque()

    def enqueue(x, y):
        if x < 0 or y < 0 or x >= width or y >= height or visited[y][x]:
            return
        pixel = x * 4
        if not dark_tile_candidate(rows[y][pixel], rows[y][pixel + 1], rows[y][pixel + 2], rows[y][pixel + 3]):
            return
        visited[y][x] = True
        queue.append((x, y))

    seed_radius = max(6, round(width * 0.08))
    near_transparent = [[False] * width for _ in range(height)]
    edge_queue = deque()
    for y in range(height):
        for x in range(width):
            if rows[y][x * 4 + 3] < 12:
                near_transparent[y][x] = True
                edge_queue.append((x, y, 0))

    while edge_queue:
        x, y, distance = edge_queue.popleft()
        if distance >= seed_radius:
            continue
        next_distance = distance + 1
        for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
            if nx < 0 or ny < 0 or nx >= width or ny >= height or near_transparent[ny][nx]:
                continue
            near_transparent[ny][nx] = True
            edge_queue.append((nx, ny, next_distance))

    for y in range(height):
        for x in range(width):
            if near_transparent[y][x]:
                enqueue(x, y)

    while queue:
        x, y = queue.popleft()
        enqueue(x + 1, y)
        enqueue(x - 1, y)
        enqueue(x, y + 1)
        enqueue(x, y - 1)

    for y in range(height):
        row = rows[y]
        for x in range(width):
            if visited[y][x]:
                row[x * 4 + 3] = 0

    edge_band = max(2, round(width * 0.085))
    for y in range(height):
        row = rows[y]
        for x in range(width):
            if not (x < edge_band or x >= width - edge_band or y < edge_band or y >= height - edge_band):
                continue
            pixel = x * 4
            if row[pixel + 3] < 12:
                continue
            if saturation(row[pixel], row[pixel + 1], row[pixel + 2]) < 0.18:
                row[pixel + 3] = 0

    write_rgba_png(out_path, width, height, rows)


def rounded_rect_coverage(x, y, left, top, right, bottom, radius):
    px = x + 0.5
    py = y + 0.5
    cx = clamp(px, left + radius, right - radius)
    cy = clamp(py, top + radius, bottom - radius)
    distance = math.hypot(px - cx, py - cy)
    return clamp(radius + 0.5 - distance, 0.0, 1.0)


def blend_over(dst, src):
    sr, sg, sb, sa = src
    if sa <= 0:
        return dst
    dr, dg, db, da = dst
    src_a = sa / 255.0
    dst_a = da / 255.0
    out_a = src_a + dst_a * (1.0 - src_a)
    if out_a <= 0:
        return (0, 0, 0, 0)
    out_r = (sr * src_a + dr * dst_a * (1.0 - src_a)) / out_a
    out_g = (sg * src_a + dg * dst_a * (1.0 - src_a)) / out_a
    out_b = (sb * src_a + db * dst_a * (1.0 - src_a)) / out_a
    return (int(round(out_r)), int(round(out_g)), int(round(out_b)), int(round(out_a * 255)))


def compose_app_icon(foreground_path, out_path, canvas_size):
    fg_width, fg_height, channels, fg_rows = read_png(foreground_path)
    fg_rows = rgba_rows(fg_width, channels, fg_rows)
    canvas_rows = [bytearray(canvas_size * 4) for _ in range(canvas_size)]

    inset = max(1, round(canvas_size * ICON_TILE_INSET))
    left = inset
    top = inset
    right = canvas_size - inset
    bottom = canvas_size - inset
    radius = max(1, round((right - left) * ICON_TILE_RADIUS))
    top_color = (44, 54, 63)
    bottom_color = (9, 14, 18)
    edge_color = (242, 248, 255)
    dark_edge = (2, 5, 8)

    for y in range(canvas_size):
        t = y / max(1, canvas_size - 1)
        base = tuple(int(round(top_color[i] * (1 - t) + bottom_color[i] * t)) for i in range(3))
        for x in range(canvas_size):
            coverage = rounded_rect_coverage(x, y, left, top, right, bottom, radius)
            if coverage <= 0:
                continue
            distance_to_edge = min(x - left, right - x, y - top, bottom - y)
            border_alpha = 0
            border_color = edge_color
            if distance_to_edge < canvas_size * 0.018:
                border_alpha = int(round(42 * coverage))
            if distance_to_edge < canvas_size * 0.006:
                border_alpha = int(round(72 * coverage))
                border_color = dark_edge
            pixel = x * 4
            tile = (base[0], base[1], base[2], int(round(255 * coverage)))
            current = tuple(canvas_rows[y][pixel + i] for i in range(4))
            blended = blend_over(current, tile)
            if border_alpha:
                blended = blend_over(blended, (*border_color, border_alpha))
            canvas_rows[y][pixel : pixel + 4] = bytes(blended)

    x_offset = (canvas_size - fg_width) // 2
    y_offset = (canvas_size - fg_height) // 2 + round(canvas_size * 0.005)
    for y in range(fg_height):
        target_y = y + y_offset
        if target_y < 0 or target_y >= canvas_size:
            continue
        source_row = fg_rows[y]
        target_row = canvas_rows[target_y]
        for x in range(fg_width):
            target_x = x + x_offset
            if target_x < 0 or target_x >= canvas_size:
                continue
            source_pixel = x * 4
            alpha = source_row[source_pixel + 3]
            if alpha <= 0:
                continue
            target_pixel = target_x * 4
            src = tuple(source_row[source_pixel + i] for i in range(4))
            dst = tuple(target_row[target_pixel + i] for i in range(4))
            target_row[target_pixel : target_pixel + 4] = bytes(blend_over(dst, src))

    write_rgba_png(out_path, canvas_size, canvas_size, canvas_rows)


def background_candidate(r, g, b):
    mn = min(r, g, b) / 255.0
    mx = max(r, g, b) / 255.0
    saturation = mx - mn
    return saturation < 0.04 and mn > 0.90


def alpha_for_background(r, g, b, alpha):
    mn = min(r, g, b) / 255.0
    if mn <= 0.925:
        return alpha
    factor = max(0.0, min(1.0, (0.985 - mn) / 0.06))
    return int(round(alpha * factor))


def make_transparent(path, out_path):
    width, height, channels, rows = read_png(path)
    rgba_rows = []
    for row in rows:
        rgba = bytearray()
        for i in range(0, len(row), channels):
            r = row[i]
            g = row[i + 1]
            b = row[i + 2]
            a = row[i + 3] if channels == 4 else 255
            rgba.extend((r, g, b, a))
        rgba_rows.append(rgba)

    visited = [[False] * width for _ in range(height)]
    queue = deque()

    def enqueue(x, y):
        if x < 0 or y < 0 or x >= width or y >= height or visited[y][x]:
            return
        pixel = x * 4
        if not background_candidate(rgba_rows[y][pixel], rgba_rows[y][pixel + 1], rgba_rows[y][pixel + 2]):
            return
        visited[y][x] = True
        queue.append((x, y))

    for x in range(width):
        enqueue(x, 0)
        enqueue(x, height - 1)
    for y in range(height):
        enqueue(0, y)
        enqueue(width - 1, y)

    while queue:
        x, y = queue.popleft()
        enqueue(x + 1, y)
        enqueue(x - 1, y)
        enqueue(x, y + 1)
        enqueue(x, y - 1)

    for y in range(height):
        row = rgba_rows[y]
        for x in range(width):
            if not visited[y][x]:
                continue
            pixel = x * 4
            row[pixel + 3] = alpha_for_background(row[pixel], row[pixel + 1], row[pixel + 2], row[pixel + 3])

    write_rgba_png(out_path, width, height, rgba_rows)


def run(command):
    subprocess.run(command, check=True)


def main():
    if not SOURCE.exists():
        print(f"Missing {SOURCE}", file=sys.stderr)
        return 1

    if ICONSET.exists():
        for item in ICONSET.iterdir():
            item.unlink()
    else:
        ICONSET.mkdir(parents=True)

    for size, name in OUTPUTS:
        target = ICONSET / name
        image_size = max(1, min(size, round(size * ICON_IMAGE_SCALE)))
        run(["/usr/bin/sips", "-s", "format", "png", "-z", str(image_size), str(image_size), str(SOURCE), "--out", str(target)])
        make_transparent(target, target)
        remove_connected_dark_tile(target, target)
        compose_app_icon(target, target, size)
        if size == 1024:
            TRANSPARENT.write_bytes(target.read_bytes())

    if ICNS.exists():
        ICNS.unlink()
    run(["/usr/bin/iconutil", "-c", "icns", str(ICONSET), "-o", str(ICNS)])
    print(ICNS)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
