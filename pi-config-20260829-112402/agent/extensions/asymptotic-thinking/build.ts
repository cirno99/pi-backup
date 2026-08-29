// build.ts — 编译版构建脚本（bun build 单文件产物）
//
// 用法：bun run build
// 产物：dist/index.js（ESM，单文件，含全部提示词模块 + 状态机 + 存储层）
//
// 设计要点：
// 1. @earendil-works/* 与 typebox 保持 external——pi 运行时通过 virtualModules
//    提供这些包（编译二进制内置），扩展 import 时解析到 pi 内置版本，避免重复打包。
// 2. node:path / node:fs / node:module 内置模块同样 external（bun 原生支持）。
// 3. src/session-store.ts 的 createRequire + bun:sqlite/node:sqlite 动态探测
//    逻辑在编译产物中保持原样（bun build 不改写运行时 require 语义）。
// 4. target=bun，产物为纯 ESM，顶层 index.ts 转发 import 即可被 pi 加载。

import { build } from "bun";

const result = await build({
  entrypoints: ["./src/index.ts"],
  outdir: "./dist",
  target: "bun",
  format: "esm",
  // external：由 pi 二进制 virtualModules 提供的包 + node 内置模块
  external: [
    "@earendil-works/*",
    "typebox",
    "node:path",
    "node:fs",
    "node:module",
  ],
  sourcemap: "external",
  // 打包产物较大（27 个提示词模块内联），压缩输出
  minify: true,
});

if (!result.success) {
  console.error("构建失败:", result.logs);
  process.exit(1);
}

console.log("构建成功:");
for (const out of result.outputs) {
  console.log(`  ${out.path} (${out.size} bytes)`);
}
