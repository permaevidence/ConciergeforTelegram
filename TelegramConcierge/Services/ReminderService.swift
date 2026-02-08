import Foundation

// MARK: - Reminder Service

/// Singleton actor that manages reminder persistence and scheduling
actor ReminderService {
    static let shared = ReminderService()
    
    private var reminders: [Reminder] = []
    
    private let remindersFileURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport.appendingPathComponent("TelegramConcierge", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("reminders.json")
    }()
    
    private init() {
        loadReminders()
    }
    
    // MARK: - Public API
    
    /// Add a new reminder and persist it
    func addReminder(triggerDate: Date, prompt: String, recurrence: RecurrenceType? = nil) -> Reminder {
        let reminder = Reminder(triggerDate: triggerDate, prompt: prompt, recurrence: recurrence)
        reminders.append(reminder)
        saveReminders()
        print("[ReminderService] Added reminder \(reminder.id) for \(triggerDate)\(recurrence != nil ? " (recurring: \(recurrence!.description))" : "")")
        return reminder
    }
    
    /// Get all reminders that are due (past trigger time and not yet triggered)
    func getDueReminders() -> [Reminder] {
        let now = Date()
        return reminders.filter { !$0.triggered && $0.triggerDate <= now }
    }
    
    /// Mark a reminder as triggered
    func markTriggered(id: UUID) {
        if let index = reminders.firstIndex(where: { $0.id == id }) {
            reminders[index].triggered = true
            saveReminders()
            print("[ReminderService] Marked reminder \(id) as triggered")
        }
    }
    
    /// Reschedule a recurring reminder after it's been triggered
    /// Returns the new reminder if rescheduled, nil if not recurring
    func rescheduleRecurring(id: UUID) -> Reminder? {
        guard let index = reminders.firstIndex(where: { $0.id == id }),
              let recurrence = reminders[index].recurrence else {
            return nil
        }
        
        let original = reminders[index]
        let nextDate = recurrence.nextTriggerDate(from: original.triggerDate)
        
        // Create a new reminder for the next occurrence
        let nextReminder = Reminder(
            triggerDate: nextDate,
            prompt: original.prompt,
            recurrence: recurrence
        )
        reminders.append(nextReminder)
        saveReminders()
        
        print("[ReminderService] Rescheduled recurring reminder: next occurrence at \(nextDate)")
        return nextReminder
    }
    
    /// Delete a reminder by ID
    /// Returns true if successful, false if not found
    func deleteReminder(id: UUID) -> Bool {
        if let index = reminders.firstIndex(where: { $0.id == id }) {
            let removed = reminders.remove(at: index)
            saveReminders()
            print("[ReminderService] Deleted reminder \(id)")
            return true
        }
        return false
    }
    
    /// Get all pending (not triggered) reminders
    func getPendingReminders() -> [Reminder] {
        reminders.filter { !$0.triggered }
    }
    
    /// Get count of pending reminders
    func pendingCount() -> Int {
        reminders.filter { !$0.triggered }.count
    }
    
    /// Clear all reminders (for memory reset)
    func clearAllReminders() {
        reminders.removeAll()
        saveReminders()
        print("[ReminderService] Cleared all reminders")
    }
    
    // MARK: - Persistence
    
    private func loadReminders() {
        guard FileManager.default.fileExists(atPath: remindersFileURL.path) else { return }
        
        do {
            let data = try Data(contentsOf: remindersFileURL)
            reminders = try JSONDecoder().decode([Reminder].self, from: data)
            print("[ReminderService] Loaded \(reminders.count) reminders")
        } catch {
            print("[ReminderService] Failed to load reminders: \(error)")
        }
    }
    
    private func saveReminders() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(reminders)
            try data.write(to: remindersFileURL)
        } catch {
            print("[ReminderService] Failed to save reminders: \(error)")
        }
    }
}
