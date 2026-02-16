# Telegram Concierge

A native macOS AI assistant that lives inside a Telegram bot you control. It reads and sends emails, searches the web, generates images, manages your calendar, transcribes voice messages, runs macOS Shortcuts, delegates coding tasks to Claude Code, and remembers everything — powered by any LLM available through OpenRouter.

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2014+-blue" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-5.9-orange" alt="Swift 5.9">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="License">
</p>

---

## ✨ Features

### 🤖 AI Core
- **Any LLM** via [OpenRouter](https://openrouter.ai) — Gemini, Claude, GPT, Grok, and more
- **Configurable reasoning effort** — adjust thinking depth per model
- **Full tool-use (function calling)** — the LLM autonomously decides when and how to use over 30 tools
- **Multimodal** — understands images, PDFs, audio, and documents you send via Telegram

### 🧠 Persistent Memory (FractalMind)
- **Tiered chunking** — conversation history is automatically archived into chunks, summarized by the LLM, and consolidated over time
- **Crash-safe archival** — pending chunks survive app restarts
- **Semantic search** — the AI can search its own memory for past conversations
- **User context** — learns facts about you over time and persists them across sessions
- **Mind export/import** — full data portability: download or restore your entire assistant state as a `.mind` file

### 📧 Email
- **Gmail API** *(recommended)* — fast, efficient, thread-aware email with OAuth2
- **IMAP/SMTP** — alternative for non-Gmail setups
- **Full lifecycle** — read, search, compose, reply, forward, download attachments, send with attachments
- **Background monitoring** — the AI is aware of your latest inbox activity

### 📅 Calendar
- View, add, edit, and delete calendar events
- Calendar context is injected into every system prompt so the AI always knows your schedule
- Export/import calendar data independently

### 🌐 Web
- **Google search** via [Serper](https://serper.dev)
- **Web page reading** via [Jina](https://jina.ai)
- **Page image viewing** — the AI can selectively download and analyze images from web pages
- **File downloads** — download files from any URL

### 🖼️ Image Generation
- Powered by **Gemini** (`gemini-3-pro-image-preview`)
- Iterative improvement — the AI can see and refine its own generated images

### 🎙️ Voice Transcription
- On-device transcription using **WhisperKit** (`whisper-large-v3-turbo`)
- CoreML-optimized for Apple Silicon
- Send voice messages in Telegram and the AI receives the transcript

### 💻 Claude Code Integration
- Delegate coding tasks to [Claude Code](https://docs.anthropic.com/en/docs/claude-code/overview) CLI
- Project workspace management — create, browse, read, and add files to projects
- Run Claude Code with prompts and receive structured results
- Send generated files back via Telegram or email

### ⚡ macOS Shortcuts
- List and run any macOS Shortcut from Telegram
- Pass input and receive output programmatically

### 📇 Contacts
- Import contacts from `.vcf` (vCard) files
- Search, add, and list contacts
- Used by the AI when composing emails to find addresses

### ⏰ Reminders & Self-Orchestration
- Set reminders with natural language
- Recurring reminders (daily, weekly, monthly, yearly)
- **Self-orchestration** — the AI proactively sets reminders for itself to follow up on tasks

### 📄 Document Handling
- Read and analyze documents (PDF, DOCX, XLSX, CSV, TXT, and more)
- Generate documents (PDF, spreadsheet, text) and send them via Telegram or email
- Multimodal analysis of images sent as documents

---

## 🏗️ Architecture

```
┌──────────────────────────────────────────────────┐
│                  Telegram User                   │
│             (messages, voice, files)             │
└─────────────────────┬────────────────────────────┘
                      │
                      ▼
┌──────────────────────────────────────────────────┐
│              TelegramBotService                  │
│          (long-polling, message dispatch)         │
└─────────────────────┬────────────────────────────┘
                      │
                      ▼
┌──────────────────────────────────────────────────┐
│            ConversationManager                   │
│    (message history, agentic loop, archival)     │
├──────────────────────────────────────────────────┤
│  OpenRouterService    │  ConversationArchive     │
│  (LLM API + context   │  Service (FractalMind    │
│   window management)  │  memory & summarization) │
└───────────┬──────────┴───────────────────────────┘
            │
            ▼
┌──────────────────────────────────────────────────┐
│               ToolExecutor                       │
│        (parallel tool dispatch, 30+ tools)       │
├──────────────────────────────────────────────────┤
│ EmailService / GmailService                      │
│ CalendarService      │ ReminderService           │
│ WebOrchestrator      │ GeminiImageService        │
│ DocumentService      │ DocumentGeneratorService  │
│ ContactsService      │ WhisperKitService         │
│ MindExportService    │ Claude Code (subprocess)  │
│ macOS Shortcuts      │ User Context Management   │
└──────────────────────────────────────────────────┘
```

### Key Design Decisions

- **Agentic loop** — the LLM runs iteratively: it can call tools, observe results, then call more tools until it has a final answer
- **Parallel tool execution** — multiple independent tool calls are dispatched concurrently
- **Dynamic context window** — conversation is kept within token limits (~10k–20k) with automatic overflow archival
- **Keychain storage** — all API keys and secrets are stored in the macOS Keychain, never on disk
- **Sandbox-aware** — runs in the macOS app sandbox with network, audio input, and Apple Events entitlements

---

## 🛠️ Available Tools

<details>
<summary><strong>📧 Email (8 IMAP tools / 5 Gmail tools)</strong></summary>

| Tool | Description |
|------|-------------|
| `read_emails` / `gmail_query` | Fetch recent inbox or search by query, sender, date, folder |
| `search_emails` | Advanced search across all folders |
| `send_email` / `gmail_send` | Compose and send new emails |
| `reply_email` | Reply to a specific email in-thread |
| `forward_email` / `gmail_forward` | Forward emails with attachments |
| `get_email_thread` / `gmail_thread` | View full email conversation thread |
| `send_email_with_attachment` | Send email with documents from storage |
| `download_email_attachment` / `gmail_attachment` | Download email attachments for analysis |

</details>

<details>
<summary><strong>📅 Calendar (4 tools)</strong></summary>

| Tool | Description |
|------|-------------|
| `view_calendar` | View upcoming (and optionally past) events |
| `add_calendar_event` | Create a new event with title, datetime, duration, notes |
| `edit_calendar_event` | Modify an existing event |
| `delete_calendar_event` | Remove an event |

</details>

<details>
<summary><strong>🌐 Web (4 tools)</strong></summary>

| Tool | Description |
|------|-------------|
| `web_search` | Search the web via Google (Serper) |
| `view_url` | Read a web page's content and image metadata |
| `view_page_image` | Download and view a specific image from a web page |
| `download_from_url` | Download any file from a URL |

</details>

<details>
<summary><strong>📄 Documents (4 tools)</strong></summary>

| Tool | Description |
|------|-------------|
| `read_document` | Read/analyze any stored document (PDF, images, etc.) |
| `list_documents` | List stored documents by recent usage with pagination (`limit`, `cursor`) |
| `generate_document` | Generate PDF, spreadsheet, or text documents |
| `send_document_to_chat` | Send a document file to the Telegram chat |

</details>

<details>
<summary><strong>💻 Claude Code (6 tools)</strong></summary>

| Tool | Description |
|------|-------------|
| `create_project` | Create a new Claude Code project workspace |
| `list_projects` | List project workspaces by recent modification with pagination (`limit`, `cursor`) |
| `browse_project` | View project file tree |
| `read_project_file` | Read a file from a project |
| `add_project_files` | Copy local files into a project |
| `run_claude_code` | Execute Claude Code with a prompt in a project |
| `send_project_result` | Send project files via Telegram or email |

</details>

> [!TIP]
> To inspect Claude Code workspaces on disk, use the folder button in the main chat header (`ContentView`). It opens the projects folder directly in Finder, where you can also delete project folders manually.

<details>
<summary><strong>🧠 Memory & Context (4 tools)</strong></summary>

| Tool | Description |
|------|-------------|
| `view_conversation_chunk` | Browse archived conversation history |
| `add_to_user_context` | Save a learned fact about the user |
| `remove_from_user_context` | Remove outdated information |
| `rewrite_user_context` | Rewrite the full user context |

</details>

<details>
<summary><strong>⚡ System (5 tools)</strong></summary>

| Tool | Description |
|------|-------------|
| `set_reminder` | Schedule a one-time or recurring reminder |
| `list_reminders` | View pending reminders |
| `delete_reminder` | Cancel a reminder |
| `list_shortcuts` | List available macOS Shortcuts |
| `run_shortcut` | Run a macOS Shortcut with optional input |
| `generate_image` | Generate an image from a text prompt |
| `find_contact` | Search contacts by name or email |
| `add_contact` | Add a new contact |
| `list_contacts` | List all contacts |

</details>

---

## 📦 Project Structure

```
TelegramConcierge/
├── TelegramConciergeApp.swift      # App entry point
├── Models/
│   ├── Message.swift               # Conversation message model (multimodal)
│   ├── ToolModels.swift            # Tool definitions (OpenAI function calling format)
│   ├── TelegramModels.swift        # Telegram API response models
│   ├── DocumentModels.swift        # Document generation types
│   ├── ConversationArchiveModels.swift  # Memory chunk models
│   ├── CalendarEvent.swift         # Calendar event model
│   ├── Contact.swift               # Contact model
│   └── Reminder.swift              # Reminder model (with recurrence)
├── Services/
│   ├── ConversationManager.swift   # Central orchestrator: agentic loop, history, archival
│   ├── OpenRouterService.swift     # LLM API: context window, multimodal, tool calls
│   ├── TelegramBotService.swift    # Telegram bot long-polling and message dispatch
│   ├── ToolExecutor.swift          # Tool dispatcher (30+ tools, parallel execution)
│   ├── ConversationArchiveService.swift  # FractalMind memory: chunking, summarization
│   ├── EmailService.swift          # IMAP/SMTP email client
│   ├── GmailService.swift          # Gmail API client (OAuth2)
│   ├── WebOrchestrator.swift       # Multi-step web search + scraping
│   ├── GeminiImageService.swift    # Image generation (Gemini)
│   ├── WhisperKitService.swift     # On-device voice transcription
│   ├── CalendarService.swift       # Calendar CRUD
│   ├── ContactsService.swift       # Contact management
│   ├── ReminderService.swift       # Reminder scheduling
│   ├── DocumentService.swift       # Document storage
│   ├── DocumentGeneratorService.swift  # PDF/spreadsheet/text generation
│   ├── MindExportService.swift     # Full-state data portability
│   └── FileDescriptionService.swift    # AI-generated file descriptions
├── Views/
│   ├── ContentView.swift           # Main chat interface
│   ├── SettingsView.swift          # Configuration panel
│   ├── MessageBubbleView.swift     # Chat bubble with file previews
│   └── ContextViewerView.swift     # Debug: view full Gemini context
└── Utilities/
    └── KeychainHelper.swift        # Secure credential storage
```

---

## 🚀 Getting Started

### Prerequisites

| Requirement | Notes |
|---|---|
| **macOS 14 Sonoma** or later | Apple Silicon recommended for WhisperKit |
| **Xcode 15+** | To build and run the project |
| A **Telegram** account | For creating the bot |

### Quick Start

1. Clone the repository:
   ```bash
   git clone https://github.com/YOUR_USERNAME/telegram-concierge.git
   ```
2. Open `TelegramConcierge.xcodeproj` in Xcode.
3. Build and run (⌘R).
4. Open **Settings** (⌘,) and follow the [**Setup Guide**](SETUP.md) to configure your API keys.

> [!TIP]
> The full setup guide walks you through each section step by step — from creating your Telegram bot to configuring email, voice transcription, and Claude Code.

---

## 🔐 Security & Privacy

- **Keychain storage** — all API keys, tokens, and credentials are stored in the macOS Keychain. Nothing touches the file system.
- **Chat ID filter** — the bot only responds to your Telegram user ID, rejecting all other messages.
- **App Sandbox** — the app runs inside the macOS sandbox with only the required entitlements (network, audio input, Apple Events for Shortcuts).
- **Local processing** — voice transcription runs entirely on-device via WhisperKit. No audio leaves your Mac.
- **No telemetry** — the app does not collect or transmit any usage data.

---

## 🧠 How Memory Works

Telegram Concierge uses a tiered memory system inspired by how human memory works:

1. **Active context** (~10k–20k tokens) — the most recent conversation messages, sent directly to the LLM.
2. **Temporary chunks** (~10k tokens each) — when the active context overflows, the oldest messages are archived into a chunk and summarized by the LLM.
3. **Consolidated chunks** (~40k tokens each) — when 6 temporary chunks accumulate, the oldest 4 are merged into a larger consolidated chunk with a richer summary.
4. **User context** — persistent facts about you (preferences, relationships, details), learned automatically or via the `add_to_user_context` tool.
5. **Chunk summaries in system prompt** — summaries of recent chunks are always visible to the AI, so it knows what was discussed even if the raw messages are no longer in context.
6. **Deep search** — the AI can retrieve and read full archived chunks when it needs to recall specific details.

---

## 📋 Configuration Reference

All configuration is done in the app's Settings panel (⌘,). See [SETUP.md](SETUP.md) for detailed instructions.

| Section | Required? | What it does |
|---|---|---|
| **Persona** | ✅ | Name your AI, tell it about yourself |
| **Telegram Bot** | ✅ | Bot token + your Chat ID |
| **OpenRouter** | ✅ | LLM API key, model selection, reasoning effort |
| **Web Search** | Optional | Serper + Jina keys for web browsing |
| **Image Generation** | Optional | Gemini API key for image generation |
| **Claude Code** | Optional | CLI command + args for Claude Code integration |
| **Email** | Optional | Gmail API (recommended) or IMAP/SMTP |
| **Voice Transcription** | Optional | Download + compile WhisperKit model |

---

## 📄 License

This project is open source and available under the [MIT License](LICENSE).

---

## 🙏 Acknowledgments

- [OpenRouter](https://openrouter.ai) — unified LLM API gateway
- [WhisperKit](https://github.com/argmaxinc/WhisperKit) — on-device speech recognition
- [Serper](https://serper.dev) — Google Search API
- [Jina AI](https://jina.ai) — web content extraction
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code/overview) — agentic coding CLI by Anthropic
