# 渐近式思考框架（bun 兼容编译版）

> 从 [~/pi-agent-extensions/asymptotic-thinking](../pi-agent-extensions/asymptotic-thinking/) 移植，适配 pi 0.84.2 + bun 1.4.0 运行时。
> 本版本为**编译版**：`bun run build` 将全部源码（含 27 个提示词模块）打包为单文件 `dist/index.js`，由 `~/.pi/agent/compiled/update-extensions.sh` 复制到 `compiled/asymptotic-thinking.js` 并经 settings.json `extensions` 数组显式加载。

渐近式思考是**六态状态机框架**，引导 LLM 结构化、分阶段深度推理：

```
START → DEEP_UNDERSTAND → DESIGN → EXECUTE → VERIFY → END
   ↑                                                     │
   └──────────── before_agent_start 自动转换 ─────────────┘
```

按难度开放路径：TRIVIAL 直达 EXECUTE；SIMPLE 到 DESIGN/EXECUTE；其余必须先 DEEP_UNDERSTAND。

## 安装

源码位于 `~/.pi/agent/extensions/asymptotic-thinking/`，编译产物由 `~/.pi/agent/compiled/update-extensions.sh` 管理：

```bash
cd ~/.pi/agent/extensions/asymptotic-thinking
bun install   # 安装构建工具链（类型检查 + 构建）

# 方式一：一键更新脚本（推荐，含打包）
~/.pi/agent/compiled/update-extensions.sh --build-only

# 方式二：手动构建
bun run build && cp dist/index.js ~/.pi/agent/compiled/asymptotic-thinking.js
```

settings.json 的 `extensions` 数组已包含 `/home/cirno99/.pi/agent/compiled/asymptotic-thinking.js`，重启 pi 生效。

```bash
cd ~/.pi/agent/extensions/asymptotic-thinking
bun install   # 安装构建工具链（类型检查 + 构建）
bun run build # 构建编译产物 dist/index.js（可选，已含预构建产物）
```

注意：本扩展**无顶层 index.ts**（与其它 compiled 扩展一致），靠 settings.json 显式加载，避免与自动发现双重加载。

## 编译版构建

```bash
bun run build   # 生成 dist/index.js（单文件，含全部提示词模块）
```

- **产物**：`dist/index.js`（~128KB，minify）+ `dist/index.js.map`（调试用，可删除）
- **external**：`@earendil-works/*`、`typebox` 由 pi 运行时 virtualModules 提供，不重复打包；`node:*` 内置模块保持外部
- **提示词模块**：原动态 `require("./prompts/...")` 改为 `src/prompt-registry.ts` 静态路由表（bun build 无法打包动态路径），查找顺序不变（精确→同大类 general→全通用兜底）
- **入口**：无顶层 index.ts；settings.json `extensions` 数组显式加载 `compiled/asymptotic-thinking.js`（`update-extensions.sh` 负责构建+复制）
- **框架规则**：SYSTEM.md 内容内联为 `src/framework-rules.ts` 常量（编译版自包含，不依赖运行时文件路径；修改 SYSTEM.md 后需重新生成该常量 + 重新构建）
- **修改源码后**需重新 `bun run build` 才能生效

## 提供的工具与命令

| 名称 | 作用 |
|:--|:--|
| `asymptotic-think_transition` | 状态流转（校验合法性 + 动态流转提示） |
| `asymptotic-think_set-task-info` | 设定任务画像（难度/大类型/小类型） |
| `asymptotic-think_status` | 查询状态机完整状态 |
| `/asymptotic-toggle` | 按 session 切换启用/禁用 |

## 事件钩子

- `before_provider_request`：按任务画像动态调优 temperature/topP（三层叠加：大类型基础 + 小类型微调 + 难度偏移）
- `before_agent_start`：注入状态引导提示词 + SYSTEM.md 框架规则
- `turn_end`：轮次计数 + 三级警告（soft/over/hardStop）+ 状态提醒
- `session_start` / `session_shutdown`：状态恢复 + 遗留记录清理

## bun 兼容要点

| 差异点 | 处理方式 |
|:--|:--|
| `node:sqlite` 在 pi 0.84.2 bun 编译二进制中不可用 | `session-store.ts` 用 `createRequire` 优先 `node:sqlite`、回退 `bun:sqlite`（`DatabaseSync` API 形状一致） |
| `DEFAULT_STATE.state = null` 违反 SQLite `NOT NULL` | 改为 `"START"`（新会话即启动态） |
| `Type.String({enum})` 对 Google 不兼容 | 改用 `StringEnum`（来自 `@earendil-works/pi-ai`） |
| LLM 传小写枚举 | `prepareArguments` 统一转大写后再过 schema 校验 |
| 动态 require `.ts` 提示词模块 | 编译版改为 `prompt-registry.ts` 静态路由表（bun build 无法打包动态路径），查找顺序不变 |
| 动态 require SYSTEM.md（fs 读取） | 编译版改为 `framework-rules.ts` 内联常量（bun build 产物不依赖运行时文件路径） |

## 开发

bunx tsc --noEmit                                          # 类型检查
~/.pi/agent/compiled/update-extensions.sh --build-only      # 重新打包 compiled 产物
pi -e ./dist/index.js -p "你好"                             # 快速加载测试（直接测产物）

## 数据存储

状态持久化于 `~/.pi/agent/extension-global.db`（`getAgentDir()`），表：`asymptotic_thinking_session_state`（append-only）+ `asymptotic_thinking_toggle`。

## 许可

MIT
