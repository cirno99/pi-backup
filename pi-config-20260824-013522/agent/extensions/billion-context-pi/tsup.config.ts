import { defineConfig } from "tsup";
import { readFileSync } from "node:fs";

const pkg = JSON.parse(
  readFileSync(new URL("./package.json", import.meta.url), "utf-8"),
);

export default defineConfig({
  entry: ["src/index.ts"],
  format: ["esm"],
  target: "es2022",
  dts: false,
  sourcemap: true,
  clean: true,
  define: {
    CURRENT_VERSION: JSON.stringify(pkg.version),
  },
  external: [
    "@earendil-works/pi-coding-agent",
    "@earendil-works/pi-ai",
    "@earendil-works/pi-agent-core",
    "acp-kernel", // 切换为 Zig 内核（acp-kernel-zig）：运行时按 exports 解析，不再内联旧内核
  ],
  noExternal: ["typebox"],
});
