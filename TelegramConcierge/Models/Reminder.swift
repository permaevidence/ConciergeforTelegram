import Foundation

// MARK: - Recurrence Type

enum RecurrenceType: Codable, Equatable {
    case daily
    case weekly
    case monthly
    case custom(minutes: Int)
    
    // Human-readable description
    var description: String {
        switch self {
        case .daily: return "daily"
        case .weekly: return "weekly"
        case .monthly: return "monthly"
        case .custom(let minutes):
            if minutes >= 60 && minutes % 60 == 0 {
                let hours = minutes / 60
                return "every \(hours) hour\(hours > 1 ? "s" : "")"
            } else {
                return "every \(minutes) minute\(minutes > 1 ? "s" : "")"
            }
        }
    }
    
    /// Calculate the next trigger date based on recurrence type
    func nextTriggerDate(from date: Date) -> Date {
        let calendar = Calendar.current
        switch self {
        case .daily:
            return calendar.date(byAdding: .day, value: 1, to: date) ?? date
        case .weekly:
            return calendar.date(byAdding: .weekOfYear, value: 1, to: date) ?? date
        case .monthly:
            return calendar.date(byAdding: .month, value: 1, to: date) ?? date
        case .custom(let minutes):
            return calendar.date(byAdding: .minute, value: minutes, to: date) ?? date
        }
    }
}

// MARK: - Reminder Model

struct Reminder: Codable, Identifiable {
    let id: UUID
    var triggerDate: Date
    let prompt: String          // Detailed instructions for future Gemini
    let createdAt: Date
    var triggered: Bool
    let recurrence: RecurrenceType?
    
    init(triggerDate: Date, prompt: String, recurrence: RecurrenceType? = nil) {
        self.id = UUID()
        self.triggerDate = triggerDate
        self.prompt = prompt
        self.createdAt = Date()
        self.triggered = false
        self.recurrence = recurrence
    }
}
