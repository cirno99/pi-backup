# pi-statusline（本地维护版）

自 `@normful/pi-statusline@0.3.1` 剥离出来的自有扩展，不再受 npm registry 管理。

## 与上游差异（本地定制）

- **缓存命中率**：footer 右侧显示 `87%c`，**修正了分母**——上游/旧版用 `cacheRead / input`，但实测 provider 返回的 `usage.input` 不含 `cacheRead`（如 `input:133, cacheRead:13440`），旧公式会溢出成 `10105%c`；现用 `cacheRead / (cacheRead + cacheWrite + input)` 且钳制在 100% 内
- **thinking 图标**：`⟐`（U+27D0，多数终端字体缺字形 → 豆腐块）替换为 `◆`（U+25C6 黑菱形，所有字体必有）

## 结构

```
src/
  index.ts    # 扩展入口：事件订阅、widget/footer 注册
  render.ts   # 渲染逻辑（上下文/成本/命中率/流式 CPS）
  format.ts   # 数字/路径/时长格式化
  color.ts    # hash 配色 + 速度色阶
  types.ts    # 类型定义
```

## 打包

`~/.pi/agent/compiled/update-extensions.sh` 打包为 `pi-statusline.js`（settings.json 引用它）。
脚本同时管理其他编译产物与扩展更新，用法见脚本头部注释（`--build-only` 等价原 build.sh）。

bash ~/.pi/agent/compiled/update-extensions.sh --build-only
```

依赖 `@earendil-works/*` 是 pi 内置虚拟模块（loader 提供），bundle 时 external，无需安装。

## 注意

- 修改源码后必须重新打包（update-extensions.sh --build-only）并重启 pi 生效
- 若 `pi update` 升级了 pi 本体，建议重跑 update-extensions.sh 确保兼容
- **加载机制**：本目录 `package.json` 的 `pi.extensions` 已清空为 `[]`，运行时只加载 `settings.json` 引用的编译产物 `compiled/pi-statusline.js`（避免源码目录被 pi 自动发现导致重复加载，节省约 17ms 启动时间）；此目录仅为源码仓库 + 打包输入，勿把 `pi.extensions` 加回去
