import Foundation

// MARK: - OpenRouter Configuration for Web Search Pipeline
enum ORModel {
    static let agent      = "openai/gpt-oss-120b"
    static let excerpts   = "openai/gpt-oss-20b"
    static let finalAns   = "openai/gpt-oss-120b"
}

enum Endpoints {
    static let openrouter     = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    static let serperSearch   = URL(string: "https://google.serper.dev/search")!
    static let jinaReaderBase = "https://r.jina.ai/"
}

struct ProviderSettings {
    static let only = ["groq", "google-vertex"]
    static let order: [String]? = nil
    static let allowFallbacks = true
}

// MARK: - Reasoning Configuration
enum ReasoningEffort {
    case off
    case low, medium, high
    case budgetTokens(Int)
}

struct ReasoningSettings {
    static var agent:    ReasoningEffort = .medium
    static var excerpts: ReasoningEffort = .medium
    static var finalAns: ReasoningEffort = .medium
}

func makeReasoning(_ r: ReasoningEffort) -> ORChatReq.Reasoning? {
    switch r {
    case .off: return nil
    case .low:    return .init(effort: "low",    max_tokens: nil, exclude: true)
    case .medium: return .init(effort: "medium", max_tokens: nil, exclude: true)
    case .high:   return .init(effort: "high",   max_tokens: nil, exclude: true)
    case .budgetTokens(let n): return .init(effort: nil, max_tokens: n, exclude: true)
    }
}

// MARK: - OpenRouter Types for Pipeline
struct ORChatReq: Encodable {
    struct Msg: Encodable { let role: String; let content: String }
    struct Reasoning: Encodable {
        let effort: String?
        let max_tokens: Int?
        let exclude: Bool?
    }
    struct Provider: Encodable {
        let order: [String]?
        let only: [String]?
        let allow_fallbacks: Bool?
        let sort: String?
    }
    let model: String
    let messages: [Msg]
    let max_tokens: Int?
    let temperature: Double?
    let stream: Bool?
    let reasoning: Reasoning?
    let provider: Provider?
}

struct ORChatResp: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let role: String; let content: String }
        let message: Message
    }
    let choices: [Choice]
}

// MARK: - Agent Types
struct AgentToolCall: Codable {
    let tool: String
    let arguments: AgentToolArguments
}

struct AgentToolArguments: Codable {
    let queries: [String]?
    let scrape_requests: [ScrapeRequest]?
}

struct ScrapeRequest: Codable {
    let url: String
    let focus: String
}

struct AgentResponse: Codable {
    let thinking: String?
    let tool_calls: [AgentToolCall]?
    let ready_for_answer: Bool
}

struct ScratchpadEntry: Codable {
    let step: Int
    let thinking: String
    let actions_taken: [String]
}

// MARK: - Serper Types
struct SerperSearchReq: Encodable { let q: String; let num: Int; let autocorrect: Bool = true }
struct SerperSearchResp: Decodable {
    struct Organic: Decodable { let title: String?; let link: String?; let snippet: String?; let date: String? }
    struct PAA: Decodable { let question: String?; let snippet: String?; let title: String?; let link: String? }
    struct Top: Decodable { let title: String?; let link: String?; let source: String?; let date: String? }
    struct AnswerBox: Decodable { let answer: String?; let snippet: String?; let title: String?; let link: String?; let type: String? }
    struct KG: Decodable { let title: String?; let type: String?; let description: String?; let source: String?; let url: String? }
    let organic: [Organic]?
    let peopleAlsoAsk: [PAA]?
    let topStories: [Top]?
    let answerBox: AnswerBox?
    let knowledgeGraph: KG?
}

struct ExcerptOut: Decodable { let excerpts: [String] }

struct RelevantAssetOut: Decodable {
    struct Link: Decodable {
        let text: String?
        let url: String?
    }

    struct Image: Decodable {
        let caption: String?
        let url: String?
    }

    let links: [Link]?
    let images: [Image]?
}

// MARK: - Web Context Types
struct WebContext: Codable {
    var queries_used: [QueryRecord]
    var results: [WebResult]
    var answerBox: WebAnswerBox?
    var knowledgeGraph: WebKG?
    var peopleAlsoAsk: [WebPAA]?
    var topStories: [WebTop]?
    var scraped: [ScrapedDoc]
    
    static func empty() -> WebContext {
        WebContext(queries_used: [], results: [], answerBox: nil, knowledgeGraph: nil, peopleAlsoAsk: nil, topStories: nil, scraped: [])
    }
    
    func clamped(to maxBytes: Int) -> WebContext {
        var t = self
        func size(_ x: WebContext) -> Int { (try? JSONEncoder().encode(x).count) ?? .max }
        if size(t) <= maxBytes { return t }
        if t.results.count > 8 { t.results = Array(t.results.prefix(8)) }
        if size(t) <= maxBytes { return t }
        t.peopleAlsoAsk = nil; t.topStories = nil
        if size(t) <= maxBytes { return t }
        t.results = Array(t.results.prefix(5))
        return t
    }
    
    mutating func merge(with other: WebContext, maxBytes: Int) {
        let have = Set(self.results.map { $0.link })
        let add = other.results.filter { !have.contains($0.link) }
        self.results.append(contentsOf: add.prefix(40 - self.results.count))
        self.queries_used.append(contentsOf: other.queries_used)
        if self.answerBox == nil { self.answerBox = other.answerBox }
        if self.knowledgeGraph == nil { self.knowledgeGraph = other.knowledgeGraph }
        var paa = (self.peopleAlsoAsk ?? []) + (other.peopleAlsoAsk ?? [])
        if paa.count > 8 { paa = Array(paa.prefix(8)) }
        self.peopleAlsoAsk = paa.isEmpty ? nil : paa
        var ts = (self.topStories ?? []) + (other.topStories ?? [])
        if ts.count > 8 { ts = Array(ts.prefix(8)) }
        self.topStories = ts.isEmpty ? nil : ts
        self = self.clamped(to: maxBytes)
    }
}

struct QueryRecord: Codable { let query: String; let retrievedAtStep: Int }
struct WebResult: Codable { let title: String; let snippet: String; let link: String; let source: String; let date: String?; let retrievedAtStep: Int }
struct WebAnswerBox: Codable { let answer: String?; let snippet: String?; let title: String?; let link: String?; let type: String?
    init(_ x: SerperSearchResp.AnswerBox) { answer = x.answer; snippet = x.snippet; title = x.title; link = x.link; type = x.type }
}
struct WebKG: Codable { let title: String?; let type: String?; let description: String?; let source: String?; let url: String?
    init(_ x: SerperSearchResp.KG) { title = x.title; type = x.type; description = x.description; source = x.source; url = x.url }
}
struct WebPAA: Codable { let question: String?; let snippet: String?; let title: String?; let link: String?
    init(_ x: SerperSearchResp.PAA) { question = x.question; snippet = x.snippet; title = x.title; link = x.link }
}
struct WebTop: Codable { let title: String?; let link: String?; let source: String?; let date: String?
    init(_ x: SerperSearchResp.Top) { title = x.title; link = x.link; source = x.source; date = x.date }
}
struct ScrapedDoc: Codable {
    let url: String
    let source: String
    let title: String?
    let excerpts: [String]
    let links: [ExtractedLink]
    let images: [ExtractedImage]
    let retrievedAtStep: Int

    enum CodingKeys: String, CodingKey {
        case url, source, title, excerpts, links, images, retrievedAtStep
    }

    init(
        url: String,
        source: String,
        title: String?,
        excerpts: [String],
        links: [ExtractedLink] = [],
        images: [ExtractedImage] = [],
        retrievedAtStep: Int
    ) {
        self.url = url
        self.source = source
        self.title = title
        self.excerpts = excerpts
        self.links = links
        self.images = images
        self.retrievedAtStep = retrievedAtStep
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.url = try container.decode(String.self, forKey: .url)
        self.source = try container.decode(String.self, forKey: .source)
        self.title = try container.decodeIfPresent(String.self, forKey: .title)
        self.excerpts = try container.decodeIfPresent([String].self, forKey: .excerpts) ?? []
        self.links = try container.decodeIfPresent([ExtractedLink].self, forKey: .links) ?? []
        self.images = try container.decodeIfPresent([ExtractedImage].self, forKey: .images) ?? []
        self.retrievedAtStep = try container.decode(Int.self, forKey: .retrievedAtStep)
    }
}

// MARK: - URL Reading Types (for view_url tool)

struct JinaReaderResult: Codable {
    let url: String
    let title: String?
    let content: String
    let links: [ExtractedLink]
    let images: [ExtractedImage]
    
    /// Downloaded image data for multimodal injection (not serialized to JSON)
    var downloadedImages: [DownloadedImage]
    
    enum CodingKeys: String, CodingKey {
        case url, title, content, links, images
        // downloadedImages is not serialized
    }
    
    init(url: String, title: String?, content: String, links: [ExtractedLink], images: [ExtractedImage], downloadedImages: [DownloadedImage] = []) {
        self.url = url
        self.title = title
        self.content = content
        self.links = links
        self.images = images
        self.downloadedImages = downloadedImages
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.url = try container.decode(String.self, forKey: .url)
        self.title = try container.decodeIfPresent(String.self, forKey: .title)
        self.content = try container.decode(String.self, forKey: .content)
        self.links = try container.decode([ExtractedLink].self, forKey: .links)
        self.images = try container.decode([ExtractedImage].self, forKey: .images)
        self.downloadedImages = [] // Not decoded from JSON
    }
    
    func asJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(self),
              let json = String(data: data, encoding: .utf8) else {
            return "{\"url\": \"\(url)\", \"error\": \"Failed to encode result\"}"
        }
        return json
    }
}

struct ExtractedLink: Codable {
    let text: String
    let url: String
}

struct ExtractedImage: Codable {
    let caption: String
    let url: String?
}

/// Downloaded image data for multimodal injection
struct DownloadedImage {
    let data: Data
    let mimeType: String
    let caption: String
    let sourceUrl: String
}

// MARK: - Web Orchestrator
final class WebOrchestrator {
    enum ProgressStage: String {
        case planning   = "Planning..."
        case searching  = "Searching..."
        case scraping   = "Scraping..."
        case analyzing  = "Analyzing..."
        case answering  = "Generating Answer..."
    }
    
    var onProgress: ((ProgressStage) -> Void)?
    
    private var openRouterApiKey: String = ""
    private var serperApiKey: String = ""
    private var jinaApiKey: String = ""
    
    private let maxSteps = 5
    private let perQueryDepth = 10
    private let maxContextBytes = 300_000
    private let excerptThreshold = 8_000
    private let chunkSizeChars = 400_000
    private let maxChunksForExtraction = 5
    private let chunkOverlapChars = 4_000
    
    // Track queries used for result
    private var lastQueriesUsed: [String] = []
    
    // MARK: - Configuration
    
    func configure(openRouterKey: String, serperKey: String, jinaKey: String) {
        self.openRouterApiKey = openRouterKey
        self.serperApiKey = serperKey
        self.jinaApiKey = jinaKey
    }
    
    // MARK: - Tool Interface
    
    /// Execute web search as a tool and return a condensed result for the main LLM
    func executeForTool(query: String) async throws -> WebSearchResult {
        lastQueriesUsed = []
        let answer = try await answer(userPrompt: query, historyPairs: [])
        
        // Extract source URLs from the answer (URLs wrapped in angle brackets)
        let sources = extractSourceURLs(from: answer)
        
        return WebSearchResult(
            summary: answer,
            sources: sources,
            searchQueriesUsed: lastQueriesUsed
        )
    }
    
    private func extractSourceURLs(from text: String) -> [String] {
        // Match URLs in angle brackets like <https://example.com>
        let pattern = "<(https?://[^>]+)>"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: range)
        
        return matches.compactMap { match in
            guard let urlRange = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[urlRange])
        }
    }
    
    // MARK: - Main Entry Point
    func answer(userPrompt: String, historyPairs: [(user: String, assistant: String)]) async throws -> String {
        let conversationContext = buildConversationContext(historyPairs: historyPairs, currentQuestion: userPrompt)
        
        var webContext = WebContext.empty()
        var scratchpadEntries: [ScratchpadEntry] = []
        var step = 0
        
        while step < maxSteps {
            step += 1
            try Task.checkCancellation()
            
            onProgress?(step == 1 ? .planning : .analyzing)
            
            let agentResponse = try await callAgent(
                conversationContext: conversationContext,
                webContext: webContext,
                scratchpadEntries: scratchpadEntries,
                currentStep: step,
                maxSteps: maxSteps
            )
            
            var actionsTaken: [String] = []
            
            if let toolCalls = agentResponse.tool_calls, !toolCalls.isEmpty {
                for call in toolCalls {
                    try Task.checkCancellation()
                    
                    switch call.tool.lowercased() {
                    case "search":
                        if let queries = call.arguments.queries, !queries.isEmpty {
                            onProgress?(.searching)
                            let queriesToRun = Array(queries.prefix(4))
                            lastQueriesUsed.append(contentsOf: queriesToRun)
                            let searchResults = try await executeSearch(queries: queriesToRun, atStep: step)
                            webContext.merge(with: searchResults, maxBytes: maxContextBytes)
                            actionsTaken.append("search(\(queriesToRun.joined(separator: ", ")))")
                        }
                        
                    case "scrape":
                        if let requests = call.arguments.scrape_requests, !requests.isEmpty {
                            onProgress?(.scraping)
                            let requestsToRun = Array(requests.prefix(3))
                            let scrapedDocs = try await executeScrape(requests: requestsToRun, atStep: step)
                            webContext.scraped.append(contentsOf: scrapedDocs)
                            let urls = requestsToRun.map { $0.url }
                            actionsTaken.append("scrape(\(urls.joined(separator: ", ")))")
                        }
                        
                    default:
                        actionsTaken.append("unknown_tool(\(call.tool))")
                    }
                }
            }
            
            if let newThinking = agentResponse.thinking, !newThinking.isEmpty {
                scratchpadEntries.append(ScratchpadEntry(step: step, thinking: newThinking, actions_taken: actionsTaken))
            } else if !actionsTaken.isEmpty {
                scratchpadEntries.append(ScratchpadEntry(step: step, thinking: "(No explicit thinking)", actions_taken: actionsTaken))
            }
            
            if agentResponse.ready_for_answer { break }
            if agentResponse.tool_calls?.isEmpty ?? true { break }
        }
        
        onProgress?(.answering)
        let contextJSON = try String(data: JSONEncoder().encode(webContext.clamped(to: maxContextBytes)), encoding: .utf8) ?? "{}"
        let fullScratchpad = formatScratchpadForFinalAnswer(scratchpadEntries)
        
        return try await generateFinalAnswer(
            currentQuestion: userPrompt,
            webContextJSON: contextJSON,
            scratchpad: fullScratchpad,
            historyPairs: historyPairs
        )
    }
    
    // MARK: - Helpers
    private func formatScratchpadForFinalAnswer(_ entries: [ScratchpadEntry]) -> String {
        guard !entries.isEmpty else { return "" }
        var output = "=== RESEARCH JOURNEY ===\n\n"
        for entry in entries {
            output += "--- Step \(entry.step) ---\nThinking: \(entry.thinking)\n"
            if !entry.actions_taken.isEmpty { output += "Actions: \(entry.actions_taken.joined(separator: "; "))\n" }
            output += "\n"
        }
        return output
    }
    
    private func buildAgentSystemPrompt(currentStep: Int, maxSteps: Int) -> String {
        """
        **Today is: \(nowStamp())**
        
        You are a research agent with access to tools. You have \(maxSteps - currentStep + 1) steps remaining (current step: \(currentStep)/\(maxSteps)).
        
        ## AVAILABLE TOOLS
        
        ### 1. search
        Execute web searches. Provide up to 4 queries.
        Arguments: { "queries": ["query1", "query2", ...] }
        
        ### 2. scrape
        Fetch and extract relevant content from URLs. Provide up to 3 URLs with focus queries.
        Arguments: { "scrape_requests": [{"url": "...", "focus": "what to look for"}, ...] }
        
        ## RESPONSE FORMAT
        
        Respond with STRICT JSON ONLY:
        {
          "thinking": "<Your thinking for THIS STEP ONLY - will be APPENDED to history>",
          "tool_calls": [{ "tool": "search" | "scrape", "arguments": { ... } }],
          "ready_for_answer": true | false
        }
        
        ## STRATEGY
        1. Step 1: Analyze question, plan search strategy, execute first searches
        2. Subsequent steps: Note new info, identify gaps, adjust plan, execute actions
        3. Set ready_for_answer = true when you have enough info
        """
    }
    
    private func formatScratchpadHistory(_ entries: [ScratchpadEntry]) -> String {
        guard !entries.isEmpty else { return "(No previous thinking - this is step 1)" }
        var output = ""
        for entry in entries {
            output += "=== STEP \(entry.step) ===\nThinking: \(entry.thinking)\n"
            if !entry.actions_taken.isEmpty { output += "Actions: \(entry.actions_taken.joined(separator: "; "))\n" }
            output += "\n"
        }
        return output
    }
    
    private func buildConversationContext(historyPairs: [(user: String, assistant: String)], currentQuestion: String) -> String {
        var context = ""
        if !historyPairs.isEmpty {
            context += "### Previous Conversation\n\n"
            for (i, pair) in historyPairs.enumerated() {
                context += "User (\(i + 1)): \(pair.user)\nAssistant (\(i + 1)): \(pair.assistant)\n\n"
            }
        }
        context += "### Current Question\n\n\(currentQuestion)"
        return context
    }
    
    // MARK: - Agent Call
    private func callAgent(conversationContext: String, webContext: WebContext, scratchpadEntries: [ScratchpadEntry], currentStep: Int, maxSteps: Int) async throws -> AgentResponse {
        let systemPrompt = buildAgentSystemPrompt(currentStep: currentStep, maxSteps: maxSteps)
        
        var userContent = "## USER QUESTION & CONVERSATION\n\n\(conversationContext)\n\n"
        userContent += "## SCRATCHPAD_HISTORY\n\n\(formatScratchpadHistory(scratchpadEntries))\n"
        
        if !webContext.results.isEmpty || !webContext.scraped.isEmpty {
            let contextJSON = (try? String(data: JSONEncoder().encode(webContext.clamped(to: maxContextBytes)), encoding: .utf8)) ?? "{}"
            userContent += "## CURRENT WEB CONTEXT\n\n\(contextJSON)\n\n"
        }
        
        userContent += "## YOUR TASK\n\nAnalyze the current state and decide your next action."
        
        let messages: [ORChatReq.Msg] = [
            .init(role: "system", content: systemPrompt),
            .init(role: "user", content: userContent)
        ]
        
        let raw = try await callOpenRouter(
            model: ORModel.agent,
            messages: messages,
            maxTokens: 16000,
            reasoning: makeReasoning(ReasoningSettings.agent)
        )
        
        guard let data = extractFirstJSONObjectData(from: raw),
              let response = try? JSONDecoder().decode(AgentResponse.self, from: data) else {
            return AgentResponse(thinking: "Failed to parse agent response", tool_calls: nil, ready_for_answer: true)
        }
        
        return response
    }
    
    // MARK: - Tool Execution
    private func executeSearch(queries: [String], atStep: Int) async throws -> WebContext {
        var seen = Set<String>()
        var results: [WebResult] = []
        var queryRecords: [QueryRecord] = []
        var firstAB: SerperSearchResp.AnswerBox?
        var firstKG: SerperSearchResp.KG?
        var paa: [SerperSearchResp.PAA] = []
        var top: [SerperSearchResp.Top] = []
        
        try await withThrowingTaskGroup(of: (String, SerperSearchResp).self) { group in
            for q in queries {
                group.addTask { (q, try await self.serperSearch(q)) }
            }
            for try await (query, r) in group {
                queryRecords.append(QueryRecord(query: query, retrievedAtStep: atStep))
                if firstAB == nil { firstAB = r.answerBox }
                if firstKG == nil { firstKG = r.knowledgeGraph }
                if let p = r.peopleAlsoAsk { paa.append(contentsOf: p.prefix(6)) }
                if let t = r.topStories { top.append(contentsOf: t.prefix(6)) }
                if let org = r.organic {
                    for item in org.prefix(perQueryDepth) {
                        guard let link = item.link, let title = item.title else { continue }
                        let key = normalize(link)
                        if seen.contains(key) { continue }
                        seen.insert(key)
                        results.append(WebResult(title: title, snippet: (item.snippet ?? "").prefixing(460), link: link, source: URL(string: link)?.host?.lowercased() ?? "", date: item.date, retrievedAtStep: atStep))
                    }
                }
            }
        }
        
        return WebContext(queries_used: queryRecords, results: results, answerBox: firstAB.map(WebAnswerBox.init), knowledgeGraph: firstKG.map(WebKG.init), peopleAlsoAsk: paa.map(WebPAA.init), topStories: top.map(WebTop.init), scraped: []).clamped(to: maxContextBytes)
    }
    
    private func executeScrape(requests: [ScrapeRequest], atStep: Int) async throws -> [ScrapedDoc] {
        await withTaskGroup(of: ScrapedDoc?.self) { group in
            for req in requests {
                group.addTask {
                    do {
                        try Task.checkCancellation()
                        return try await self.scrapeAndExtract(url: req.url, focus: req.focus, atStep: atStep)
                    } catch { return nil }
                }
            }
            var docs: [ScrapedDoc] = []
            for await maybeDoc in group { if let doc = maybeDoc { docs.append(doc) } }
            return docs
        }
    }
    
    // MARK: - API Calls
    private func callOpenRouter(
        model: String,
        messages: [ORChatReq.Msg],
        maxTokens: Int,
        reasoning: ORChatReq.Reasoning? = nil
    ) async throws -> String {
        let body = ORChatReq(
            model: model,
            messages: messages,
            max_tokens: maxTokens,
            temperature: 0.7,
            stream: false,
            reasoning: reasoning,
            provider: .init(
                order: ProviderSettings.order,
                only: ProviderSettings.only,
                allow_fallbacks: ProviderSettings.allowFallbacks,
                sort: nil
            )
        )
        let data = try await httpJSONPost(url: Endpoints.openrouter, body: body, headers: ["Authorization": "Bearer \(openRouterApiKey)"], timeout: 120)
        let resp = try JSONDecoder().decode(ORChatResp.self, from: data)
        return resp.choices.first?.message.content ?? ""
    }
    
    private func serperSearch(_ q: String) async throws -> SerperSearchResp {
        let req = SerperSearchReq(q: q, num: perQueryDepth)
        let data = try await httpJSONPost(url: Endpoints.serperSearch, body: req, headers: ["X-API-KEY": serperApiKey], timeout: 60)
        return try JSONDecoder().decode(SerperSearchResp.self, from: data)
    }
    
    private func fetchWithJinaReader(originalURL: String, includeImageCaptions: Bool = false) async throws -> (title: String?, content: String) {
        let target = (originalURL.hasPrefix("http://") || originalURL.hasPrefix("https://")) ? originalURL : "https://\(originalURL)"
        guard let proxyURL = URL(string: Endpoints.jinaReaderBase + target) else { throw URLError(.badURL) }
        var req = URLRequest(url: proxyURL)
        req.httpMethod = "GET"
        req.timeoutInterval = 120
        if !jinaApiKey.isEmpty {
            req.setValue("Bearer \(jinaApiKey)", forHTTPHeaderField: "Authorization")
        }
        // Enable image captioning for vision model context
        if includeImageCaptions {
            req.setValue("true", forHTTPHeaderField: "x-with-generated-alt")
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        try HTTPError.throwIfBad(resp, data: data)
        let text = String(data: data, encoding: .utf8) ?? ""
        let lines = text.split(separator: "\n", maxSplits: 20, omittingEmptySubsequences: true)
        var title: String? = nil
        for line in lines.prefix(8) {
            if line.hasPrefix("# ") { title = String(line.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines); break }
        }
        return (title, text)
    }
    
    // MARK: - Public URL Reading (for view_url tool)
    
    /// Read URL content directly via Jina Reader with image captions for Gemini
    /// Downloads up to 5 images from the page for multimodal injection
    func readUrlContent(url: String) async throws -> JinaReaderResult {
        let (title, content) = try await fetchWithJinaReader(originalURL: url, includeImageCaptions: true)
        
        // Extract links from the markdown content
        let links = extractLinksFromMarkdown(content)
        
        // Extract image references from the markdown (with captions and URLs)
        // LLM can use view_page_image tool to selectively download images it wants to see
        let images = extractImageReferences(content)
        
        return JinaReaderResult(
            url: url,
            title: title,
            content: content,
            links: links,
            images: images,
            downloadedImages: [] // Images are downloaded separately via view_page_image tool
        )
    }
    
    /// Download a single image from URL - used by view_page_image tool
    func downloadImage(url: String, caption: String = "") async -> DownloadedImage? {
        guard let imageUrl = URL(string: url) else { return nil }
        
        do {
            var request = URLRequest(url: imageUrl)
            request.timeoutInterval = 15 // Reasonable timeout for single image
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return nil
            }
            
            // Validate it's an image
            let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""
            guard contentType.hasPrefix("image/") else { return nil }
            
            // Limit image size to 10MB
            guard data.count <= 10_000_000 else {
                print("[WebOrchestrator] Image too large: \(data.count) bytes")
                return nil
            }
            
            return DownloadedImage(
                data: data,
                mimeType: contentType,
                caption: caption,
                sourceUrl: url
            )
        } catch {
            print("[WebOrchestrator] Failed to download image: \(error.localizedDescription)")
            return nil
        }
    }
    
    private func extractLinksFromMarkdown(_ text: String) -> [ExtractedLink] {
        // Match markdown links: [text](url)
        let pattern = #"\[([^\]]+)\]\((https?://[^)]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: range)
        
        return matches.compactMap { match -> ExtractedLink? in
            guard let textRange = Range(match.range(at: 1), in: text),
                  let urlRange = Range(match.range(at: 2), in: text) else { return nil }
            return ExtractedLink(
                text: String(text[textRange]),
                url: String(text[urlRange])
            )
        }.prefix(50).map { $0 } // Limit to 50 links
    }
    
    private func extractImageReferences(_ text: String) -> [ExtractedImage] {
        // Match markdown images: ![alt](url) and Jina's Image [n]: caption format
        var images: [ExtractedImage] = []
        
        // Standard markdown images
        let mdPattern = #"!\[([^\]]*)\]\((https?://[^)]+)\)"#
        if let regex = try? NSRegularExpression(pattern: mdPattern) {
            let range = NSRange(text.startIndex..., in: text)
            let matches = regex.matches(in: text, range: range)
            for match in matches {
                if let altRange = Range(match.range(at: 1), in: text),
                   let urlRange = Range(match.range(at: 2), in: text) {
                    images.append(ExtractedImage(
                        caption: String(text[altRange]),
                        url: String(text[urlRange])
                    ))
                }
            }
        }
        
        // Jina's captioned images: "Image [1]: description"
        let jinaPattern = #"Image \[(\d+)\]: ([^\n]+)"#
        if let regex = try? NSRegularExpression(pattern: jinaPattern) {
            let range = NSRange(text.startIndex..., in: text)
            let matches = regex.matches(in: text, range: range)
            for match in matches {
                if let captionRange = Range(match.range(at: 2), in: text) {
                    images.append(ExtractedImage(
                        caption: String(text[captionRange]),
                        url: nil // Jina captions don't always include the URL
                    ))
                }
            }
        }
        
        return Array(images.prefix(20)) // Limit to 20 images
    }
    
    private func scrapeAndExtract(url: String, focus: String, atStep: Int) async throws -> ScrapedDoc {
        let (maybeTitle, rawContent) = try await fetchWithJinaReader(originalURL: url, includeImageCaptions: true)
        let host = URL(string: url)?.host?.lowercased() ?? ""

        if rawContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ScrapedDoc(url: url, source: host, title: maybeTitle, excerpts: [], links: [], images: [], retrievedAtStep: atStep)
        }

        let candidateLinks = extractLinksFromMarkdown(rawContent)
        let candidateImages = extractImageReferences(rawContent)
        let relevantAssets = try? await extractRelevantLinksAndImages(
            page: rawContent,
            focus: focus,
            candidateLinks: candidateLinks,
            candidateImages: candidateImages
        )
        let relevantLinks = relevantAssets?.links ?? []
        let relevantImages = relevantAssets?.images ?? []

        if rawContent.count <= excerptThreshold {
            return ScrapedDoc(
                url: url,
                source: host,
                title: maybeTitle,
                excerpts: [rawContent],
                links: relevantLinks,
                images: relevantImages,
                retrievedAtStep: atStep
            )
        }

        if rawContent.count <= chunkSizeChars {
            let ex = try await extractExcerpts(page: rawContent, focus: focus)
            return ScrapedDoc(
                url: url,
                source: host,
                title: maybeTitle,
                excerpts: ex,
                links: relevantLinks,
                images: relevantImages,
                retrievedAtStep: atStep
            )
        }

        let chunks = makeChunks(for: rawContent, chunk: chunkSizeChars, maxChunks: maxChunksForExtraction, overlap: chunkOverlapChars)
        var allExcerpts: [String] = []

        for chunk in chunks {
            do {
                let ex = try await extractExcerpts(page: chunk, focus: focus)
                if !ex.isEmpty { allExcerpts.append(contentsOf: ex) }
            } catch is CancellationError { throw CancellationError() }
            catch { /* continue */ }
        }

        return ScrapedDoc(
            url: url,
            source: host,
            title: maybeTitle,
            excerpts: dedupeExcerpts(allExcerpts),
            links: relevantLinks,
            images: relevantImages,
            retrievedAtStep: atStep
        )
    }
    
    private func extractExcerpts(page: String, focus: String) async throws -> [String] {
        let sys = """
        Cite verbatim and in full the most relevant parts of the provided TEXT for the given FOCUS.
        OUTPUT STRICT JSON ONLY: { "excerpts": ["...", "..."] }
        """
        let msgs: [ORChatReq.Msg] = [
            .init(role: "system", content: sys),
            .init(role: "user", content: "FOCUS:\n\(focus)\n\nTEXT:\n\(page.prefix(chunkSizeChars))")
        ]
        let raw = try await callOpenRouter(
            model: ORModel.excerpts,
            messages: msgs,
            maxTokens: 16000,
            reasoning: makeReasoning(ReasoningSettings.excerpts)
        )
        guard let d = extractFirstJSONObjectData(from: raw),
              let out = try? JSONDecoder().decode(ExcerptOut.self, from: d) else { return [] }
        return out.excerpts
    }

    private func extractRelevantLinksAndImages(
        page: String,
        focus: String,
        candidateLinks: [ExtractedLink],
        candidateImages: [ExtractedImage]
    ) async throws -> (links: [ExtractedLink], images: [ExtractedImage]) {
        guard !candidateLinks.isEmpty || !candidateImages.isEmpty else { return ([], []) }

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let linksJSON = String(
            data: (try? encoder.encode(candidateLinks)) ?? Data("[]".utf8),
            encoding: .utf8
        ) ?? "[]"
        let imagesJSON = String(
            data: (try? encoder.encode(candidateImages)) ?? Data("[]".utf8),
            encoding: .utf8
        ) ?? "[]"

        let sys = """
        You extract focus-relevant page assets from provided candidates.
        Return STRICT JSON only in this schema:
        {
          "links": [{ "text": "...", "url": "https://..." }],
          "images": [{ "caption": "...", "url": "https://..." | null }]
        }

        Rules:
        - Select only items relevant to FOCUS.
        - Use only URLs and items that appear in candidates; do not invent.
        - Keep URLs exact.
        - Return at most 8 links and 8 images.
        """

        let msgs: [ORChatReq.Msg] = [
            .init(role: "system", content: sys),
            .init(
                role: "user",
                content: """
                FOCUS:
                \(focus)

                CANDIDATE_LINKS_JSON:
                \(linksJSON)

                CANDIDATE_IMAGES_JSON:
                \(imagesJSON)

                PAGE_CONTEXT:
                \(page.prefixing(60000))
                """
            )
        ]

        let raw = try await callOpenRouter(
            model: ORModel.excerpts,
            messages: msgs,
            maxTokens: 8000,
            reasoning: makeReasoning(ReasoningSettings.excerpts)
        )

        guard let d = extractFirstJSONObjectData(from: raw),
              let out = try? JSONDecoder().decode(RelevantAssetOut.self, from: d) else {
            return ([], [])
        }

        let linkLookup: [String: ExtractedLink] = Dictionary(
            candidateLinks.map { ($0.url, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let imageURLPairs: [(String, ExtractedImage)] = candidateImages.compactMap { image in
            guard let url = image.url else { return nil }
            return (url, image)
        }
        let imageURLLookup: [String: ExtractedImage] = Dictionary(
            imageURLPairs,
            uniquingKeysWith: { first, _ in first }
        )
        let imageCaptionLookup: [String: ExtractedImage] = Dictionary(
            candidateImages.map { ($0.caption.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let modelLinks = out.links ?? []
        let modelImages = out.images ?? []

        let filteredLinks = modelLinks.compactMap { item -> ExtractedLink? in
            guard let url = item.url?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !url.isEmpty,
                  let candidate = linkLookup[url] else { return nil }
            let text = item.text?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedText: String
            if let text, !text.isEmpty {
                resolvedText = text
            } else {
                resolvedText = candidate.text
            }
            return ExtractedLink(text: resolvedText, url: candidate.url)
        }

        let filteredImages = modelImages.compactMap { item -> ExtractedImage? in
            let caption = item.caption?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if let rawURL = item.url?.trimmingCharacters(in: .whitespacesAndNewlines),
               !rawURL.isEmpty,
               let candidate = imageURLLookup[rawURL] {
                return ExtractedImage(caption: caption.isEmpty ? candidate.caption : caption, url: candidate.url)
            }

            if !caption.isEmpty, let candidate = imageCaptionLookup[caption.lowercased()] {
                return candidate
            }

            return nil
        }

        return (
            links: dedupeLinks(filteredLinks).prefix(8).map { $0 },
            images: dedupeImages(filteredImages).prefix(8).map { $0 }
        )
    }
    
    private func generateFinalAnswer(currentQuestion: String, webContextJSON: String, scratchpad: String, historyPairs: [(user: String, assistant: String)]) async throws -> String {
        let sys = """
        **Today is: \(nowStamp())**
        Use the provided WEB_CONTEXT_JSON and RESEARCH_JOURNEY to answer the question concisely.
        Provide sources with URLs so the information you provide can be verified.
        
        Requirements:
        - Prefer recent sources when appropriate
        - If sources conflict, note briefly
        - Keep answer concise, add "Sources" list at end
        - Do NOT invent citations
        """
        
        var msgs = [ORChatReq.Msg(role: "system", content: sys)]
        for p in historyPairs {
            msgs.append(.init(role: "user", content: p.user))
            msgs.append(.init(role: "assistant", content: p.assistant))
        }
        
        var userContent = currentQuestion
        if !scratchpad.isEmpty { userContent += "\n\nRESEARCH_JOURNEY:\n\(scratchpad)" }
        userContent += "\n\nWEB_CONTEXT_JSON:\n\(webContextJSON)"
        msgs.append(.init(role: "user", content: userContent))
        
        let raw = try await callOpenRouter(
            model: ORModel.finalAns,
            messages: msgs,
            maxTokens: 16000,
            reasoning: makeReasoning(ReasoningSettings.finalAns)
        )
        return autolinkPhoneNumbers(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    
    // MARK: - Utilities
    private func normalize(_ link: String) -> String {
        guard var c = URLComponents(string: link) else { return link }
        c.queryItems = c.queryItems?.filter { !["utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content", "gclid", "fbclid", "igshid"].contains($0.name.lowercased()) }
        c.fragment = nil
        return c.string ?? link
    }
    
    private func makeChunks(for s: String, chunk: Int, maxChunks: Int, overlap: Int) -> [String] {
        guard !s.isEmpty, chunk > 0, maxChunks > 0 else { return [] }
        let n = s.count
        var result: [String] = []
        let step = max(1, chunk - max(0, overlap))
        var startOffset = 0
        for _ in 0..<maxChunks {
            if startOffset >= n { break }
            let endOffset = min(startOffset + chunk, n)
            let startIdx = s.index(s.startIndex, offsetBy: startOffset)
            let endIdx = s.index(s.startIndex, offsetBy: endOffset)
            result.append(String(s[startIdx..<endIdx]))
            if endOffset == n { break }
            startOffset += step
        }
        return result
    }
    
    private func dedupeExcerpts(_ arr: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for x in arr {
            let key = x.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty, seen.insert(key).inserted { out.append(x) }
        }
        return out
    }

    private func dedupeLinks(_ arr: [ExtractedLink]) -> [ExtractedLink] {
        var seen = Set<String>()
        var out: [ExtractedLink] = []
        for x in arr {
            let key = x.url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !key.isEmpty, seen.insert(key).inserted { out.append(x) }
        }
        return out
    }

    private func dedupeImages(_ arr: [ExtractedImage]) -> [ExtractedImage] {
        var seen = Set<String>()
        var out: [ExtractedImage] = []
        for x in arr {
            let key = (x.url?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
                ?? "caption:\(x.caption.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
            if !key.isEmpty, seen.insert(key).inserted { out.append(x) }
        }
        return out
    }
}
