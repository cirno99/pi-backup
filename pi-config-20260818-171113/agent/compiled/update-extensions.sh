#!/usr/bin/env bash
# pi 扩展构建 + 一键更新脚本（合并自原 build.sh 与 update-extensions.sh）
# 用法：
#   ./update-extensions.sh           更新所有扩展包并重新打包（完整流程）
#   ./update-extensions.sh --build-only   只重新打包编译产物（等价原 build.sh）
#   ./update-extensions.sh --skip-update  更新 settings 包 + 打包，跳过依赖更新（--skip-npm 为兼容旧名）
#
# 完整流程：
#   1) pi update --extensions        更新 settings.json packages 里的包
#   2) bun update（npm/ 目录）       更新所有 dependencies（含 pi-readseek 这类
#                                     已移出 settings packages、由 package.json 管理的包）
#   3) 打包                          重新 bundle 编译产物 + 确保 compiled/node_modules 链接
#   4) 校验产物                      提示重启 pi 生效
#
# 说明：
#   - pi-readseek 已从 settings.json 的 packages 移除（改用 compiled/pi-readseek.js 编译产物），
#     pi update 不认识它（会报 No matching package），所以靠步骤 2 的 bun update 更新。
#   - 换电脑/迁移后：装好 pi、拷 ~/.pi/agent 后重跑本脚本即可自动重建链接与产物。
#   - 依赖管理已切换为 bun（settings.json 的 npmCommand = ["bun"]）：装依赖、更新、打包都用 bun；
#     --build-only 模式不需要网络。bun 自带全局缓存，重建/更新极快。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
NPM_DIR="$HOME/.pi/agent/npm"
SETTINGS="$HOME/.pi/agent/settings.json"

# ==================== 打包配置（原 build.sh） ====================

# 打包目标：入口 -> 产物文件名（statusline 单独处理，见下方 build_statusline）
declare -A ENTRIES=(
  ["pi-observational-memory/src/index.ts"]="pi-observational-memory.js"
  ["@tintinweb/pi-subagents/src/index.ts"]="@tintinweb-pi-subagents.js"
  ["@juicesharp/rpiv-web-tools/index.ts"]="@juicesharp-rpiv-web-tools.js"
  ["pi-rtk-optimizer/index.ts"]="pi-rtk-optimizer.js"
  ["pi-cache-optimizer/index.ts"]="pi-cache-optimizer.js"
  ["@juicesharp/rpiv-ask-user-question/index.ts"]="@juicesharp-rpiv-ask-user-question.js"
  ["@narumitw/pi-btw/src/index.ts"]="@narumitw-pi-btw.js"
  ["@narumitw/pi-lsp/src/index.ts"]="@narumitw-pi-lsp.js"
  ["pi-readseek/dist/index.ts"]="pi-readseek.js"
)

# pi 内置提供的模块（loader.ts 的 VIRTUAL_MODULES），必须 external，不能打进 bundle
EXTERNAL=(--external "node:*" --external "@earendil-works/*" --external "@mariozechner/*"
  --external "typebox" --external "typebox/*" --external "@sinclair/typebox" --external "@sinclair/typebox/*")
# pi-btw 额外依赖 @narumitw/pi-tui-kit（~380KB，仅 /btw 菜单交互时动态 import 使用）。
# 打进 bundle 会膨胀到 1MB、拖慢启动（16ms）；external 后产物仅 ~45KB，运行时经 compiled/node_modules 链接解析。
PI_BTW_EXTERNAL=(--external "@narumitw/pi-tui-kit")
# pi-readseek 额外依赖 diff、xxhash-wasm（运行时经 compiled/node_modules 链接解析，避免打进 bundle）
PI_READSEEK_EXTERNAL=(--external "diff" --external "xxhash-wasm")

# --- statusline 打包（本地维护版 pi-statusline）---
# 说明：自 @normful/pi-statusline@0.3.1 剥离为自有扩展，源码在 extensions/pi-statusline，
#       零运行时依赖、含 git 分支显示，直接 bundle 约 8.5KB。
#       本地定制：footer 缓存命中率（如 87%c）、thinking 图标 ◆（替代生僻字符 ⟐）。
build_statusline() {
  local src_dir="$HOME/.pi/agent/extensions/pi-statusline/src"
  [ -f "$src_dir/index.ts" ] || { echo "跳过 statusline（本地源码不存在）"; return; }
  echo "打包 statusline（本地维护版）-> pi-statusline.js"
  (cd "$HOME/.pi/agent/extensions/pi-statusline" \
    && bun build src/index.ts \
       --outfile "$HERE/pi-statusline.js" --format esm --minify \
       "${EXTERNAL[@]}")
}

# pi-rtk-optimizer 通过 createLazyModuleLoader("./output-compactor.js")（变量字符串动态 import）
# 懒加载 output-compactor.ts，bun 无法静态分析该 specifier，bundle 里保留为运行时
# import("./output-compactor.js")。若不打出来，运行时会报
# "Cannot find module './output-compactor.js'"，output compaction 降级为 raw output。
# 因此必须把 output-compactor.ts 单独打成 compiled/output-compactor.js 供运行时解析。
build_output_compactor() {
  local src="$NPM_DIR/node_modules/pi-rtk-optimizer/src/output-compactor.ts"
  [ -f "$src" ] || { echo "跳过 output-compactor（源码不存在）"; return; }
  echo "打包 pi-rtk-optimizer/src/output-compactor.ts -> output-compactor.js"
  (cd "$NPM_DIR/node_modules/pi-rtk-optimizer" \
    && bun build src/output-compactor.ts \
       --outfile "$HERE/output-compactor.js" --format esm --minify \
       "${EXTERNAL[@]}")
}

# 打包全部编译产物（原 build.sh 主体）
build_all() {
  local src out entry extra_ext
  build_statusline

  for entry in "${!ENTRIES[@]}"; do
    out="${ENTRIES[$entry]}"
    src="$NPM_DIR/node_modules/$entry"
    if [ ! -f "$src" ]; then
      echo "跳过（入口不存在）: $entry"
      continue
    fi
    echo "打包 $entry -> $out"
    extra_ext=()
    if [ "$out" = "@narumitw-pi-btw.js" ]; then
      extra_ext=("${PI_BTW_EXTERNAL[@]}")
    elif [ "$out" = "pi-readseek.js" ]; then
      extra_ext=("${PI_READSEEK_EXTERNAL[@]}")
    fi
    (cd "$NPM_DIR/node_modules/$(dirname "$entry")" \
      && bun build "$src" \
         --outfile "$HERE/$out" --format esm --minify \
         "${EXTERNAL[@]}" "${extra_ext[@]}")
  done

  # output-compactor.js（pi-rtk-optimizer 懒加载依赖，见 build_output_compactor 注释）
  build_output_compactor

  # 编译产物目录建 node_modules 链接：external 的 npm 依赖（如 @narumitw/pi-tui-kit）运行时从这解析
  # （pi 按扩展文件所在目录向上找 node_modules；compiled/ 不在 npm 包目录里，不建链接会解析失败）
  if [ ! -e "$HERE/node_modules" ]; then
    ln -s "$NPM_DIR/node_modules" "$HERE/node_modules"
    echo "已创建 $HERE/node_modules -> $NPM_DIR/node_modules"
  fi
}

# ==================== 主流程 ====================

BUILD_ONLY=false
SKIP_UPDATE=false
case "${1:-}" in
  --build-only)   BUILD_ONLY=true ;;
  --skip-update)  SKIP_UPDATE=true ;;
  --skip-npm)     SKIP_UPDATE=true ;;   # 兼容旧参数名
  "" ) ;;
  * ) echo "未知参数: $1（支持 --build-only / --skip-update）"; exit 1 ;;
esac

# --- 前置检查 ---
command -v bun >/dev/null 2>&1 || { echo "✗ 未找到 bun（打包编译产物需要）"; exit 1; }
[ -d "$NPM_DIR/node_modules" ] || { echo "✗ 未找到 $NPM_DIR/node_modules（扩展包未安装，先装包再打包）"; exit 1; }

if $BUILD_ONLY; then
  echo "=== 只重新打包编译产物（--build-only）==="
  build_all
  echo
  echo "=== 打包完成 ✅ 重启 pi 生效 ==="
  exit 0
fi

echo "=== pi 扩展一键更新脚本 ==="
echo "工作目录: $HERE"
echo

command -v pi >/dev/null 2>&1 || { echo "✗ 未找到 pi 命令"; exit 1; }
[ -f "$SETTINGS" ] || { echo "✗ 未找到 $SETTINGS"; exit 1; }

# --- 备份 settings.json（防呆）---
cp "$SETTINGS" "$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
echo "✓ 已备份 settings.json"

# --- 1. 更新 settings.json packages 里的包 ---
echo
echo "--- [1/4] pi update --extensions（settings packages）---"
if pi update --extensions; then
  echo "✓ settings 包更新完成"
else
  echo "⚠ pi update --extensions 返回非零（可能网络问题或无更新），继续执行"
fi

# --- 2. bun update（含 pi-readseek 等已移出 packages 的包）---
#      --omit=peer 与 pi 安装参数保持一致：跳过 @earendil-works/pi-* 等由 pi 宿主注入的 peer 依赖
if $SKIP_UPDATE; then
  echo
  echo "--- [2/4] 跳过依赖更新（--skip-update）---"
else
  echo
  echo "--- [2/4] bun update（npm/ 目录全部 dependencies）---"
  (
    cd "$NPM_DIR"
    if bun update --omit=peer 2>&1; then
      echo "✓ bun 依赖更新完成"
    else
      echo "⚠ bun update 返回非零，继续执行（可能个别包更新失败）"
    fi
  )
fi

# --- 3. 重新打包编译产物 ---
echo
echo "--- [3/4] 重新打包编译产物 ---"
build_all

# --- 4. 校验产物与链接 ---
echo
echo "--- [4/4] 校验 ---"
[ -e "$HERE/node_modules" ] && echo "✓ compiled/node_modules 链接存在: $(readlink "$HERE/node_modules")" \
  || echo "⚠ compiled/node_modules 链接缺失（打包步骤应已创建，请检查）"

# 校验关键产物存在且非空
for f in pi-statusline.js pi-readseek.js @narumitw-pi-btw.js output-compactor.js; do
  if [ -s "$HERE/$f" ]; then
    echo "✓ $f ($(du -h "$HERE/$f" | cut -f1))"
  else
    echo "✗ $f 缺失或为空！"
    exit 1
  fi
done

echo
echo "=== 完成 ✅ ==="
echo "请退出当前 pi 会话后重新启动，扩展变更才会生效。"
echo "若本次更新后启动异常，可回滚 settings.json："
latest_bak="$(ls -t "$HOME/.pi/agent/settings.json.bak."* 2>/dev/null | head -1)"
if [ -n "$latest_bak" ]; then
  echo "  cp \"$latest_bak\" \"$SETTINGS\""
else
  echo "  （未找到备份，可手工编辑 $SETTINGS）"
fi
