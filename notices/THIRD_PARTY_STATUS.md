# Alpha 1 第三方组件、许可与分发门

范围：这是发布前的许可台账，不是法律意见。它刻意分开三个问题：源码许可证是否允许再分发、当前机器上的**预编译文件**是否有可证明的再分发权、以及随包时还缺哪些 notice/源码材料。游戏本体、游戏更新、网易下载核心和商标不随 Alpha 包分发；技术上能下载不等于获得这些内容的再分发许可。

## 结论先行

| 组件/版本 | 当前事实 | 源码许可 | 当前预编译文件能否进 Alpha 包 | 发布结论 |
| --- | --- | --- | --- | --- |
| `idv-login` 6.3.0 stable | 主 App 不含 `idv-login.raw` 或任何上游二进制；用户明确启用时才从固定上游 Release 直接下载，并校验大小、SHA-256 与 arm64 Mach-O | 源文件声明 GPL-3.0-or-later | **不进入 RC1 发行包** | 本项目不重分发该二进制或其含 Windows payload 的 codeload 归档；随发行材料仅给 GPL 原文和精确上游 tag/commit/source 获取说明。 |
| Wine 11 / CodeWeavers 26.1 基础 runtime | Alpha 1 以固定 URL/大小/SHA-256 从 `novak037/yanyun-on-mac` v0.1.2 的原始 GitHub Release 直接取得 `DWRG.dmg`；我们的包和下载站均不夹带或镜像它 | 上游项目标注 LGPL-2.1，闭包各组件许可证不同 | **不进入 Alpha 包** | 自动获取只解决“本项目不二次分发该基础闭包”；不等于替上游补全全部履约材料，也不授权以后改为自建镜像。 |
| 本项目 runtime patch payloads | 随包仅带自建 `winemac.so`、GMP 6.3.0、PCRE2 10.47、zstd 1.5.7 四枚替换文件 | LGPL-2.1-or-later；GMP 双许可；PCRE2 BSD；zstd BSD/GPLv2 | **可以，条件式** | 必须随附精确源码、补丁/构建配方和所选许可证文本；构建脚本逐枚验 hash，不能把基础 runtime 一并拷入。 |
| DXMT 0.80 | 本机源码 tag `v0.80` = commit `589adb780…` | MIT | **源码/自行构建物可；当前 bundle 中的二进制不能单独证明** | 仅作为可追溯的 v0.80 自建物才可入包，并保留 MIT notice。 |
| MoltenVK 1.4.1 | runtime 库字符串报告 1.4.1，catalog 有 hash | Apache-2.0 | **源码/自行构建物可；当前 bundle 来源不足** | 需保留 Apache-2.0、版权和上游 `NOTICE`（如该发行含有）。 |
| GStreamer native closure | runtime 含 GStreamer/GLib/GnuTLS 等，未附逐包 source/BOM/notice | 多许可证 | **不可以（当前形态）** | 先补精确 BOM、源码/offer、插件列表和全部 notice。 |
| 自建 Go helpers | 下载监督器的编译依赖为 `zmq4 v0.17.0`、`x/sync v0.7.0`、`x/text v0.15.0`；planner/global 为 `xxhash/v2 v2.3.0` | BSD-3-Clause / MIT | **可以，条件式** | 以最终二进制的 `go list -deps` 复核实际编入模块并汇总 notice。 |
| 网易下载核心 | 首次使用时按固定 commit+hash 获取，不放入安装包 | 未审计 | **不可以** | 保持不随包分发；首次下载不等于取得网易再分发授权。 |

## runtime 的 Alpha 1 获取路线

`runtime-catalog.json` 中的 hash 只能证明启动器要检查哪些文件，不能证明发行权。虽然本机有 `crossover-sources-26.1.0.tar.gz`（SHA-256 `e4ec87d…`），它只能证明取得过一份源码，**不能自动授权本项目二次托管一整份第三方预编译闭包**，也不能替代完整 runtime closure 的对应源码。

Alpha 1 采用“不二次分发基础闭包”的开箱路线：

- Alpha 包和本项目下载站均不含 `DWRG.dmg`、Wine/DXMT/MoltenVK/GStreamer 基础 runtime；
- 启动器只从 `novak037/yanyun-on-mac` v0.1.2 的原始 GitHub Release URL 下载 `DWRG.dmg`，固定校验 `326,791,695` bytes 与 SHA-256 `69b79d250b794af8289b6e57e50c675d5ba37b7bd6bd74dbc3dee392f5248a96`，再在用户本机只读挂载、提取和组装；
- GitHub Release API 自身公布的 asset 名称、大小、URL 和 digest 与本地 manifest 一致；上游仓库以 LGPL-2.1 发布自身代码，并列出基础 runtime 的主要第三方组件；
- 随我们的包分发的只有四枚自建 patch payload，因此对它们单独履行 LGPL/GMP/PCRE2/zstd 的源码、修改、构建和 notice 义务。

这条路线保留两项边界：用户最终仍直接取得上游 release，我们不替上游保证其全部闭包履约；如果将来把该 DMG 改放到自己的网站、GitHub Release 或镜像，完整基础 runtime 的 BOM/源码/notice 审计会立刻重新成为发布门。长期仍可选择从公开源码重建完整 runtime，但不是 Alpha 1 的前置。

## 应随发行物提供的材料

### idv-login 6.3.0 stable

- 发行 tag：[`v6.3.0-stable`](https://github.com/KKeygen/idv-login/releases/tag/v6.3.0-stable)，精确源 commit：[`389d23a7763fe9e5985cb77a3114b8c4dcb670e1`](https://github.com/KKeygen/idv-login/tree/389d23a7763fe9e5985cb77a3114b8c4dcb670e1)。
- 许可证原文：[`LICENSE` (GPL-3.0)](https://github.com/KKeygen/idv-login/blob/389d23a7763fe9e5985cb77a3114b8c4dcb670e1/LICENSE)。2026-09-23 从该 commit 的原始文件复验 SHA-256 为 `3972dc97…36986`，与锁定值相同；即使许可证文本未变，也要把来源指向实际发行版本。
- 上游 codeload archive 在该精确 commit 内含 `assets/mpay.dll`、`binaries/OrbitSDK.dll`、`binaries/aria2c.exe`、`binaries/downloadIPC.exe` 与嵌套 `downloadIPC.zip`。这些文件没有在本项目的许可台账中得到独立的再分发授权；GPL 覆盖 idv-login 源码，并不自动许可这些嵌套文件。
- Alpha 材料包只提供 GPL 文本和精确 upstream commit/tag/source 获取说明，**不**再附这个 archive。上游行为可能获得网易容忍，不等于本项目有可审计的二次分发许可。
- Alpha 1 已落地“用户机器从上游 Release 直接下载并 hash 校验”；构建与封包脚本均 fail closed 拒绝 `idv-login.raw` 及上游 macOS asset。若以后改为本项目夹带或镜像该二进制，PyInstaller/PyQt/Qt 闭包的 SBOM、许可证/NOTICE、对应源码/构建信息和再分发权审计会立即重新成为发布门。

### Wine 与本项目补丁

- Wine 许可证原文：[`COPYING.LIB` (LGPL-2.1-or-later)](https://gitlab.winehq.org/wine/wine/-/blob/wine-11.0/COPYING.LIB)。
- 若发行任意基于 Wine 的修改二进制（含 ClipCursor/CoreAudio），至少要给 LGPL 文本、对应 Wine 源版本、全部 patch、准确 configure/build flags、依赖来源，以及使收件人能修改/重建/替换 LGPL 部分的材料。
- Alpha 1 的 `winemac.so` 来自 CodeWeavers 26.1 对应源码包 `crossover-sources-26.1.0.tar.gz`，应用上游 `eefbbc07` ClipCursor reset 补丁后以 `MACOSX_DEPLOYMENT_TARGET=14.0` 自建；发行材料要带源码 URL/哈希、该补丁、实际构建脚本和 LGPL 文本。
- 基础 CodeWeavers runtime 的完整 closure 不进入我们的包；若以后改变这一点，仍不能被“Wine 是 LGPL”一句覆盖。

### GMP / PCRE2 / zstd 替换库

- GMP 6.3.0：官方 `gmp-6.3.0.tar.xz`，归档 SHA-256 `a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898`。发行时明确选择其可适用的 LGPL 路径，随附对应文本、完整源码与实际构建参数。
- PCRE2 10.47：官方 release 归档 SHA-256 `47fe8c99461250d42f89e6e8fdaeba9da057855d06eb7fc08d9ca03fd08d7bc7`，随附 BSD notice、源码 URL/哈希和构建记录。
- zstd 1.5.7：官方 release `zstd-1.5.7.tar.zst`，SHA-256 `5b331d961d6989dc21bb03397fc7a2a4d86bc65a14adc5ffbbce050354e30fd2`，发行时采用其 BSD 路径并随附 notice、源码 URL/哈希和构建记录。
- 三枚库均以 `clang -arch x86_64 -mmacosx-version-min=14.0` / `MACOSX_DEPLOYMENT_TARGET=14.0` 自建；精确二进制哈希与 ABI 边界见 [`../runtimeManifest/dependencyCompatibilityClosure.md`](../runtimeManifest/dependencyCompatibilityClosure.md)。

### DXMT 0.80 与 MoltenVK 1.4.1

- DXMT：[`v0.80`](https://github.com/3Shain/dxmt/tree/v0.80)，精确 commit `589adb780354b461645b29999cefaf533594ee99`，[`MIT LICENSE`](https://github.com/3Shain/dxmt/blob/v0.80/LICENSE)。保留版权和许可证；修改时标记修改和构建版本。
- MoltenVK：[`v1.4.1`](https://github.com/KhronosGroup/MoltenVK/tree/v1.4.1)，精确 commit `db445ff2042d9ce348c439ad8451112f354b8d2a`，[`Apache-2.0 LICENSE`](https://github.com/KhronosGroup/MoltenVK/blob/v1.4.1/LICENSE)。保留许可证、版权/归属，以及该发行所含的 `NOTICE`（若有）。

二者的开源许可允许按其条件分发源码或自行构建对象；这不倒推出当前 CodeWeavers bundle 中同名库的来源或再分发权。

### GStreamer 与 native closure

`winegstreamer.so` 直接加载 GStreamer core、base/audio/video/tag、GLib/GObject/GIO 和 gettext；runtime 还携带 GnuTLS、GMP、Nettle/Hogweed、p11-kit、libtasn1、libidn2、libunistring、PCRE2、zstd、SDL2、FreeType、libffi、libpng、ORC 等。当前仅能以 `otool`/文件名识别部分库，不能可靠断定每枚的精确版本、编译选项、插件集合或完整许可证。

若以后改为由本项目打包、镜像或再分发这份基础闭包，必须先生成：

1. 逐文件 BOM（hash、上游、精确版本/commit、许可证、来源、修改状态）；
2. 每个 copyleft 项的完整对应源码与构建配方，或符合许可证的 source offer；
3. 全部许可证及上游 NOTICE；
4. 插件目录和动态加载路径的实测清单，避免漏掉 GPL/专有插件。

GStreamer 的上游许可入口是 [source COPYING](https://gitlab.freedesktop.org/gstreamer/gstreamer/-/blob/main/COPYING)，但这只覆盖上游项目，不覆盖本 runtime 中的所有库。

### 自建 Go binaries

对当前 `go list -deps` 所示的发行二进制，正式 `ThirdPartyNotices/` 至少应归档：

- [`go-zeromq/zmq4 v0.17.0` — BSD-3-Clause](https://github.com/go-zeromq/zmq4/blob/v0.17.0/LICENSE)；
- [`golang.org/x/sync v0.7.0` — BSD-3-Clause](https://cs.opensource.google/go/x/sync/+/refs/tags/v0.7.0:LICENSE)；
- [`golang.org/x/text v0.15.0` — BSD-3-Clause](https://cs.opensource.google/go/x/text/+/refs/tags/v0.15.0:LICENSE)；
- [`cespare/xxhash/v2 v2.3.0` — MIT](https://github.com/cespare/xxhash/blob/v2.3.0/LICENSE.txt)。

`gameDownloader/THIRD_PARTY_NOTICES.md` 目前只完整收录 zmq4；`goczmq/v4 v4.2.2`（MPL-2.0）虽出现在 `go.mod` 的间接模块图中，但当前 `go list -deps` 表明它未编入监督器。发布前必须依最终二进制的 `go list -deps` 补齐，不能因依赖是 indirect 就不作判断。

## 需要风吟拍板的发布决策

1. Alpha 1 已选定“基础 runtime 只从上游原始 release 获取、不由我们夹带或镜像”的路线；需要风吟最后确认发布页是否接受这段透明说明。
2. idv-login 已选定“用户机器从固定上游 Release 独立下载并 hash 校验”；Alpha 1 不随包内置或自建镜像。
3. 下载核心在产品页的表述。建议维持“不随包分发、首次使用单独取得”，且不声称已获网易授权。
4. “完整自建、可由本项目独立分发的 runtime”保留为后续工程，不再阻塞 Alpha 1。

## 打包门

- [ ] 最终 DMG/zip 的 `ThirdPartyNotices/` 有实际许可证文本，不只是网页链接。
- [x] 最终 App 与 ZIP 不含 idv-login raw 或上游二进制；仅含固定上游 URL/大小/SHA-256 的按需下载器和 GPL/source 获取说明。
- [ ] 打包脚本证明不含 `DWRG.dmg` 或基础 Wine runtime，只含 RuntimeBootstrap、固定 manifest 和四枚 hash 锁定 patch payload。
- [x] `winemac.so`、GMP、PCRE2、zstd 的许可证原文、完整精确源码归档、URL/哈希、补丁和实际构建说明已由 `prepareReleaseNotices.command` 生成；打包时仍须把这一代材料与二进制放在同一发行位置。
- [ ] 若含 DXMT/MoltenVK：MIT/Apache 文本、版权/NOTICE、精确构建出处入包。
- [ ] 若含 GStreamer closure：BOM、源码/offer、插件清单和所有 notice 已归档。
- [x] ReleaseMaterials 生成器递归拒绝 `downloadIPC`、`OrbitSDK`、`aria2`、`mpay`、DWRG 与常见游戏 payload；仍须对最终 Preview ZIP 再做独立审计。
- [ ] 发行页不暗示网易、CodeWeavers、WineHQ、DXMT 或 Khronos 对本项目背书。

## Alpha 1 生成入口

[`prepareReleaseNotices.command`](prepareReleaseNotices.command) 与
[`releaseMaterialsManifest.tsv`](releaseMaterialsManifest.tsv) 是 Alpha 1 的可重复
材料入口。它生成忽略的 `.build/ReleaseMaterials/ThirdPartyNotices/` 和
`.build/ReleaseMaterials/CorrespondingSources/`，并在构建后写入完整 SHA-256 清单。
每项下载都锁定 HTTPS 来源、允许主机、最大体积与哈希；idv-login 仅提供 GPL 原文与
精确 upstream commit/tag/source 获取说明，不重打包其含 Windows payload 的 archive。
CodeWeavers 26.1 的 149 MB source archive 作为明确的
同发行位置 source offer 给出，而不是偷偷进入 Alpha 包。
