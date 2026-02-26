# Telegram Concierge — Setup Guide

> **Telegram Concierge** is a native macOS AI assistant that lives inside a Telegram bot you own.
> It can read and send emails, search the web, generate images, manage your calendar, transcribe voice messages, and more — all orchestrated by a large-language model you control.

---

## Prerequisites

| Requirement | Notes |
|---|---|
| **macOS 14 Sonoma** or later | Apple Silicon recommended for WhisperKit |
| **Xcode 15+** | To build and run the project |
| A **Telegram** account | Used on your phone to create the bot |

---

## 1 — Persona

Open the app. The very first section is **Persona** — this tells the AI who it is and who you are.

| Field | What to enter |
|---|---|
| **Assistant Name** | The name your AI will use for itself (e.g. *Jarvis*, *Friday*). |
| **Your Name** | Your name, so the assistant addresses you correctly. |
| **About You** | Free-text background about yourself. The more you write, the better the assistant understands your world. |

**Tips for "About You":**

- Your age, location, occupation.
- Names of family members, close friends, colleagues — this helps the AI reference people correctly when handling your emails.
- If the assistant controls a separate email address (not your personal one), explain that here. For example: *"You have your own email address (assistant@example.com). My personal email is me@example.com. When you send emails, always make it clear you are writing on my behalf."*
- Communication style preferences, languages you speak, etc.

> [!TIP]
> Don't press **"Process & Save"** yet — it needs a working OpenRouter API key (configured in Step 3).

---

## 2 — Telegram Bot

You need to create a Telegram bot and link it to the app.

### 2a — Create the bot

1. Open **Telegram** on your phone.
2. Search for **@BotFather** and start a chat.
3. Send `/start`, then `/newbot`.
4. Choose a **display name** (what you'll see in Telegram, e.g. *My Concierge*).
5. Choose a **username** (must end in `bot`, e.g. `my_concierge_bot`).
6. BotFather will reply with an **API token** — a long string like `123456789:ABCdef...`. Copy it.

### 2b — Enter the token

Back in the app, paste the token into the **Bot Token** field and click **Test**. You should see a green checkmark with your bot's username.

### 2c — Get your Chat ID

The app needs your **Telegram user ID** (a numeric Chat ID) so it only responds to you.

1. Open Telegram and search for **@userinfobot**.
2. Send it `/start` — it will reply with your numeric user ID.
3. Paste that number into the **Chat ID** field in the app.

> [!IMPORTANT]
> The Chat ID is a safety measure — without it anyone who finds your bot could talk to it.

---

## 3 — OpenRouter (LLM)

The AI brain runs through [OpenRouter](https://openrouter.ai), a unified API gateway for many language models.

1. Go to [openrouter.ai](https://openrouter.ai) and create an account.
2. Add credit (even $5–10 is enough to start; Gemini models are very inexpensive).
3. Go to **Keys** → **Create Key** → copy the key.
4. Paste it into the **API Key** field.

| Field | Default | Notes |
|---|---|---|
| **Model** | `google/gemini-3-flash-preview` | Leave empty to use the default. |
| **Preferred Providers** | *(all)* | Leave empty to allow all. |
| **Reasoning Effort** | *High* | Leave to **High** if using the default Gemini 3 Flash model — good balance of quality and cost. |

---

## 4 — Web Search

These two APIs let the assistant search the web and read web pages.

| Service | Purpose | How to get a key |
|---|---|---|
| [serper.dev](https://serper.dev) | Google search results | Create a free account → Dashboard → API Key. The free tier includes 2,500 searches. |
| [jina.ai](https://jina.ai) | Web page scraping / reading | Create a free account → get an API key from the dashboard. |

Both are **optional** but strongly recommended — without them the assistant cannot browse the web.

---

## 5 — Image Generation *(optional)*

If you want the assistant to generate and edit images:

1. Go to [Google AI Studio](https://aistudio.google.com/apikey).
2. Create an API key (or use an existing one).
3. Paste it into the **Gemini API Key** field.

The app uses `gemini-3-pro-image-preview` for generation. The assistant can see its own generated images and iteratively improve them.

---

## 6 — Code CLI *(optional)*

If you want the assistant to delegate coding tasks, configure one of the supported providers in Settings:
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code/overview)
- Gemini CLI
- [Codex CLI](https://developers.openai.com/codex/cli)

### 6a — Install the CLI you want to use

| Provider | Install command |
|---|---|
| **Claude Code** | `curl -fsSL https://claude.ai/install.sh \| bash` |
| **Codex CLI** | `npm i -g @openai/codex` |

Then verify the installed binary in Terminal (for example: `claude --version` or `codex --version`).

### 6b — Authenticate in Terminal

Complete the provider's first-run login flow in Terminal before using it from Telegram Concierge.

### 6c — Configure in the app

In Telegram Concierge, open **Settings → Code CLI** and pick a provider.

| Provider | Default command | Default args | Notes |
|---|---|---|---|
| **Claude Code** | `claude` | `-p --permission-mode bypassPermissions` | Uses Claude's print mode for headless runs. |
| **Gemini CLI** | `gemini` | `--yolo --output-format json` | Optional model override is supported in Settings. |
| **Codex CLI** | `codex` | `exec --sandbox workspace-write --skip-git-repo-check` | Uses non-interactive `codex exec` defaults suitable for project tool runs. |

All providers support timeout configuration (30–3600 seconds), and you can override CLI args per `run_claude_code` call.

### 6d — Remote provider switch from Telegram

You can switch provider remotely by sending one of these commands in Telegram:

- `/claude` → use Claude Code
- `/gemini` → use Gemini CLI
- `/codex` → use Codex CLI
- `/transcribe_local` → use local Whisper transcription
- `/transcribe_openai` → use OpenAI transcription (`gpt-4o-transcribe`)
- `/spend` → show OpenRouter spend totals (today and this month)

The change is saved immediately and applies to the next delegated Code CLI run.

> [!TIP]
> To view project working directories, click the **folder icon** in the main chat header (next to the Settings gear). This opens the projects folder directly in Finder, where you can delete project folders manually when needed.

---

## 7 — Email (Gmail API) ⭐ Recommended

The Gmail API is the **recommended** way to give the assistant email access. It is significantly faster than IMAP and requires fewer tool calls for the AI.

### 7a — Decide which account to use

You have two options:

| Option | Pros | Cons |
|---|---|---|
| **Dedicated assistant email** | Your personal inbox stays untouched; the assistant has its own address | You need to create a new Google account |
| **Your personal email** | No extra account needed | The assistant has full read/send access to your inbox |

> [!NOTE]
> For security, using a **dedicated email address** for the assistant is recommended. You can always tell the AI about your personal address in the Persona section so it knows how to reference you.

### 7b — Create a Google Cloud project

1. Sign in to [Google Cloud Console](https://console.cloud.google.com/) with the Google account whose email the assistant will use.
2. Click the project dropdown at the top of the page → **New Project**.
3. Give it a name (e.g. *Telegram Concierge*) and click **Create**.
4. Make sure your new project is selected in the dropdown.

### 7c — Enable the Gmail API

1. In the Google Cloud Console, go to **APIs & Services → Library** (or search for "Gmail API" in the top search bar).
2. Click **Gmail API** → **Enable**.

### 7d — Configure the OAuth Consent Screen

Before you can create credentials, Google requires an OAuth consent screen:

1. Go to **APIs & Services → OAuth consent screen**.
2. Select **External** as user type → **Create**.
3. Fill in the required fields:
   - **App name**: anything (e.g. *Telegram Concierge*)
   - **User support email**: your email
   - **Developer contact email**: your email
4. Click **Save and Continue**.
5. On the **Scopes** page, just click **Save and Continue** — the app requests the necessary scopes automatically during authentication.
6. On the **Test users** page, click **Add Users** and add the email address the assistant will use. Click **Save and Continue**.

> [!WARNING]
> While the app is in "Testing" mode, **only the test users you add** can authenticate. This is fine for personal use — you don't need to publish the app.

### 7e — Create OAuth Credentials

1. Go to **APIs & Services → Credentials**.
2. Click **+ Create Credentials → OAuth client ID**.
3. Set **Application type** to **Desktop app**.
4. Give it a name (e.g. *Telegram Concierge Desktop*).
5. Click **Create**.
6. A dialog will show your **Client ID** and **Client Secret**. Copy both.

### 7f — Enter credentials and authenticate

1. Back in the Telegram Concierge app, make sure the Email section shows **Gmail API** (the default). If it shows "IMAP/SMTP", click the small *"Use Gmail API"* link.
2. Paste your **Client ID** and **Client Secret**.
3. Click **"Authenticate with Google"**.
4. Your browser will open a Google sign-in page. Sign in with the account whose email the assistant will use.
5. You will see a warning that the app is not verified — click **Advanced → Go to [app name] (unsafe)**. This is normal for personal OAuth apps.
6. Grant the requested permissions.
7. The browser will show **"✓ Authentication Successful!"** — you can close the tab.
8. Back in the app, you should see a green **"Authenticated ✓"** status.

> [!TIP]
> The app runs a temporary local server on `localhost:8080` to capture the OAuth callback. Make sure nothing else is using that port when you authenticate.

### Alternative: IMAP/SMTP

If you prefer not to use the Gmail API, click *"Use IMAP instead"* in the Email section. You'll need to set up an [App Password](https://myaccount.google.com/apppasswords) for Gmail (requires 2-Step Verification enabled). Note that IMAP is noticeably slower for email operations.

---

## 8 — Voice Transcription (Whisper)

This lets the assistant transcribe voice messages you send via Telegram.

1. In the **Voice Transcription** section, click **Download**. This downloads the `whisper-large-v3-turbo` model (~632 MB).
2. Once downloaded, click **Compile**. This converts the model into CoreML format optimized for your Mac.

> [!IMPORTANT]
> Compilation takes **3–5 minutes** on Apple Silicon. Let it finish — the status will change to **"Model ready"** when done.

The model only needs to be downloaded and compiled once. If you update the app, it may need to recompile automatically on first launch.

---

## 9 — Structure Your Persona *(optional but recommended)*

Now that OpenRouter is configured, go back to the **Persona** section:

1. Click **"Process & Save"** — this reformats your free-text "About You" into a structured format the AI can use more effectively.
2. Expand "Structured Context" to review what the AI generated. Edit the "About You" text and re-structure if needed.

---

## 10 — Save & Start

Click **"Save & Start Bot"** at the bottom. The app will:

- Save all settings to the macOS Keychain (API keys never touch the filesystem)
- Configure and start the Telegram bot
- Begin polling for messages and monitoring your email inbox

**Open Telegram, find your bot, and send it a message.** You're done! 🎉

---

## Optional: Contacts

In the **Data** section at the bottom of Settings, you can import a `.vcf` (vCard) contact file. This gives the AI a directory of names and emails it can use when composing messages.

Export contacts from Apple Contacts, Google Contacts, or any other source as a `.vcf` file, then click **Import vCard**.

---

## Troubleshooting

| Issue | Solution |
|---|---|
| Bot doesn't respond | Check that both **Bot Token** and **Chat ID** are filled in and tested. Make sure the bot is started (`/start` in your chat with the bot). |
| Gmail auth fails | Ensure you added yourself as a test user in the OAuth consent screen. Make sure port `8080` is free. |
| *"This app isn't verified"* warning | Expected for personal OAuth apps. Click **Advanced → Go to [app name]**. |
| Whisper compilation hangs | Wait at least 5 minutes. On Intel Macs it may take longer. Restart the app if it truly stalls. |
| OpenRouter errors | Verify you have credit on openrouter.ai and the API key is correct. |
| Email operations are slow | Switch from IMAP to Gmail API for significantly faster performance. |
