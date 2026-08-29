#!/usr/bin/env bun
//! verify-acp-kernel —— billion-context-pi 内核模式自查脚本
//!
//! 判定当前安装的 billion-context-pi 是「bun:ffi + Zig 原生内核」(FFI 模式)
//! 还是回退到了「旧全 TS 内核」(TS 模式)。
//!
//! 判定依据(从硬到软):
//!   1. 运行中的 pi 进程 /proc/<pid>/maps 是否已映射 libacp_kernel.so(含 r-xp 可执行段 → 已执行过)
//!   2. 独立 bun 进程走与 pi 运行时相同的解析链(compiled/node_modules/acp-kernel 符号链接),
//!      调用 refs/index_to_ref(该 API 100% 走 FFI syncCall)后再查自身 maps
//!   3. 扩展 package.json 的 description / 依赖声明佐证
//!
//! 用法:
//!   verify-acp-kernel              # 全面检查(pi 进程 maps + 独立 smoke)
//!   verify-acp-kernel --no-smoke   # 只查运行中 pi 进程的 maps(更快)
//!   verify-acp-kernel --smoke-only # 只跑独立进程 smoke 测试
//!
//! 退出码: 0 = FFI 模式正常; 1 = 发现异常(回退 TS / 库缺失 / 无法判定)

import { existsSync, readFileSync } from "node:fs";
import { join, dirname, basename } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { execFileSync } from "node:child_process";

const HERE = dirname(fileURLToPath(import.meta.url));
const EXT_DIR = join(HERE, "..", "extensions", "billion-context-pi");
const COMPILED_DIR = join(HERE, "..", "compiled");
const ENTRY_DIR = join(COMPILED_DIR, "node_modules", "acp-kernel");
const SO_PATTERN = /libacp_kernel\.(?:so|dylib)/;

const args = new Set(process.argv.slice(2));
const noSmoke = args.has("--no-smoke");
const smokeOnly = args.has("--smoke-only");

// ---------------------------------------------------------------------------
// 工具:找运行中的 pi 进程(按进程名,兜底按二进制路径)
// ---------------------------------------------------------------------------
function findPiPids() {
  const pids = new Set();
  try {
    // 优先:进程名精确匹配
    const out = execFileSync("pgrep", ["-x", "pi"], { encoding: "utf8" });
    out.trim().split(/\s+/).filter(Boolean).forEach((p) => pids.add(Number(p)));
  } catch { /* 无匹配 */ }
  if (pids.size === 0) {
    // 兜底:按 pi 二进制路径特征匹配(过滤掉 grep 自身)
    try {
      const out = execFileSync("pgrep", ["-f", "mise/installs/pi/[0-9.]+/pi/pi"], {
        encoding: "utf8",
      });
      out.trim().split(/\s+/).filter(Boolean).forEach((p) => pids.add(Number(p)));
    } catch { /* 无匹配 */ }
  }
  // 排除自身(本脚本也是 bun 进程,但进程名是 bun,不会撞上)
  pids.delete(process.pid);
  return [...pids].sort((a, b) => a - b);
}

// 检查单个 pid 的 maps,返回 { mapped: boolean, segments: string[], executable: boolean }
function checkMaps(pid) {
  try {
    const maps = readFileSync(`/proc/${pid}/maps`, "utf8");
    const hits = maps.split("\n").filter((l) => SO_PATTERN.test(l));
    if (hits.length === 0) return { mapped: false, segments: [], executable: false };
    const segments = hits.map((l) => {
      const [range, perms] = l.split(/\s+/);
      const file = l.split(/\s+/).slice(-1)[0].split("/").pop();
      return `${range} ${perms} ${file}`;
    });
    return { mapped: true, segments, executable: hits.some((l) => /r-xp/.test(l)) };
  } catch (e) {
    return { mapped: false, segments: [], executable: false, error: String(e.message ?? e) };
  }
}

// ---------------------------------------------------------------------------
// 1) 运行中 pi 进程的 maps 检查
// ---------------------------------------------------------------------------
function checkRunningPis() {
  const pids = findPiPids();
  if (pids.length === 0) {
    console.log("ℹ️  未发现运行中的 pi 进程(maps 检查跳过)");
    return { found: false, ffi: false };
  }
  let anyFfi = false;
  for (const pid of pids) {
    const r = checkMaps(pid);
    const state = !r.mapped
      ? "❌ 未加载 .so(TS 回退 / 尚未触发内核调用)"
      : r.executable
        ? "✅ FFI 生效:Zig 原生内核已 dlopen 且执行过"
        : "⚠️  已映射但无可执行段(仅数据段,异常)";
    if (r.executable) anyFfi = true;
    console.log(`\n[pi 进程 ${pid}] ${state}`);
    r.segments.forEach((s) => console.log(`    ${s}`));
    if (r.error) console.log(`    (读取 maps 失败: ${r.error})`);
  }
  return { found: true, ffi: anyFfi };
}

// ---------------------------------------------------------------------------
// 2) 独立进程 smoke:走运行时解析链,触发 FFI 后再查自身 maps
// ---------------------------------------------------------------------------
async function runSmoke() {
  console.log("\n[独立 smoke 测试] 走运行时解析链触发内核调用……");
  const entry = resolveEntry();
  if (!entry) {
    console.log("❌ 找不到内核入口(compiled/node_modules/acp-kernel 缺失?)\n   预期: " + ENTRY_DIR);
    return { ok: false, ffi: false, tsFallback: false };
  }
  console.log(`   入口: ${entry}`);

  let api;
  try {
    api = await import(pathToFileURL(entry).href);
  } catch (e) {
    console.log(`❌ import 内核失败: ${String(e.message ?? e).slice(0, 300)}`);
    return { ok: false, ffi: false, tsFallback: false };
  }

  // 3 个调用:indexToRef / refToIndex 100% 走 syncCall("refs/*");defaultCountTokens 走 tokenize
  const results = [];
  const call = (label, fn) => {
    try {
      const v = fn();
      results.push(`   ✅ ${label} → ${JSON.stringify(v)}`);
      return true;
    } catch (e) {
      const msg = String(e.message ?? e).slice(0, 200);
      results.push(`   ❌ ${label} → ${msg}`);
      return false;
    }
  };
  const ok1 = call("indexToRef(5)", () => api.indexToRef?.(5));
  const ok2 = ok1 && call(`refToIndex(${JSON.stringify(api.indexToRef?.(5))})`, () => api.refToIndex?.(api.indexToRef?.(5)));
  const ok3 = call('defaultCountTokens("hello acp kernel hello")', () => api.defaultCountTokens?.("hello acp kernel hello"));
  console.log(results.join("\n"));

  const tsFallback = ok1 && !ok2; // 仅 indexToRef 成功但 round-trip 失败 → 可疑
  const missingLib = results.some((r) => r.includes("原生库未找到"));

  // 查自身 maps
  const self = checkMaps(process.pid);
  if (self.mapped) {
    console.log(`\n✅ 本进程已加载 Zig 原生内核(${self.segments.length} 段映射):`);
    self.segments.forEach((s) => console.log(`    ${s}`));
    return { ok: true, ffi: true, tsFallback };
  }
  if (missingLib) {
    console.log("\n❌ 报错「acp-kernel 原生库未找到」→ 走的是旧全 TS 内核(回退模式)");
    return { ok: false, ffi: false, tsFallback: true };
  }
  console.log("\n⚠️  调用成功但本进程 maps 无 .so → 功能层未走原生库(疑似 TS 回退)");
  return { ok: true, ffi: false, tsFallback: true };
}

function resolveEntry() {
  const pkgPath = join(ENTRY_DIR, "package.json");
  if (!existsSync(pkgPath)) return null;
  try {
    const pkg = JSON.parse(readFileSync(pkgPath, "utf8"));
    const rel =
      pkg?.exports?.["."]?.import ??
      pkg?.exports?.["."]?.default ??
      pkg?.module ??
      pkg?.main ??
      "dist/index.js";
    const abs = join(ENTRY_DIR, rel.replace(/^\.\//, ""));
    return existsSync(abs) ? abs : join(ENTRY_DIR, "dist", "index.js");
  } catch {
    return join(ENTRY_DIR, "dist", "index.js");
  }
}

// ---------------------------------------------------------------------------
// 3) 扩展配置佐证
// ---------------------------------------------------------------------------
function showConfig() {
  const pkgPath = join(EXT_DIR, "package.json");
  if (!existsSync(pkgPath)) {
    console.log("ℹ️  未找到扩展 package.json: " + EXT_DIR);
    return;
  }
  try {
    const pkg = JSON.parse(readFileSync(pkgPath, "utf8"));
    console.log(`\n[扩展配置] billion-context-pi v${pkg.version}`);
    console.log(`   描述: ${pkg.description ?? "(无)"}`);
    const dep = pkg.devDependencies?.["acp-kernel"] ?? pkg.dependencies?.["acp-kernel"];
    if (dep) console.log(`   acp-kernel 依赖: ${dep}`);
  } catch (e) {
    console.log(`⚠️  读取扩展 package.json 失败: ${String(e.message ?? e)}`);
  }
}

// ---------------------------------------------------------------------------
// 主流程 + 综合判定
// ---------------------------------------------------------------------------
let exitCode = 0;

console.log("═".repeat(60));
console.log(" verify-acp-kernel —— billion-context-pi 内核模式自查");
console.log("═".repeat(60));

if (smokeOnly) {
  const s = await runSmoke();
  if (!s.ffi) exitCode = 1;
} else if (noSmoke) {
  const p = checkRunningPis();
  if (!p.ffi) exitCode = 1;
} else {
  const p = checkRunningPis();
  const s = await runSmoke();

  console.log("\n" + "═".repeat(60));
  console.log(" 综合判定");
  console.log("═".repeat(60));
  const runningFfi = p.found && p.ffi;
  const smokeFfi = s.ffi;
  if (runningFfi) {
    console.log(" ✅ 运行中的 pi 进程已 dlopen Zig 原生内核 → FFI 模式生效");
    exitCode = 0;
  } else if (smokeFfi) {
    console.log(" ✅ 独立进程走同一解析链可加载原生内核 → FFI 模式可用(pi 进程未加载,可能尚未触发内核调用)");
    exitCode = 0;
  } else if (s.tsFallback) {
    console.log(" ❌ 调用成功但无 .so → 回退到了旧全 TS 内核模式");
    exitCode = 1;
  } else {
    console.log(" ⚠️  无法判定(请确认扩展与内核已安装:compiled/node_modules/acp-kernel)");
    exitCode = 1;
  }
  showConfig();
}

console.log("");
process.exit(exitCode);
