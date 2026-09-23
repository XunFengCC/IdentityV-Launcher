# 四枚受控运行环境补丁输入

本目录的 `winemac.so`、`libgmp.10.dylib`、`libpcre2-8.0.dylib` 和 `libzstd.1.dylib` 是当前启动器构建要嵌入的**已签名精确字节**。它们不是完整 Wine runtime；基础 runtime 由用户机器按锁定上游地址下载，游戏本体也不随包。

四枚文件的实际 SHA-256 在 `../runtime-manifest.json` 的 `patches[].sha256` 与 `../../runtimeManifest/runtime-catalog.json` 中锁定。对应签名前源码字节有独立的 `sourceSha256`，上游版本、补丁/构建说明和许可证见[运行环境说明](../README.md)、[第三方材料](../../notices/README.md)及 `../../runtimeAssembly/patches/`。签名附带时间戳，再签会改变文件哈希，不能把新字节静默替换到本目录；先刷新两个清单，再从干净副本构建、签名和验证。

本仓纳入这四枚输入是为了让新 clone 能在声明的依赖下复建 App，不需要访问旧维护者私人缓存。这里不得放账号、私钥、基础 Wine bundle、游戏文件或临时构建输出。
