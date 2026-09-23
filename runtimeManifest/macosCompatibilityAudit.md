# Wine 11 macOS compatibility audit

范围：本文件记录 2026-08-29 对外置盘 Wine 11 + DXMT 0.80 runtime 的**只读**
Mach-O 盘点与隔离构建结果。没有改写 `installation.json`、活动 prefix 或任何运行中
进程。

## 活动 runtime 的实际闭包门槛

`auditWineRuntimeCompatibility.command` 对
`runtimes/wine11-codeweavers-26.1-dxmt-0.80` 递归扫描到 82 个带
`LC_BUILD_VERSION` 的 Mach-O，最高为 macOS 26.0。影响分层如下：

| 组件 | minos | 来源/状态 | 影响 |
| --- | --- | --- | --- |
| `lib/wine/x86_64-unix/winemac.so` | 10.15 | CodeWeavers Wine 26.1 | 原版 Wine macOS driver 本身不挡 macOS 14。 |
| `lib/dxmt/x86_64-unix/winemetal.so` | 15.0 | DXMT 0.80 的已编译 builtin 包 | macOS 14 的第一项图形阻塞。 |
| `lib64/libgmp.10.dylib` | 26.0 | Wine runtime closure | macOS 14/15 的依赖阻塞。 |
| `lib64/libpcre2-8.0.dylib` | 26.0 | Wine runtime closure | 同上。 |
| `lib64/libzstd.1.dylib` | 26.0 | Wine runtime closure | 同上。 |

扫描器不运行 Wine；它只说明运行时内的二进制声明了什么最低系统版本。真正的
运行时加载路径还必须由发布前的冷机实测确认。

## ClipCursor 独立候选

`wine11-codeweavers-26.1-dxmt-0.80-clipcursor-reset-eefbbc07-macos14-r3` 是
APFS clone 的独立候选槽，只替换 `winemac.so`。它从本机已校验的
`crossover-sources-26.1.0.tar.gz`（SHA-256
`e4ec87d5821a009dd1f1d2e36ffe2e24b8fcbae9516375ea42f95a16928ab8fa`）构建，且
显式使用 `MACOSX_DEPLOYMENT_TARGET=14.0` 和
`-mmacosx-version-min=14.0`。

- 新 `winemac.so`：x86_64、`minos 14.0`、SHA-256
  `bd64b3bd5b53a0939a0535f62743a6a26cd3cd1d9e5b66a27e9456de37444e1a`。
- 已通过原有 ABI 导出、install-name 依赖、补丁反汇编、签名与 `wine --version`
  的无 UI 验证。
- 候选整槽仍为最高 `minos 26.0`：它保留了 GMP/PCRE2/zstd 三项 26.0 closure，
  以及 DXMT 15.0；因此它仅把光标修复模块降到 14，**不是 macOS 14 完整 runtime**。

## 依赖可复现性结论

本机归档确实包含 CodeWeavers/Wine 源码，足以重建 `winemac.so`，但最初没有一并
保存三枚 closure 的源码/配方。后续已从库本身确认精确版本，并从各自官方源重建
GMP 6.3.0、PCRE2 10.47 和 zstd 1.5.7 的 x86_64/minOS 14 候选。它们保持 dylib
identity/current/compatibility，且满足当前槽内静态消费者；与原库的严格导出超集仍
不同，所以在隔离 loader/game 冷烟测前不激活。完整证据见
[`dependencyCompatibilityClosure.md`](dependencyCompatibilityClosure.md)。

DXMT 的本地 `dxmt-v0.80-builtin.tar.gz` 只有 15 个已编译 module/DLL 文件。后续已从
官方 `3Shain/dxmt` 的 `v0.80` tag 取得精确源码；源码确认 macOS 14 使用 Metal 3.1，
macOS 15 才启用 Metal 3.2/AIR 路径。当前仍缺 LLVM 15、mingw-w64 与匹配 Wine build
tree，不能安全重建为 14；见
[`dxmt080MacOS14Compatibility.md`](dxmt080MacOS14Compatibility.md)。

## 当前可声明档位

- 自建 launcher / audio / metrics：macOS 14.0。
- ClipCursor 的替换 `winemac.so`：macOS 14.0（隔离候选，未激活）。
- 活动 runtime：静态部署目标最高 macOS 26.0。
- 三枚 closure 的隔离重建候选：静态部署目标最高降至 DXMT 的 macOS 15.0；尚未激活，
  不能据此宣称产品已经支持 15。
- macOS 14：需要可复现重建 DXMT，并在对应正式系统实测。

## 2026-08-29 macOS 15 Alpha 组合候选

在不改动活动 `-r2` 槽的前提下，已从两个未激活候选组合出第三个独立槽：
`runtimes/wine11-codeweavers-26.1-dxmt-0.80-macos15-alpha1-r1`。它以
`-macos14-deps-gmp-pcre2-zstd-r1` 为底，只换入
`-clipcursor-reset-eefbbc07-macos14-r3` 的 `winemac.so`；原候选和活动 runtime 均保留。

- `winemac.so` SHA-256：`bd64b3bd5b53a0939a0535f62743a6a26cd3cd1d9e5b66a27e9456de37444e1a`。
- GMP / PCRE2 / zstd SHA-256 依次为
  `b25b382a90dda844517078c7d3dda3a44bd4a10c99bbd86aad37b0a90c8d589a`、
  `09b6e680ccd8ca452a88d08981593237986ef58576a903290df74dd9a7696e00`、
  `d5894bcd6c7eac70765f7d5186c5c98537ee983d89f240b6a47b93bac1c7b314`。
- 全槽 82 枚 Mach-O 的最高 `minos` 为 15.0，仅剩 DXMT `winemetal.so` 构成上限。
- 新建 284 MiB 隔离 prefix 后，候选已通过 `wineboot -i`、`cmd /c ver`
  （Windows 10.0.19045）、Wine 注册表写入和精确 `wineserver -k/-w`；没有缺符号、
  loader 崩溃或残留进程。测试 prefix 已移入废纸篓，未触碰活动游戏。

这把 macOS 15 的门从“静态候选”推进到“本机 loader 已通过”，但仍不能代替真正
macOS 15 上的冷启动与游戏图形、音频、登录和对局验收。由于三枚重建 closure 的严格
原导出超集门仍不满足，它们的接受依据仍是当前槽内静态消费者交集为零加上述 loader
实测；发布说明必须保留这一已知边界。

不要将上述“最低声明版本”表述为产品已支持某版本；最终兼容承诺需要该版本 macOS
的干净系统冷启动、登录、图形、音频、网络和长局测试。
