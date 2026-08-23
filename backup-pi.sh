#!/usr/bin/env bash
# ============================================================
# pi 配置备份脚本
# 特点：不包含私密信息（auth.json 等），产物小，适合上传 GitHub
#
# 用法:
#   ./backup-pi.sh                 # 备份到 ~/pi-backup/pi-config-<时间戳>/
#   PI_TAR=1 ./backup-pi.sh        # 备份并打包成 tar.gz（不留目录）
#   PI_BACKUP_ROOT=/mnt/disk ./backup-pi.sh   # 指定备份根目录
# ============================================================
set -euo pipefail

BACKUP_ROOT="${PI_BACKUP_ROOT:-$HOME/pi-backup}"
DEST="$BACKUP_ROOT/pi-config-$(date +%Y%m%d-%H%M%S)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

AGENT_DIR="$HOME/.pi/agent"
SKILLS_DIR="$HOME/.skills-manager/skills"

# 检查源目录
[ -d "$AGENT_DIR" ] || { echo "❌ 找不到 $AGENT_DIR"; exit 1; }
command -v rsync >/dev/null || { echo "❌ 需要 rsync"; exit 1; }

mkdir -p "$DEST/agent"
echo "备份到: $DEST"

# ------------------------------------------------------------
# 1. 核心配置：~/.pi/agent 的子集
#    排除规则集中在同目录的 excludes.txt（rsync --exclude-from 格式），
#    增删规则只改文件，不用动脚本
#    skills/ 下全是符号链接，先排除，恢复时自动重建（换用户名也有效）
# ------------------------------------------------------------
echo "==> 复制核心配置 ..."
rsync -a "$AGENT_DIR/" "$DEST/agent/" --exclude-from="$SCRIPT_DIR/excludes.txt"
rm -rf "$DEST/agent/skills"   # 防御：链接目录不进入备份

# ------------------------------------------------------------
# 2.6 settings.json 脱敏：extensions 绝对路径 $HOME/... → \$HOME 占位
#     防止上传公开仓库时泄露本机用户名（restore 时自动还原）
# ------------------------------------------------------------
sed -i "s|$HOME/.pi/agent|\$HOME/.pi/agent|g" "$DEST/agent/settings.json"

# ------------------------------------------------------------
# 2.5 保留 bun 重装配方（package.json + bun.lock）
#     node_modules 不备份（约 110M），换机后用 bun ci --omit=peer 按 lock 精确复现
#     （npmCommand 已切换为 bun；--omit=peer 跳过 @earendil-works/pi-* 等由 pi 宿主注入的 peer 依赖）
# ------------------------------------------------------------
mkdir -p "$DEST/agent/npm"
for f in package.json bun.lock; do
  [ -f "$AGENT_DIR/npm/$f" ] && cp "$AGENT_DIR/npm/$f" "$DEST/agent/npm/$f"
done

# ------------------------------------------------------------
# 2.7 billion-context-pi 全局配置（~/.pi/acp.json 在 agent 目录外，单独复制）
#     注意：同步修改 restore-pi.sh 还原到 ~/.pi/acp.json
# ------------------------------------------------------------
mkdir -p "$DEST"
for f in acp.json; do
  [ -f "$HOME/.pi/$f" ] && cp "$HOME/.pi/$f" "$DEST/$f"
done
# ------------------------------------------------------------
# ------------------------------------------------------------
# 2.8 billion-context-pi Zig 内核项目（acp-kernel-zig）不备份
#     内核项目整体不备份（含原生产物）：换机恢复时若还原会覆盖本机现有的
#     内核项目（restore 会把现有目录 mv 到 .bak 再 rsync 覆盖），有覆盖风险。
#     内核由 GitHub 仓库 clone + zig build 重建，缺失时 update-extensions.sh
#     自动回退 npm 包内联的旧 TS 内核（功能可用，无 Zig 原生加速）。
# ------------------------------------------------------------

# ------------------------------------------------------------
# 2. 技能不备份：~/.pi/agent/skills/ 是指向 ~/.skills-manager/skills/
#    的符号链接，技能由 skills-manager 应用管理，恢复时重新安装即可
#    （manifest.txt 会记录技能名列表）
# ------------------------------------------------------------

# ------------------------------------------------------------
# 3. 生成 manifest.txt（恢复时的依据）
# ------------------------------------------------------------
{
  echo "pi 配置备份清单"
  echo "================="
  echo "备份时间: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "用户名路径: 已脱敏（settings.json 内 \$HOME 占位，restore 时还原）"
  echo "pi 版本:  $(pi --version 2>/dev/null || echo '未知（见 settings.json lastChangelogVersion）')"
  echo
  echo "== 安装的 pi 包（恢复时 pi install 重装）=="
  python3 - "$AGENT_DIR/settings.json" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
print('\n'.join(cfg.get('packages', [])) or '(无)')
PY
  echo
  echo "== 扩展复现配方（node_modules 不备份，靠配方重装）=="
  echo "agent/npm/package.json + bun.lock"
  echo "恢复时: bun ci --omit=peer 重建 node_modules → update-extensions.sh 重新打包"
  echo
  b
  echo "== 技能列表（由 skills-manager 管理，不在备份内，恢复后需重新安装）=="
  ls "$SKILLS_DIR" 2>/dev/null || echo '(无)'
  echo
  echo
  echo "== 已排除内容 =="
  echo "私密:   agent/auth.json（登录凭据，恢复后需重新 /login）"
  echo "        agent/sessions/ agent/pi-sessions-extracted/ agent/state/ agent/missions/ run-history.jsonl"
  echo "可重建: agent/npm/（约 110M 的 node_modules；配方 package.json/bun.lock 已备份，恢复时 bun ci --omit=peer 重建）"
  echo "技能:   全部技能（约 383M，含 .venv/ 虚拟环境与媒体素材），"
  echo "        由 skills-manager 应用管理，恢复后重新安装即可"
} > "$DEST/manifest.txt"

# ------------------------------------------------------------
# 4. 收尾：大小统计 + 可选打包 + git 提示
# ------------------------------------------------------------
echo "==> 生成恢复说明副本"
cp "$(dirname "$0")/RESTORE.md" "$DEST/RESTORE.md" 2>/dev/null || true
cp "$SCRIPT_DIR/excludes.txt" "$DEST/excludes.txt" 2>/dev/null || true
cp "$(dirname "$0")/restore-pi.sh" "$DEST/restore-pi.sh" 2>/dev/null || true
chmod +x "$DEST/restore-pi.sh" 2>/dev/null || true

SIZE=$(du -sh "$DEST" | cut -f1)
echo "✅ 备份完成: $DEST ($SIZE)"

if [ "${PI_TAR:-0}" = "1" ]; then
  echo "==> 打包压缩 ..."
  tar czf "$DEST.tar.gz" -C "$BACKUP_ROOT" "$(basename "$DEST")"
  rm -rf "$DEST"
  echo "✅ 已打包: $DEST.tar.gz ($(du -sh "$DEST.tar.gz" | cut -f1))"
fi

cat <<EOF

下一步（可选）：
  cd "$BACKUP_ROOT"
  git init && git add -A && git commit -m "pi 配置备份 $(date +%Y%m%d)"
  # 推到 GitHub 私有仓库:
  #   git remote add origin <你的私有仓库地址> && git push -u origin main
EOF
