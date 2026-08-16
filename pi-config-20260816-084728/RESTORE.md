# pi 配置备份与恢复说明

本目录包含一套完整的 pi 配置备份方案，备份产物不含任何私密信息（登录凭据、会话记录等），
可以放心提交到 GitHub（建议用私有仓库）。

## 文件说明

| 文件 | 用途 |
|---|---|
| `backup-pi.sh` | 备份脚本（生成新的备份产物） |
| `restore-pi.sh` | 恢复脚本（放入备份产物中，随备份一起入库） |
| `RESTORE.md` | 本文档 |
| `pi-config-<时间戳>/` | 备份产物（含 `agent/`、`manifest.txt`、`RESTORE.md`） |

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
  `subagents.json`、`prompts/`、`extensions/`、`themes/`、`sounds/`、`compiled/`、`models-store.json`
- **npm 重装配方** `agent/npm/` 下的 `package.json` + `package-lock.json`（node_modules 不备份）

隐私说明：
- **已脱敏**：`settings.json` 里的绝对路径（如 `/home/用户名/.pi/agent/...`）备份时替换为 `$HOME` 占位符，恢复时自动还原；`settings.json.bak*` 历史备份不入库
- **不含**：登录凭据（`auth.json`）、会话记录、API key（key 只存在于环境变量中，从未写入配置）
- **公开可见**：你使用的模型/服务商（`models-store.json`）、prompt 模板、扩展源码——这些是公开仓库的正常内容，自行评估

**明确不备份**（防止泄露/缩小体积）：
- `auth.json` —— OAuth 登录凭据（恢复后需重新 `/login`）
- `sessions/`、`state/`、`missions/`、`run-history.jsonl` —— 会话/运行记录
- `npm/node_modules`（约 524M）—— 不备份；`package.json` + `package-lock.json` 配方已备份，恢复时 `npm ci` 按 lock 精确复现，再跑 `update-extensions.sh` 重新打包
- 技能内容（约 383M）—— 技能由 skills-manager 应用管理，不在备份内，恢复后重新安装

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
bun --version  # 确认可用（扩展重新打包需要）
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
3. 修正 `settings.json` 里扩展的绝对路径（换用户名也能用）
4. 创建空的 `~/.pi/agent/skills/` 目录（技能由 skills-manager 重装）
5. 重建扩展环境（node_modules 不备份，全部由配方重建）：
   - 恢复 `agent/npm/` 的 `package.json`/`package-lock.json` 配方
   - `pi install` 注册 `settings.json` 里的包
   - `npm ci` 按 lock 精确重建 `node_modules`（需联网，即那 524M 的来源）
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
- **node_modules 怎么复现？** node_modules（约 524M）不备份，恢复脚本已自动完成复现：
  `npm ci`（按备份的 `package-lock.json` 精确安装）→ `update-extensions.sh` 重新打包。
  手动操作：`cd ~/.pi/agent/npm && npm ci && bash ~/.pi/agent/compiled/update-extensions.sh --build-only`
  重新 `/login` 后会自动刷新；自定义 provider 请参考官方 docs 重新配置。
