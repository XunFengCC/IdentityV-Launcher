# ThirdPartyNotices 的使用说明

本目录是 RC1 的许可审计正本。打包阶段应复制成发行物内可见的 `ThirdPartyNotices/`，并在每次改变“包里有什么”后重新审核；它不替代法律意见。

项目原创的启动器、工具箱、helper 与相关源代码的根许可证是
[`GPL-3.0-or-later`](../LICENSE)。本目录的第三方材料、Wine/yanyun 衍生补丁、
游戏资源与 `idv-login` 均不因该选择改为 GPL；它们继续按各自许可证、来源和
再分发边界处理。

[THIRD_PARTY_STATUS.md](THIRD_PARTY_STATUS.md) 给出按精确 tag/commit 的公开许可证原文或直接来源。链接是审计依据；正式包对需要随附文本的许可证仍应实际附上原文，不能只放网页链接。

特别规则：开源项目不等于当前手上任意来源的预编译二进制都可由我们重新托管。RC1 不把 `DWRG.dmg` 或基础 Wine/GStreamer 闭包拷入 DMG/zip，而由启动器按固定 URL、大小和 SHA-256 从原作者 GitHub Release 直接取得。随包的四枚自建 runtime patch 仍须独立履行对应源码、补丁、构建信息和许可证义务；以后若改为本项目镜像基础 runtime，完整闭包审计会重新成为发布门。

`gameDownloader/THIRD_PARTY_NOTICES.md` 是 Go 下载监督器的局部 notice；当前 `ReleaseMaterials` 已按五个 helper 的依赖图把 `zmq4`、`x/sync`、`x/text`、`xxhash/v2` 的许可证和 `GO_MODULES.txt` 汇入 `ThirdPartyNotices/`。最终 helper 若改变依赖图，应先复核实际编入的模块再更新材料，不能仅从 `go.mod` 的 indirect 标记推断是否入包。

## RC1 可重复材料

运行 `./prepareReleaseNotices.command` 会从 [`releaseMaterialsManifest.tsv`](releaseMaterialsManifest.tsv) 的固定 HTTPS 来源重建忽略的 `.build/ReleaseMaterials/`。它校验重定向主机、文件上限、SHA-256、普通文件属性和可能泄露本机路径/会话字段，最后给出 `SHA256SUMS`。

生成物包含发行物应带的 `ThirdPartyNotices/` 与 `CorrespondingSources/`：idv-login 的 GPL 原文及精确 commit/tag/source 获取说明、GMP/PCRE2/zstd 源码、Wine LGPL 文本、ClipCursor patch/构建配方、CodeWeavers 精确源码归档与获取说明，以及实际编入五个 Go helper 的外部 module notice。

生成器也把当前 [`THIRD_PARTY_STATUS.md`](THIRD_PARTY_STATUS.md) 复制入材料包。改这份说明或锁定清单后，旧 `ReleaseMaterials.zip` 的内容与哈希不会自动更新；最终候选必须重新生成并与实际 App 组件对照。

它**不**下载或夹带 idv-login 的 codeload 源码归档：该归档在锁定 commit 中含 `downloadIPC.exe`、`OrbitSDK.dll`、`aria2c.exe`、`mpay.dll` 和嵌套下载器，不能借“完整源码”名义由本项目二次分发。生成器会递归检查 ZIP/TAR 内容，发现上述项目、DWRG 或常见游戏 payload 即拒绝生成。主 App 当前不捆绑 `idv-login.raw`；如果以后改为捆绑或镜像，PyInstaller/PyQt/Qt 闭包、原始 hash 与再分发路线会重新成为公开发布门。
