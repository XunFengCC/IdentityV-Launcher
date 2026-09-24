# emoji2 runtime 候选

此目录的 manifest 从公开 RC1 的 r1 输入派生，但使用独立不可变版本名 `wine11-codeweavers-26.1-dxmt-0.80-macos15-alpha1-r1-emoji2`。它保留四枚已签 Mach-O 补丁，并增加 `gdi32.dll` 的 x86_64 PE 补丁。主干源码构建现默认选择此 runtime；公开 `v1.0.0-rc.1` tag、已发布包及 r1 runtime 均不改写。

候选 GDI 由 CodeWeavers 26.1 对应源码加 [`wineEmojiPatch`](../../../wineEmojiPatch/README.md) 的两份补丁构建，SHA-256 `3aa45d33ab949a188f3249d0a6ecdb7793f141eefa10d631e404dfe78464de48`。候选字体是 Noto Sans CJK SC + Noto Emoji 的 OFL 派生字体，SHA-256 `c002488492344453723dc491ecbe2646018f94a3060a8d0cb5829ef8b4d0d45b`。manifest 校验下载源的原始 GDI hash `3069d43300df2d0d054fbb4d4641f0b412032a11384a6c534009fd92b0ba98ac`，安装后校验补丁 hash；`runtimeBootstrap` 还检查它确是 PE AMD64 DLL，避免拿 Mach-O 检查套在 Windows DLL 上。

独立验证时，可在仓外准备 patch-root，把四枚已签 Mach-O 补丁与 `wineEmojiPatch/releasePayloads/gdi32.dll` 放入，再将本 manifest、patch-root 和全新 destination-root 传给 `IdentityVRuntimeBootstrap install`。不要把该验证用 runtime 或游戏 prefix 指向日常安装。已用 r1 的独立 APFS clone 替换 GDI 后执行 `verify-tree`，结果通过；字体与 GDI 的 `compositeRegression` 31 组行为用例失败 0。此前直接拿 9 月旧候选 runtime 验证失败在 `winemac.so` hash，因为它不是 RC1 的已签补丁字节；不能用旧候选冒充这一份 manifest。

`1.0.0-rc.1-test.2` 已完成一次游戏内 A–N 聊天复测，截图中未见方框或组合拆散。公开封包仍需从干净提交构建、核对最终载荷及 OFL 声明，并使用新发行号；每次升级 Wine、Noto 或 Unicode 数据仍须重跑对应回归。语音破音另有独立问题；`emoji2` 本身不包含音频源补丁。
