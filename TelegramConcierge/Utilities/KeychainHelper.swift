import Foundation
import Security

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
    static let defaultClaudeCodeArgs = "-p --permission-mode bypassPermissions"
    static let defaultClaudeCodeTimeout = "1000"
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
    
    // Claude Code CLI Settings
    static let claudeCodeCommandKey = "claude_code_command"
    static let claudeCodeArgsKey = "claude_code_args"
    static let claudeCodeTimeoutKey = "claude_code_timeout"
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
