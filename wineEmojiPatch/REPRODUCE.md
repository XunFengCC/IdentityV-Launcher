# Wine 单色组合 Emoji 复现

本目录保存可审阅的 0002 补丁、生成器、Unicode 15.1 序列数据和测试源码；不含任何字体二进制。0002 应在已应用
`0001-gdi32-shape-valid-surrogate-pairs.patch` 的同一 CodeWeavers Wine 26.1 源码树根目录应用：

```sh
patch -p1 < /path/to/0002-uniscribe-rgi-composite-emoji.patch
```

补丁新增的 `dlls/gdi32/uniscribe/emoji_rgi_sequences.h` 与
`repro/emoji_rgi_sequences.h` 相同，SHA-256 必须为：

```text
0edb20f186c6771ef0b91226a91b7d6f2ef7cb5d97cd1a1a7a1f9715a285ae25
```

它按首个 Unicode scalar 分桶，最长匹配 Unicode Emoji 15.1 的 2,384 条 RGI
序列、12 条键帽序列及 953 条仅去掉 VS16 的对应形式。非完整匹配、普通文本、孤立肤色修饰符和无效
ZWJ 不会进入组合 run。输入数据和 Unicode License v3 在 `repro/unicode-15.1/` 与
`licenses/Unicode-License-v3.txt`；两个输入 SHA 分别为：

```text
emoji-sequences.txt      eb72c9115e3504fbbe1c8621b619f879471a46ccc56e2f445417b7c1cad050d1
emoji-zwj-sequences.txt  9a76a03dcacfcd8f9bfe08c49c8d90b55182b977cbcc87a694e8a8193efb0e57
```

## 字体生成

v6 的 `--base-font` **不是任意 Arial 字体**。先准备不改动的 Arial Unicode 原字体和
Google Noto Emoji 可变字体，安装 `fontTools` 与 `hb-shape`，生成 v1 基底：

```sh
python3 repro/build_base_font.py \
  --arial-unicode-font '/System/Library/Fonts/Supplemental/Arial Unicode.ttf' \
  --noto-font /path/to/NotoEmoji-wght.ttf \
  --output-font /tmp/IdentityV-Local-Emoji-Test-base.ttf
```

审核环境中该基底的 SHA-256 为
`c706486b219f097dd8b1093c7d9fc718546a324bf0c911136f9be554a9f16efb`。再以它作为
v6 输入。Noto 输入字体的本次 SHA-256 是
`de6c18832938afc99caf132b39d6a30a19bac7f2e812e28db2535b4608d27551`。Noto Emoji
适用的 OFL 1.1 全文在 `licenses/Noto-Emoji-OFL-1.1.txt`。派生字体还包含系统 Arial Unicode 字形，仅供本机使用，不提交字体二进制或加入公共发行包；Noto 的 OFL 不能替代另一来源的许可。

```sh
python3 repro/build_font_v6.py \
  --base-font /tmp/IdentityV-Local-Emoji-Test-base.ttf \
  --noto-font /path/to/NotoEmoji-wght.ttf \
  --output-font /tmp/IdentityV-Local-Emoji-Test.ttf \
  --work-dir /tmp/emoji-font-work \
  --report /tmp/emoji-font-report.txt
```

默认 family 是 `IdentityV Local Emoji Test`。审计版本的输出 SHA-256 为
`f782b20e17155e349347ca83fbcb99dea658b9614e5504c64b97faef13e336e8`；脚本固定该版本
的 TrueType modified 时间戳，使相同输入可以字节复现。字体审计结果：50,377 个原有
glyph 和 metrics 保持不变。

如只需重建序列 header：

```sh
python3 repro/generate_emoji_rgi_header.py \
  --output /path/to/wine/dlls/gdi32/uniscribe/emoji_rgi_sequences.h
```

## Windows/Wine 回归

两份测试不写死用户名或本机路径。用 mingw 编译，分别传入 Windows 侧字体路径、family
和 BMP 输出路径：

```sh
x86_64-w64-mingw32-gcc -O2 -municode repro/compositeRegression.c \
  -o compositeRegression.exe -lgdi32 -luser32 -lusp10
x86_64-w64-mingw32-gcc -O2 -municode -Irepro repro/compositeSweep.c \
  -o compositeSweep.exe -lgdi32 -luser32 -lusp10

wine compositeRegression.exe 'C:\fonts\IdentityV-Local-Emoji-Test.ttf' \
  'IdentityV Local Emoji Test' 'C:\emoji-composite.bmp'
wine compositeSweep.exe 'C:\fonts\IdentityV-Local-Emoji-Test.ttf' \
  'IdentityV Local Emoji Test'
```

审计结果为 31 项可视回归失败 0，3,349 条 sequence sweep 失败 0。最终 PE 的
SHA-256：`3aa45d33ab949a188f3249d0a6ecdb7793f141eefa10d631e404dfe78464de48`。
实机游戏聊天 A--N 已通过：肤色、职业合成和国旗均正确显示。
