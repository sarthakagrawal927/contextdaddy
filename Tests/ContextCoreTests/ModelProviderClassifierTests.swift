import Testing
@testable import ContextCore

struct ModelProviderClassifierTests {
    @Test func identifiesOnlyRecognizableModelFamilies() {
        #expect(ModelProviderClassifier.label(for: "gpt-5.6-sol") == "OpenAI")
        #expect(ModelProviderClassifier.label(for: "anthropic/claude-opus-4") == "Anthropic")
        #expect(ModelProviderClassifier.label(for: "grok-4") == "xAI")
        #expect(ModelProviderClassifier.label(for: "google/gemini-2.5-pro") == "Google")
        #expect(ModelProviderClassifier.label(for: "swe-2-high") == "Cognition")
        #expect(ModelProviderClassifier.label(for: "glm-5-2") == "Z.ai")
        #expect(ModelProviderClassifier.label(for: "devin-model") == "Unknown provider")
        #expect(ModelProviderClassifier.label(for: "") == "Unknown provider")
    }
}
