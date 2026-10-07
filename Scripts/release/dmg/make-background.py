#!/usr/bin/env python3
"""生成 DMG 窗口背景（640×400，含 @2x），输出 background.tiff（Finder 按屏幕倍率自动选图）。

改动布局后重新运行：python3 Scripts/release/dmg/make-background.py
图标位置要与 dmg-settings.py 的 icon_locations 一致：Caplo 在 (180, 180)，应用程序在 (460, 180)。
"""
import subprocess
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = Path(__file__).resolve().parent
WIDTH, HEIGHT = 640, 400
APP, APPLICATIONS = (180, 180), (460, 180)
FONT = "/System/Library/Fonts/Hiragino Sans GB.ttc"


def render(scale: int) -> Image.Image:
    # PIL 画线不抗锯齿：按 4 倍尺寸画，最后缩回目标尺寸。
    final = (WIDTH * scale, HEIGHT * scale)
    scale *= 4
    w, h = WIDTH * scale, HEIGHT * scale
    s = lambda v: int(round(v * scale))
    # 底色：极浅的冷灰，从上到下略微加深，避免纯白显得空。
    image = Image.new("RGB", (w, h), (248, 248, 250))
    shade = Image.new("L", (1, h))
    shade.putdata([int(10 * y / h) for y in range(h)])
    image.paste((236, 236, 241), (0, 0, w, h), shade.resize((w, h)))

    # 品牌光晕：应用图标后面一团淡紫，提示"从这里拖"。
    glow = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse([s(APP[0] - 72), s(APP[1] - 72), s(APP[0] + 72), s(APP[1] + 72)], fill=(110, 110, 255, 34))
    glow = glow.filter(ImageFilter.GaussianBlur(s(28)))
    image = Image.alpha_composite(image.convert("RGBA"), glow)

    # 中间的箭头：细线 + 圆头箭尖，落在两个图标之间。
    draw = ImageDraw.Draw(image)
    color = (150, 146, 170, 255)
    y = s(APP[1] - 6)
    start, end = s(APP[0] + 84), s(APPLICATIONS[0] - 84)
    stroke = s(2.5)
    draw.line([(start, y), (end, y)], fill=color, width=stroke)
    head = s(11)
    draw.line([(end - head, y - head), (end, y), (end - head, y + head)], fill=color, width=stroke, joint="curve")
    # 线端补圆头，箭尖三个端点也补，避免方头。
    for x, yy in ((start, y), (end, y), (end - head, y - head), (end - head, y + head)):
        r = stroke / 2
        draw.ellipse([x - r, yy - r, x + r, yy + r], fill=color)

    # 底部一句安装提示。
    font = ImageFont.truetype(FONT, s(14))
    text = "将 Caplo 拖到“应用程序”即可安装"
    box = draw.textbbox((0, 0), text, font=font)
    draw.text(((w - (box[2] - box[0])) / 2, s(318)), text, font=font, fill=(110, 106, 126, 255))
    return image.convert("RGB").resize(final, Image.LANCZOS)


def main() -> None:
    one, two = HERE / "background.png", HERE / "background@2x.png"
    render(1).save(one)
    render(2).save(two)
    # 合成多倍率 TIFF：Finder 在视网膜屏上用 2x，其余用 1x。
    subprocess.run(["tiffutil", "-cathidpicheck", str(one), str(two), "-out", str(HERE / "background.tiff")], check=True,
                   capture_output=True)
    one.unlink()
    two.unlink()
    print(HERE / "background.tiff")


if __name__ == "__main__":
    main()
