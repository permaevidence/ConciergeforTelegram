import Foundation
import Security

enum VoiceTranscriptionProvider: String, CaseIterable, Identifiable {
    case local
    case openAI = "openai"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .local:
            return "Local (Whisper)"
        case .openAI:
            return "OpenAI (gpt-4o-transcribe)"
        }
    }

    static var defaultProvider: VoiceTranscriptionProvider { .local }

    static func fromStoredValue(_ value: String?) -> VoiceTranscriptionProvider {
        guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              let provider = VoiceTranscriptionProvider(rawValue: normalized) else {
            return .defaultProvider
        }
        return provider
    }
}

enum KeychainHelper {
    
    enum KeychainError: Error {
        case duplicateItem
        case itemNotFound
        case unexpectedStatus(OSStatus)
    }
    
    private static let service = "com.telegramconcierge"
    
    static func save(key: String, value: String) throws {
        guard let data = value.data(using: .utf8) else { return }
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data
        ]
        
        // Try to delete existing item first
        SecItemDelete(query as CFDictionary)
        
        let status = SecItemAdd(query as CFDictionary, nil)
        
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
    
    static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        
        return string
    }
    
    static func delete(key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}

// MARK: - Credential Keys
extension KeychainHelper {
    static let defaultCodeCLIProvider = "claude"
    static let defaultClaudeCodeArgs = "-p --permission-mode bypassPermissions"
    static let defaultClaudeCodeTimeout = "1000"
    static let defaultGeminiCodeCommand = "gemini"
    static let defaultGeminiCodeArgs = "--yolo --output-format json"
    static let defaultGeminiCodeModel = ""
    static let defaultGeminiCodeTimeout = "1000"
    static let defaultCodexCodeCommand = "codex"
    static let defaultCodexCodeArgs = "exec --sandbox workspace-write --skip-git-repo-check"
    static let defaultCodexCodeModel = ""
    static let defaultCodexCodeTimeout = "1000"
    static let defaultVercelCommand = "vercel"
    static let defaultVercelTimeout = "1200"
    static let defaultInstantCLICommand = "npx instant-cli@latest"
    
    static let telegramBotTokenKey = "telegram_bot_token"
    static let telegramChatIdKey = "telegram_chat_id"
    static let openRouterApiKeyKey = "openrouter_api_key"
    
    // Web Search Tool Keys
    static let serperApiKeyKey = "serper_api_key"
    static let jinaApiKeyKey = "jina_api_key"
    
    // Email (IMAP/SMTP) Keys
    static let imapHostKey = "imap_host"
    static let imapPortKey = "imap_port"
    static let imapUsernameKey = "imap_username"
    static let imapPasswordKey = "imap_password"
    static let smtpHostKey = "smtp_host"
    static let smtpPortKey = "smtp_port"
    static let smtpUsernameKey = "smtp_username"
    static let smtpPasswordKey = "smtp_password"
    static let emailDisplayNameKey = "email_display_name"
    
    // Google Gemini API Key
    static let geminiApiKeyKey = "gemini_api_key"
    
    // Code CLI Settings (Claude Code, Gemini CLI, Codex CLI)
    static let codeCLIProviderKey = "code_cli_provider"
    static let claudeCodeCommandKey = "claude_code_command"
    static let claudeCodeArgsKey = "claude_code_args"
    static let claudeCodeTimeoutKey = "claude_code_timeout"
    static let geminiCodeCommandKey = "gemini_code_command"
    static let geminiCodeArgsKey = "gemini_code_args"
    static let geminiCodeModelKey = "gemini_code_model"
    static let geminiCodeTimeoutKey = "gemini_code_timeout"
    static let codexCodeCommandKey = "codex_code_command"
    static let codexCodeArgsKey = "codex_code_args"
    static let codexCodeModelKey = "codex_code_model"
    static let codexCodeTimeoutKey = "codex_code_timeout"
    static let claudeCodeDisableLegacyDocumentGenerationToolsKey = "claude_code_disable_legacy_document_generation_tools"
    
    // Vercel Deployment Settings
    static let vercelApiTokenKey = "vercel_api_token"
    static let vercelTeamScopeKey = "vercel_team_scope"
    static let vercelProjectNameKey = "vercel_project_name"
    static let vercelCommandKey = "vercel_command"
    static let vercelTimeoutKey = "vercel_timeout"
    
    // Instant Database Settings
    static let instantApiTokenKey = "instant_api_token"
    static let instantCLICommandKey = "instant_cli_command"
    
    // Persona Settings Keys
    static let assistantNameKey = "assistant_name"
    static let userNameKey = "user_name"
    static let userContextKey = "user_context"
    static let structuredUserContextKey = "structured_user_context"
    
    // Model Settings
    static let openRouterModelKey = "openrouter_model"
    static let openRouterProvidersKey = "openrouter_providers"
    static let openRouterReasoningEffortKey = "openrouter_reasoning_effort"
    static let openRouterToolSpendLimitPerTurnUSDKey = "openrouter_tool_spend_limit_per_turn_usd"
    static let openRouterToolSpendLimitDailyUSDKey = "openrouter_tool_spend_limit_daily_usd"
    static let openRouterToolSpendLimitMonthlyUSDKey = "openrouter_tool_spend_limit_monthly_usd"

    // Voice Transcription Settings
    static let voiceTranscriptionProviderKey = "voice_transcription_provider"
    static let openAITranscriptionApiKeyKey = "openai_transcription_api_key"
    
    // Archive Settings
    static let archiveChunkSizeKey = "archive_chunk_size"
    
    // Email Mode Selection
    static let emailModeKey = "email_mode" // "imap" or "gmail"
    
    // Gmail API OAuth Keys
    static let gmailClientIdKey = "gmail_client_id"
    static let gmailClientSecretKey = "gmail_client_secret"
    static let gmailAccessTokenKey = "gmail_access_token"
    static let gmailRefreshTokenKey = "gmail_refresh_token"
    static let gmailTokenExpiryKey = "gmail_token_expiry"
}

// MARK: - OpenRouter Spend Ledger (UserDefaults-backed)
extension KeychainHelper {
    private static let openRouterSpendLedgerDefaultsKey = "openrouter_spend_ledger_v1"
    private static let openRouterSpendLedgerRetentionDays = 500

    private struct OpenRouterSpendLedger: Codable {
        var byDay: [String: Double]
    }

    static func recordOpenRouterSpend(_ amountUSD: Double, at date: Date = Date()) {
        guard amountUSD.isFinite, amountUSD > 0 else { return }
        var ledger = loadOpenRouterSpendLedger()
        pruneOldSpendEntries(&ledger, referenceDate: date)
        let key = dayKey(for: date)
        ledger.byDay[key, default: 0] += amountUSD
        saveOpenRouterSpendLedger(ledger)
    }

    static func openRouterSpendSnapshot(referenceDate: Date = Date()) -> (today: Double, month: Double) {
        var ledger = loadOpenRouterSpendLedger()
        pruneOldSpendEntries(&ledger, referenceDate: referenceDate)
        saveOpenRouterSpendLedger(ledger)

        let todayKey = dayKey(for: referenceDate)
        let monthPrefix = monthPrefixKey(for: referenceDate)

        let today = ledger.byDay[todayKey] ?? 0
        let month = ledger.byDay
            .filter { $0.key.hasPrefix(monthPrefix) }
            .reduce(0) { $0 + $1.value }

        return (today: max(0, today), month: max(0, month))
    }

    private static func loadOpenRouterSpendLedger() -> OpenRouterSpendLedger {
        guard let data = UserDefaults.standard.data(forKey: openRouterSpendLedgerDefaultsKey),
              let ledger = try? JSONDecoder().decode(OpenRouterSpendLedger.self, from: data) else {
            return OpenRouterSpendLedger(byDay: [:])
        }
        return ledger
    }

    private static func saveOpenRouterSpendLedger(_ ledger: OpenRouterSpendLedger) {
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        UserDefaults.standard.set(data, forKey: openRouterSpendLedgerDefaultsKey)
    }

    private static func pruneOldSpendEntries(_ ledger: inout OpenRouterSpendLedger, referenceDate: Date) {
        guard !ledger.byDay.isEmpty else { return }

        let calendar = Calendar.current
        let cutoffDate = calendar.date(byAdding: .day, value: -openRouterSpendLedgerRetentionDays, to: referenceDate) ?? referenceDate
        let cutoffKey = dayKey(for: cutoffDate)

        ledger.byDay = ledger.byDay.filter { day, value in
            day >= cutoffKey && value.isFinite && value > 0
        }
    }

    private static func dayKey(for date: Date) -> String {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 1970
        let month = components.month ?? 1
        let day = components.day ?? 1
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private static func monthPrefixKey(for date: Date) -> String {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month], from: date)
        let year = components.year ?? 1970
        let month = components.month ?? 1
        return String(format: "%04d-%02d-", year, month)
    }
}
