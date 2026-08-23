# billion-context-pi 迁移操作清单（方案 A）

> 目标：用 billion-context-pi（模型驱动上下文压缩）替换 pi-observational-memory 与 @tintinweb/pi-subagents，
> 附带同步更新备份仓库（cirno99/pi-backup），全程可回滚。
> 生成时间：2026-08-23 · pi 版本 0.84.2 · 模型 DeepSeek V4 Flash

---

## ⚠️ 动工前必读（3 条硬规则）

1. **压缩插件只能留一个**。billion-context-pi 会接管 Pi 内置压缩，且官方明确警告：与其他压缩插件并存会互相改写消息列表导致**会话损坏**。所以 observational-memory 必须卸载，**顺序不能反**。
2. **先备份再动手**。执行前先跑一次 `./backup-pi.sh` 生成一个干净快照，回滚全靠它。
3. **acp.json 在备份范围外**。billion-context-pi 的全局配置位于 `~/.pi/acp.json`（`~/.pi/` 下，不在 `~/.pi/agent/`），你的 backup-pi.sh 目前**不会备份它**——本清单第 4 步会补上。

---

## 第 1 步：前置备份（2 分钟）

```bash
cd ~/pi-backup
./backup-pi.sh
git add -A && git commit -m "chore: backup before billion-context-pi migration"
git push
```

确认生成 `pi-config-<时间戳>/` 且体积正常后再继续。

---

## 第 2 步：卸载两个旧扩展

### 2.1 编辑 `~/.pi/agent/settings.json`，共 3 处改动

**① extensions 数组：删除这两行**

```json
"$HOME/.pi/agent/compiled/pi-observational-memory.js",
"$HOME/.pi/agent/compiled/@tintinweb-pi-subagents.js",
```

**② 删除 observational-memory 配置块**（整个对象）：

```json
"observational-memory": {
  "compactAfterTokensMode": "ratio",
  "compactAfterTokensRatio": 0.5
},
```

> ⚠️ 不删这个块的话，它变成死配置，billion-context-pi 接管后行为不可预期。

**③ 检查 packages 数组**：确认没有 `npm:pi-observational-memory` / `npm:@tintinweb/pi-subagents`（当前你的 packages 里没有，如有则一并删）。

### 2.2 同步更新 npm 配方 `~/.pi/agent/npm/package.json`

删除 dependencies 中的这两条：

```json
"pi-observational-memory": "^3.0.4",
"@tintinweb/pi-subagents": "^0.16.1",
```

然后更新 lockfile 并清理：

```bash
cd ~/.pi/agent/npm
bun install    # 重新解析 bun.lock
```

### 2.3 清理编译产物（可选但推荐，省备份体积）

```bash
rm -f ~/.pi/agent/compiled/pi-observational-memory.js
rm -f ~/.pi/agent/compiled/@tintinweb-pi-subagents.js
```

### 2.4 验证卸载干净

```bash
pi /restart
# 确认：/extensions 列表里已无 observational-memory 与 subagents
# 确认：启动无报错，settings.json 无残留引用
```

---

## 第 3 步：安装 billion-context-pi

```bash
pi install npm:billion-context-pi
pi /restart
```

**验证安装**：

```bash
/acp          # 应显示上下文用量、压缩块、可压缩范围
```

预期效果：每次 LLM 调用前自动运行压缩管道，模型获得 `compress` / `decompress` / `search_context` / `acp_status` / `acp_delegate` 工具组；Pi 内置自动压缩被自动取消。

**配置说明**：开箱即用、无必需配置，自动读取模型上下文窗口。可选调优项：
- 全局配置：`~/.pi/acp.json`（项目级覆盖：`<项目>/.pi/acp.json`）
- 日志重定向：环境变量 `ACP_LOG_FILE`（默认 `~/.pi/acp.log`，10MB 轮转）
- 建议第一周**保持默认配置**，验证通过后再调优，别一上来就改参数

---

## 第 4 步：更新备份仓库（关键，容易漏）

### 4.1 `excludes.txt` 增加保险排除

`~/pi-backup/excludes.txt` 追加：

```
# billion-context-pi 运行日志与状态（acp.log 默认在 ~/.pi/ 下，此处为保险，防其写入 agent 目录）
acp.log
acp.log.*
acp-state/
```

### 4.2 `backup-pi.sh` 补 acp.json 备份逻辑

acp.json 在 `~/.pi/` 下、不在 rsync 范围内。参照现有 npm 配方的处理方式，在脚本中"2.5 保留 bun 重装配方"那段**后面**追加：

```bash
# ------------------------------------------------------------
# 2.7 billion-context-pi 全局配置（~/.pi/acp.json 在 agent 目录外，单独复制）
#     注意：同步修改 restore-pi.sh 还原到 ~/.pi/acp.json
# ------------------------------------------------------------
mkdir -p "$DEST"
for f in acp.json; do
  [ -f "$HOME/.pi/$f" ] && cp "$HOME/.pi/$f" "$DEST/$f"
done
```

> ⚠️ **必须同步改 `restore-pi.sh`**：把 `$DEST/acp.json` 还原到 `$HOME/.pi/acp.json`。
> 若你不改 restore 脚本，备份了也还原不回去，等于白备份。

### 4.3 立即做一次"预演备份"验证

```bash
cd ~/pi-backup
./backup-pi.sh
# 检查产物：
#   ✓ 含 acp.json（如已配置）
#   ✓ 不含 acp.log
#   ✓ settings.json 的 $HOME 脱敏正常（billion-context-pi 的扩展路径如含 $HOME 会被自动处理）
git add -A && git commit -m "feat: backup acp.json + exclude acp runtime files"
```

---

## 第 5 步：一周验证 checklist

跑满 7 天，逐项打勾，全部通过才算迁移成功：

- [ ] **D1 功能冒烟**：小项目跑 1~2 个任务，`/acp` 状态正常，`acp_status` 能看到可压缩范围
- [ ] **D1 无回归**：read/edit/write、bash、web 工具（rpiv-web-tools）均正常工作，无工具冲突报错
- [ ] **D2 压缩行为**：跑一个长会话，观察模型是否主动调用 `compress`（不是等到顶才被动截断）
- [ ] **D2 信息保真（关键）**：压缩发生后，追问模型几个具体细节（改过的文件路径、关键数值、决策理由），验证模型能答出或能用 `search_context` 捞回。**答不出 = Flash 的压缩决策不可靠，考虑回滚或换 context-mode**
- [ ] **D3 子代理替代**：用 `acp_delegate` 跑一次 reviewer/researcher 任务，确认 5 角色可用、结果落在 `/tmp/acp-delegate/<runId>.out`
- [ ] **D4 成本观察**：对比 statusline 的上下文占用与缓存命中率——预期上下文稳定在 ~150K、缓存命中率不低于迁移前
- [ ] **D5 稳定性**：连续 2 天无崩溃、无 acp.log 异常报错、无会话损坏
- [ ] **D7 备份验证**：再跑一次 backup-pi.sh，体积合理（acp.json 极小），推送 GitHub 正常

---

## 第 6 步：回滚方案（随时可用）

**方式 A：一键还原（推荐）**

```bash
cd ~/pi-backup
./restore-pi.sh pi-config-<迁移前的时间戳>/
# 然后重新登录：pi /login
```

**方式 B：手动回滚**

```bash
pi remove npm:billion-context-pi
pi install npm:pi-observational-memory
pi install npm:@tintinweb/pi-subagents
# 恢复 settings.json：加回 extensions 两行 + observational-memory 配置块
# 恢复 npm/package.json：加回两个依赖 + bun install
pi /restart
```

---

## 附录：迁移前后配置对照

| 项 | 迁移前 | 迁移后 |
|---|---|---|
| 上下文压缩 | pi-observational-memory（0.5 ratio 摘要） | billion-context-pi（模型驱动选择性压缩，可搜索可解压） |
| 子代理 | @tintinweb/pi-subagents（~7K tok/轮） | acp_delegate 内置（~600 tok/轮，5 角色） |
| 内置压缩 | 默认启用 | 被 billion-context-pi 接管（自动取消） |
| 缓存优化 | pi-cache-optimizer | 保留（不冲突，协同） |
| 输出压缩 | pi-rtk-optimizer | 保留（不同层，不冲突） |
| 备份覆盖 | — | + acp.json（需改 backup/restore 脚本） |

**保留不动**：pi-statusline、pi-readseek、pi-cache-optimizer、pi-rtk-optimizer、@juicesharp/rpiv-web-tools、@juicesharp/rpiv-ask-user-question、@narumitw-pi-btw、@narumitw-pi-lsp、pi-command-code-provider、@ff-labs/pi-fff 等。
