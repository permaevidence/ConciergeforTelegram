import Foundation

// MARK: - Calendar Service

/// Singleton actor that manages calendar event persistence
actor CalendarService {
    static let shared = CalendarService()
    
    private var events: [CalendarEvent] = []
    
    private let calendarFileURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport.appendingPathComponent("TelegramConcierge", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("calendar.json")
    }()
    
    private init() {
        loadEvents()
    }
    
    // MARK: - Public API
    
    /// Add a new calendar event and persist it
    func addEvent(title: String, datetime: Date, notes: String?) -> CalendarEvent {
        let event = CalendarEvent(title: title, datetime: datetime, notes: notes)
        events.append(event)
        saveEvents()
        print("[CalendarService] Added event '\(title)' for \(datetime)")
        return event
    }
    
    /// Get events, optionally including past events
    /// By default only returns future events to keep context window small
    func getEvents(includePast: Bool = false) -> [CalendarEvent] {
        let now = Date()
        if includePast {
            return events.sorted { $0.datetime < $1.datetime }
        } else {
            return events.filter { $0.datetime >= now }.sorted { $0.datetime < $1.datetime }
        }
    }
    
    /// Get only past events
    func getPastEvents() -> [CalendarEvent] {
        let now = Date()
        return events.filter { $0.datetime < now }.sorted { $0.datetime > $1.datetime }
    }
    
    /// Update an existing event
    func updateEvent(id: UUID, title: String?, datetime: Date?, notes: String?) -> Bool {
        guard let index = events.firstIndex(where: { $0.id == id }) else {
            print("[CalendarService] Event \(id) not found for update")
            return false
        }
        
        if let title = title {
            events[index].title = title
        }
        if let datetime = datetime {
            events[index].datetime = datetime
        }
        if let notes = notes {
            events[index].notes = notes
        }
        
        saveEvents()
        print("[CalendarService] Updated event \(id)")
        return true
    }
    
    /// Delete an event
    func deleteEvent(id: UUID) -> Bool {
        guard let index = events.firstIndex(where: { $0.id == id }) else {
            print("[CalendarService] Event \(id) not found for deletion")
            return false
        }
        
        let event = events.remove(at: index)
        saveEvents()
        print("[CalendarService] Deleted event '\(event.title)'")
        return true
    }
    
    /// Get a specific event by ID
    func getEvent(id: UUID) -> CalendarEvent? {
        events.first { $0.id == id }
    }
    
    /// Get count of upcoming events
    func upcomingCount() -> Int {
        let now = Date()
        return events.filter { $0.datetime >= now }.count
    }
    
    // MARK: - Calendar Context for System Prompt
    
    private var cachedContext: String?
    private var cacheInvalidated: Bool = true
    
    // Token thresholds (approximate: 4 chars per token)
    private let maxTokens = 4000
    private let triggerTokens = 5000
    private let charsPerToken = 4
    
    /// Get formatted calendar context for LLM system prompt
    /// Returns a string with today's and future events, auto-summarized if too long
    func getCalendarContextForSystemPrompt() -> String {
        // Return cached if valid
        if !cacheInvalidated, let cached = cachedContext {
            return cached
        }
        
        let context = generateCalendarContext()
        cachedContext = context
        cacheInvalidated = false
        return context
    }
    
    /// Invalidate cache when events change
    private func invalidateCache() {
        cacheInvalidated = true
        cachedContext = nil
    }
    
    /// Generate calendar context with progressive detail
    private func generateCalendarContext() -> String {
        let now = Date()
        let calendar = Calendar.current
        
        // Get future events (including today)
        let startOfToday = calendar.startOfDay(for: now)
        let futureEvents = events
            .filter { $0.datetime >= startOfToday }
            .sorted { $0.datetime < $1.datetime }
        
        guard !futureEvents.isEmpty else {
            return "📅 **Your Calendar**: No upcoming events."
        }
        
        // First pass: generate full detail version
        let fullContext = generateFullDetailContext(events: futureEvents, now: now, calendar: calendar)
        
        // Check if we need to compress
        let estimatedTokens = fullContext.count / charsPerToken
        if estimatedTokens <= triggerTokens {
            return fullContext
        }
        
        // Need to compress - use progressive detail
        return generateCompressedContext(events: futureEvents, now: now, calendar: calendar)
    }
    
    /// Generate full detail version of calendar
    private func generateFullDetailContext(events: [CalendarEvent], now: Date, calendar: Calendar) -> String {
        var lines: [String] = ["📅 **Your Calendar**:", ""]
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEEE, MMM d"
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mm a"
        
        var currentDateString = ""
        
        for event in events {
            let eventDateString = dateFormatter.string(from: event.datetime)
            
            // Add date header if new day
            if eventDateString != currentDateString {
                if !currentDateString.isEmpty {
                    lines.append("")
                }
                
                // Mark today specially
                if calendar.isDateInToday(event.datetime) {
                    lines.append("**TODAY - \(eventDateString)**")
                } else if calendar.isDateInTomorrow(event.datetime) {
                    lines.append("**TOMORROW - \(eventDateString)**")
                } else {
                    lines.append("**\(eventDateString)**")
                }
                currentDateString = eventDateString
            }
            
            // Event details
            let timeStr = timeFormatter.string(from: event.datetime)
            var eventLine = "• \(timeStr): \(event.title)"
            if let notes = event.notes, !notes.isEmpty {
                eventLine += " — \(notes)"
            }
            eventLine += " [id: \(event.id.uuidString.prefix(8))...]"
            lines.append(eventLine)
        }
        
        return lines.joined(separator: "\n")
    }
    
    /// Generate compressed version with progressive detail
    private func generateCompressedContext(events: [CalendarEvent], now: Date, calendar: Calendar) -> String {
        var lines: [String] = ["📅 **Your Calendar** (summarized):", ""]
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEEE, MMM d"
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mm a"
        let weekFormatter = DateFormatter()
        weekFormatter.dateFormat = "'Week of' MMM d"
        
        // Boundaries
        let sevenDaysOut = calendar.date(byAdding: .day, value: 7, to: now)!
        let thirtyDaysOut = calendar.date(byAdding: .day, value: 30, to: now)!
        
        // Partition events
        let nearEvents = events.filter { $0.datetime < sevenDaysOut }
        let midEvents = events.filter { $0.datetime >= sevenDaysOut && $0.datetime < thirtyDaysOut }
        let farEvents = events.filter { $0.datetime >= thirtyDaysOut }
        
        // Near events: full detail
        var currentDateString = ""
        for event in nearEvents {
            let eventDateString = dateFormatter.string(from: event.datetime)
            
            if eventDateString != currentDateString {
                if !currentDateString.isEmpty { lines.append("") }
                if calendar.isDateInToday(event.datetime) {
                    lines.append("**TODAY - \(eventDateString)**")
                } else if calendar.isDateInTomorrow(event.datetime) {
                    lines.append("**TOMORROW - \(eventDateString)**")
                } else {
                    lines.append("**\(eventDateString)**")
                }
                currentDateString = eventDateString
            }
            
            let timeStr = timeFormatter.string(from: event.datetime)
            var eventLine = "• \(timeStr): \(event.title)"
            if let notes = event.notes, !notes.isEmpty {
                eventLine += " — \(notes)"
            }
            eventLine += " [id: \(event.id.uuidString.prefix(8))...]"
            lines.append(eventLine)
        }
        
        // Mid events: title + date only
        if !midEvents.isEmpty {
            lines.append("")
            lines.append("**Next 8-30 days:**")
            for event in midEvents {
                let dateStr = dateFormatter.string(from: event.datetime)
                lines.append("• \(dateStr): \(event.title) [id: \(event.id.uuidString.prefix(8))...]")
            }
        }
        
        // Far events: grouped by week
        if !farEvents.isEmpty {
            lines.append("")
            lines.append("**Beyond 30 days:**")
            
            // Group by week
            var weeklyGroups: [String: [CalendarEvent]] = [:]
            for event in farEvents {
                let weekStart = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: event.datetime))!
                let weekKey = weekFormatter.string(from: weekStart)
                weeklyGroups[weekKey, default: []].append(event)
            }
            
            // Sort by date and output
            let sortedWeeks = weeklyGroups.keys.sorted { key1, key2 in
                weeklyGroups[key1]!.first!.datetime < weeklyGroups[key2]!.first!.datetime
            }
            
            for weekKey in sortedWeeks {
                let count = weeklyGroups[weekKey]!.count
                let titles = weeklyGroups[weekKey]!.prefix(2).map { $0.title }.joined(separator: ", ")
                if count > 2 {
                    lines.append("• \(weekKey): \(titles) +\(count - 2) more")
                } else {
                    lines.append("• \(weekKey): \(titles)")
                }
            }
        }
        
        // Ensure we're under the limit
        var result = lines.joined(separator: "\n")
        let maxChars = maxTokens * charsPerToken
        if result.count > maxChars {
            result = String(result.prefix(maxChars - 50)) + "\n... [calendar truncated, use view_calendar for full details]"
        }
        
        return result
    }
    
    // MARK: - Persistence
    
    private func loadEvents() {
        guard FileManager.default.fileExists(atPath: calendarFileURL.path) else { return }
        
        do {
            let data = try Data(contentsOf: calendarFileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            events = try decoder.decode([CalendarEvent].self, from: data)
            print("[CalendarService] Loaded \(events.count) events")
            invalidateCache()
        } catch {
            print("[CalendarService] Failed to load events: \(error)")
        }
    }
    
    private func saveEvents() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(events)
            try data.write(to: calendarFileURL)
            invalidateCache()
        } catch {
            print("[CalendarService] Failed to save events: \(error)")
        }
    }
    
    // MARK: - Export/Import for Standalone Calendar Backup
    
    /// Get all events as JSON data for export
    func getEventsData() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(events)
    }
    
    /// Import events from JSON data (replaces all existing events)
    func importEvents(from data: Data) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let importedEvents = try decoder.decode([CalendarEvent].self, from: data)
        events = importedEvents
        saveEvents()
        print("[CalendarService] Imported \(events.count) events")
    }
    
    /// Get count of all events (past + future)
    func totalEventCount() -> Int {
        events.count
    }
}

