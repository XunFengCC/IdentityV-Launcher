# Wine runtime bootstrap（Alpha 1）

这个小型原生 arm64 helper 解决的只是 Wine runtime 的**取得、核验与原子发布**：Alpha 1 不把
`DWRG.dmg` 或其中的 CodeWeavers 预编译 Wine bundle 打进我们的安装包，也不镜像它。用户的
启动器从 manifest 固定的 `novak037/yanyun-on-mac` v0.1.2 GitHub Release 原始 URL 下载，严格核对
326,791,695 bytes 和 SHA-256，才从只读 DMG 取出预期的 `wine-release` 根目录。

这条下载路径不表示上游把该 runtime 授权给本项目重新分发；它恰恰避免了我们重分发这一问题。

## 接口

构建：`./build.command /absolute/output/IdentityVRuntimeBootstrap`。

最低 macOS 版本核验使用 Go 标准库 `debug/macho` 在进程内读取 thin / universal Mach-O 的每个
架构切片，检查 `LC_BUILD_VERSION`（macOS 平台）或 `LC_VERSION_MIN_MACOSX`。缺失部署目标、
非 macOS 平台、损坏或截断的头部/命令、任一切片超过 manifest 上限都会拒绝。
运行时无需 Xcode、Command Line Tools 或 `otool`；构建仍使用 Go，DMG 挂载使用系统 `hdiutil`。
`go test ./...` 的相关测试直接生成小型二进制夹具，覆盖上述接受与拒绝路径。

安装（由启动器调用）：

```text
IdentityVRuntimeBootstrap install --manifest /absolute/runtime-manifest.json \
  --destination-root "$HOME/Library/Application Support/IdentityVOnMac/Components/wine-runtime" \
  --patch-root /absolute/read-only-patch-payloads
```

`patch-root` 由安装器提供，必须含 manifest 中四个相对 payload 名：`winemac.so`、
`libgmp.10.dylib`、`libpcre2-8.0.dylib` 和 `libzstd.1.dylib`。helper 不会创建、启动或读取任何 Wine
prefix，也不会启动游戏。它拒绝符号链接、路径逃逸、损坏/缺失 patch、非预期重定向和任何版本冲突；失败时
不发布 `current`，并卸载临时 DMG。网络中断留下的 staging 会在下一次安全清理，不会被当作完成版本复用。

下载时标准错误会给启动器输出稀疏、机器可读的进度行，例如
`runtime-bootstrap stage=download bytes=… total=326791695 percent=…`：开始时为 0%，随后至多每跨过
5 个百分点报告一次，最后为 100%，不会按网络小块刷屏。

发布采用“先原子移动版本目录、再建立 `current` 链接”。若进程恰好在两者之间崩溃，下一次安装会只对该
版本完整 `verify-tree`：通过后补回精确指向该版本的 `current`，已正确指向且通过核验则直接成功；任何其他
`current` 或版本目录冲突都会 fail closed，不会擅自改链或覆盖文件。

离线验收既有 runtime（只读，不复制、不修改）：

```text
IdentityVRuntimeBootstrap verify-tree --manifest /absolute/runtime-manifest.json --tree /absolute/runtime
```

当前 manifest 是 macOS 15 Alpha 组合候选；其四枚自建 patch 与关键运行时哈希来自
[`../runtimeManifest/macosCompatibilityAudit.md`](../runtimeManifest/macosCompatibilityAudit.md)。

## 补丁载荷的签名与哈希契约（2026-09-21）

公证要求 App 包内每个 Mach-O 都带 Developer ID 签名与安全时间戳，所以 `winemac.so`、
`libgmp.10.dylib`、`libpcre2-8.0.dylib`、`libzstd.1.dylib` 现在由
`stageRuntimePatchPayloads.command` 在暂存时签名。签了时间戳的产物不可逐字节复现，
因此 manifest 分成两个字段：

- `patches[].sourceSha256`：**未签名候选**的复现契约，staging 用它校验自产 runtime 候选；
- `patches[].sha256`、`finalVerificationFiles`，以及
  `../runtimeManifest/runtime-catalog.json` 的 `verificationFiles`：随 App 分发的
  **已签名**哈希，由 staging 脚本从实际签名产物刷新，不反向校验可复现构建。

`verifyRuntimePatchPayloads.command` 与 `main.go` 继续使用 `sha256`（分发契约）。任何
改动补丁字节的步骤都必须让 staging 脚本刷新这两处哈希，否则 runner 会在启动时以
`integrity check failed` 中止。已签名补丁的功能尚未在真实游戏中单独回归，替换已装
runtime 里这四枚文件时应先保留原文件以便回退。

2026-09-23 从空运行环境首装时发现一个先前被已有缓存遮住的失败路径：bootstrap
以 `DisallowUnknownFields` 解析**同一份** manifest，但原先的 `patchSpec` 漏掉仅供 staging
使用的 `sourceSha256`，导致下载前立即报 `unknown field "sourceSha256"`。运行时现明确
识别并校验该字段的格式，仍只用已签名 `sha256` 核验分发字节；测试直接读取随包的真实
`runtime-manifest.json`，避免只用简化夹具而再次漏掉两端共享字段。
