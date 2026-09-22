import type { ModelInfo } from "@anthropic-ai/claude-agent-sdk";

export type Model = { id: string; name: string; description: string; efforts: string[] };

export function fromSDK(models: ModelInfo[]): Model[] {
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
