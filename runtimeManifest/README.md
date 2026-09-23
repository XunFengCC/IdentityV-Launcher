# Runtime manifest contract

`runtime-catalog.json` is shipped read-only inside the app. It is the trust
boundary: it names the only approved engine IDs and launch profiles, the two
relative executables each profile may use, and integrity hashes for critical
runtime files. `verificationFiles` has stable logical keys (`wine`,
`wineserver`, `dxmt`, `moltenVK`, `winemac`, `gmp`, `pcre2`, and `zstd`) rather than filesystem paths as JSON
keys, so it is safe to address through `plutil`. It deliberately contains no
absolute paths, shell commands, or arbitrary environment variables.

`capabilities.coreAudioCapturePolicy` is also part of that read-only engine
contract. `rebinder-filter-required` means the runtime still enumerates every
macOS capture device and the runner must load the verified local
`rebinder-filter`; `runtime-default-input-only` means the runtime contains the
source-level default-input patch and must not receive the interposer a second
time. `unmanaged` keeps legacy fallback behavior unchanged. For the first two
values the catalog policy wins over stale `launcher.env` values in both
directions: an LKG user cannot silently turn the required filter off, and a
later self-built runtime cannot inherit an old interposer and double-inject it.
This also makes a clean user installation behave like the tested development
configuration.

`wine11-codeweavers-26_1-dxmt-0_80-selfbuilt-gnutls-macos15-r4` is a distinct
maintainer candidate, not a replacement for
`wine11-codeweavers-26_1-dxmt-0_80-macos15-alpha1-r1`. Its catalog record
requires an explicit isolated-prefix selection and names r1 as fallback; its
mere presence never makes it an installer default. r4 explicitly records
`runtime-default-input-only`, `without-gstreamer`, and
`verified-game-native-dynamic-only`: it must not receive the legacy audio
rebinder, it does not bundle a GStreamer media closure, and its
`d3dcompiler_47.dll` must be the verified game-native DLL staged dynamically
into an isolated prefix rather than Wine's builtin DLL. `moltenVK` is likewise
recorded as not bundled instead of borrowing r1's hash. Before r4 can enter a
distribution, its corresponding sources and notices still have to ship.

`runtime-binding.json` is the per-user writable runtime-only binding; it is
created only after `IdentityVRuntimeBootstrap` downloads the original upstream
DMG, verifies it, applies the four bundled patch payloads and publishes its
`current` directory atomically. `installation.json` is written only after a
complete mainland game/prefix publish; the global runner combines the runtime
binding with its complete product record. Every engine key must exist in the
catalog. The launcher must reject unknown
engine IDs/profiles, missing UUIDs, malformed hashes, absolute paths, and
relative paths that escape their mounted volume.

## Switching and verification

2026-09-08：r1的新prefix也实测出现builtin D3DCompiler无法编译
`terrain_mojin`中的`isnan`。r1现在声明
`verified-game-native-when-manifest-present`：全新国服尚无游戏生成的
`Documents/engine_patch_check.file`时允许首启并记录延后；下一次启动若清单已存在，
必须按官方size/MD5、唯一CEF路径、PE64及prefix边界校验安装游戏原生DLL。
不存在才延后，损坏/悬空链接清单不放行；r4的强制策略不变。
该策略不随runtime分发游戏DLL，也不清理shader cache。

Write a complete candidate `installation.json` beside the current one, parse it
and resolve all three locations, then check the catalog's critical-file SHA-256
values before atomically replacing the live file. Do not change
`selectedEngineId` in place. A successful game entry/exit records that ID as
`lastKnownGoodEngineId`; a failed preflight or launch leaves the previous file
in place or selects only the already recorded last-known-good catalog entry.

The observed Wine 11 bundle contains DXMT 0.80 and MoltenVK 1.4.1. The legacy
Wine 10 bundle identifies itself as `wine sikarugir 10.0 (revision 6)`; a DXMT
version string and a bundled MoltenVK library were not found, so neither is
invented here. Neither bundle currently supplies a verified redistributable
license/notice reference. That is an explicit public-release blocker: replace
each `licenseNotice` placeholder with an audited, shipped notice bundle before
distribution.

## 自产 runtime 的隔离规则

2026-08-30 起，项目会探索一套不依赖 yanyun `DWRG.dmg` 的自产 Wine 11 +
DXMT runtime。当前 `wine11-codeweavers-26_1-dxmt-0_80-macos15-alpha1-r1`
仍是摘要锁定、已实测的 fallback/last-known-good，不能被构建实验原地改写。

自产候选必须拥有新的 engine/version ID、不可变版本目录、完整关键文件摘要和独立
prefix；在 macOS 27 的分层门通过前，不得更新 `current`、`runtime-binding.json`、
任何游戏安装记录或 RC 默认引擎。`IdentityVProductManager` 目前仍把 Alpha engine ID
写死为上述 fallback，`RuntimeBootstrap` 也只接收单一 manifest；因此“只往 catalog
增加一项”不会让新候选进入安装链。真正接入前必须先把 bootstrap manifest 路由和
产品管理器选择改成显式、可回退的多 engine 契约。

把现有 yanyun runtime 做 APFS clone 仍可用于单模块 A/B，但不能被称为自产候选。
自产定义要求 CodeWeavers Wine、DXMT、MoltenVK 与实际 native closure 都有明确的
上游、源码/官方产物身份、构建记录、BOM、许可材料、ABI/rpath/minOS 审计和哈希。

## 自建产物的 macOS 最低版本门

我们自己编译的启动入口、CoreAudio 候选和高密度指标工具统一以
`-mmacosx-version-min=14.0` 构建。`auditMachODeploymentTargets.command` 只读
检查 Mach-O 的 `LC_BUILD_VERSION`；默认递归检查项目 App 与上述自建产物，任一
`minos` 高于 macOS 14.0 即失败，并报告所检查二进制的最高值。各自的构建/暂存脚本都会调用它，避免本机 SDK
升级后静默把产物抬高。

这只是**自建层**的门，不能据此宣称整条 Wine 链已支持 macOS 14。Alpha 1 选定的
`wine11-codeweavers-26.1-dxmt-0.80-macos15-alpha1-r1` 经过完整 Mach-O 盘点，最高
最低版本为 macOS 15.0（DXMT）；它是 macOS 15 的候选，不是 macOS 14 支持声明。其
ClipCursor `winemac.so` 已独立降到 macOS 14，但完整 closure 仍需要 DXMT 和其余依赖
重新构建，才可能降低整槽下限。

`auditWineRuntimeCompatibility.command [runtime-dir]` 是运行时的只读盘点：递归列出
每个含 `LC_BUILD_VERSION` 的 Mach-O 及其最低系统版本，并特别标注 Wine macOS
driver、DXMT Unix module 与 GMP/PCRE2/zstd closure。它不启动 Wine，也不读取或修改
prefix；用于区分“我们能重建的依赖”与上游 DXMT/Wine 组件。

2026-08-29 的实际盘点、ClipCursor macOS 14 隔离候选与三层阻塞结论见
[`macosCompatibilityAudit.md`](macosCompatibilityAudit.md)。
