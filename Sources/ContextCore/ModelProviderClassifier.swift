import Foundation

/// A deliberately narrow name-based grouping, never a billing-provider claim.
/// Unknown or private model aliases retain an explicit unknown bucket.
public enum ModelProviderClassifier {
    public static func label(for model: String) -> String {
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if matches(name, namespaces: ["anthropic/", "anthropic:"], prefixes: ["claude-"]) { return "Anthropic" }
        if matches(name, namespaces: ["openai/", "openai:"], prefixes: ["gpt-", "chatgpt-", "o1-", "o3-", "o4-"])
            || ["o1", "o3", "o4"].contains(name) { return "OpenAI" }
        if matches(name, namespaces: ["xai/", "x-ai/"], prefixes: ["grok-"]) { return "xAI" }
        if matches(name, namespaces: ["cognition/"], prefixes: ["swe-2-"]) { return "Cognition" }
        if matches(name, namespaces: ["google/", "google:"], prefixes: ["gemini-"]) { return "Google" }
        if matches(name, namespaces: ["zai/", "z.ai/", "zhipu/"], prefixes: ["glm-"]) { return "Z.ai" }
        if matches(name, namespaces: ["deepseek/"], prefixes: ["deepseek-"]) { return "DeepSeek" }
        if matches(name, namespaces: ["alibaba/"], prefixes: ["qwen-"]) { return "Alibaba" }
        if matches(name, namespaces: ["moonshot/"], prefixes: ["kimi-"]) { return "Moonshot" }
        if matches(name, namespaces: ["meta/"], prefixes: ["llama-"]) { return "Meta" }
        if matches(name, namespaces: ["mistral/"], prefixes: ["mistral-"]) { return "Mistral" }
        return "Unknown provider"
    }

    private static func matches(_ name: String, namespaces: [String], prefixes: [String]) -> Bool {
        namespaces.contains(where: name.hasPrefix) || prefixes.contains(where: name.hasPrefix)
    }
}
