#!/usr/bin/env python3
"""Create a local-only Arial Unicode MS derivative with Noto Emoji glyphs."""
from copy import deepcopy
import argparse
from pathlib import Path
from fontTools.ttLib import TTFont
from fontTools.ttLib.tables._c_m_a_p import cmap_format_12
from fontTools.varLib.instancer import instantiateVariableFont

parser = argparse.ArgumentParser(description='Build the Arial Unicode + Noto Emoji v1 base font.')
parser.add_argument('--arial-unicode-font', type=Path, required=True)
parser.add_argument('--noto-font', type=Path, required=True)
parser.add_argument('--output-font', type=Path, required=True)
parser.add_argument('--family', default='IdentityV Local Emoji Test')
parser.add_argument('--head-modified', type=int, default=3871834854,
                    help='TrueType epoch timestamp; default reproduces the audited v1 base.')
args = parser.parse_args()
BASE, NOTO, OUT, FAMILY = args.arial_unicode_font, args.noto_font, args.output_font, args.family

base = TTFont(BASE)
noto = instantiateVariableFont(TTFont(NOTO), {'wght': 400}, inplace=False)
base_map, noto_map = base.getBestCmap(), noto.getBestCmap()
base_glyf, noto_glyf = base['glyf'], noto['glyf']
base_hmtx, noto_hmtx = base['hmtx'], noto['hmtx']
base_order = base.getGlyphOrder()

def copy_glyph(name):
    if name in base_glyf.glyphs:
        return name
    glyph = deepcopy(noto_glyf[name])
    if glyph.isComposite():
        for component in glyph.components:
            component.glyphName = copy_glyph(component.glyphName)
    base_glyf.glyphs[name] = glyph
    base_hmtx.metrics[name] = noto_hmtx.metrics[name]
    base_order.append(name)
    return name

copied = 0
for codepoint, name in noto_map.items():
    if codepoint not in base_map:
        base_map[codepoint] = copy_glyph(name)
        copied += 1

base.setGlyphOrder(base_order)
base['maxp'].numGlyphs = len(base_order)
for table in base['cmap'].tables:
    if table.isUnicode():
        table.cmap = dict(base_map) if table.format in (12, 13) else {cp: name for cp, name in base_map.items() if cp <= 0xffff}
if not any(table.isUnicode() and table.format in (12, 13) for table in base['cmap'].tables):
    table = cmap_format_12(12)
    table.platformID, table.platEncID, table.language, table.cmap = 3, 10, 0, dict(base_map)
    base['cmap'].tables.append(table)

for record in base['name'].names:
    if record.nameID in (1, 4, 16):
        record.string = FAMILY.encode('utf-16-be') if record.isUnicode() else FAMILY.encode('mac_roman')
    elif record.nameID == 2:
        record.string = 'Regular'.encode('utf-16-be') if record.isUnicode() else b'Regular'
    elif record.nameID == 6:
        value = 'IdentityVLocalEmojiTest-Regular'
        record.string = value.encode('utf-16-be') if record.isUnicode() else value.encode('mac_roman')

OUT.parent.mkdir(parents=True, exist_ok=True)
base['head'].modified = args.head_modified
base.recalcTimestamp = False
base.save(OUT)
print(f'base_glyphs={len(base.getGlyphOrder())} copied_codepoints={copied} output={OUT}')
for cp in (0x41, 0x4e2d, 0x1f600, 0x1f602, 0x1f62d, 0x1f621, 0x1f44d):
    print(f'U+{cp:04X}={base.getBestCmap().get(cp)}')
