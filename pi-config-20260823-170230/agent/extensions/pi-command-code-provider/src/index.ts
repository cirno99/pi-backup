/**
 * Command Code Provider Extension for pi
 *
 * Model catalog is sourced live from commandcode.ai's own /provider/v1/models
 * endpoint. No model names, prices, or limits are hardcoded here.
 *
 * 启动性能优化（2026-08-22）：
 * 旧实现每次启动在扩展 factory 里同步 `await fetch()` 拉取模型目录，
 * 网络往返（约 600ms）直接阻塞 pi 启动（PI_TIMING 实测 extensions 段 614ms）。
 * 现改为 pi 官方的 `refreshModels` 动态回调：
 *   - 启动离线阶段（allowNetwork=false）从 models-store.json 恢复缓存模型，毫秒级；
 *   - 联网刷新移到后台 refresh 阶段（allowNetwork=true），不阻塞启动；
 *   - 联网刷新结果通过 context.publish({ persist }) 持久化到 models-store.json。
 * 首启（无缓存）时模型列表短暂为空，后台刷新完成后自动填充。
 *
 * 实现要点（基于 pi 0.84.2 provider-composer 源码）：
 *   - command-code 无内置 base provider，缓存恢复只能由本回调完成：
 *     离线阶段直接返回 context.stored.models（compose 层会把返回值应用到内存）；
 *   - compose 层不会自动持久化，联网刷新后必须显式 context.publish({ persist })；
 *   - context.publish 返回 false 表示发布被 generation 检查拒绝，应中止。
 */
import type { ExtensionAPI, RefreshModelsContext } from "@earendil-works/pi-coding-agent";

const MODELS_URL = "https://api.commandcode.ai/provider/v1/models";

interface RawModel {
	id: string;
	name?: string;
	context_length?: number;
}

function toPiModel(m: RawModel) {
	return {
		id: m.id,
		name: m.name ?? m.id,
		// Most models on commandcode.ai support reasoning; the models endpoint
		// doesn't expose this flag, so default to true.
		reasoning: true,
		// The models endpoint doesn't expose modality info; text-only is the
		// conservative default. Models that support images (Claude, GPT,
		// Gemini) work fine with this — pi sends images as data URIs in text
		// content blocks, which the upstream handles.
		input: ["text"] as ("text" | "image")[],
		cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
		contextWindow: m.context_length ?? 128000,
		// The models endpoint doesn't expose max output tokens; 128K is a
		// safe upper bound for most models on the platform.
		maxTokens: 128000,
	};
}

export default function (pi: ExtensionAPI) {
	pi.registerProvider("command-code", {
		name: "Command Code",
		baseUrl: "https://api.commandcode.ai/provider/v1",
		apiKey: "$CMD_API_KEY",
		authHeader: true,
		api: "openai-completions",
		// 启动时不拉取任何数据（models 为空），由 refreshModels 负责恢复缓存与联网刷新。
		models: [],
		refreshModels: async (context: RefreshModelsContext) => {
			// 离线/缓存初始化阶段（allowNetwork=false，如启动时的
			// modelRuntime.refresh({ allowNetwork: false })）：不联网，
			// 直接返回持久化缓存（若有），让 compose 层应用到内存模型。
			if (!context.allowNetwork || context.signal.aborted) {
				return context.stored?.models ?? [];
			}

			// 后台联网刷新（不阻塞启动）
			const response = await fetch(MODELS_URL, { signal: context.signal });
			if (!response.ok) {
				throw new Error(
					`command-code provider: models endpoint fetch failed (${response.status})`,
				);
			}
			const payload = (await response.json()) as {
				data?: RawModel[];
			};
			const models = (payload.data ?? []).map(toPiModel);
			if (models.length === 0) {
				throw new Error("command-code provider: models endpoint returned no models");
			}

			// 持久化到 models-store.json（compose 层不会自动持久化）
			const published = await context.publish({
				persist: { models, checkedAt: Date.now() },
			});
			if (!published) {
				// 发布被 generation 检查拒绝（期间有更新的刷新），放弃本次结果
				return [];
			}
			return models;
		},
	});
}
