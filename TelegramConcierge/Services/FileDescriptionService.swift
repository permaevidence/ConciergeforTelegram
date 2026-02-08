import Foundation

/// Simple service to persist file descriptions for future reference
/// Uses UserDefaults for persistence across app launches
actor FileDescriptionService {
    static let shared = FileDescriptionService()
    
    private let storageKey = "FileDescriptions"
    private var cache: [String: String] = [:]
    private var loaded = false
    
    private init() {}
    
    /// Load descriptions from storage
    private func loadIfNeeded() {
        guard !loaded else { return }
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let descriptions = try? JSONDecoder().decode([String: String].self, from: data) {
            cache = descriptions
        }
        loaded = true
    }
    
    /// Save descriptions to storage
    private func persist() {
        if let data = try? JSONEncoder().encode(cache) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
    
    /// Save a description for a file
    func save(filename: String, description: String) {
        loadIfNeeded()
        cache[filename] = description
        persist()
        print("[FileDescriptionService] Saved description for \(filename): \(description.prefix(50))...")
    }
    
    /// Get description for a file
    func get(filename: String) -> String? {
        loadIfNeeded()
        return cache[filename]
    }
    
    /// Get all descriptions
    func getAll() -> [String: String] {
        loadIfNeeded()
        return cache
    }
    
    /// Save multiple descriptions at once
    func saveMultiple(_ descriptions: [String: String]) {
        loadIfNeeded()
        for (filename, description) in descriptions {
            cache[filename] = description
            print("[FileDescriptionService] Saved description for \(filename): \(description.prefix(50))...")
        }
        persist()
    }
    
    /// Clear all stored descriptions
    func clearAll() {
        cache.removeAll()
        UserDefaults.standard.removeObject(forKey: storageKey)
        print("[FileDescriptionService] Cleared all file descriptions")
    }
}
