import Foundation

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
    let content: String
    
    /// Optional files to inject as multimodal content (not serialized to API directly)
    var fileAttachments: [FileAttachment]
    
    enum CodingKeys: String, CodingKey {
        case role
        case toolCallId = "tool_call_id"
        case content
    }
    
    init(toolCallId: String, content: String, fileAttachment: FileAttachment? = nil, fileAttachments: [FileAttachment]? = nil) {
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
    }
    
    // Manual Decodable conformance - fileAttachments is not serialized
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.role = try container.decode(String.self, forKey: .role)
        self.toolCallId = try container.decode(String.self, forKey: .toolCallId)
        self.content = try container.decode(String.self, forKey: .content)
        self.fileAttachments = [] // Not decoded, only used transiently
    }
}

// MARK: - Web Search Tool Result

struct WebSearchResult: Codable {
    let summary: String
    let sources: [String]
    let searchQueriesUsed: [String]
    
    func asJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(self),
              let json = String(data: data, encoding: .utf8) else {
            return "{\"summary\": \"\(summary)\", \"sources\": [], \"searchQueriesUsed\": []}"
        }
        return json
    }
}

// MARK: - LLM Response Types

enum LLMResponse {
    case text(String, promptTokens: Int?)
    case toolCalls(assistantMessage: AssistantToolCallMessage, calls: [ToolCall], promptTokens: Int?)
}

/// The assistant's message when it decides to call tools (must be preserved for the follow-up)
struct AssistantToolCallMessage: Codable {
    let role: String
    let content: String?
    let toolCalls: [ToolCall]
    
    enum CodingKeys: String, CodingKey {
        case role
        case content
        case toolCalls = "tool_calls"
    }
    
    init(content: String?, toolCalls: [ToolCall]) {
        self.role = "assistant"
        self.content = content
        self.toolCalls = toolCalls
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
    
    static let setReminder = ToolDefinition(
        function: FunctionDefinition(
            name: "set_reminder",
            description: "Schedule a future prompt to yourself. This is your primary tool for self-orchestration and agentic workflows. Use it for: (1) User-requested reminders (\"remind me to...\"), (2) Delayed actions you decide are needed (\"I'll check stock prices at market close\"), (3) Multi-step workflows where subsequent steps need time gaps, (4) Follow-up tasks where you want to verify something later, (5) Any time you think \"I should do X later\" — schedule it. The prompt you write becomes a message to your future self, injected into the conversation at trigger time with full tool access. Supports recurring reminders.",
            parameters: FunctionParameters(
                properties: [
                    "trigger_datetime": ParameterProperty(
                        type: "string",
                        description: "ISO 8601 datetime string (e.g., '2026-02-01T09:00:00+01:00') when the reminder should trigger. Must be in the future."
                    ),
                    "prompt": ParameterProperty(
                        type: "string",
                        description: "Detailed instructions for your future self. Include: what action to take, full context from the current conversation, any user preferences mentioned, and the expected outcome. You will have full tool access when this triggers, so you can web search, send emails, check calendar, or even set another reminder."
                    ),
                    "recurrence": ParameterProperty(
                        type: "string",
                        description: "Optional. Make this a recurring reminder. Values: 'daily', 'weekly', 'monthly', or 'every_X_minutes' (e.g., 'every_30_minutes' for every half hour). If omitted, reminder fires only once."
                    )
                ],
                required: ["trigger_datetime", "prompt"]
            )
        )
    )
    
    static let listReminders = ToolDefinition(
        function: FunctionDefinition(
            name: "list_reminders",
            description: "List all pending (not yet triggered) reminders. Shows reminder ID, scheduled time, prompt text, and recurrence if set. Use when user asks 'what reminders do I have?' or you need to find a reminder ID to delete.",
            parameters: FunctionParameters(
                properties: [:],
                required: []
            )
        )
    )
    
    static let deleteReminder = ToolDefinition(
        function: FunctionDefinition(
            name: "delete_reminder",
            description: "Delete/cancel a reminder by its ID. Use list_reminders first to get the reminder ID. Use when user wants to cancel a scheduled reminder.",
            parameters: FunctionParameters(
                properties: [
                    "reminder_id": ParameterProperty(
                        type: "string",
                        description: "The UUID of the reminder to delete (get this from list_reminders output)."
                    )
                ],
                required: ["reminder_id"]
            )
        )
    )
    
    // MARK: - Calendar Tools
    
    static let viewCalendar = ToolDefinition(
        function: FunctionDefinition(
            name: "view_calendar",
            description: "View the user's calendar events. By default shows only upcoming (future) events to save context space. Set include_past to true to also see past events.",
            parameters: FunctionParameters(
                properties: [
                    "include_past": ParameterProperty(
                        type: "boolean",
                        description: "If true, includes past events in the response. Default is false (only future events)."
                    )
                ],
                required: []
            )
        )
    )
    
    static let addCalendarEvent = ToolDefinition(
        function: FunctionDefinition(
            name: "add_calendar_event",
            description: "Add a new event to the user's calendar. Use when the user wants to schedule meetings, appointments, or any time-based events.",
            parameters: FunctionParameters(
                properties: [
                    "title": ParameterProperty(
                        type: "string",
                        description: "The title/name of the event (e.g., 'Meeting with John', 'Dentist appointment')."
                    ),
                    "datetime": ParameterProperty(
                        type: "string",
                        description: "ISO 8601 datetime string (e.g., '2026-02-01T15:00:00+01:00') for when the event occurs."
                    ),
                    "notes": ParameterProperty(
                        type: "string",
                        description: "Optional additional notes or details about the event."
                    )
                ],
                required: ["title", "datetime"]
            )
        )
    )
    
    static let editCalendarEvent = ToolDefinition(
        function: FunctionDefinition(
            name: "edit_calendar_event",
            description: "Edit an existing calendar event. Use view_calendar first to get the event_id. Only provide the fields you want to change.",
            parameters: FunctionParameters(
                properties: [
                    "event_id": ParameterProperty(
                        type: "string",
                        description: "The UUID of the event to edit (get this from view_calendar)."
                    ),
                    "title": ParameterProperty(
                        type: "string",
                        description: "New title for the event (optional, only if changing)."
                    ),
                    "datetime": ParameterProperty(
                        type: "string",
                        description: "New ISO 8601 datetime for the event (optional, only if changing)."
                    ),
                    "notes": ParameterProperty(
                        type: "string",
                        description: "New notes for the event (optional, only if changing)."
                    )
                ],
                required: ["event_id"]
            )
        )
    )
    
    static let deleteCalendarEvent = ToolDefinition(
        function: FunctionDefinition(
            name: "delete_calendar_event",
            description: "Delete a calendar event. Use view_calendar first to get the event_id.",
            parameters: FunctionParameters(
                properties: [
                    "event_id": ParameterProperty(
                        type: "string",
                        description: "The UUID of the event to delete (get this from view_calendar)."
                    )
                ],
                required: ["event_id"]
            )
        )
    )
    
    // MARK: - Conversation History Tool
    
    static let viewConversationChunk = ToolDefinition(
        function: FunctionDefinition(
            name: "view_conversation_chunk",
            description: "Access your long-term conversation memory. This tool has TWO uses: (1) LIST ALL ARCHIVED SUMMARIES: Call with no arguments to see summaries of ALL past conversation chunks, including older ones not shown in your context. Use this when the user asks about something from the past that you don't remember. (2) VIEW FULL CHUNK: Call with a chunk_id to retrieve the complete messages from that specific archived chunk. Use this after seeing the summaries to read the actual conversation.",
            parameters: FunctionParameters(
                properties: [
                    "chunk_id": ParameterProperty(
                        type: "string",
                        description: "Optional. If provided, returns the full messages from that chunk. If omitted, returns a list of ALL archived chunk summaries with their IDs so you can find what you're looking for."
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
                        description: "Email folder to search. Use 'sent' to search sent emails, 'drafts' for drafts, 'trash' for trash, or 'inbox' (default). The tool automatically handles Gmail folder naming conventions."
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
            description: "List all documents that the user has sent via Telegram. Use this to find document filenames before attaching them to emails. Returns filename, size, and type for each stored document.",
            parameters: FunctionParameters(
                properties: [:],
                required: []
            )
        )
    )
    
    static let readDocument = ToolDefinition(
        function: FunctionDefinition(
            name: "read_document",
            description: "Open and read the contents of a document from your local file storage. Use when the user asks you to view, analyze, read, or examine a document they previously sent or that was saved from an email or download. Returns the raw file data (images, PDFs, documents) that you can directly process with your vision capabilities. Use list_documents first to find available files.",
            parameters: FunctionParameters(
                properties: [
                    "document_filename": ParameterProperty(
                        type: "string",
                        description: "The filename of the document to read (from list_documents, e.g. 'abc123.pdf'). This is the stored filename."
                    )
                ],
                required: ["document_filename"]
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
    
    static let findContact = ToolDefinition(
        function: FunctionDefinition(
            name: "find_contact",
            description: "Search for a contact by name or email. Use when user mentions sending email/message to a person by name, or asks for someone's contact info (e.g., 'What is John's email?', 'Send email to Sarah Smith'). Returns matching contacts with their details. Use the email from the results for send_email or reply_email tools.",
            parameters: FunctionParameters(
                properties: [
                    "query": ParameterProperty(
                        type: "string",
                        description: "Name or email to search for. Can be partial (e.g., 'John' will match 'John Doe', 'John Smith')."
                    )
                ],
                required: ["query"]
            )
        )
    )
    
    static let addContact = ToolDefinition(
        function: FunctionDefinition(
            name: "add_contact",
            description: "Add a new contact to the user's contact list. Use when user explicitly asks to save/add a contact or provides contact information to remember.",
            parameters: FunctionParameters(
                properties: [
                    "first_name": ParameterProperty(
                        type: "string",
                        description: "Contact's first name (required)."
                    ),
                    "last_name": ParameterProperty(
                        type: "string",
                        description: "Contact's last name (optional)."
                    ),
                    "email": ParameterProperty(
                        type: "string",
                        description: "Contact's email address (optional)."
                    ),
                    "phone": ParameterProperty(
                        type: "string",
                        description: "Contact's phone number (optional)."
                    ),
                    "organization": ParameterProperty(
                        type: "string",
                        description: "Contact's company or organization (optional)."
                    )
                ],
                required: ["first_name"]
            )
        )
    )
    
    static let listContacts = ToolDefinition(
        function: FunctionDefinition(
            name: "list_contacts",
            description: "List all contacts in the user's contact list. Use when user asks to see all their contacts or wants to browse contacts. Returns up to 50 contacts to save context space.",
            parameters: FunctionParameters(
                properties: [:],
                required: []
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
            description: "Read and view the content of a URL directly. Use AFTER web_search when you need to see the full content of a page, not just snippets. Returns markdown content with image descriptions (captions and URLs) and all links. If you want to actually SEE an image from the page, use view_page_image with the image URL returned in the images array. Ideal for: reading articles, documentation, product pages, or any URL from search results that you need more detail on.",
            parameters: FunctionParameters(
                properties: [
                    "url": ParameterProperty(
                        type: "string",
                        description: "The full URL to read (e.g., 'https://example.com/article'). Use URLs from web_search results or user-provided URLs."
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
    
    // MARK: - User Context Management
    
    static let addToUserContext = ToolDefinition(
        function: FunctionDefinition(
            name: "add_to_user_context",
            description: "Append new information to your persistent memory about the user. Use when you learn something new worth remembering: preferences, life events (birthdays, moves), relationships, work details, communication style, etc. The fact is added to your existing context. Be concise but complete. Total context is limited to ~5000 tokens (~20k chars) — the response will tell you current usage.",
            parameters: FunctionParameters(
                properties: [
                    "fact": ParameterProperty(
                        type: "string",
                        description: "The new fact or information to add. Write concisely (e.g., 'Birthday: March 15th', 'Prefers morning meetings', 'Works at Google as a software engineer'). Will be appended to existing context."
                    )
                ],
                required: ["fact"]
            )
        )
    )
    
    static let removeFromUserContext = ToolDefinition(
        function: FunctionDefinition(
            name: "remove_from_user_context",
            description: "Remove outdated or incorrect information from your persistent memory. Use when user corrects something ('Actually my birthday is in April, not March') or when information becomes irrelevant (got a new job, moved to a new city). Specify keywords to identify what to remove. The response will show remaining space after removal.",
            parameters: FunctionParameters(
                properties: [
                    "keywords": ParameterProperty(
                        type: "string",
                        description: "Keywords or phrase to identify what to remove. Lines containing these keywords (case-insensitive) will be removed. E.g., 'birthday', 'old job', 'previous address'."
                    )
                ],
                required: ["keywords"]
            )
        )
    )
    
    static let rewriteUserContext = ToolDefinition(
        function: FunctionDefinition(
            name: "rewrite_user_context",
            description: "Completely rewrite your persistent memory about the user. Use sparingly — only when context needs major reorganization or cleanup. Replaces ALL existing context. Limited to ~5000 tokens (~20k chars). The response shows usage after rewrite.",
            parameters: FunctionParameters(
                properties: [
                    "new_context": ParameterProperty(
                        type: "string",
                        description: "The complete new user context. Write in second person ('You are assisting [name]...'). Organize by categories if helpful (Personal, Work, Preferences). Keep it under 20,000 characters."
                    )
                ],
                required: ["new_context"]
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
                        description: "Type of document: 'pdf' (best for formatted reports, letters, or fullscreen images), 'excel' (CSV format, best for data/tables), or 'word' (RTF format, best for editable documents)."
                    ),
                    "title": ParameterProperty(
                        type: "string",
                        description: "Document title - used as filename and shown as main heading. Optional for fullscreen_image layout."
                    ),
                    "layout": ParameterProperty(
                        type: "string",
                        description: "PDF layout mode: 'standard' (default, with title/sections/margins) or 'fullscreen_image' (image fills entire page with no margins or title). Only applies to PDFs."
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
            description: "Send a document or file directly to the user via Telegram. Use when the user asks you to send/share a file, document, or image that's in your file management. Works with: PDFs, images, documents downloaded from URLs, email attachments, or any file in your documents folder. First use list_documents to find the filename.",
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
    
    // MARK: - Gmail API Tools (5 consolidated tools)
    
    static let gmailQuery = ToolDefinition(
        function: FunctionDefinition(
            name: "gmail_query",
            description: "Search or list emails using Gmail's powerful query syntax. Use for: checking inbox, finding specific emails, searching by sender/date/subject. Examples: '' (empty = recent inbox), 'from:john@example.com', 'after:2026/01/01 before:2026/02/01', 'subject:invoice', 'has:attachment', 'is:unread'. Returns message ID, thread ID, from, subject, date, snippet, and attachment info.",
            parameters: FunctionParameters(
                properties: [
                    "query": ParameterProperty(
                        type: "string",
                        description: "Gmail search query. Leave empty for recent inbox messages. Examples: 'from:sender@example.com', 'subject:meeting', 'after:2026/01/15', 'is:unread has:attachment'."
                    ),
                    "limit": ParameterProperty(
                        type: "integer",
                        description: "Maximum number of emails to return (1-50). Default is 10."
                    )
                ],
                required: []
            )
        )
    )
    
    static let gmailSend = ToolDefinition(
        function: FunctionDefinition(
            name: "gmail_send",
            description: "Send a new email OR reply to an existing thread. If thread_id is provided, the email is sent as a reply in that thread (proper threading). Supports multiple file attachments from your documents folder.",
            parameters: FunctionParameters(
                properties: [
                    "to": ParameterProperty(
                        type: "string",
                        description: "Recipient email address."
                    ),
                    "subject": ParameterProperty(
                        type: "string",
                        description: "Email subject line. For replies, use 'Re: original subject'."
                    ),
                    "body": ParameterProperty(
                        type: "string",
                        description: "Plain text email body."
                    ),
                    "thread_id": ParameterProperty(
                        type: "string",
                        description: "Optional. The thread ID from gmail_query to send as a reply in that thread. If provided, email will be threaded with previous messages."
                    ),
                    "in_reply_to": ParameterProperty(
                        type: "string",
                        description: "Optional. The Message-ID header of the email being replied to. Use with thread_id for proper threading."
                    ),
                    "cc": ParameterProperty(
                        type: "string",
                        description: "Optional CC recipients. Comma-separated string (e.g., 'a@example.com, b@example.com') or JSON array string."
                    ),
                    "bcc": ParameterProperty(
                        type: "string",
                        description: "Optional BCC recipients. Comma-separated string (e.g., 'a@example.com, b@example.com') or JSON array string."
                    ),
                    "attachment_filenames": ParameterProperty(
                        type: "string",
                        description: "Optional. JSON array of filenames from list_documents to attach to the email. Example: [\"document.pdf\", \"image.jpg\"]. Use list_documents to find available files."
                    )
                ],
                required: ["to", "subject", "body"]
            )
        )
    )
    
    static let gmailThread = ToolDefinition(
        function: FunctionDefinition(
            name: "gmail_thread",
            description: "Get ALL emails in a conversation thread. Use when user wants to see the full email chain, understand conversation context, or read the complete discussion. Returns all messages in chronological order with full content.",
            parameters: FunctionParameters(
                properties: [
                    "thread_id": ParameterProperty(
                        type: "string",
                        description: "The thread ID from gmail_query output (threadId field)."
                    )
                ],
                required: ["thread_id"]
            )
        )
    )
    
    static let gmailForward = ToolDefinition(
        function: FunctionDefinition(
            name: "gmail_forward",
            description: "Forward an email to another recipient, including all attachments. The forwarded message includes original sender, date, and content.",
            parameters: FunctionParameters(
                properties: [
                    "to": ParameterProperty(
                        type: "string",
                        description: "Recipient email address to forward to."
                    ),
                    "message_id": ParameterProperty(
                        type: "string",
                        description: "The message ID from gmail_query to forward."
                    ),
                    "comment": ParameterProperty(
                        type: "string",
                        description: "Optional comment to add above the forwarded message."
                    )
                ],
                required: ["to", "message_id"]
            )
        )
    )
    
    static let gmailAttachment = ToolDefinition(
        function: FunctionDefinition(
            name: "gmail_attachment",
            description: "Download an attachment from an email. First use gmail_query or gmail_thread to see available attachments with their attachment_id values, then use this to download specific files. IMPORTANT: Always provide the filename parameter from the query/thread results.",
            parameters: FunctionParameters(
                properties: [
                    "message_id": ParameterProperty(
                        type: "string",
                        description: "The message ID containing the attachment."
                    ),
                    "attachment_id": ParameterProperty(
                        type: "string",
                        description: "The attachment_id from the gmail_query or gmail_thread output (the long string shown in parentheses after the filename)."
                    ),
                    "filename": ParameterProperty(
                        type: "string",
                        description: "The filename of the attachment from gmail_query or gmail_thread output (e.g., 'report.pdf'). Required for proper file saving."
                    )
                ],
                required: ["message_id", "attachment_id", "filename"]
            )
        )
    )
    
    // MARK: - macOS Shortcuts Tools
    
    static let listShortcuts = ToolDefinition(
        function: FunctionDefinition(
            name: "list_shortcuts",
            description: "List all available macOS Shortcuts that can be run. Use this first to discover what shortcuts the user has installed. Returns shortcut names that can be used with run_shortcut.",
            parameters: FunctionParameters(
                properties: [:],
                required: []
            )
        )
    )
    
    static let runShortcut = ToolDefinition(
        function: FunctionDefinition(
            name: "run_shortcut",
            description: "Run a macOS Shortcut by name. Shortcuts can automate complex system actions, control apps, send messages, interact with smart home devices, and much more. The shortcut runs and returns success/failure status plus any output it produces. If the shortcut returns an image or media file, it will be visible to you for analysis. Use list_shortcuts first to see available shortcuts.",
            parameters: FunctionParameters(
                properties: [
                    "name": ParameterProperty(
                        type: "string",
                        description: "Exact name of the Shortcut to run (as shown in the Shortcuts app or from list_shortcuts)."
                    ),
                    "input": ParameterProperty(
                        type: "string",
                        description: "Optional input text to pass to the shortcut. Some shortcuts accept input (text, URLs, etc.) to process."
                    )
                ],
                required: ["name"]
            )
        )
    )

    // MARK: - Claude Code Project Workspace Tools

    static let createProject = ToolDefinition(
        function: FunctionDefinition(
            name: "create_project",
            description: "Create a new local project workspace folder that Claude Code can work in. Use this when starting a new coding task or when the user asks to create a new project.",
            parameters: FunctionParameters(
                properties: [
                    "project_name": ParameterProperty(
                        type: "string",
                        description: "Human-friendly project name (e.g., 'Landing Page Redesign', 'Invoice Parser')."
                    ),
                    "initial_notes": ParameterProperty(
                        type: "string",
                        description: "Optional starter notes or requirements to save in the project README."
                    )
                ],
                required: ["project_name"]
            )
        )
    )

    static let listProjects = ToolDefinition(
        function: FunctionDefinition(
            name: "list_projects",
            description: "List all available project workspaces created for Claude Code, including AI-generated project description and last_edited_at. Use this to choose which project to inspect or run.",
            parameters: FunctionParameters(
                properties: [:],
                required: []
            )
        )
    )

    static let browseProject = ToolDefinition(
        function: FunctionDefinition(
            name: "browse_project",
            description: "Browse files and folders inside a specific project workspace. Use this to inspect project structure before running Claude Code or sending results.",
            parameters: FunctionParameters(
                properties: [
                    "project_id": ParameterProperty(
                        type: "string",
                        description: "Project ID from list_projects."
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
                        description: "Project ID from list_projects."
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
            description: "Copy files from local app storage into a Claude project workspace. Use this when the user sends files/images and wants Claude Code to use them in the project.",
            parameters: FunctionParameters(
                properties: [
                    "project_id": ParameterProperty(
                        type: "string",
                        description: "Project ID from list_projects."
                    ),
                    "document_filenames": ParameterProperty(
                        type: "string",
                        description: "JSON array of filenames from list_documents (or CSV). Example: [\"brief.pdf\", \"photo.jpg\"]"
                    ),
                    "source_directory": ParameterProperty(
                        type: "string",
                        description: "Optional source storage location: 'documents' (default) or 'images'. Use 'images' for files from the app image directory."
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

    static let runClaudeCode = ToolDefinition(
        function: FunctionDefinition(
            name: "run_claude_code",
            description: "Run Claude Code CLI in a selected project workspace with a prompt. Use this as the primary code-building tool for project implementation tasks. Always check created_files/modified_files/file_changes_detected before claiming code was written. This tool also refreshes project_description metadata for future project selection.",
            parameters: FunctionParameters(
                properties: [
                    "project_id": ParameterProperty(
                        type: "string",
                        description: "Project ID from list_projects."
                    ),
                    "prompt": ParameterProperty(
                        type: "string",
                        description: "Task instructions for Claude Code."
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
                        description: "Project ID from list_projects."
                    ),
                    "destination": ParameterProperty(
                        type: "string",
                        description: "Where to send files: 'chat' or 'email'."
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
                        description: "Packaging mode: 'files' (default, send files directly), 'zip_selection' (zip selected files), or 'zip_project' (zip the full project deliverables)."
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
    
    static let flagProjectsForDeletion = ToolDefinition(
        function: FunctionDefinition(
            name: "flag_projects_for_deletion",
            description: "Flag one or more Claude project workspaces for deletion review in Settings. This does NOT delete any files. The user must confirm deletion manually in 'Browse Claude Projects'.",
            parameters: FunctionParameters(
                properties: [
                    "project_ids": ParameterProperty(
                        type: "string",
                        description: "Project IDs from list_projects. Accepts JSON array string, CSV string, or a single ID."
                    ),
                    "reason": ParameterProperty(
                        type: "string",
                        description: "Optional short reason shown in settings (e.g., 'Superseded by new project')."
                    )
                ],
                required: ["project_ids"]
            )
        )
    )
    
    // MARK: - Tool Arrays
    
    /// IMAP email tools (8 tools - used when email_mode is "imap")
    static var imapEmailTools: [ToolDefinition] {
        [readEmails, searchEmails, sendEmail, replyEmail, forwardEmail, getEmailThread, sendEmailWithAttachment, downloadEmailAttachment]
    }
    
    /// Gmail API tools (5 consolidated tools - used when email_mode is "gmail")
    static var gmailEmailTools: [ToolDefinition] {
        [gmailQuery, gmailSend, gmailThread, gmailForward, gmailAttachment]
    }
    
    /// Non-email tools that do not depend on web search credentials
    static var coreToolsWithoutWebSearch: [ToolDefinition] {
        [setReminder, listReminders, deleteReminder, viewCalendar, addCalendarEvent, editCalendarEvent, deleteCalendarEvent, viewConversationChunk, listDocuments, readDocument, findContact, addContact, listContacts, generateImage, downloadFromUrl, addToUserContext, removeFromUserContext, rewriteUserContext, sendDocumentToChat, generateDocument, listShortcuts, runShortcut, createProject, listProjects, browseProject, readProjectFile, addProjectFiles, runClaudeCode, sendProjectResult, flagProjectsForDeletion]
    }
    
    /// All available tools - dynamically selects email tools and optionally web search
    static func all(includeWebSearch: Bool) -> [ToolDefinition] {
        let emailMode = KeychainHelper.load(key: KeychainHelper.emailModeKey) ?? "imap"
        let emailTools = emailMode == "gmail" ? gmailEmailTools : imapEmailTools
        let disableLegacyDocumentGeneration =
            (KeychainHelper.load(key: KeychainHelper.claudeCodeDisableLegacyDocumentGenerationToolsKey) ?? "false")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "true"
        let webTools = includeWebSearch ? [webSearch, viewUrl, viewPageImage] : []
        var coreTools = webTools + coreToolsWithoutWebSearch
        
        if disableLegacyDocumentGeneration {
            coreTools.removeAll { $0.function.name == "generate_document" }
        }
        
        return coreTools + emailTools
    }
    
    /// Backward-compatible default: include web search
    static var all: [ToolDefinition] {
        all(includeWebSearch: true)
    }
}
