# 隔离候选载荷

`gdi32.dll` 是按 [`REPRODUCE.md`](../REPRODUCE.md) 的 CodeWeavers 26.1 + 0001/0002 补丁得到的 x86_64 PE 候选；`IdentityV-Emoji-CJK.ttf` 是全 OFL 的 Noto Sans CJK SC 与 Noto Emoji 单色派生字体。两件都由 catalog 的 emoji2 条目锁定 SHA-256，当前 `productDefault=false`，不进入 RC1 已发布物。

字体构建输入、hash、行为边界与许可在 [`REPRODUCE.md`](../REPRODUCE.md)、[`README.md`](../README.md) 和 `../licenses/`。单色渲染不承诺彩色 emoji；更换 Unicode、Noto 或 Wine 版本须重新验证字形、组合规则与实际加载路径。载荷进入公开包前仍需更新对应源码材料与真实游戏验收。
