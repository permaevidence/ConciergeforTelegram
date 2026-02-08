import Foundation

// MARK: - Contacts Service

/// Singleton actor that manages contact persistence, vCard import, and search
actor ContactsService {
    static let shared = ContactsService()
    
    private var contacts: [Contact] = []
    
    private let contactsFileURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport.appendingPathComponent("TelegramConcierge", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("contacts.json")
    }()
    
    private init() {
        loadContacts()
    }
    
    // MARK: - Public API
    
    /// Import contacts from a vCard (.vcf) file data
    /// - Returns: Number of contacts imported
    func importFromVCard(data: Data) -> Int {
        guard let content = String(data: data, encoding: .utf8) else {
            print("[ContactsService] Failed to decode vCard data as UTF-8")
            return 0
        }
        
        let parsedContacts = parseVCard(content)
        
        for contact in parsedContacts {
            // Avoid duplicates: check if contact with same name and email exists
            let isDuplicate = contacts.contains { existing in
                existing.firstName.lowercased() == contact.firstName.lowercased() &&
                existing.lastName?.lowercased() == contact.lastName?.lowercased() &&
                existing.email?.lowercased() == contact.email?.lowercased()
            }
            
            if !isDuplicate {
                contacts.append(contact)
            }
        }
        
        saveContacts()
        print("[ContactsService] Imported \(parsedContacts.count) contacts, total: \(contacts.count)")
        return parsedContacts.count
    }
    
    /// Search contacts by name or email (case-insensitive partial match)
    func searchContacts(query: String) -> [Contact] {
        let lowercasedQuery = query.lowercased()
        
        return contacts.filter { contact in
            contact.firstName.lowercased().contains(lowercasedQuery) ||
            (contact.lastName?.lowercased().contains(lowercasedQuery) ?? false) ||
            contact.fullName.lowercased().contains(lowercasedQuery) ||
            (contact.email?.lowercased().contains(lowercasedQuery) ?? false) ||
            (contact.organization?.lowercased().contains(lowercasedQuery) ?? false)
        }
    }
    
    /// Add a new contact manually
    func addContact(
        firstName: String,
        lastName: String? = nil,
        email: String? = nil,
        phone: String? = nil,
        organization: String? = nil
    ) -> Contact {
        let contact = Contact(
            firstName: firstName,
            lastName: lastName,
            email: email,
            phone: phone,
            organization: organization
        )
        contacts.append(contact)
        saveContacts()
        print("[ContactsService] Added contact: \(contact.fullName)")
        return contact
    }
    
    /// Get all contacts
    func getAllContacts() -> [Contact] {
        return contacts
    }
    
    /// Get count of contacts
    func contactCount() -> Int {
        return contacts.count
    }
    
    /// Delete a contact by ID
    func deleteContact(id: UUID) -> Bool {
        if let index = contacts.firstIndex(where: { $0.id == id }) {
            let removed = contacts.remove(at: index)
            saveContacts()
            print("[ContactsService] Deleted contact: \(removed.fullName)")
            return true
        }
        return false
    }
    
    /// Clear all contacts (for memory reset)
    func clearAllContacts() {
        let count = contacts.count
        contacts.removeAll()
        saveContacts()
        print("[ContactsService] Cleared \(count) contacts")
    }
    
    // MARK: - vCard Parsing
    
    private func parseVCard(_ content: String) -> [Contact] {
        var parsedContacts: [Contact] = []
        
        // Split content into individual vCard blocks
        let vcardBlocks = content.components(separatedBy: "BEGIN:VCARD")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        
        for block in vcardBlocks {
            guard block.contains("END:VCARD") else { continue }
            
            var firstName = ""
            var lastName: String? = nil
            var email: String? = nil
            var phone: String? = nil
            var organization: String? = nil
            
            let lines = block.components(separatedBy: .newlines)
            
            for line in lines {
                let cleanLine = line.trimmingCharacters(in: .whitespaces)
                
                // Handle FN (Full Name) - use as fallback
                if cleanLine.hasPrefix("FN:") || cleanLine.hasPrefix("FN;") {
                    let value = extractValue(from: cleanLine, key: "FN")
                    if firstName.isEmpty {
                        let parts = value.split(separator: " ", maxSplits: 1).map(String.init)
                        firstName = parts.first ?? value
                        if parts.count > 1 {
                            lastName = parts[1]
                        }
                    }
                }
                
                // Handle N (Structured Name) - preferred
                else if cleanLine.hasPrefix("N:") || cleanLine.hasPrefix("N;") {
                    let value = extractValue(from: cleanLine, key: "N")
                    let parts = value.split(separator: ";").map { String($0).trimmingCharacters(in: .whitespaces) }
                    // N format: LastName;FirstName;MiddleName;Prefix;Suffix
                    if parts.count >= 2 {
                        lastName = parts[0].isEmpty ? nil : parts[0]
                        firstName = parts[1]
                    } else if parts.count == 1 && !parts[0].isEmpty {
                        firstName = parts[0]
                    }
                }
                
                // Handle EMAIL
                else if cleanLine.hasPrefix("EMAIL") {
                    email = extractValue(from: cleanLine, key: "EMAIL")
                }
                
                // Handle TEL (Phone)
                else if cleanLine.hasPrefix("TEL") {
                    phone = extractValue(from: cleanLine, key: "TEL")
                }
                
                // Handle ORG (Organization)
                else if cleanLine.hasPrefix("ORG") {
                    let value = extractValue(from: cleanLine, key: "ORG")
                    // ORG can have multiple parts separated by ;
                    organization = value.replacingOccurrences(of: ";", with: " ").trimmingCharacters(in: .whitespaces)
                }
            }
            
            // Only add if we have at least a first name
            if !firstName.isEmpty {
                parsedContacts.append(Contact(
                    firstName: firstName,
                    lastName: lastName,
                    email: email,
                    phone: phone,
                    organization: organization
                ))
            }
        }
        
        return parsedContacts
    }
    
    /// Extract value from a vCard line, handling various formats like "KEY:value" or "KEY;PARAMS:value"
    private func extractValue(from line: String, key: String) -> String {
        // Find the colon that separates key/params from value
        guard let colonIndex = line.firstIndex(of: ":") else { return "" }
        let value = String(line[line.index(after: colonIndex)...])
        return value.trimmingCharacters(in: .whitespaces)
    }
    
    // MARK: - Persistence
    
    private func loadContacts() {
        guard FileManager.default.fileExists(atPath: contactsFileURL.path) else { return }
        
        do {
            let data = try Data(contentsOf: contactsFileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            contacts = try decoder.decode([Contact].self, from: data)
            print("[ContactsService] Loaded \(contacts.count) contacts")
        } catch {
            print("[ContactsService] Failed to load contacts: \(error)")
        }
    }
    
    private func saveContacts() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(contacts)
            try data.write(to: contactsFileURL)
        } catch {
            print("[ContactsService] Failed to save contacts: \(error)")
        }
    }
}
