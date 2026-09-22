import type { ModelInfo } from "@anthropic-ai/claude-agent-sdk";

export type Model = { id: string; name: string; description: string; efforts: string[] };

/// Models that take adaptive thinking, filled from the SDK's list. Asking one that doesn't
/// for it is an error, so a model the engine hasn't heard about gets no thinking option.
export const adaptive = new Set<string>();

export function fromSDK(models: ModelInfo[]): Model[] {
  for (const model of models) {
    if (model.supportsAdaptiveThinking) adaptive.add(model.value);
  }
  return models.map((model) => ({
    id: model.value,
    name: model.displayName,
    description: model.description,
    efforts: model.supportsEffort ? (model.supportedEffortLevels ?? []) : [],
  }));
}

/// Fallback for when the SDK's supported-models call fails. Aliases, so they keep
/// pointing at the newest model of each family.
export const fallback: Model[] = [
  { id: "default", name: "Default", description: "The model Claude Code picks", efforts: ["low", "medium", "high", "xhigh", "max"] },
  { id: "opus", name: "Opus", description: "Most capable", efforts: ["low", "medium", "high", "xhigh", "max"] },
  { id: "sonnet", name: "Sonnet", description: "Fast and capable", efforts: ["low", "medium", "high", "xhigh", "max"] },
  { id: "haiku", name: "Haiku", description: "Fastest", efforts: [] },
];
