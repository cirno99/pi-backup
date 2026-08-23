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
  # [已移除] billion-context-pi 不再从 npm 发行包打包，改由本地维护版 build_bcpi 重建（见下方函数）
  ["@juicesharp/rpiv-web-tools/index.ts"]="@juicesharp-rpiv-web-tools.js"
  ["pi-rtk-optimizer/index.ts"]="pi-rtk-optimizer.js"
  ["pi-cache-optimizer/index.ts"]="pi-cache-optimizer.js"
  ["@juicesharp/rpiv-ask-user-question/index.ts"]="@juicesharp-rpiv-ask-user-question.js"
  ["@narumitw/pi-btw/src/index.ts"]="@narumitw-pi-btw.js"
  ["@narumitw/pi-lsp/src/index.ts"]="@narumitw-pi-lsp.js"
  ["pi-readseek/dist/index.ts"]="pi-readseek.js"
)

# billion-context-pi 是预编译的 dist/index.js（非 TS 源码），bun 默认按 browser 目标打包会报
# "Browser build cannot import Node.js builtin"，必须显式 --target bun（打包头带 // @bun）
BILLION_TARGET=(--target bun)

# --- Zig 内核（acp-kernel-zig）---
# billion-context-pi 已切换为 bun:ffi + Zig 内核（acp-kernel-zig）：
#   职责边界：**内核构建归内核项目**（cd acp-kernel-zig && npm run build:release：
#   zig native ReleaseFast + dist）；本脚本只做「链接/移动内核产物」——产物不完整时
#   提示构建（BUILD_KERNEL=1 可自动调用内核项目脚本），然后链接到宿主/compiled
#   node_modules 并把宿主 bundle 产物移动到位。
#   宿主构建（tsup → dist/index.js）同样归宿主项目（extensions/billion-context-pi），
#   脚本仅调用其 npm run build。
#   宿主 tsup.config.ts 已 external "acp-kernel"（不内联旧 TS 内核），bundle 后运行时
#   从 compiled/node_modules/acp-kernel 解析；内核 = native/zig-out/lib/*.so（原生算法）
#   + dist（TS 封装层，exports . ./wire ./panel ./persist）。
# 路径可用环境变量覆盖（换电脑/迁移时指向各自位置）。
ACP_KERNEL_ZIG="${ACP_KERNEL_ZIG:-$HOME/Code/TypeScript/billion-context-pi-zig/acp-kernel-zig}"
BILLION_SRC="${BILLION_SRC:-$HOME/.pi/agent/extensions/billion-context-pi}"

# pi 内置提供的模块（loader.ts 的 VIRTUAL_MODULES），必须 external，不能打进 bundle
# acp-kernel 也必须 external：billion-context-pi 宿主依赖链上的内核 dist（bridge.ts）若被内联进 bundle，
# 其 import.meta.url 会指向 compiled/，而 bridge 靠 import.meta.url 向上找 native/zig-out/lib，
# 内核项目不在 ~/.pi 树内 → 原生库永远找不到。external 后运行时经 compiled/node_modules/acp-kernel
# 链接解析，bridge 的 import.meta.url 位于内核 dist 内，向上 1 层即命中 native/zig-out/lib。
EXTERNAL=(--external "node:*" --external "@earendil-works/*" --external "@mariozechner/*"
  --external "typebox" --external "typebox/*" --external "@sinclair/typebox" --external "@sinclair/typebox/*"
  --external "acp-kernel")
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

# --- command-code provider 打包（本地维护版 pi-command-code-provider）---
# 说明：自 codeberg.org/jr2804/pi-command-code-provider 剥离为自有扩展，源码在
#       extensions/pi-command-code-provider/src，单文件零运行时依赖（仅 type import
#       @earendil-works/pi-coding-agent），直接 bundle 约 2KB。
build_command_code() {
  local src_dir="$HOME/.pi/agent/extensions/pi-command-code-provider/src"
  [ -f "$src_dir/index.ts" ] || { echo "跳过 command-code provider（本地源码不存在）"; return; }
  echo "打包 command-code provider（本地维护版）-> pi-command-code-provider.js"
  (cd "$HOME/.pi/agent/extensions/pi-command-code-provider" \
    && bun build src/index.ts \
       --outfile "$HERE/pi-command-code-provider.js" --format esm --minify \
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

# --- billion-context-pi 打包（Zig 内核模式）---
# 完整链路：原生库（ReleaseFast）→ 内核 dist（tsup+tsc）→ 宿主 node_modules/acp-kernel
# 链接 → 宿主 rebuild（tsup external "acp-kernel"）→ bundle 到 compiled →
# compiled/node_modules/acp-kernel 链接（运行时解析点）。任一步失败即 return 1。
build_bcpi() {
  if [ ! -f "$ACP_KERNEL_ZIG/native/build.zig" ] || [ ! -d "$BILLION_SRC" ]; then
    echo "⚠ Zig 内核路径不可用（ACP_KERNEL_ZIG=$ACP_KERNEL_ZIG / BILLION_SRC=$BILLION_SRC）"
    echo "  回退：从 npm 发行包 billion-context-pi/dist 打包（旧全 TS 内核）"
    local src="$NPM_DIR/node_modules/billion-context-pi/dist/index.js"
    [ -f "$src" ] || { echo "✗ npm 发行包入口不存在: $src"; return 1; }
    (cd "$NPM_DIR/node_modules/billion-context-pi" \
      && bun build "$src" --outfile "$HERE/billion-context-pi.js" --format esm --minify \
         "${EXTERNAL[@]}" "${BILLION_TARGET[@]}") || return 1
    return 0
  fi

  echo ">>> billion-context-pi（Zig 内核模式）"
  echo "  内核: $ACP_KERNEL_ZIG"
  echo "  宿主: $BILLION_SRC"

  # 1) 内核产物检查 —— 构建职责在内核项目（package.json build:release），
  #    本脚本只做「链接/移动内核产物」：产物不完整则提示构建，不在此处内联构建逻辑。
  #    BUILD_KERNEL=1 时自动调用内核项目的一键构建脚本。
  local need_build=0
  [ -e "$ACP_KERNEL_ZIG/native/zig-out/lib/libacp_kernel.so" ] || { echo "  ⚠ 原生库缺失"; need_build=1; }
  [ -e "$ACP_KERNEL_ZIG/dist/index.js" ] || { echo "  ⚠ 内核 dist 缺失"; need_build=1; }
  if [ "$need_build" = 1 ]; then
    if [ "${BUILD_KERNEL:-0}" = 1 ]; then
      echo "  构建内核产物（BUILD_KERNEL=1 显式请求；逻辑在内核项目 build:release）"
      (cd "$ACP_KERNEL_ZIG" && npm run build:release) || { echo "✗ 内核构建失败"; return 1; }
    else
      echo "✗ 内核产物不完整。构建在内核项目完成，请先执行："
      echo "    cd $ACP_KERNEL_ZIG && npm run build:release"
      echo "  （或在命令前加 BUILD_KERNEL=1 由本脚本自动调用上述命令）"
      return 1
    fi
  fi

  # 2) 链接内核产物到宿主 node_modules（目标不一致才重建）
  echo "  [1/3] 链接内核产物 -> 宿主 node_modules/acp-kernel"
  mkdir -p "$BILLION_SRC/node_modules"
  if [ -e "$BILLION_SRC/node_modules/acp-kernel" ]; then
    if [ "$(readlink "$BILLION_SRC/node_modules/acp-kernel")" != "$ACP_KERNEL_ZIG" ]; then
      ln -sfn "$ACP_KERNEL_ZIG" "$BILLION_SRC/node_modules/acp-kernel"
      echo "    已重新链接 -> $ACP_KERNEL_ZIG"
    else
      echo "    已指向正确: $ACP_KERNEL_ZIG"
    fi
  else
    ln -s "$ACP_KERNEL_ZIG" "$BILLION_SRC/node_modules/acp-kernel"
    echo "    已创建 -> $ACP_KERNEL_ZIG"
  fi

  # 3) 宿主构建（宿主项目自己的脚本，产出 dist/index.js）
  #    devDeps（tsup）缺失时给出手动安装提示
  if [ ! -e "$BILLION_SRC/node_modules/.bin/tsup" ]; then
    echo "✗ 宿主缺 tsup：cd $BILLION_SRC && npm i -D tsup typescript"; return 1
  fi
  echo "  [2/3] npm run build（宿主 dist/index.js）"
  (cd "$BILLION_SRC" && npm run build) \
    || { echo "✗ 宿主构建失败（确认 tsup.config.ts 已 external \"acp-kernel\"）"; return 1; }

  # 4) bundle 宿主产物 -> compiled（移动产物）
  echo "  [3/3] bun build dist/index.js -> compiled/billion-context-pi.js"
  (cd "$BILLION_SRC" \
    && bun build dist/index.js \
       --outfile "$HERE/billion-context-pi.js" --format esm --minify \
       "${EXTERNAL[@]}" "${BILLION_TARGET[@]}") || { echo "✗ bundle 失败"; return 1; }

  # 5) 链接内核产物到 compiled/node_modules（运行时 import "acp-kernel" 的解析点）
  echo "     链接内核产物 -> compiled/node_modules/acp-kernel"
  if [ -e "$HERE/node_modules/acp-kernel" ]; then
    if [ "$(readlink "$HERE/node_modules/acp-kernel")" != "$ACP_KERNEL_ZIG" ]; then
      ln -sfn "$ACP_KERNEL_ZIG" "$HERE/node_modules/acp-kernel"
      echo "    已重新链接 -> $ACP_KERNEL_ZIG"
    fi
  else
    ln -s "$ACP_KERNEL_ZIG" "$HERE/node_modules/acp-kernel"
    echo "    已创建 -> $ACP_KERNEL_ZIG"
  fi
  echo "  ✓ billion-context-pi 产物已就位"
}
build_all() {
  local src out entry extra_ext
  build_statusline
  build_command_code
  build_bcpi

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
    extra_target=()
    (cd "$NPM_DIR/node_modules/$(dirname "$entry")" \
      && bun build "$src" \
         --outfile "$HERE/$out" --format esm --minify \
         "${EXTERNAL[@]}" "${extra_ext[@]}" "${extra_target[@]}")
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

# 校验 Zig 内核链接与原生库（billion-context-pi 运行时依赖）
if [ -e "$HERE/node_modules/acp-kernel" ]; then
  echo "✓ compiled/node_modules/acp-kernel -> $(readlink "$HERE/node_modules/acp-kernel")"
  if [ -e "$HERE/node_modules/acp-kernel/native/zig-out/lib/libacp_kernel.so" ]; then
    echo "✓ 原生库存在: native/zig-out/lib/libacp_kernel.so"
  else
    echo "⚠ 原生库缺失！检查 ACP_KERNEL_ZIG（当前: $ACP_KERNEL_ZIG）后重跑 --build-only"
  fi
else
  echo "⚠ compiled/node_modules/acp-kernel 链接缺失（billion-context-pi 运行时将解析不到 acp-kernel）"
fi
# 校验关键产物存在且非空
for f in pi-statusline.js pi-readseek.js billion-context-pi.js @narumitw-pi-btw.js output-compactor.js; do
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
