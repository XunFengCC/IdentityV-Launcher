#!/usr/bin/env python3
"""Build a redistributable CJK/emoji base from the two pinned OFL fonts.

Noto Sans CJK's full variable TTF occupies all 65,535 glyph slots. Pass a
static, cmap-subset copy so emoji glyphs fit. The source font itself is left
untouched. See wineEmojiPatch/README.md for exact inputs and license terms.
"""

import argparse
from pathlib import Path

from fontTools.pens.transformPen import TransformPen
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.pens.recordingPen import DecomposingRecordingPen
from fontTools.ttLib import TTFont


parser = argparse.ArgumentParser()
parser.add_argument("--cjk-font", type=Path, required=True)
parser.add_argument("--emoji-font", type=Path, required=True)
parser.add_argument("--output-font", type=Path, required=True)
parser.add_argument("--family", default="IdentityV Emoji CJK")
args = parser.parse_args()

base = TTFont(args.cjk_font)
emoji = TTFont(args.emoji_font)
if "fvar" in base:
    parser.error("CJK input must first be subset and instantiated at wght=400")
if "glyf" not in base or "glyf" not in emoji:
    parser.error("both inputs must contain TrueType outlines")

base_map = base.getBestCmap()
emoji_map = emoji.getBestCmap()
order = base.getGlyphOrder()
# Wine's GDI bridge needs a real empty zero-width glyph for controls that
# Uniscribe blanks. The CJK subset omits U+200B, so a missing-glyph fallback
# would otherwise give isolated joiners the width of a space.
if 0x200B not in base_map:
    blank_name = "idvZeroWidthSpace"
    base["glyf"].glyphs[blank_name] = TTGlyphPen(None).glyph()
    base["hmtx"].metrics[blank_name] = (0, 0)
    base_map[0x200B] = blank_name
    order.append(blank_name)
scale = base["head"].unitsPerEm / emoji["head"].unitsPerEm
source_set = emoji.getGlyphSet()
copied = 0
for codepoint, source_name in emoji_map.items():
    if codepoint in base_map:
        continue
    target_name = "idvEmoji_" + source_name
    if target_name not in base["glyf"].glyphs:
        pen = TTGlyphPen(None)
        recording = DecomposingRecordingPen(source_set)
        source_set[source_name].draw(recording)
        recording.replay(TransformPen(pen, (scale, 0, 0, scale, 0, 0)))
        base["glyf"].glyphs[target_name] = pen.glyph()
        advance, lsb = emoji["hmtx"].metrics[source_name]
        base["hmtx"].metrics[target_name] = (round(advance * scale), round(lsb * scale))
        order.append(target_name)
    base_map[codepoint] = target_name
    copied += 1

if len(order) > 65535:
    parser.error(f"too many glyphs for TrueType: {len(order)}")
base.setGlyphOrder(order)
base["maxp"].numGlyphs = len(order)
for table in base["cmap"].tables:
    if table.isUnicode():
        table.cmap = (
            dict(base_map) if table.format in (12, 13)
            else {cp: name for cp, name in base_map.items() if cp <= 0xFFFF}
        )

for record in base["name"].names:
    if record.nameID in (1, 4, 16):
        value = args.family
    elif record.nameID == 2:
        value = "Regular"
    elif record.nameID == 6:
        value = "IdentityVEmojiCJK-Regular"
    else:
        continue
    record.string = value.encode("utf-16-be") if record.isUnicode() else value.encode("mac_roman")

base["head"].modified = 3873043200
base.recalcTimestamp = False
args.output_font.parent.mkdir(parents=True, exist_ok=True)
base.save(args.output_font)
print(f"output={args.output_font} glyphs={len(order)} copied_codepoints={copied}")
