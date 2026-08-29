#!/usr/bin/env bash
# ============================================================
# pi 配置恢复脚本
# 用法: ./restore-pi.sh <备份目录或.tar.gz>
#   例如: ./restore-pi.sh pi-config-20260816-093000
#         ./restore-pi.sh pi-config-20260816-093000.tar.gz
# ============================================================
set -euo pipefail

SRC="${1:?用法: ./restore-pi.sh <备份目录或.tar.gz>}"
TMP=""

# 如果是 tar.gz 先解包
if [[ "$SRC" == *.tar.gz ]]; then
  TMP=$(mktemp -d)
  tar xzf "$SRC" -C "$TMP"
  SRC="$TMP/$(basename "$SRC" .tar.gz)"
fi

[ -d "$SRC/agent" ] || { echo "❌ $SRC 里没有 agent/ 目录，不是有效的备份"; exit 1; }

echo "==> 检查 pi 是否已安装 ..."
command -v pi >/dev/null || { echo "❌ 未找到 pi。请先安装 pi（建议与备份时同版本，见 manifest.txt），例如: mise use -g pi@<版本>"; exit 1; }
echo "    pi 版本: $(pi --version)"
echo "==> 检查 bun 是否已安装 ..."
command -v bun >/dev/null || { echo "❌ 未找到 bun。npmCommand 已切换为 bun，装包与重建 node_modules 都依赖它。请先安装: mise use -g bun（建议与备份时同版本）"; exit 1; }
echo "    bun 版本: $(bun --version)"

# ------------------------------------------------------------
# 1. 防呆：已有配置先备份移走
# ------------------------------------------------------------
if [ -e "$HOME/.pi" ] && [ -n "$(ls -A "$HOME/.pi" 2>/dev/null || true)" ]; then
  BAK="$HOME/.pi.bak.$(date +%s)"
  mv "$HOME/.pi" "$BAK"
  echo "ℹ️  已把现有 ~/.pi 移到 $BAK（可随时删掉）"
fi
mkdir -p "$HOME/.pi/agent"

# ------------------------------------------------------------
# 2. 恢复核心配置
# ------------------------------------------------------------
echo "==> 恢复核心配置 ..."
rsync -a "$SRC/agent/" "$HOME/.pi/agent/"

# ------------------------------------------------------------
# 2b. 还原 billion-context-pi 全局配置（~/.pi/acp.json 在 agent 目录外）
#     对应 backup-pi.sh 的 2.7 段；无此文件时跳过（未配置过 acp）
# ------------------------------------------------------------
if [ -f "$SRC/acp.json" ]; then
  cp "$SRC/acp.json" "$HOME/.pi/acp.json"
  echo "==> 已还原 ~/.pi/acp.json（billion-context-pi 全局配置）"
else
  echo "==> 备份中无 acp.json（billion-context-pi 未配置或旧备份），跳过"
fi

# ------------------------------------------------------------
# 3. 修正 settings.json 中的绝对路径（extensions 数组）
#    备份里是 $HOME 占位符（或旧格式 /home/xxx），换机后还原为实际路径
# ------------------------------------------------------------
echo "==> 修正 settings.json 中的绝对路径 ..."
python3 - "$HOME/.pi/agent/settings.json" <<'PY'
import json, os, re, sys
p = sys.argv[1]
cfg = json.load(open(p))
home = os.path.expanduser("~")
cfg["extensions"] = [
    re.sub(r'^/home/[^/]+(/\.pi/agent/)', home + r'\1', e.replace("$HOME", home))
    for e in cfg.get("extensions", [])
]
json.dump(cfg, open(p, "w"), indent=2, ensure_ascii=False)
print("    已修正 extensions 路径")
PY

# ------------------------------------------------------------
# 4. 恢复技能真实内容 + 重建符号链接
# ------------------------------------------------------------
# ------------------------------------------------------------
# 4. 技能由 skills-manager 应用管理，不在备份内
#    只创建空的 skills 目录，等用户重装技能后再建符号链接
# ------------------------------------------------------------
mkdir -p "$HOME/.pi/agent/skills"
if command -v skills-manager >/dev/null 2>&1; then
  echo "==> 检测到 skills-manager，技能请重新安装（见 RESTORE.md）"
else
  echo "==> 未检测到 skills-manager（桌面应用），技能恢复方式见 RESTORE.md"
fi
# ------------------------------------------------------------
# ------------------------------------------------------------
# 4b. billion-context-pi Zig 内核项目（acp-kernel-zig）不还原
#     备份不再包含内核项目；内核由 GitHub 仓库 clone + zig build 重建（见 RESTORE.md），
#     缺失时 update-extensions.sh 自动回退 npm 包内联的旧 TS 内核（功能可用，无 Zig 原生加速）。
# ------------------------------------------------------------

# ------------------------------------------------------------
# 5. 重建扩展环境：node_modules + 编译产物
#    node_modules 不备份，依据备份的 package.json/bun.lock 重建
#    npmCommand 已切换为 bun：必须用 bun ci --omit=peer
#    （--omit=peer 跳过 @earendil-works/pi-* 等由 pi 宿主注入的 peer 依赖，与 pi 安装参数一致）
# ------------------------------------------------------------
echo "==> 恢复 bun 依赖配方（package.json / bun.lock）..."
if [ -d "$SRC/agent/npm" ]; then
  mkdir -p "$HOME/.pi/agent/npm"
  cp "$SRC/agent/npm/"* "$HOME/.pi/agent/npm/" 2>/dev/null || true
  ls "$HOME/.pi/agent/npm/"
fi

echo "==> 注册 pi 包（settings.json 的 packages 列表，pi install 走 bun）..."
python3 - "$HOME/.pi/agent/settings.json" <<'PY' | while read -r pkg; do
import json, sys
cfg = json.load(open(sys.argv[1]))
for p in cfg.get("packages", []):
    print(p)
PY
  [ -z "$pkg" ] && continue
  echo "    pi install $pkg"
  pi install "$pkg" || echo "    ⚠️  安装 $pkg 失败（可稍后手动: pi install $pkg）"
done

echo "==> bun ci 重建 node_modules（依据 bun.lock，需联网）..."
if [ -f "$HOME/.pi/agent/npm/bun.lock" ]; then
  (cd "$HOME/.pi/agent/npm" && bun ci --omit=peer) || {
    echo "    ⚠️  bun ci 失败，改用 bun install --omit=peer ..."
    (cd "$HOME/.pi/agent/npm" && bun install --omit=peer) || echo "    ⚠️  bun install 失败，请联网后手动执行: cd ~/.pi/agent/npm && bun ci --omit=peer"
  }
else
  echo "    ⚠️  无 bun.lock（旧备份只有 package-lock.json？），改用 bun install --omit=peer（重新解析并生成 bun.lock）"
  (cd "$HOME/.pi/agent/npm" && bun install --omit=peer) || echo "    ⚠️  bun install 失败，请联网后手动执行: cd ~/.pi/agent/npm && bun install --omit=peer"
fi

echo "==> 重新打包扩展编译产物 ..."
if [ -f "$HOME/.pi/agent/compiled/update-extensions.sh" ]; then
  (cd "$HOME/.pi/agent/compiled" && bash update-extensions.sh --build-only) \
    || echo "    ⚠️  打包失败，可稍后手动: bash ~/.pi/agent/compiled/update-extensions.sh --build-only"
else
  echo "    缺少 update-extensions.sh，跳过打包"
  echo "    （compiled/ 已有备份产物，直接重启 pi 通常也能用）"
fi

# ------------------------------------------------------------
# 6. 收尾
# ------------------------------------------------------------
[ -n "$TMP" ] && rm -rf "$TMP"

cat <<EOF

✅ 配置恢复完成！

接下来请完成（见 RESTORE.md）:
1. 运行 pi，执行 /login 重新登录（auth.json 凭据未备份）
2. 设置 provider 的 API key 环境变量（如 OPENROUTER_API_KEY、XAI_API_KEY 等）
3. 若扩展仍报错: rm -rf ~/.pi/agent/compiled && 重启 pi（自动重新编译）
4. 技能（由 skills-manager 应用管理，不在备份内）:
     安装 skills-manager 并重新安装需要的技能（列表见 manifest.txt）
     若符号链接未自动重建，手动执行:
       for d in ~/.skills-manager/skills/*/; do
         ln -sfn "$d" ~/.pi/agent/skills/"$(basename "$d")"
       done
5. 各项目目录下的项目级配置（.pi/settings.json 等）请自行复制
6. 检查恢复效果: pi 里执行 /settings 和 /theme
7. 内核项目（acp-kernel-zig）不随备份还原：换机后如需 Zig 原生内核，请 clone 内核仓库并重建（见 RESTORE.md）：
      git clone <内核仓库> ~/Code/TypeScript/billion-context-pi-zig/acp-kernel-zig
      cd ~/Code/TypeScript/billion-context-pi-zig/acp-kernel-zig && zig build
      （或设 BUILD_KERNEL=1 重跑 bash ~/.pi/agent/compiled/update-extensions.sh --build-only 自动重建，详见 RESTORE.md）
EOF
