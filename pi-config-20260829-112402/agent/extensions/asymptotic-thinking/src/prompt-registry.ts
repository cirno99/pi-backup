// prompt-registry.ts — 提示词模块静态注册表（编译版）
//
// 原实现（templates.ts loadPromptModule）用动态 require("./prompts/...") 加载提示词模块，
// jiti 在运行时逐文件转译。编译版（bun build 单文件）无法打包动态路径，
// 因此改为静态 import 全部 27 个模块，构建「kebab 路径 → PromptModule」路由表。
// 查找顺序与原实现完全一致：精确匹配 → 同大类 general → general/general 兜底。

import type { MasterTaskType, SubTaskType, Difficulty, ThinkingState } from "./types";

// ── 提示词模块接口 ──
export interface PromptModule {
  buildPrompt(diff: Difficulty, state: ThinkingState): string;
}

// ── 静态导入全部提示词模块（bun build 可全部内联进单文件）──
import * as analyticsCodeAnalysis from "./prompts/analytics/code-analysis";
import * as analyticsDataAnalysis from "./prompts/analytics/data-analysis";
import * as analyticsLogAnalysis from "./prompts/analytics/log-analysis";
import * as analyticsRequirementAnalysis from "./prompts/analytics/requirement-analysis";
import * as codingArchitect from "./prompts/coding/architect";
import * as codingBugFix from "./prompts/coding/bug-fix";
import * as codingCodeRefactor from "./prompts/coding/code-refactor";
import * as codingCodeReview from "./prompts/coding/code-review";
import * as codingCrudDev from "./prompts/coding/crud-dev";
import * as codingGoDev from "./prompts/coding/go-dev";
import * as codingJavaDev from "./prompts/coding/java-dev";
import * as codingJsDev from "./prompts/coding/js-dev";
import * as codingPerfOptimize from "./prompts/coding/perf-optimize";
import * as codingPythonDev from "./prompts/coding/python-dev";
import * as codingRustDev from "./prompts/coding/rust-dev";
import * as codingTesting from "./prompts/coding/testing";
import * as devopsCicd from "./prompts/devops/cicd";
import * as devopsConfig from "./prompts/devops/config";
import * as devopsDeploy from "./prompts/devops/deploy";
import * as devopsMonitor from "./prompts/devops/monitor";
import * as entertainmentCreativeWriting from "./prompts/entertainment/creative-writing";
import * as entertainmentFunChat from "./prompts/entertainment/fun-chat";
import * as generalGeneral from "./prompts/general/general";
import * as retrievalCodeRetrieval from "./prompts/retrieval/code-retrieval";
import * as retrievalDailyRetrieval from "./prompts/retrieval/daily-retrieval";
import * as retrievalDocRetrieval from "./prompts/retrieval/doc-retrieval";
import * as retrievalPaperRetrieval from "./prompts/retrieval/paper-retrieval";

// ── kebab 路径 → 模块路由表 ──
const PROMPT_MODULES: Record<string, PromptModule> = {
  // analytics
  "analytics/code-analysis": analyticsCodeAnalysis as unknown as PromptModule,
  "analytics/data-analysis": analyticsDataAnalysis as unknown as PromptModule,
  "analytics/log-analysis": analyticsLogAnalysis as unknown as PromptModule,
  "analytics/requirement-analysis": analyticsRequirementAnalysis as unknown as PromptModule,
  // coding
  "coding/architect": codingArchitect as unknown as PromptModule,
  "coding/bug-fix": codingBugFix as unknown as PromptModule,
  "coding/code-refactor": codingCodeRefactor as unknown as PromptModule,
  "coding/code-review": codingCodeReview as unknown as PromptModule,
  "coding/crud-dev": codingCrudDev as unknown as PromptModule,
  "coding/go-dev": codingGoDev as unknown as PromptModule,
  "coding/java-dev": codingJavaDev as unknown as PromptModule,
  "coding/js-dev": codingJsDev as unknown as PromptModule,
  "coding/perf-optimize": codingPerfOptimize as unknown as PromptModule,
  "coding/python-dev": codingPythonDev as unknown as PromptModule,
  "coding/rust-dev": codingRustDev as unknown as PromptModule,
  "coding/testing": codingTesting as unknown as PromptModule,
  // devops
  "devops/cicd": devopsCicd as unknown as PromptModule,
  "devops/config": devopsConfig as unknown as PromptModule,
  "devops/deploy": devopsDeploy as unknown as PromptModule,
  "devops/monitor": devopsMonitor as unknown as PromptModule,
  // entertainment
  "entertainment/creative-writing": entertainmentCreativeWriting as unknown as PromptModule,
  "entertainment/fun-chat": entertainmentFunChat as unknown as PromptModule,
  // general
  "general/general": generalGeneral as unknown as PromptModule,
  // retrieval
  "retrieval/code-retrieval": retrievalCodeRetrieval as unknown as PromptModule,
  "retrieval/daily-retrieval": retrievalDailyRetrieval as unknown as PromptModule,
  "retrieval/doc-retrieval": retrievalDocRetrieval as unknown as PromptModule,
  "retrieval/paper-retrieval": retrievalPaperRetrieval as unknown as PromptModule,
};

// ── 路径构建（与原实现一致）──
function masterEnumToKebab(master: MasterTaskType): string {
  return master.toLowerCase();
}

function subEnumToKebab(sub: SubTaskType): string {
  return sub.toLowerCase().replace(/_/g, "-");
}

/**
 * 按 master/sub 查找提示词模块。
 * 查找顺序（与原动态 require 版完全一致）：
 * 1. 精确匹配：./prompts/{master}/{sub}
 * 2. 同大类通用：./prompts/{master}/general
 * 3. 全通用兜底：./prompts/general/general
 */
export function loadPromptModule(
  master: MasterTaskType | null,
  sub: SubTaskType | null,
): PromptModule | null {
  if (!master || !sub) return null;

  const exact = PROMPT_MODULES[`${masterEnumToKebab(master)}/${subEnumToKebab(sub)}`];
  if (exact) return exact;

  if (sub !== "GENERAL") {
    const generalSub = PROMPT_MODULES[`${masterEnumToKebab(master)}/general`];
    if (generalSub) return generalSub;
  }

  return PROMPT_MODULES["general/general"] ?? null;
}
