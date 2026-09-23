#!/usr/bin/env python3
"""Build a local font containing direct ligatures for Noto-supported RGI emoji.

Candidate sequences come only from Unicode 15.1 emoji-sequences and
emoji-zwj-sequences.  They are retained only if Noto Emoji's own ccmp shapes
the whole sequence into one non-.notdef glyph.  The resulting `emji` lookup is
simple LigatureSubst, the part of GSUB exercised by the isolated Wine patch.
"""
from copy import deepcopy
import argparse
from pathlib import Path
import re
import subprocess

from fontTools.ttLib import TTFont
from fontTools.feaLib.builder import addOpenTypeFeaturesFromString

HERE = Path(__file__).resolve().parent
parser = argparse.ArgumentParser(description='Build the local monochrome RGI emoji test font.')
parser.add_argument('--base-font', type=Path, required=True)
parser.add_argument('--noto-font', type=Path, required=True)
parser.add_argument('--unicode-dir', type=Path, default=HERE / 'unicode-15.1')
parser.add_argument('--output-font', type=Path, required=True)
parser.add_argument('--work-dir', type=Path, required=True)
parser.add_argument('--report', type=Path, required=True)
parser.add_argument('--family', default='IdentityV Local Emoji Test')
parser.add_argument('--head-modified', type=int, default=3871839578,
                    help='TrueType epoch timestamp; default reproduces the audited v6 binary.')
args = parser.parse_args()
BASE, NOTO, DATA, OUT, FAMILY = args.base_font, args.noto_font, args.unicode_dir, args.output_font, args.family
WORK, REPORT = args.work_dir, args.report
WORK.mkdir(parents=True, exist_ok=True)
TEXT = WORK / 'unicode-rgi-candidates-v6.txt'
HB = WORK / 'unicode-rgi-noto-ccmp-v6.txt'

def sequences():
    found = []
    seen = set()
    for name in ('emoji-sequences.txt', 'emoji-zwj-sequences.txt'):
        for raw in (DATA / name).read_text(encoding='utf-8').splitlines():
            raw = raw.split('#', 1)[0].strip()
            if not raw or ';' not in raw:
                continue
            field, kind = (part.strip() for part in raw.split(';', 1))
            # Keep standardized RGI sequences, not explanatory range records.
            if not (kind.startswith('RGI_') or kind.startswith('Emoji_Keycap_Sequence')) or '..' in field:
                continue
            points = tuple(int(value, 16) for value in field.split())
            if points not in seen:
                seen.add(points)
                found.append(points)
    return found

def cp_text(points):
    return ''.join(map(chr, points))

def shape_all(points_list, path):
    path.write_text(''.join(cp_text(points) + '\n' for points in points_list), encoding='utf-8')
    shaped = subprocess.check_output([
        'hb-shape', '--text-file=' + str(path), '--features=ccmp',
        '--no-glyph-names', '--show-line-num', str(NOTO),
    ], text=True)
    results = {}
    for line in shaped.splitlines():
        match = re.fullmatch(r'(\d+): \[(.*)\]', line)
        if not match:
            continue
        glyphs = [(int(g), int(advance)) for g, advance in
                  re.findall(r'(\d+)=\d+\+(-?\d+)', match.group(2))]
        substantive = [gid for gid, advance in glyphs if advance]
        if len(substantive) == 1 and substantive[0] != 0:
            results[int(match.group(1)) - 1] = substantive[0]
    return shaped, results

candidate = sequences()
shaped, out_gids = shape_all(candidate, TEXT)
HB.write_text(shaped, encoding='utf-8')

# If the monochrome source leaves modifier glyphs as separate advances, map a
# *legal RGI modifier sequence* to the Noto glyph of its exact tone-stripped
# sequence.  This preserves profession/family semantics while rendering the
# permitted single-colour form; isolated modifiers receive no ligature rule.
tones = set(range(0x1f3fb, 0x1f400))
normalized = []
normal_index = {}
for points in candidate:
    norm = tuple(point for point in points if point not in tones)
    if norm != points and norm not in normal_index:
        normal_index[norm] = len(normalized)
        normalized.append(norm)
normalized_text = WORK / 'unicode-rgi-normalized-v6.txt'
_, normalized_gids = shape_all(normalized, normalized_text)

base = TTFont(BASE)
noto = TTFont(NOTO)
base_map, noto_map = base.getBestCmap(), noto.getBestCmap()
base_glyf, noto_glyf = base['glyf'], noto['glyf']
base_hmtx, noto_hmtx = base['hmtx'], noto['hmtx']
base_order, noto_order = base.getGlyphOrder(), noto.getGlyphOrder()

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

def copy_output(name):
    target = 'notoEmojiLig_' + name
    if target in base_glyf.glyphs:
        return target
    glyph = deepcopy(noto_glyf[name])
    if glyph.isComposite():
        for component in glyph.components:
            component.glyphName = copy_glyph(component.glyphName)
    base_glyf.glyphs[target] = glyph
    base_hmtx.metrics[target] = noto_hmtx.metrics[name]
    base_order.append(target)
    return target

ligatures, skipped, normalized_count, vs16_variants = [], [], 0, 0
for index, points in enumerate(candidate):
    gid = out_gids.get(index)
    was_normalized = False
    if gid is None and any(point in tones for point in points):
        gid = normalized_gids.get(normal_index[tuple(point for point in points if point not in tones)])
        was_normalized = gid is not None
    if gid is None:
        skipped.append(points)
        continue
    components = []
    for point in points:
        name = base_map.get(point) or noto_map.get(point)
        if name is None:
            skipped.append(points)
            break
        components.append(copy_glyph(name))
    else:
        output = copy_output(noto_order[gid])
        ligatures.append((points, components, output))
        if was_normalized:
            normalized_count += 1
        # Wine's initial surrogate shaping may consume VS16 before GSUB.
        # Add the same direct rule without it, only for this exact emoji
        # component sequence; ordinary characters cannot satisfy the rule.
        no_vs16 = tuple(point for point in points if point != 0xfe0f)
        if no_vs16 != points:
            variant_components = []
            for point in no_vs16:
                name = base_map.get(point) or noto_map.get(point)
                if name is None:
                    break
                variant_components.append(copy_glyph(name))
            else:
                ligatures.append((no_vs16, variant_components, output))
                vs16_variants += 1

base.setGlyphOrder(base_order)
base['maxp'].numGlyphs = len(base_order)
fea = ['languagesystem DFLT dflt;', 'feature emji {']
for points, components, output in ligatures:
    fea.append(f"  sub {' '.join(components)} by {output};")
fea.append('} emji;')
addOpenTypeFeaturesFromString(base, '\n'.join(fea))

for record in base['name'].names:
    if record.nameID in (1, 4, 16):
        record.string = FAMILY.encode('utf-16-be') if record.isUnicode() else FAMILY.encode('mac_roman')
    elif record.nameID == 2:
        record.string = 'Regular'.encode('utf-16-be') if record.isUnicode() else b'Regular'
    elif record.nameID == 6:
        value = 'IdentityVEmojiCompositeV4-Regular'
        record.string = value.encode('utf-16-be') if record.isUnicode() else value.encode('mac_roman')

OUT.parent.mkdir(parents=True, exist_ok=True)
REPORT.parent.mkdir(parents=True, exist_ok=True)
base['head'].modified = args.head_modified
base.recalcTimestamp = False
base.save(OUT)
REPORT.write_text(
    f'Unicode RGI candidates: {len(candidate)}\n'
    f'Direct ligature rules (including VS16-free variants): {len(ligatures)}\n'
    f'Tone-normalized legal sequences: {normalized_count}\n'
    f'VS16-free variants: {vs16_variants}\n'
    f'Skipped (no one-glyph Noto result after legal tone normalization or missing component): {len(skipped)}\n'
    + ''.join('skipped ' + ' '.join(f'U+{point:04X}' for point in points) + '\n' for points in skipped),
    encoding='utf-8',
)
print(REPORT.read_text(encoding='utf-8').splitlines()[:3])
print(f'output={OUT} glyphs={len(base.getGlyphOrder())}')
