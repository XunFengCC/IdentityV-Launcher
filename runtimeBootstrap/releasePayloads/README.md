# 受控运行环境补丁输入

本目录的 `winemac.so`、`libgmp.10.dylib`、`libpcre2-8.0.dylib` 和 `libzstd.1.dylib` 是**已签名精确字节**；`gdi32.dll` 是由本项目所带 CodeWeavers 26.1 补丁构建的 PE AMD64 文件，SHA-256 为 `3aa45d33ab949a188f3249d0a6ecdb7793f141eefa10d631e404dfe78464de48`。它们不是完整 Wine runtime；基础 runtime 仍由用户机器按锁定上游地址下载，游戏本体也不随包。

五枚文件的实际 SHA-256 在 `../runtime-manifest.json` 的 `patches[].sha256` 与 `../../runtimeManifest/runtime-catalog.json` 中锁定。Mach-O 文件的签名前源码字节有独立的 `sourceSha256`；GDI DLL 的对应源码、补丁、工具链和字体许可见 [`../../wineEmojiPatch/README.md`](../../wineEmojiPatch/README.md) 与 [`../../wineEmojiPatch/REPRODUCE.md`](../../wineEmojiPatch/REPRODUCE.md)。Mach-O 签名附带时间戳，再签会改变哈希；更新任何载荷前都要刷新清单并从干净副本复核。

本仓纳入这些输入是为了让新 clone 能在声明的依赖下复建 App，不需要访问旧维护者私人缓存。公开 RC1 的 tag 和已发布包仍固定为原 r1；主干源码构建默认使用 emoji2 候选。这里不得放账号、私钥、基础 Wine bundle、游戏文件或临时构建输出。
