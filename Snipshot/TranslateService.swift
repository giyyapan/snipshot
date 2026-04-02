import Foundation
import Cocoa

// MARK: - Translation Settings

struct TranslateSettings {
    static let targetLanguageKey = "translateTargetLanguage"
    static let systemPromptKey = "translateSystemPrompt"
    static let recentLanguagesKey = "translateRecentLanguages"

    static let defaultTargetLanguage = "Simplified Chinese"
    static let defaultSystemPrompt = """
You are a professional translator. Translate the following text to {{TARGET_LANGUAGE}}.
The text is OCR-extracted from a screenshot. Use the provided image as visual context to preserve the original layout and formatting.
Rules:
- Keep line breaks as they appear in the image. Merge lines only when a line is clearly broken due to space constraints.
- Use bold, italic, code blocks, and extra line breaks to reflect the visual hierarchy of the original.
- Ignore all icons, buttons, arrows, and UI elements. Do not represent them with emoji or symbols.
- Output only the translated text content.
"""

    static var targetLanguage: String {
        get { UserDefaults.standard.string(forKey: targetLanguageKey) ?? defaultTargetLanguage }
        set { UserDefaults.standard.set(newValue, forKey: targetLanguageKey) }
    }

    static var systemPrompt: String {
        let raw = UserDefaults.standard.string(forKey: systemPromptKey) ?? defaultSystemPrompt
        return raw.replacingOccurrences(of: "{{TARGET_LANGUAGE}}", with: targetLanguage)
    }

    static var rawSystemPrompt: String {
        get { UserDefaults.standard.string(forKey: systemPromptKey) ?? defaultSystemPrompt }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || newValue == defaultSystemPrompt {
                UserDefaults.standard.removeObject(forKey: systemPromptKey)
            } else {
                UserDefaults.standard.set(newValue, forKey: systemPromptKey)
            }
        }
    }

    static var isConfigured: Bool {
        AISettings.isConfigured
    }

    static let availableLanguages = [
        "Simplified Chinese",
        "Traditional Chinese",
        "English",
        "Japanese",
        "Korean",
        "Spanish",
        "French",
        "German",
        "Portuguese",
        "Russian",
        "Arabic",
        "Italian",
    ]

    /// Languages the user has selected before, in order of most recent use.
    static var recentLanguages: [String] {
        get {
            let stored = UserDefaults.standard.stringArray(forKey: recentLanguagesKey) ?? []
            if stored.isEmpty {
                return [targetLanguage]
            }
            return stored
        }
        set {
            UserDefaults.standard.set(newValue, forKey: recentLanguagesKey)
        }
    }

    /// Mark a language as recently used (moves it to front).
    static func markLanguageUsed(_ language: String) {
        var recent = recentLanguages
        recent.removeAll { $0 == language }
        recent.insert(language, at: 0)
        if recent.count > 5 { recent = Array(recent.prefix(5)) }
        recentLanguages = recent
    }

    /// Build an NSMenu with recent languages on top, separator, then all languages.
    static func buildLanguageMenu(target: AnyObject, action: Selector) -> NSMenu {
        let menu = NSMenu()
        let recent = recentLanguages

        for lang in recent {
            let item = NSMenuItem(title: lang, action: action, keyEquivalent: "")
            item.target = target
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())

        for lang in availableLanguages where !recent.contains(lang) {
            let item = NSMenuItem(title: lang, action: action, keyEquivalent: "")
            item.target = target
            menu.addItem(item)
        }

        return menu
    }
}

// MARK: - OCR Refine Settings

struct OCRRefineSettings {
    static let systemPromptKey = "ocrRefineSystemPrompt"

    static let defaultSystemPrompt = """
You are a professional OCR post-processor. The following text was extracted via OCR from a screenshot.
Use the provided image as visual context to correct any OCR errors and improve formatting.
Rules:
- Fix obvious OCR mistakes (misrecognized characters, broken words, wrong punctuation).
- Preserve the original language, meaning, and structure.
- Ignore all icons, buttons, arrows, and UI elements. Do not represent them with emoji or symbols.
- Keep line breaks as they appear in the image. Merge lines only when a line is clearly broken due to space constraints.
- Do not add any commentary or explanation. Output only the corrected text.
"""

    static var systemPrompt: String {
        UserDefaults.standard.string(forKey: systemPromptKey) ?? defaultSystemPrompt
    }

    static var rawSystemPrompt: String {
        get { UserDefaults.standard.string(forKey: systemPromptKey) ?? defaultSystemPrompt }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || newValue == defaultSystemPrompt {
                UserDefaults.standard.removeObject(forKey: systemPromptKey)
            } else {
                UserDefaults.standard.set(newValue, forKey: systemPromptKey)
            }
        }
    }
}

// MARK: - Translation Service (uses AIService for API calls)

class TranslateService {

    static let shared = TranslateService()

    private init() {}

    /// Translate text using the AI service with optional image context.
    func translateStreaming(
        text: String,
        imageDataURL: String? = nil,
        onPhase: @escaping (String) -> Void,
        onChunk: @escaping (String) -> Void,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard AISettings.isConfigured else {
            DispatchQueue.main.async { completion(.failure(AIError.notConfigured)) }
            return
        }

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            DispatchQueue.main.async { completion(.failure(TranslateError.emptyText)) }
            return
        }

        let systemMessage = AIMessage.text(role: .system, content: TranslateSettings.systemPrompt)

        let userMessage: AIMessage
        if let dataURL = imageDataURL {
            userMessage = AIMessage.multimodal(
                role: .user,
                text: "OCR extracted text:\n\(text)",
                imageDataURL: dataURL
            )
        } else {
            userMessage = AIMessage.text(role: .user, content: text)
        }

        DispatchQueue.main.async { onPhase("Thinking") }

        AIService.shared.streamChat(
            messages: [systemMessage, userMessage],
            temperature: 0.3,
            logPrefix: "Translate",
            onChunk: onChunk,
            completion: completion
        )
    }

    /// Cancel the current translation request.
    func cancelCurrentRequest() {
        AIService.shared.cancelCurrentRequest()
    }
}

// MARK: - Translate-specific Errors

enum TranslateError: LocalizedError {
    case emptyText

    var errorDescription: String? {
        switch self {
        case .emptyText:
            return "No text was recognized in the selected area."
        }
    }
}
