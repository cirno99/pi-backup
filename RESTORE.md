# pi 配置备份与恢复说明

本目录包含一套完整的 pi 配置备份方案，备份产物不含任何私密信息（登录凭据、会话记录等），
可以放心提交到 GitHub（建议用私有仓库）。

## 文件说明

| 文件 | 用途 |
|---|---|
| `backup-pi.sh` | 备份脚本（生成新的备份产物） |
| `restore-pi.sh` | 恢复脚本（放入备份产物中，随备份一起入库） |
| `RESTORE.md` | 本文档 |
| `pi-config-<时间戳>/` | 备份产物（含 `agent/`、`manifest.txt`、`RESTORE.md`、`restore-pi.sh`、`excludes.txt`、可选的 `acp.json`） |

## 备份

```bash
cd ~/pi-backup
./backup-pi.sh            # 生成 pi-config-<时间戳>/ 目录
./backup-pi.sh            # 再次运行 = 增量叠加进 git，历史版本可用 git 找回

# 或者想要单个压缩包：
PI_TAR=1 ./backup-pi.sh   # 生成 pi-config-<时间戳>.tar.gz
```

备份内容：
- **核心配置** `~/.pi/agent/` 的子集：`settings.json`、`AGENTS.md`、`pi-lsp.json`、
  `subagents.json`、`prompts/`、`extensions/`、`themes/`、`compiled/`、`models-store.json`，
  以及随运行产生的 `fff/`（pi-fff 索引缓存）、`git/`（各扩展 git 状态缓存）、
  `pi-cache-optimizer-stats.d/`（pi-cache-optimizer 统计分片）
- **bun 重装配方** `agent/npm/` 下的 `package.json` + `bun.lock`（node_modules 不备份）
- **ACP 全局配置** `~/.pi/acp.json`（billion-context-pi 全局配置，在 agent 目录外，有则备份到产物根目录）
- **内核项目**（acp-kernel-zig）**不备份**：billion-context-pi 的 Zig 原生内核整体不备份，避免换机还原时覆盖本机现有内核项目（restore 会把现有目录 mv 到 .bak 再覆盖）。需要 Zig 原生内核时从 GitHub 仓库 clone + `zig build` 重建；缺失时 `update-extensions.sh` 自动回退 npm 包内联的旧 TS 内核（功能可用，无 Zig 原生加速）

隐私说明：
- **已脱敏**：`settings.json` 里的绝对路径（如 `/home/用户名/.pi/agent/...`）备份时替换为 `$HOME` 占位符，恢复时自动还原；`settings.json.bak*` 历史备份不入库
- **不含**：登录凭据（`auth.json`）、会话记录、API key（key 只存在于环境变量中，从未写入配置）
- **公开可见**：你使用的模型/服务商（`models-store.json`）、prompt 模板、扩展源码——这些是公开仓库的正常内容，自行评估

**明确不备份**（防止泄露/缩小体积）：
- `auth.json` —— OAuth 登录凭据（恢复后需重新 `/login`）
- `sessions/`、`state/`、`missions/`、`run-history.jsonl` —— 会话/运行记录
- `npm/node_modules`（约 110M）—— 不备份；`package.json` + `bun.lock` 配方已备份，恢复时 `bun ci --omit=peer` 按 lock 精确复现，再跑 `update-extensions.sh` 重新打包
- `extensions/*/node_modules`（约 270M）—— 扩展构建依赖，纯构建期：运行时 `compiled` bundle 已内联全部依赖（仅 external `acp-kernel`、`acp-kernel/panel` 与 pi 宿主注入的 `@earendil-works/pi-coding-agent`），恢复时 `update-extensions.sh` 会 `mkdir -p` 并重建 `acp-kernel` 链接，无需备份
- 技能内容（约 383M）—— 技能由 skills-manager 应用管理，不在备份内，恢复后重新安装
- `acp-kernel-zig/` 内核项目（含原生产物 `native/zig-out` + `dist/`）—— 整体不备份（源码在 GitHub 仓库，需重建/改动时才 clone；原生产物按备份机 CPU 架构编译，换机还原有覆盖风险），缺失时 `update-extensions.sh` 自动回退 npm 包内联的旧 TS 内核
- `acp.log`、`acp-state/` —— ACP（billion-context-pi）运行日志与状态，不备份（已加入排除清单；`~/.pi/acp.log` 在本机 ~/.pi 根目录，防其写入 agent 目录的 `acp-state/` 一并排除）

## 推送到 GitHub

```bash
cd ~/pi-backup
git init
git add -A
git commit -m "pi 配置备份 $(date +%Y%m%d)"
git branch -M main
git remote add origin git@github.com:<你的用户名>/<仓库名>.git   # 私有仓库
git push -u origin main
```

以后每次备份后：`git add -A && git commit -m "update" && git push`。

## 恢复到新机器

### 前置条件（版本建议与备份一致，见 `manifest.txt`）

```bash
# 安装 mise + pi（示例，按官方方式即可）
curl https://mise.run | sh
mise use -g pi@<manifest.txt 里的版本>
mise use -g pi@<manifest.txt 里的版本> bun
pi --version   # 确认可用
bun --version  # 确认可用（重建 node_modules 与重新打包都需要）
```

### 执行恢复

```bash
# 方法一：克隆仓库后直接恢复
git clone <你的私有仓库地址> pi-restore && cd pi-restore
./restore-pi.sh pi-config-<时间戳>/

# 方法二：用压缩包
tar xzf pi-config-<时间戳>.tar.gz
./restore-pi.sh pi-config-<时间戳>
```

恢复脚本会自动完成：
1. 把已有 `~/.pi` 移走（防覆盖，可随时删掉 `~/.pi.bak.*`）
2. 复制核心配置到 `~/.pi/agent/`
3. 还原 `~/.pi/acp.json`（billion-context-pi 全局配置；备份中无此文件则跳过）
4. 修正 `settings.json` 里扩展的绝对路径（换用户名也能用）
5. 创建空的 `~/.pi/agent/skills/` 目录（技能由 skills-manager 重装）
6. **不还原内核项目**（acp-kernel-zig）—— 备份不再包含内核，避免覆盖本机现有的内核项目。
   需要 Zig 原生内核时 clone 内核仓库重建（见下文常见问题），缺失时 build 自动回退 npm 包内联的旧 TS 内核
7. 重建扩展环境（node_modules 不备份，全部由配方重建）：
   - 恢复 `agent/npm/` 的 `package.json`/`bun.lock` 配方
   - `pi install` 注册 `settings.json` 里的包
   - `bun ci --omit=peer` 按 lock 精确重建 `node_modules`（需联网；`--omit=peer` 跳过 @earendil-works/pi-* 等由 pi 宿主注入的 peer 依赖，与 pi 安装参数一致）
   - 跑 `update-extensions.sh --build-only` 用 bun 重新打包编译产物

### 恢复后手动操作

1. **重新登录**：运行 `pi`，执行 `/login` 选择你的 provider（Claude / OpenRouter / xAI 等）
2. **API key**：在 shell 配置（`~/.bashrc` 等）里补上 API key 环境变量，例如：
   ```bash
   export OPENROUTER_API_KEY=sk-xxx
   export XAI_API_KEY=xxx
   ```
3. **扩展报错处理**（pi 版本不同导致编译产物不兼容时）：
   ```bash
   rm -rf ~/.pi/agent/compiled && pi
   ```
   重启后扩展会自动重新编译。
4. **恢复技能**：备份不含技能内容（由 skills-manager 应用管理），安装并打开
   skills-manager，按 `manifest.txt` 的技能列表重新安装。安装后若
   `~/.pi/agent/skills/` 下的符号链接未自动重建，手动执行:
   ```bash
   for d in ~/.skills-manager/skills/*/; do
     ln -sfn "$d" ~/.pi/agent/skills/"$(basename "$d")"
   done
   ```
5. **项目级配置**：如果你在项目目录里用过 pi（`.pi/settings.json`、`.pi/SYSTEM.md` 等），
   这些是跟着项目走的，自行从旧机器对应项目复制，或交给 git 管理。
6. **验证**：`pi` 里执行 `/settings` 确认设置、`/theme` 确认主题、`/skills` 确认技能列表。

## 常见问题

- **技能怎么恢复？** 备份不含技能内容（由 skills-manager 应用管理）。安装并打开
  skills-manager 重新安装需要的技能；确认 `~/.pi/agent/skills/` 下的符号链接指向
  `~/.skills-manager/skills/<技能名>`（必要时按上面的命令重建）。
- **主题丢了？** 主题文件在备份的 `agent/themes/` 里，确认 `settings.json` 的
  `theme` 值与 `~/.pi/agent/themes/` 下的文件名一致。
- **登录 provider 列表和原来不同？** 备份不含 `models-store.json` 之外的目录缓存，
- **node_modules 怎么复现？** node_modules（约 110M）不备份，恢复脚本已自动完成复现：
  `bun ci --omit=peer`（按备份的 `bun.lock` 精确安装）→ `update-extensions.sh` 重新打包。
  手动操作：`cd ~/.pi/agent/npm && bun ci --omit=peer && bash ~/.pi/agent/compiled/update-extensions.sh --build-only`
- **为什么用 bun 而不是 npm？** `settings.json` 的 `npmCommand` 已切换为 `["bun"]`，pi 安装/更新扩展包时固定以 `bun install <specs> --cwd <root> --omit=peer` 执行（跳过 @earendil-works/pi-* 等由 pi 宿主注入的 peer 依赖，裸跑 `bun ci` 会额外装这些 peer，与 pi 管理状态不一致）。bun 自带全局缓存，重建极快；`bun ci` 与 `npm ci` 同为 frozen-lockfile 语义，不会改动 `bun.lock`。旧备份若只有 `package-lock.json`，恢复脚本会自动降级为 `bun install --omit=peer` 重新解析并生成 `bun.lock`。
- **内核项目（acp-kernel-zig）怎么恢复？** 备份**不再包含**内核项目（避免还原时覆盖本机现有的内核）。换机后如需 Zig 原生内核，从 GitHub 仓库 clone 并重建：`git clone <内核仓库> ~/Code/TypeScript/billion-context-pi-zig/acp-kernel-zig && cd ~/Code/TypeScript/billion-context-pi-zig/acp-kernel-zig && zig build`（需先安装 zig，见内核项目 README）；或设 `BUILD_KERNEL=1 bash ~/.pi/agent/compiled/update-extensions.sh --build-only` 由脚本自动重建。未重建时 `update-extensions.sh` 自动回退 npm 包内联的旧 TS 内核（功能可用，无 Zig 原生加速）。注意原生产物 `libacp_kernel.so` 按 CPU 架构编译（x86_64 / aarch64 不通用），务必在目标机上重新 `zig build`。
  重新 `/login` 后会自动刷新；自定义 provider 请参考官方 docs 重新配置。
