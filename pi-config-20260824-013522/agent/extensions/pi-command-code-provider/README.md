# pi-command-code-provider（本地维护版）

自 [codeberg.org/jr2804/pi-command-code-provider](https://codeberg.org/jr2804/pi-command-code-provider) 剥离出来的自有扩展，不再受 `pi install` 的 git 包管理，由本机自行维护。

## 功能

- OpenAI 兼容端点（`/v1/chat/completions`），注册 provider 名为 `command-code`
- 模型目录在每次会话启动时从 [commandcode.ai](https://commandcode.ai) 的 `provider/v1/models` 端点实时拉取，不硬编码模型名/价格/上限
- 支持推理（reasoning）标记

## 与上游差异（本地定制）

独立维护，可按需修改，无固定差异项。

## 结构

```
src/
  index.ts    # 扩展入口：拉取模型目录并注册 command-code provider
```

## 打包

`~/.pi/agent/compiled/update-extensions.sh` 打包为 `pi-command-code-provider.js`（settings.json 的 `extensions` 引用它）。

```bash
~/.pi/agent/compiled/update-extensions.sh --build-only
```

打包由脚本内 `build_command_code` 函数负责（与 `build_statusline` 同模式：源码在 `extensions/pi-command-code-provider/src`，bundle 时 external `@earendil-works/*`）。依赖 `@earendil-works/pi-coding-agent` 仅为类型导入，是 pi 内置虚拟模块，无需安装。

## 注意

- 修改源码后必须重新打包（update-extensions.sh --build-only）并重启 pi 生效
- **加载机制**：本目录 `package.json` 的 `pi.extensions` 已清空为 `[]`，运行时只加载 `settings.json` 引用的编译产物 `compiled/pi-command-code-provider.js`（避免源码目录被 pi 自动发现导致重复加载）；此目录仅为源码仓库 + 打包输入，勿把 `pi.extensions` 加回去

## 使用

设置 API key：

```bash
export CMD_API_KEY="your-key"
```

然后在 pi 中：

```
/model command-code
```

## License

MIT（上游作者 jr2804，见 LICENSE）