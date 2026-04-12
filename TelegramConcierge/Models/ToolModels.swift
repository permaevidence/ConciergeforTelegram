import Foundation

enum JSONValue: Codable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.typeMismatch(
                JSONValue.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON value")
            )
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

// MARK: - Tool Definitions (OpenAI Function Calling Format)

struct ToolDefinition: Codable {
    let type: String
    let function: FunctionDefinition
    
    init(function: FunctionDefinition) {
        self.type = "function"
        self.function = function
    }
}

struct FunctionDefinition: Codable {
    let name: String
    let description: String
    let parameters: FunctionParameters
}

struct FunctionParameters: Codable {
    let type: String
    let properties: [String: ParameterProperty]
    let required: [String]
    
    init(properties: [String: ParameterProperty], required: [String]) {
        self.type = "object"
        self.properties = properties
        self.required = required
    }
}

struct ParameterProperty: Codable {
    let type: String
    let description: String
    let enumValues: [String]?

    enum CodingKeys: String, CodingKey {
        case type
        case description
        case enumValues = "enum"
    }

    init(type: String, description: String, enumValues: [String]? = nil) {
        self.type = type
        self.description = description
        self.enumValues = enumValues
    }
}

// MARK: - Tool Calls (from LLM response)

struct ToolCall: Codable, Identifiable {
    let id: String
    let type: String
    let function: FunctionCall
}

struct FunctionCall: Codable {
    let name: String
    let arguments: String  // JSON string that needs parsing
}

// MARK: - Tool Results (sent back to LLM)

/// Represents file data to be shown to the LLM as multimodal content
struct FileAttachment {
    let data: Data
    let mimeType: String
    let filename: String
}

struct ToolResultMessage: Codable {
    let role: String
    let toolCallId: String
    var content: String
    
    /// Optional files to inject as multimodal content (not serialized to API directly)
    var fileAttachments: [FileAttachment]
    
    /// Optional spend associated with tool-internal API calls (not serialized to API directly)
    var spendUSD: Double?
    
    enum CodingKeys: String, CodingKey {
        case role
        case toolCallId = "tool_call_id"
        case content
    }
    
    init(
        toolCallId: String,
        content: String,
        fileAttachment: FileAttachment? = nil,
        fileAttachments: [FileAttachment]? = nil,
        spendUSD: Double? = nil
    ) {
        self.role = "tool"
        self.toolCallId = toolCallId
        self.content = content
        // Support both single and multiple attachments
        if let attachments = fileAttachments {
            self.fileAttachments = attachments
        } else if let single = fileAttachment {
            self.fileAttachments = [single]
        } else {
            self.fileAttachments = []
        }
        self.spendUSD = spendUSD
    }
    
    // Manual Decodable conformance - fileAttachments is not serialized
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.role = try container.decode(String.self, forKey: .role)
        self.toolCallId = try container.decode(String.self, forKey: .toolCallId)
        self.content = try container.decode(String.self, forKey: .content)
        self.fileAttachments = [] // Not decoded, only used transiently
        self.spendUSD = nil // Not decoded, only used transiently
    }
}

// MARK: - Web Search Tool Result

struct WebSearchResult: Codable {
    let summary: String
    let sources: [String]
    let searchQueriesUsed: [String]
    let spendUSD: Double?
    
    func asJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(self),
              let json = String(data: data, encoding: .utf8) else {
            return "{\"summary\": \"\(summary)\", \"sources\": [], \"searchQueriesUsed\": [], \"spendUSD\": null}"
        }
        return json
    }
}

// MARK: - LLM Response Types

enum LLMResponse {
    case text(String, promptTokens: Int?, spendUSD: Double?)
    case toolCalls(assistantMessage: AssistantToolCallMessage, calls: [ToolCall], promptTokens: Int?, spendUSD: Double?)
}

/// The assistant's message when it decides to call tools (must be preserved for the follow-up)
struct AssistantToolCallMessage: Codable {
    let role: String
    let content: String?
    let toolCalls: [ToolCall]
    let reasoning: JSONValue?
    let reasoningDetails: JSONValue?
    
    enum CodingKeys: String, CodingKey {
        case role
        case content
        case toolCalls = "tool_calls"
        case reasoning
        case reasoningDetails = "reasoning_details"
    }
    
    init(content: String?, toolCalls: [ToolCall], reasoning: JSONValue? = nil, reasoningDetails: JSONValue? = nil) {
        self.role = "assistant"
        self.content = content
        self.toolCalls = toolCalls
        self.reasoning = reasoning
        self.reasoningDetails = reasoningDetails
    }
}

// MARK: - Available Tools Registry

enum AvailableTools {
    static let webSearch = ToolDefinition(
        function: FunctionDefinition(
            name: "web_search",
            description: "Perform a comprehensive web search with multi-step reasoning. Use when the user asks about current events, recent news, specific facts you're uncertain about, prices, stock quotes, weather, availability, or any topic where fresh real-time information would improve your answer. Do NOT use for general knowledge questions you can answer directly.",
            parameters: FunctionParameters(
                properties: [
                    "query": ParameterProperty(
                        type: "string",
                        description: "The user's question or topic to research. Be specific and include relevant context from the conversation."
                    )
                ],
                required: ["query"]
            )
        )
    )

    static let deepResearch = ToolDefinition(
        function: FunctionDefinition(
            name: "deep_research",
            description: "Perform deep, comprehensive research with multi-step web search and source triangulation. Use when the user asks for a detailed report, a thorough analysis, a full comparison, or a long-form answer with extensive sourcing.",
            parameters: FunctionParameters(
                properties: [
                    "query": ParameterProperty(
                        type: "string",
                        description: "The research question or topic to investigate in depth. Include constraints, scope, and context from the conversation."
                    )
                ],
                required: ["query"]
            )
        )
    )
    
    static let manageReminders = ToolDefinition(
        function: FunctionDefinition(
            name: "manage_reminders",
            description: "Single reminder tool. Use action='set' to schedule, action='list' to view pending reminders, and action='delete' to cancel one or many reminders.",
            parameters: FunctionParameters(
                properties: [
                    "action": ParameterProperty(
                        type: "string",
                        description: "Reminder action: 'set', 'list', or 'delete'.",
                        enumValues: ["set", "list", "delete"]
                    ),
                    "trigger_datetime": ParameterProperty(
                        type: "string",
                        description: "Required for action='set'. Local datetime in the future (e.g., '2026-04-12T15:00:00'). Use the same timezone as the conversation timestamps."
                    ),
                    "prompt": ParameterProperty(
                        type: "string",
                        description: "Required for action='set'. Reminder instructions."
                    ),
                    "recurrence": ParameterProperty(
                        type: "string",
                        description: "Optional for action='set'. 'daily', 'weekly', 'monthly', 'every_X_minutes', or 'every_X_hours'. Also optional for action='delete' when delete_recurring=true to filter which recurring reminders to delete."
                    ),
                    "reminder_id": ParameterProperty(
                        type: "string",
                        description: "For action='delete'. Single reminder UUID to delete."
                    ),
                    "reminder_ids": ParameterProperty(
                        type: "string",
                        description: "For action='delete'. Multiple reminder IDs as JSON array string or CSV (e.g. [\"id1\",\"id2\"] or \"id1,id2\")."
                    ),
                    "delete_all": ParameterProperty(
                        type: "boolean",
                        description: "For action='delete'. If true, deletes all pending reminders."
                    ),
                    "delete_recurring": ParameterProperty(
                        type: "boolean",
                        description: "For action='delete'. If true, deletes all pending recurring reminders. Optional recurrence filter can narrow to daily/weekly/monthly/every_X_minutes/every_X_hours."
                    )
                ],
                required: ["action"]
            )
        )
    )
    
    // MARK: - Calendar Tools
    
    static let manageCalendar = ToolDefinition(
        function: FunctionDefinition(
            name: "manage_calendar",
            description: "Single calendar tool. Use action='view' to list events, action='add' to create events, action='edit' to update events, and action='delete' to remove events.",
            parameters: FunctionParameters(
                properties: [
                    "action": ParameterProperty(
                        type: "string",
                        description: "Calendar action: 'view', 'add', 'edit', or 'delete'.",
                        enumValues: ["view", "add", "edit", "delete"]
                    ),
                    "include_past": ParameterProperty(
                        type: "boolean",
                        description: "Optional for action='view'. If true, include past events."
                    ),
                    "event_id": ParameterProperty(
                        type: "string",
                        description: "Required for actions 'edit' and 'delete'. Event UUID."
                    ),
                    "title": ParameterProperty(
                        type: "string",
                        description: "Required for action='add'. Optional for action='edit'. Event title."
                    ),
                    "datetime": ParameterProperty(
                        type: "string",
                        description: "Required for action='add'. Optional for action='edit'. Local datetime (e.g., '2026-04-12T15:00:00'). Use the same timezone as the conversation timestamps."
                    ),
                    "notes": ParameterProperty(
                        type: "string",
                        description: "Optional for actions 'add' and 'edit'. Event notes."
                    )
                ],
                required: ["action"]
            )
        )
    )
    
    // MARK: - Conversation History Tool
    
    static let viewConversationChunk = ToolDefinition(
        function: FunctionDefinition(
            name: "view_conversation_chunk",
            description: "Access your long-term conversation memory. This tool has TWO uses: (1) LIST PAGINATED OLDER SUMMARIES: Call without chunk_id to list archived chunk summaries in pages of 15, newest to oldest, excluding summaries already shown in context. Use page=1 for the most recent older summaries and increment page to go further back. (2) VIEW FULL CHUNK: Call with a chunk_id to retrieve complete messages from that specific archived chunk.",
            parameters: FunctionParameters(
                properties: [
                    "chunk_id": ParameterProperty(
                        type: "string",
                        description: "Optional. If provided, returns the full messages from that chunk."
                    ),
                    "page": ParameterProperty(
                        type: "integer",
                        description: "Optional for summary listing mode (ignored when chunk_id is provided). 1-based page number. Each page shows 15 older summaries, ordered newest to oldest."
                    )
                ],
                required: []
            )
        )
    )
    
    // MARK: - Email Tools
    
    static let readEmails = ToolDefinition(
        function: FunctionDefinition(
            name: "read_emails",
            description: "Read recent emails from the user's inbox via IMAP. Returns email details including 'messageId' (needed for reply_email), 'from' (sender), 'subject', 'date', and 'bodyPreview'. Use when the user asks about their emails or wants to check messages. If user wants to REPLY to an email, first use this to get the messageId and sender, then call reply_email.",
            parameters: FunctionParameters(
                properties: [
                    "count": ParameterProperty(
                        type: "integer",
                        description: "Number of recent emails to fetch (1-20). Default is 10."
                    )
                ],
                required: []
            )
        )
    )
    
    static let searchEmails = ToolDefinition(
        function: FunctionDefinition(
            name: "search_emails",
            description: "Search emails by keywords, sender, or date range in any folder. Use when: user asks 'find emails about X', 'emails from John', 'emails from last week', 'show sent emails', 'find emails I sent', or wants to search past emails. More powerful than read_emails which only shows recent inbox messages.",
            parameters: FunctionParameters(
                properties: [
                    "query": ParameterProperty(
                        type: "string",
                        description: "Text to search in email subject and body. Use for keyword searches like 'invoice', 'meeting', 'project update'."
                    ),
                    "from": ParameterProperty(
                        type: "string",
                        description: "Filter by sender. Can be email address (john@example.com) or name (John)."
                    ),
                    "since": ParameterProperty(
                        type: "string",
                        description: "Find emails on or after this date. Format: YYYY-MM-DD (e.g., '2026-01-20')."
                    ),
                    "before": ParameterProperty(
                        type: "string",
                        description: "Find emails before this date. Format: YYYY-MM-DD (e.g., '2026-02-01')."
                    ),
                    "folder": ParameterProperty(
                        type: "string",
                        description: "Email folder to search. Use 'sent' to search sent emails, 'drafts' for drafts, 'trash' for trash, or 'inbox' (default). The tool automatically handles Gmail folder naming conventions.",
                        enumValues: ["inbox", "sent", "drafts", "trash"]
                    ),
                    "limit": ParameterProperty(
                        type: "integer",
                        description: "Maximum number of results (1-50). Default is 10."
                    )
                ],
                required: []  // All optional, but at least one filter recommended
            )
        )
    )
    
    static let sendEmail = ToolDefinition(
        function: FunctionDefinition(
            name: "send_email",
            description: "Send a NEW email (not a reply). Use this only for composing fresh emails to someone. If the user wants to REPLY to an existing email, use reply_email instead (which maintains proper email threading).",
            parameters: FunctionParameters(
                properties: [
                    "to": ParameterProperty(
                        type: "string",
                        description: "Recipient email address (e.g., 'john@example.com')."
                    ),
                    "subject": ParameterProperty(
                        type: "string",
                        description: "Email subject line."
                    ),
                    "body": ParameterProperty(
                        type: "string",
                        description: "Plain text email body content."
                    ),
                    "cc": ParameterProperty(
                        type: "string",
                        description: "Optional CC recipients. Comma-separated string (e.g., 'a@example.com, b@example.com') or JSON array string."
                    ),
                    "bcc": ParameterProperty(
                        type: "string",
                        description: "Optional BCC recipients. Comma-separated string (e.g., 'a@example.com, b@example.com') or JSON array string."
                    )
                ],
                required: ["to", "subject", "body"]
            )
        )
    )
    
    static let replyEmail = ToolDefinition(
        function: FunctionDefinition(
            name: "reply_email",
            description: "REPLY to an existing email with proper threading. Use this when the user wants to respond to an email they received. Requires the 'messageId' from read_emails output. The reply will appear in the same email thread as the original message in the recipient's inbox.",
            parameters: FunctionParameters(
                properties: [
                    "message_id": ParameterProperty(
                        type: "string",
                        description: "The Message-ID of the email being replied to (from the 'messageId' field in read_emails output, e.g. '<abc123@mail.example.com>')."
                    ),
                    "to": ParameterProperty(
                        type: "string",
                        description: "Recipient email address (extract from the 'from' field of the original email)."
                    ),
                    "subject": ParameterProperty(
                        type: "string",
                        description: "Email subject (use 'Re: ' + original subject)."
                    ),
                    "body": ParameterProperty(
                        type: "string",
                        description: "Plain text reply body content."
                    )
                ],
                required: ["message_id", "to", "subject", "body"]
            )
        )
    )
    
    static let forwardEmail = ToolDefinition(
        function: FunctionDefinition(
            name: "forward_email",
            description: "FORWARD an email to someone else, INCLUDING all attachments. Use this when the user wants to share an email they received with another person. Requires the email's 'id' (UID) from read_emails to forward attachments. The forwarded email will include the original message content AND all original attachments.",
            parameters: FunctionParameters(
                properties: [
                    "to": ParameterProperty(
                        type: "string",
                        description: "Email address to forward the email to."
                    ),
                    "email_uid": ParameterProperty(
                        type: "string",
                        description: "The UID of the email to forward (from the 'id' field in read_emails). Required to forward attachments."
                    ),
                    "original_from": ParameterProperty(
                        type: "string",
                        description: "The original sender (from 'from' field in read_emails)."
                    ),
                    "original_date": ParameterProperty(
                        type: "string",
                        description: "The original email date (from 'date' field in read_emails)."
                    ),
                    "original_subject": ParameterProperty(
                        type: "string",
                        description: "The original email subject (from 'subject' field in read_emails)."
                    ),
                    "original_body": ParameterProperty(
                        type: "string",
                        description: "The original email body content (from 'bodyPreview' field in read_emails)."
                    ),
                    "comment": ParameterProperty(
                        type: "string",
                        description: "Optional comment to add before the forwarded message. Can be empty string if no comment needed."
                    )
                ],
                required: ["to", "email_uid", "original_from", "original_date", "original_subject", "original_body"]
            )
        )
    )
    
    static let getEmailThread = ToolDefinition(
        function: FunctionDefinition(
            name: "get_email_thread",
            description: "Fetch ALL emails in a conversation thread. Use when user wants to see a complete email conversation, understand the full context of a thread, or analyze an email chain. Requires a message_id from any email in the thread (from read_emails output). Returns all emails in the thread sorted chronologically (oldest first).",
            parameters: FunctionParameters(
                properties: [
                    "message_id": ParameterProperty(
                        type: "string",
                        description: "The Message-ID of any email in the thread (from 'messageId' field in read_emails output, e.g. '<abc123@mail.example.com>'). The tool will find all related emails."
                    )
                ],
                required: ["message_id"]
            )
        )
    )
    
    // MARK: - Document Tools
    
    static let listDocuments = ToolDefinition(
        function: FunctionDefinition(
            name: "list_documents",
            description: "List stored documents ranked by recent usage (most recently opened first; never-opened files fall back to newest created first). Use this to find document filenames before attaching them to emails. Supports pagination: pass limit (default 40, max 100) and cursor (from previous response next_cursor) to continue browsing older files page by page. Returns universal ISO 8601 UTC timestamps for each document.",
            parameters: FunctionParameters(
                properties: [
                    "limit": ParameterProperty(
                        type: "integer",
                        description: "Optional number of documents to return per page. Default 40, max 100."
                    ),
                    "cursor": ParameterProperty(
                        type: "string",
                        description: "Optional pagination cursor from a previous list_documents response (next_cursor). Omit on first call to get the latest documents."
                    )
                ],
                required: []
            )
        )
    )
    
    static let readDocument = ToolDefinition(
        function: FunctionDefinition(
            name: "read_document",
            description: "Open and read one or more documents from local file storage. Use proactively to view, analyze, read, or examine files that are relevant to the user's request, but of which you can only see the name and description. It is important that you see first hand the documents that you are analyzing. It returns raw file data (images, PDFs, documents) for direct multimodal analysis. You can open up to 10 documents per call. You can use list_documents to find available files to read/open.",
            parameters: FunctionParameters(
                properties: [
                    "document_filenames": ParameterProperty(
                        type: "string",
                        description: "JSON array of document filenames to read (from list_documents). Supports 1 to 10 files per call. Example: [\"a.pdf\", \"b.jpg\"]."
                    ),
                    "document_filename": ParameterProperty(
                        type: "string",
                        description: "Optional legacy single filename form (from list_documents, e.g. 'abc123.pdf'). Prefer document_filenames."
                    )
                ],
                required: ["document_filenames"]
            )
        )
    )
    
    static let sendEmailWithAttachment = ToolDefinition(
        function: FunctionDefinition(
            name: "send_email_with_attachment",
            description: "Send an email with one or more documents attached. Use when the user wants to email files/documents they previously sent via Telegram. First use list_documents to find the filenames.",
            parameters: FunctionParameters(
                properties: [
                    "to": ParameterProperty(
                        type: "string",
                        description: "Recipient email address."
                    ),
                    "subject": ParameterProperty(
                        type: "string",
                        description: "Email subject line."
                    ),
                    "body": ParameterProperty(
                        type: "string",
                        description: "Plain text email body content."
                    ),
                    "cc": ParameterProperty(
                        type: "string",
                        description: "Optional CC recipients. Comma-separated string (e.g., 'a@example.com, b@example.com') or JSON array string."
                    ),
                    "bcc": ParameterProperty(
                        type: "string",
                        description: "Optional BCC recipients. Comma-separated string (e.g., 'a@example.com, b@example.com') or JSON array string."
                    ),
                    "document_filenames": ParameterProperty(
                        type: "string",
                        description: "JSON array of document filenames to attach (from list_documents). Example: [\"report.pdf\", \"image.jpg\"]. Use list_documents to find available files."
                    )
                ],
                required: ["to", "subject", "body", "document_filenames"]
            )
        )
    )
    
    // MARK: - Email Attachment Download Tool
    
    static let downloadEmailAttachment = ToolDefinition(
        function: FunctionDefinition(
            name: "download_email_attachment",
            description: "Download attachments from an email. Use read_emails first to see available attachments. Two modes: (1) Single attachment: provide email_uid and part_id to download one file. (2) Batch download: provide email_uid and set download_all=true to download ALL attachments at once and save them to the documents folder. Batch mode is more efficient when you need multiple or all attachments.",
            parameters: FunctionParameters(
                properties: [
                    "email_uid": ParameterProperty(
                        type: "string",
                        description: "The UID of the email containing the attachment (from the 'id' field in read_emails output)."
                    ),
                    "part_id": ParameterProperty(
                        type: "string",
                        description: "The MIME part ID of a specific attachment (from the 'partId' field in the attachments array). Required unless download_all is true."
                    ),
                    "download_all": ParameterProperty(
                        type: "boolean",
                        description: "Set to true to download ALL attachments from the email at once. Files are saved to documents folder. More efficient than downloading one at a time."
                    )
                ],
                required: ["email_uid"]
            )
        )
    )
    
    // MARK: - Contact Tools
    
    static let manageContacts = ToolDefinition(
        function: FunctionDefinition(
            name: "manage_contacts",
            description: "Single contacts tool. Prefer action='find' to search by name/email (more token-efficient). Use action='add' to create a contact, action='list' to browse contacts with pagination, and action='delete' to remove one or many contacts.",
            parameters: FunctionParameters(
                properties: [
                    "action": ParameterProperty(
                        type: "string",
                        description: "Contact action: 'find', 'add', 'list', or 'delete'.",
                        enumValues: ["find", "add", "list", "delete"]
                    ),
                    "query": ParameterProperty(
                        type: "string",
                        description: "Required for action='find'. Name or email search query."
                    ),
                    "first_name": ParameterProperty(
                        type: "string",
                        description: "Required for action='add'. Contact first name."
                    ),
                    "last_name": ParameterProperty(
                        type: "string",
                        description: "Optional for action='add'. Contact last name."
                    ),
                    "email": ParameterProperty(
                        type: "string",
                        description: "Optional for action='add'. Contact email."
                    ),
                    "phone": ParameterProperty(
                        type: "string",
                        description: "Optional for action='add'. Contact phone."
                    ),
                    "organization": ParameterProperty(
                        type: "string",
                        description: "Optional for action='add'. Contact organization."
                    ),
                    "limit": ParameterProperty(
                        type: "integer",
                        description: "Optional for action='list'. Page size (default 40, max 40)."
                    ),
                    "cursor": ParameterProperty(
                        type: "string",
                        description: "Optional for action='list'. Pagination cursor from previous response (next_cursor). Omit on first call."
                    ),
                    "contact_id": ParameterProperty(
                        type: "string",
                        description: "For action='delete'. Single contact UUID."
                    ),
                    "contact_ids": ParameterProperty(
                        type: "string",
                        description: "For action='delete'. Multiple contact IDs as JSON array string or CSV (e.g. [\"id1\",\"id2\"] or \"id1,id2\")."
                    )
                ],
                required: ["action"]
            )
        )
    )
    
    // MARK: - Image Generation Tool
    
    static let generateImage = ToolDefinition(
        function: FunctionDefinition(
            name: "generate_image",
            description: "Generate an image from a text description using AI, or transform/edit an existing image. Use when the user asks you to create, generate, draw, make, edit, or transform an image/picture/illustration. The generated image will be sent to the user in the chat. When editing a user's image, reference the most recently received image file.",
            parameters: FunctionParameters(
                properties: [
                    "prompt": ParameterProperty(
                        type: "string",
                        description: "A detailed description of the image to generate, or instructions for how to transform the source image. For new images: be specific about subjects, style, colors, lighting, composition, and mood. For edits: describe what changes to make (e.g., 'make the sky more dramatic', 'add a rainbow', 'convert to oil painting style')."
                    ),
                    "source_image": ParameterProperty(
                        type: "string",
                        description: "Optional. The filename of an image previously sent in the conversation to use as source for transformation/editing. Use the exact filename (e.g., 'abc123.jpg') from a previously received image. Leave empty to generate a new image from scratch."
                    ),
                    "size": ParameterProperty(
                        type: "string",
                        description: "Optional output size. Supported values: '1K' (default), '2K', '4K'. Use '4K' when the user requests ultra-high resolution or when high-detail output is important.",
                        enumValues: ["1K", "2K", "4K"]
                    )
                ],
                required: ["prompt"]
            )
        )
    )
    
    // MARK: - URL Viewing and Download Tools
    
    static let viewUrl = ToolDefinition(
        function: FunctionDefinition(
            name: "view_url",
            description: "Read and view the content of a URL directly. Use AFTER web_search or deep_research when you need to see the full content of a page, not just snippets. Returns markdown content with image descriptions (captions and URLs) and all links. If you want to actually SEE an image from the page, use view_page_image with the image URL returned in the images array. Ideal for: reading articles, documentation, product pages, or any URL from search results that you need more detail on.",
            parameters: FunctionParameters(
                properties: [
                    "url": ParameterProperty(
                        type: "string",
                        description: "The full URL to read (e.g., 'https://example.com/article'). Use URLs from web_search/deep_research results or user-provided URLs."
                    )
                ],
                required: ["url"]
            )
        )
    )
    
    static let viewPageImage = ToolDefinition(
        function: FunctionDefinition(
            name: "view_page_image",
            description: "Download and view a specific image from a webpage. Use AFTER view_url when you want to actually see and analyze an image. The images array from view_url contains captions and URLs - use the caption to decide which image is relevant, then call this tool with the image_url. The downloaded image will be visible to you for analysis.",
            parameters: FunctionParameters(
                properties: [
                    "image_url": ParameterProperty(
                        type: "string",
                        description: "Direct URL to the image to download and view. Use the url field from an image in the images array returned by view_url."
                    ),
                    "caption": ParameterProperty(
                        type: "string",
                        description: "Optional caption or description for the image (from the view_url response). Helps with context."
                    )
                ],
                required: ["image_url"]
            )
        )
    )
    
    static let downloadFromUrl = ToolDefinition(
        function: FunctionDefinition(
            name: "download_from_url",
            description: "Download a file or image from a URL. Use to save images, PDFs, documents, or other files from the web. The file is saved locally and you can reference it in subsequent messages or attach it to emails. Supports: images (jpg, png, gif, webp), PDFs, and common document formats.",
            parameters: FunctionParameters(
                properties: [
                    "url": ParameterProperty(
                        type: "string",
                        description: "Direct URL to the file to download (e.g., 'https://example.com/image.jpg'). Must be a direct link to the file, not a webpage."
                    ),
                    "filename": ParameterProperty(
                        type: "string",
                        description: "Optional preferred filename for the downloaded file. If not provided, will be derived from the URL or generated."
                    )
                ],
                required: ["url"]
            )
        )
    )
    
    // MARK: - Document Generation Tool
    
    static let generateDocument = ToolDefinition(
        function: FunctionDefinition(
            name: "generate_document",
            description: "Generate a document file (PDF, Word, or Excel/CSV) with specified content. Use for: creating reports, summaries, spreadsheets, formal documents, invoices, meeting notes, OR full-page image PDFs. For fullscreen images, use layout='fullscreen_image' with image_filename. IMPORTANT: When embedding images in PDFs, use read_document first to preview the image and verify it's appropriate for the content before referencing it. Generated files are saved and automatically sent via Telegram.",
            parameters: FunctionParameters(
                properties: [
                    "document_type": ParameterProperty(
                        type: "string",
                        description: "Type of document: 'pdf' (best for formatted reports, letters, or fullscreen images), 'excel' (CSV format, best for data/tables), or 'word' (RTF format, best for editable documents).",
                        enumValues: ["pdf", "excel", "word"]
                    ),
                    "title": ParameterProperty(
                        type: "string",
                        description: "Document title - used as filename and shown as main heading. Optional for fullscreen_image layout."
                    ),
                    "layout": ParameterProperty(
                        type: "string",
                        description: "PDF layout mode: 'standard' (default, with title/sections/margins) or 'fullscreen_image' (image fills entire page with no margins or title). Only applies to PDFs.",
                        enumValues: ["standard", "fullscreen_image"]
                    ),
                    "image_filenames": ParameterProperty(
                        type: "string",
                        description: "Required for fullscreen_image layout. Array of image filenames (e.g. [\"photo1.jpg\", \"photo2.jpg\"]) or single filename. Each image becomes a full page in the PDF. Use list_documents to find available images."
                    ),
                    "sections": ParameterProperty(
                        type: "string",
                        description: "JSON array of section objects for PDF/Word. Each section can have: 'heading' (string), 'body' (string), 'bullet_points' (array of strings), 'table' (object with 'headers' array and 'rows' 2D array), 'image' (object with 'filename' from documents/images directory, optional 'caption', optional 'width' as percentage 10-100 of page width default 50, optional 'alignment' left/center/right default center). Example: [{\"heading\":\"Introduction\",\"body\":\"Text here\"}]"
                    ),
                    "table_data": ParameterProperty(
                        type: "string",
                        description: "For Excel or simple table documents: JSON object with 'headers' (array of column names) and 'rows' (2D array of cell values). Example: {\"headers\":[\"Name\",\"Age\"],\"rows\":[[\"John\",\"30\"],[\"Jane\",\"25\"]]}"
                    )
                ],
                required: ["document_type"]
            )
        )
    )
    
    // MARK: - Send Document to Telegram Chat
    
    static let sendDocumentToChat = ToolDefinition(
        function: FunctionDefinition(
            name: "send_document_to_chat",
            description: "Send a document or file directly to the user via Telegram. Use when the user asks you to send/share a file, document, or image that's in your file management. Works with: PDFs, images, documents downloaded from URLs, email attachments, or any file in your documents folder. You can use list_documents to find the filename before sending.",
            parameters: FunctionParameters(
                properties: [
                    "document_filename": ParameterProperty(
                        type: "string",
                        description: "The filename of the document to send (from list_documents, e.g. 'abc123.pdf'). This is the stored filename."
                    ),
                    "caption": ParameterProperty(
                        type: "string",
                        description: "Optional caption to include with the document."
                    )
                ],
                required: ["document_filename"]
            )
        )
    )
    
    // MARK: - Gmail API Tools (2 consolidated tools)
    
    static let gmailReader = ToolDefinition(
        function: FunctionDefinition(
            name: "gmailreader",
            description: "Unified Gmail reading tool. Required field: action. Use action='search' to search/list emails with Gmail query syntax, action='read_message' to read one full message by message_id, action='read_thread' to read an entire thread by thread_id, and action='download_attachment' to download a specific attachment so it becomes visible for analysis. Examples: {action:'search', query:'from:john@example.com has:attachment'}, {action:'read_message', message_id:'...'}, {action:'read_thread', thread_id:'...'}, {action:'download_attachment', message_id:'...', attachment_id:'...', filename:'report.pdf'}.",
            parameters: FunctionParameters(
                properties: [
                    "action": ParameterProperty(
                        type: "string",
                        description: "Required Gmail reader action: 'search', 'read_message', 'read_thread', or 'download_attachment'.",
                        enumValues: ["search", "read_message", "read_thread", "download_attachment"]
                    ),
                    "query": ParameterProperty(
                        type: "string",
                        description: "For action='search'. Gmail search query. Leave empty for recent inbox messages. Examples: 'from:sender@example.com', 'subject:meeting', 'after:2026/01/15', 'is:unread has:attachment'."
                    ),
                    "limit": ParameterProperty(
                        type: "integer",
                        description: "For action='search'. Maximum number of emails to return (1-50). Default is 10."
                    ),
                    "message_id": ParameterProperty(
                        type: "string",
                        description: "For action='read_message' or action='download_attachment'. The Gmail message ID."
                    ),
                    "thread_id": ParameterProperty(
                        type: "string",
                        description: "For action='read_thread'. The thread ID from a previous search/read result."
                    ),
                    "attachment_id": ParameterProperty(
                        type: "string",
                        description: "For action='download_attachment'. The attachment_id shown in search/read results."
                    ),
                    "filename": ParameterProperty(
                        type: "string",
                        description: "For action='download_attachment'. The exact attachment filename from search/read results. Required for proper file saving."
                    )
                ],
                required: ["action"]
            )
        )
    )
    
    static let gmailComposer = ToolDefinition(
        function: FunctionDefinition(
            name: "gmailcomposer",
            description: "Unified Gmail writing tool. Required field: action. Use action='new' to send a new email, action='reply' to reply in an existing thread, and action='forward' to forward an existing message with its attachments. For new/reply you can also pass cc, bcc, and attachment_filenames from list_documents. Examples: {action:'new', to:'a@example.com', subject:'Hello', body:'...'}, {action:'reply', to:'a@example.com', subject:'Re: Hello', body:'...', thread_id:'...', in_reply_to:'...'}, {action:'forward', to:'b@example.com', message_id:'...', comment:'FYI'}.",
            parameters: FunctionParameters(
                properties: [
                    "action": ParameterProperty(
                        type: "string",
                        description: "Required Gmail composer action: 'new', 'reply', or 'forward'.",
                        enumValues: ["new", "reply", "forward"]
                    ),
                    "to": ParameterProperty(
                        type: "string",
                        description: "Recipient email address. Required for all composer actions."
                    ),
                    "subject": ParameterProperty(
                        type: "string",
                        description: "For action='new' or action='reply'. Email subject line. For replies, usually use 'Re: original subject'."
                    ),
                    "body": ParameterProperty(
                        type: "string",
                        description: "For action='new' or action='reply'. Plain text email body."
                    ),
                    "thread_id": ParameterProperty(
                        type: "string",
                        description: "For action='reply'. The thread ID from gmailreader search/read results. Required for proper reply threading."
                    ),
                    "in_reply_to": ParameterProperty(
                        type: "string",
                        description: "For action='reply'. Optional Message-ID header of the message being replied to. Use with thread_id for best threading."
                    ),
                    "cc": ParameterProperty(
                        type: "string",
                        description: "For action='new' or action='reply'. Optional CC recipients. Comma-separated string (e.g., 'a@example.com, b@example.com') or JSON array string."
                    ),
                    "bcc": ParameterProperty(
                        type: "string",
                        description: "For action='new' or action='reply'. Optional BCC recipients. Comma-separated string (e.g., 'a@example.com, b@example.com') or JSON array string."
                    ),
                    "attachment_filenames": ParameterProperty(
                        type: "string",
                        description: "For action='new' or action='reply'. Optional JSON array of filenames from list_documents to attach. Example: [\"document.pdf\", \"image.jpg\"]."
                    ),
                    "message_id": ParameterProperty(
                        type: "string",
                        description: "For action='forward'. The Gmail message ID to forward."
                    ),
                    "comment": ParameterProperty(
                        type: "string",
                        description: "For action='forward'. Optional comment to add above the forwarded message."
                    )
                ],
                required: ["action", "to"]
            )
        )
    )
    
    // MARK: - macOS Shortcuts Tools
    
    static let shortcuts = ToolDefinition(
        function: FunctionDefinition(
            name: "shortcuts",
            description: "Unified macOS Shortcuts tool. Use action='list' to discover available shortcuts. Use action='run' to execute a shortcut by exact name with optional input text. If a shortcut returns an image or other media, it will be made visible for analysis. Examples: {action:'list'} or {action:'run', name:'My Shortcut', input:'some text'}.",
            parameters: FunctionParameters(
                properties: [
                    "action": ParameterProperty(
                        type: "string",
                        description: "Required shortcuts action: 'list' or 'run'.",
                        enumValues: ["list", "run"]
                    ),
                    "name": ParameterProperty(
                        type: "string",
                        description: "For action='run'. Exact name of the Shortcut to run, as shown in the Shortcuts app or from shortcuts action='list'."
                    ),
                    "input": ParameterProperty(
                        type: "string",
                        description: "For action='run'. Optional input text to pass to the shortcut. Some shortcuts accept input (text, URLs, etc.) to process."
                    )
                ],
                required: ["action"]
            )
        )
    )
    
    // MARK: - Gated Deployment/Database Tools
    
    static let showProjectDeploymentTools = ToolDefinition(
        function: FunctionDefinition(
            name: "show_project_deployment_tools",
            description: "Reveal advanced deployment/database tools for the current turn only. Call this BEFORE trying to deploy to Vercel or provision/sync project databases with InstantDB. Once called, the gated tools remain visible for the rest of this turn. After unlocking, if reusing an existing project for deployment/database work, call view_project_deployment_history once for that project before the first deployment/database tool call in the turn.",
            parameters: FunctionParameters(
                properties: [:],
                required: []
            )
        )
    )

    static let viewProjectDeploymentHistory = ToolDefinition(
        function: FunctionDefinition(
            name: "view_project_deployment_history",
            description: "View recent deployment/database history for a specific project. Use this once per turn before the first deployment/database tool call whenever you are reusing an existing project_id so the coordinator can review prior Vercel CLI and InstantDB CLI activity. Do not call it repeatedly in the same turn for the same project unless the history load failed.",
            parameters: FunctionParameters(
                properties: [
                    "project_id": ParameterProperty(
                        type: "string",
                        description: "Project ID from manage_projects action='list'."
                    )
                ],
                required: ["project_id"]
            )
        )
    )
    
    static let provisionProjectDatabase = ToolDefinition(
        function: FunctionDefinition(
            name: "provision_project_database",
            description: "Provision a project database (currently optimized for Instant) and persist project database metadata. Uses Instant CLI in non-interactive mode with an API token from settings or instant_token argument. Reuses an already-linked app by default unless force_reprovision=true. If reusing an existing project for deployment/database work, call view_project_deployment_history once earlier in the turn before this tool.",
            parameters: FunctionParameters(
                properties: [
                    "project_id": ParameterProperty(
                        type: "string",
                        description: "Project ID from manage_projects action='list'."
                    ),
                    "provider": ParameterProperty(
                        type: "string",
                        description: "Database provider. Supported: 'instantdb' (default).",
                        enumValues: ["instantdb"]
                    ),
                    "environment": ParameterProperty(
                        type: "string",
                        description: "Optional database environment. Use 'test' for preview/testing DB or 'prod' for production DB. Default: existing legacy project link.",
                        enumValues: ["test", "prod"]
                    ),
                    "database_title": ParameterProperty(
                        type: "string",
                        description: "Optional human title for the database app. Defaults to project name."
                    ),
                    "instant_token": ParameterProperty(
                        type: "string",
                        description: "Optional Instant CLI auth token override. If omitted, uses Settings token."
                    ),
                    "use_temporary_app": ParameterProperty(
                        type: "boolean",
                        description: "If true, create a temporary Instant app (ephemeral; no long-term token needed). Default false."
                    ),
                    "force_reprovision": ParameterProperty(
                        type: "boolean",
                        description: "If true, create a new Instant app even when this project already has a saved app_id. Default false."
                    ),
                    "timeout_seconds": ParameterProperty(
                        type: "integer",
                        description: "Optional timeout in seconds for provisioning command. Default 120."
                    ),
                    "max_output_chars": ParameterProperty(
                        type: "integer",
                        description: "Optional max output characters returned from stdout/stderr. Default 12000."
                    )
                ],
                required: ["project_id"]
            )
        )
    )
    
    static let pushProjectDatabaseSchema = ToolDefinition(
        function: FunctionDefinition(
            name: "push_project_database_schema",
            description: "Apply/push project database schema to the provisioned database (currently optimized for Instant). Requires project database metadata from provision_project_database. If reusing an existing project for deployment/database work, call view_project_deployment_history once earlier in the turn before this tool.",
            parameters: FunctionParameters(
                properties: [
                    "project_id": ParameterProperty(
                        type: "string",
                        description: "Project ID from manage_projects action='list'."
                    ),
                    "provider": ParameterProperty(
                        type: "string",
                        description: "Database provider. Supported: 'instantdb' (default).",
                        enumValues: ["instantdb"]
                    ),
                    "environment": ParameterProperty(
                        type: "string",
                        description: "Optional database environment to push schema to: 'test' or 'prod'. Default: existing legacy project link.",
                        enumValues: ["test", "prod"]
                    ),
                    "relative_path": ParameterProperty(
                        type: "string",
                        description: "Optional working directory inside the project where schema/perms files live. Default '.'."
                    ),
                    "schema_file_path": ParameterProperty(
                        type: "string",
                        description: "Optional schema file path for Instant CLI via INSTANT_SCHEMA_FILE_PATH."
                    ),
                    "perms_file_path": ParameterProperty(
                        type: "string",
                        description: "Optional perms file path for Instant CLI via INSTANT_PERMS_FILE_PATH."
                    ),
                    "instant_token": ParameterProperty(
                        type: "string",
                        description: "Optional Instant CLI auth token override. If omitted, uses saved project admin token, then Settings token."
                    ),
                    "timeout_seconds": ParameterProperty(
                        type: "integer",
                        description: "Optional timeout in seconds. Default 120."
                    ),
                    "max_output_chars": ParameterProperty(
                        type: "integer",
                        description: "Optional max output characters returned from stdout/stderr. Default 12000."
                    )
                ],
                required: ["project_id"]
            )
        )
    )
    
    static let syncProjectDatabaseEnvToVercel = ToolDefinition(
        function: FunctionDefinition(
            name: "sync_project_database_env_to_vercel",
            description: "Upsert project database environment variables to Vercel using the Vercel REST API. Can use saved database metadata/env values and optional overrides. If reusing an existing project for deployment/database work, call view_project_deployment_history once earlier in the turn before this tool.",
            parameters: FunctionParameters(
                properties: [
                    "project_id": ParameterProperty(
                        type: "string",
                        description: "Project ID from manage_projects action='list'."
                    ),
                    "environment": ParameterProperty(
                        type: "string",
                        description: "Optional database environment source: 'test' or 'prod'. When set and targets are omitted, defaults are test->development+preview, prod->production.",
                        enumValues: ["test", "prod"]
                    ),
                    "relative_path": ParameterProperty(
                        type: "string",
                        description: "Optional folder inside the project where .vercel/project.json is located. Default '.'."
                    ),
                    "include_saved_database_env": ParameterProperty(
                        type: "boolean",
                        description: "If true (default), include env vars inferred from saved database metadata."
                    ),
                    "include_admin_token": ParameterProperty(
                        type: "boolean",
                        description: "If true, include sensitive admin token env vars when available. Default false."
                    ),
                    "env_vars": ParameterProperty(
                        type: "string",
                        description: "Optional JSON object string of additional env vars to upsert. Example: {\"FOO\":\"bar\"}."
                    ),
                    "targets": ParameterProperty(
                        type: "string",
                        description: "Optional target environments as JSON array string or CSV. Defaults depend on environment: test->development,preview; prod->production; otherwise development,preview,production."
                    ),
                    "project_name": ParameterProperty(
                        type: "string",
                        description: "Optional Vercel project id/name override when no saved or local Vercel link exists. Passing this once lets the app persist the mapping for later runs."
                    ),
                    "team_id": ParameterProperty(
                        type: "string",
                        description: "Optional Vercel team ID override for API requests (e.g., team_xxx)."
                    ),
                    "timeout_seconds": ParameterProperty(
                        type: "integer",
                        description: "Optional HTTP timeout per request in seconds. Default 30."
                    ),
                    "max_output_chars": ParameterProperty(
                        type: "integer",
                        description: "Optional max characters for debug output in response. Default 12000."
                    )
                ],
                required: ["project_id"]
            )
        )
    )
    
    static let generateProjectMCPConfig = ToolDefinition(
        function: FunctionDefinition(
            name: "generate_project_mcp_config",
            description: "Generate or update project MCP configuration (.mcp.json) for database tooling. Useful as optional Phase 2 after direct provisioning/env sync works. If reusing an existing project for deployment/database work, call view_project_deployment_history once earlier in the turn before this tool.",
            parameters: FunctionParameters(
                properties: [
                    "project_id": ParameterProperty(
                        type: "string",
                        description: "Project ID from manage_projects action='list'."
                    ),
                    "provider": ParameterProperty(
                        type: "string",
                        description: "MCP provider target. Supported: 'instantdb' (default).",
                        enumValues: ["instantdb"]
                    ),
                    "relative_path": ParameterProperty(
                        type: "string",
                        description: "Optional folder inside project to write config. Default '.'."
                    ),
                    "mode": ParameterProperty(
                        type: "string",
                        description: "MCP mode: 'remote' (default, https endpoint) or 'local' (command-based MCP server).",
                        enumValues: ["remote", "local"]
                    ),
                    "output_path": ParameterProperty(
                        type: "string",
                        description: "Optional output filename/path inside relative_path. Default '.mcp.json'."
                    )
                ],
                required: ["project_id"]
            )
        )
    )

    // MARK: - Project Workspace Tools

    static let manageProjects = ToolDefinition(
        function: FunctionDefinition(
            name: "manage_projects",
            description: "Unified project workspace admin tool. Use action='create' to create a new local isolated workspace for the configured Code CLI Sub-Agent. Use action='list' to list or search available project workspaces, including both 'User Projects' and your own internal 'Agent Automations'. Examples: {action:'create', project_name:'Landing Page Redesign', initial_notes:'...'} or {action:'list', query:'invoice parser', limit:20}.",
            parameters: FunctionParameters(
                properties: [
                    "action": ParameterProperty(
                        type: "string",
                        description: "Required project admin action: 'create' or 'list'.",
                        enumValues: ["create", "list"]
                    ),
                    "project_name": ParameterProperty(
                        type: "string",
                        description: "For action='create'. Human-friendly project name (e.g., 'Landing Page Redesign', 'Invoice Parser')."
                    ),
                    "initial_notes": ParameterProperty(
                        type: "string",
                        description: "For action='create'. Optional starter notes or requirements to save in the project README. If you are creating an internal tool/automation for your own use, explicitly state 'This is an internal agent automation' here."
                    ),
                    "query": ParameterProperty(
                        type: "string",
                        description: "For action='list'. Optional keyword to search for specific project names, IDs, or description contents (case-insensitive)."
                    ),
                    "limit": ParameterProperty(
                        type: "integer",
                        description: "For action='list'. Optional number of projects to return per page. Default 20, max 100."
                    ),
                    "cursor": ParameterProperty(
                        type: "string",
                        description: "For action='list'. Optional pagination cursor from a previous manage_projects list response (next_cursor). Omit on first call to get the latest projects."
                    )
                ],
                required: ["action"]
            )
        )
    )

    static let browseProject = ToolDefinition(
        function: FunctionDefinition(
            name: "browse_project",
            description: "Browse files and folders inside a specific project workspace. Use this to inspect project structure before running project automation/coding or sending results.",
            parameters: FunctionParameters(
                properties: [
                    "project_id": ParameterProperty(
                        type: "string",
                        description: "Project ID from manage_projects action='list'."
                    ),
                    "relative_path": ParameterProperty(
                        type: "string",
                        description: "Optional subfolder path inside the project. Leave empty to browse project root."
                    ),
                    "recursive": ParameterProperty(
                        type: "boolean",
                        description: "If true, recursively list nested files. If false, only list direct children."
                    ),
                    "max_entries": ParameterProperty(
                        type: "integer",
                        description: "Maximum number of entries to return (default 200, max 1000)."
                    )
                ],
                required: ["project_id"]
            )
        )
    )

    static let readProjectFile = ToolDefinition(
        function: FunctionDefinition(
            name: "read_project_file",
            description: "Read a file inside a project workspace. For text files, returns content. For binary files, returns metadata and makes the file visible for multimodal analysis.",
            parameters: FunctionParameters(
                properties: [
                    "project_id": ParameterProperty(
                        type: "string",
                        description: "Project ID from manage_projects action='list'."
                    ),
                    "relative_path": ParameterProperty(
                        type: "string",
                        description: "Relative file path inside the project (e.g., 'src/main.swift')."
                    ),
                    "max_chars": ParameterProperty(
                        type: "integer",
                        description: "Optional max characters for text file output (default 12000)."
                    )
                ],
                required: ["project_id", "relative_path"]
            )
        )
    )
    
    static let addProjectFiles = ToolDefinition(
        function: FunctionDefinition(
            name: "add_project_files",
            description: "Copy files from local app storage into a project workspace. If any selected file is a .zip archive, it is automatically extracted into the destination folder inside the project. Use this when the user sends files/images and wants the configured Code CLI to use them in the project.",
            parameters: FunctionParameters(
                properties: [
                    "project_id": ParameterProperty(
                        type: "string",
                        description: "Project ID from manage_projects action='list'."
                    ),
                    "document_filenames": ParameterProperty(
                        type: "string",
                        description: "JSON array of filenames from list_documents (or CSV). Example: [\"brief.pdf\", \"project.zip\"]. ZIP archives are extracted automatically."
                    ),
                    "source_directory": ParameterProperty(
                        type: "string",
                        description: "Optional source storage location: 'documents' (default) or 'images'. Use 'images' for files from the app image directory.",
                        enumValues: ["documents", "images"]
                    ),
                    "relative_path": ParameterProperty(
                        type: "string",
                        description: "Optional target subfolder inside the project (default '.')."
                    ),
                    "overwrite": ParameterProperty(
                        type: "boolean",
                        description: "If true, overwrite same-name files in destination. If false, auto-renames to avoid collisions."
                    )
                ],
                required: ["project_id", "document_filenames"]
            )
        )
    )
    
    static let viewProjectHistory = ToolDefinition(
        function: FunctionDefinition(
            name: "view_project_history",
            description: "View the recent history of your project tool runs for a specific project. Use this once per turn before the first run_claude_code call whenever you are reusing an existing project_id so the coordinator can review past attempts and avoid repeating prior prompting mistakes. Do not call it repeatedly in the same turn for the same project unless the history load failed. This is for the coordinator's planning context; the Code CLI still resumes its own native project session separately.",
            parameters: FunctionParameters(
                properties: [
                    "project_id": ParameterProperty(
                        type: "string",
                        description: "Project ID from manage_projects action='list'."
                    ),
                    "max_tokens": ParameterProperty(
                        type: "integer",
                        description: "Optional token budget for history context (default 10000, range 500-20000)."
                    )
                ],
                required: ["project_id"]
            )
        )
    )

    static let runClaudeCode = ToolDefinition(
        function: FunctionDefinition(
            name: "run_claude_code",
            description: "Delegate a task to the configured Code CLI Sub-Agent (Claude Code, Gemini CLI, or Codex CLI) in a specific workspace. Use this for complex file manipulations, iterative local tasks, data processing, or script execution. The Code CLI acts autonomously within the project. CRITICAL: The Code CLI's memory is strictly project-bound; it only remembers past interactions within this specific project ID. If reusing an existing project, call view_project_history for that same project_id once per turn before the first run_claude_code call so the coordinator reviews prior attempts before composing the new prompt. Do not repeat the history tool again in the same turn for the same project unless the history load failed. Always check created_files/modified_files/file_changes_detected before claiming work is done.",
            parameters: FunctionParameters(
                properties: [
                    "project_id": ParameterProperty(
                        type: "string",
                        description: "Project ID from manage_projects action='list'."
                    ),
                    "prompt": ParameterProperty(
                        type: "string",
                        description: "Task instructions for the configured Code CLI."
                    ),
                    "timeout_seconds": ParameterProperty(
                        type: "integer",
                        description: "Optional execution timeout in seconds. If omitted, uses app default."
                    ),
                    "max_output_chars": ParameterProperty(
                        type: "integer",
                        description: "Optional max output characters returned from stdout/stderr. Default 12000."
                    ),
                    "cli_args": ParameterProperty(
                        type: "string",
                        description: "Optional CLI argument string override. If omitted, uses saved default args from settings."
                    )
                ],
                required: ["project_id", "prompt"]
            )
        )
    )

    static let sendProjectResult = ToolDefinition(
        function: FunctionDefinition(
            name: "send_project_result",
            description: "Send project output files either to Telegram chat or via email. Use after run_claude_code when user asks to share deliverables. Supports packaging as individual files or as ZIP archives (selected files or whole project). For websites/apps with multiple files, prefer package_as='zip_project'.",
            parameters: FunctionParameters(
                properties: [
                    "project_id": ParameterProperty(
                        type: "string",
                        description: "Project ID from manage_projects action='list'."
                    ),
                    "destination": ParameterProperty(
                        type: "string",
                        description: "Where to send files: 'chat' or 'email'.",
                        enumValues: ["chat", "email"]
                    ),
                    "to": ParameterProperty(
                        type: "string",
                        description: "Required when destination is 'email'. Recipient email address."
                    ),
                    "subject": ParameterProperty(
                        type: "string",
                        description: "Optional email subject (for destination='email')."
                    ),
                    "body": ParameterProperty(
                        type: "string",
                        description: "Optional email body text (for destination='email')."
                    ),
                    "file_paths": ParameterProperty(
                        type: "string",
                        description: "Optional JSON array of relative file paths inside the project to send. Example: [\"dist/app.zip\", \"README.md\"]"
                    ),
                    "package_as": ParameterProperty(
                        type: "string",
                        description: "Packaging mode: 'files' (default, send files directly), 'zip_selection' (zip selected files), or 'zip_project' (zip the full project deliverables).",
                        enumValues: ["files", "zip_selection", "zip_project"]
                    ),
                    "archive_name": ParameterProperty(
                        type: "string",
                        description: "Optional archive base name when package_as is zip mode. '.zip' is added automatically."
                    ),
                    "use_last_changed_files": ParameterProperty(
                        type: "boolean",
                        description: "If true (default), send files changed in the last run_claude_code execution when file_paths is not provided."
                    ),
                    "max_files": ParameterProperty(
                        type: "integer",
                        description: "Maximum number of selected files to include (default 10). In zip_project mode, all project deliverables are included unless max_files is explicitly set."
                    ),
                    "caption": ParameterProperty(
                        type: "string",
                        description: "Optional caption used when sending to chat."
                    )
                ],
                required: ["project_id", "destination"]
            )
        )
    )
    
    static let deployProjectToVercel = ToolDefinition(
        function: FunctionDefinition(
            name: "deploy_project_to_vercel",
            description: "Deploy a project workspace (or subfolder) to Vercel. Use when the user asks to publish, deploy, or put a website/app online. By default create a preview deployment; set production=true only when user explicitly asks for production/live deployment. If reusing an existing project for deployment/database work, call view_project_deployment_history once earlier in the turn before this tool.",
            parameters: FunctionParameters(
                properties: [
                    "project_id": ParameterProperty(
                        type: "string",
                        description: "Project ID from manage_projects action='list'."
                    ),
                    "relative_path": ParameterProperty(
                        type: "string",
                        description: "Optional folder inside the project to deploy (default '.'). Use this when the app lives in a subdirectory."
                    ),
                    "production": ParameterProperty(
                        type: "boolean",
                        description: "If true, deploy to production. If false or omitted, deploy a preview build."
                    ),
                    "project_name": ParameterProperty(
                        type: "string",
                        description: "Optional Vercel project id/name to link before deploy when the workspace has no saved Vercel mapping yet. Passing this once lets later deploys reuse the same project."
                    ),
                    "team_scope": ParameterProperty(
                        type: "string",
                        description: "Optional Vercel team/account scope (slug). Defaults to the configured value in Settings if present."
                    ),
                    "force_relink": ParameterProperty(
                        type: "boolean",
                        description: "If true, re-run `vercel link` even if .vercel/project.json already exists in the target folder."
                    ),
                    "timeout_seconds": ParameterProperty(
                        type: "integer",
                        description: "Optional timeout for each CLI command (link/deploy). Defaults to configured Settings value."
                    ),
                    "max_output_chars": ParameterProperty(
                        type: "integer",
                        description: "Optional max output characters to return from stdout/stderr. Default 12000."
                    )
                ],
                required: ["project_id"]
            )
        )
    )
    
    // MARK: - Tool Arrays
    
    /// IMAP email tools (8 tools - used when email_mode is "imap")
    static var imapEmailTools: [ToolDefinition] {
        [readEmails, searchEmails, sendEmail, replyEmail, forwardEmail, getEmailThread, sendEmailWithAttachment, downloadEmailAttachment]
    }
    
    /// Gmail API tools (2 consolidated tools - used when email_mode is "gmail")
    static var gmailEmailTools: [ToolDefinition] {
        [gmailReader, gmailComposer]
    }
    
    /// Non-email tools that do not depend on web search credentials
    static var coreToolsWithoutWebSearch: [ToolDefinition] {
        [manageReminders, manageCalendar, viewConversationChunk, listDocuments, readDocument, manageContacts, generateImage, downloadFromUrl, sendDocumentToChat, generateDocument, shortcuts, showProjectDeploymentTools, manageProjects, browseProject, readProjectFile, addProjectFiles, viewProjectHistory, runClaudeCode, sendProjectResult]
    }
    
    static var gatedProjectDeploymentTools: [ToolDefinition] {
        [viewProjectDeploymentHistory, deployProjectToVercel, provisionProjectDatabase, pushProjectDatabaseSchema, syncProjectDatabaseEnvToVercel, generateProjectMCPConfig]
    }
    
    /// All available tools - dynamically selects email tools and optionally web search
    static func all(includeWebSearch: Bool, includeProjectDeploymentTools: Bool = false) -> [ToolDefinition] {
        let emailMode = KeychainHelper.load(key: KeychainHelper.emailModeKey) ?? "imap"
        let emailTools = emailMode == "gmail" ? gmailEmailTools : imapEmailTools
        let disableLegacyDocumentGeneration =
            (KeychainHelper.load(key: KeychainHelper.claudeCodeDisableLegacyDocumentGenerationToolsKey) ?? "false")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "true"
        let webTools = includeWebSearch ? [webSearch, deepResearch, viewUrl, viewPageImage] : []
        var coreTools = webTools + coreToolsWithoutWebSearch
        
        if disableLegacyDocumentGeneration {
            coreTools.removeAll { $0.function.name == "generate_document" }
        }
        
        if includeProjectDeploymentTools {
            coreTools += gatedProjectDeploymentTools
        }
        
        return coreTools + emailTools
    }
    
    /// Backward-compatible default: include web search
    static var all: [ToolDefinition] {
        all(includeWebSearch: true)
    }
}
