import AppKit
import Foundation

// MARK: - Tool Executor

/// Central dispatcher that routes tool calls to their implementations
actor ToolExecutor {
    private let webOrchestrator = WebOrchestrator()
    private let archiveService = ConversationArchiveService()
    
    private static let runningProcessLock = NSLock()
    private static var runningProcesses: [ObjectIdentifier: Process] = [:]
    
    // MARK: - Configuration
    
    func configure(openRouterKey: String, serperKey: String, jinaKey: String) {
        webOrchestrator.configure(openRouterKey: openRouterKey, serperKey: serperKey, jinaKey: jinaKey)
        Task { await archiveService.configure(apiKey: openRouterKey) }
    }
    
    func cancelAllRunningProcesses() async {
        let processes = Self.snapshotRunningProcesses()
        guard !processes.isEmpty else { return }
        
        print("[ToolExecutor] Cancelling \(processes.count) running subprocess(es)")
        for process in processes where process.isRunning {
            process.terminate()
        }
        
        try? await Task.sleep(nanoseconds: 300_000_000)
        
        for process in processes where process.isRunning {
            process.interrupt()
        }
    }
    
    private static func registerRunningProcess(_ process: Process) {
        runningProcessLock.lock()
        runningProcesses[ObjectIdentifier(process)] = process
        runningProcessLock.unlock()
    }
    
    private static func unregisterRunningProcess(_ process: Process) {
        runningProcessLock.lock()
        runningProcesses.removeValue(forKey: ObjectIdentifier(process))
        runningProcessLock.unlock()
    }
    
    private static func snapshotRunningProcesses() -> [Process] {
        runningProcessLock.lock()
        let processes = Array(runningProcesses.values)
        runningProcessLock.unlock()
        return processes
    }
    
    // MARK: - Execution
    
    /// Execute a single tool call and return the result
    func execute(_ call: ToolCall) async throws -> ToolResultMessage {
        try Task.checkCancellation()
        
        // Special cases for tools that return ToolResultMessage with file attachment for multimodal injection
        switch call.function.name {
        case "read_document":
            return await executeReadDocument(call)
        case "read_project_file":
            return await executeReadProjectFile(call)
        case "download_email_attachment":
            return await executeDownloadEmailAttachment(call)
        case "gmail_attachment":
            return await executeGmailAttachment(call)
        case "generate_image":
            return await executeGenerateImage(call)
        case "view_page_image":
            return await executeViewPageImage(call)
        case "run_shortcut":
            return await executeRunShortcut(call)
        default:
            break
        }
        
        let content: String
        
        switch call.function.name {
        case "show_project_deployment_tools":
            content = await executeShowProjectDeploymentTools(call)
            
        case "web_search":
            content = try await executeWebSearch(call)

        case "deep_research":
            content = try await executeDeepResearch(call)
            
        case "manage_reminders":
            content = try await executeManageReminders(call)
            
        case "manage_calendar":
            content = await executeManageCalendar(call)
            
        case "view_conversation_chunk":
            content = await executeViewConversationChunk(call)
            
        case "read_emails":
            content = await executeReadEmails(call)
            
        case "search_emails":
            content = await executeSearchEmails(call)
            
        case "send_email":
            content = await executeSendEmail(call)
            
        case "reply_email":
            content = await executeReplyEmail(call)
            
        case "forward_email":
            content = await executeForwardEmail(call)
            
        case "list_documents":
            content = await executeListDocuments(call)
            
        case "send_email_with_attachment":
            content = await executeSendEmailWithAttachment(call)
            
        // download_email_attachment handled above with file attachment
            
        case "get_email_thread":
            content = await executeGetEmailThread(call)
            
        case "manage_contacts":
            content = await executeManageContacts(call)
            
        // generate_image is handled in the special multimodal injection switch above
            
        case "view_url":
            content = await executeViewUrl(call)
            
        case "download_from_url":
            content = await executeDownloadFromUrl(call)
            
        case "send_document_to_chat":
            content = await executeSendDocumentToChat(call)
            
        case "create_project":
            content = await executeCreateProject(call)
            
        case "list_projects":
            content = await executeListProjects(call)
            
        case "browse_project":
            content = await executeBrowseProject(call)
            
        case "add_project_files":
            content = await executeAddProjectFiles(call)
            
        case "view_project_history":
            content = await executeViewProjectHistory(call)
            
        case "run_claude_code":
            content = await executeRunClaudeCode(call)
            
        case "send_project_result":
            content = await executeSendProjectResult(call)
            
        case "deploy_project_to_vercel":
            content = await executeDeployProjectToVercel(call)
        
        case "provision_project_database":
            content = await executeProvisionProjectDatabase(call)
        
        case "push_project_database_schema":
            content = await executePushProjectDatabaseSchema(call)
        
        case "sync_project_database_env_to_vercel":
            content = await executeSyncProjectDatabaseEnvToVercel(call)
        
        case "generate_project_mcp_config":
            content = await executeGenerateProjectMCPConfig(call)
            
        case "edit_user_context":
            content = await executeEditUserContext(call)
            
        case "generate_document":
            content = await executeGenerateDocument(call)
            
        // Shortcuts Tools
        case "list_shortcuts":
            content = await executeListShortcuts(call)
        // run_shortcut is handled above with file attachment for media output
            
        // Gmail API Tools
        case "gmail_query":
            content = await executeGmailQuery(call)
            
        case "gmail_send":
            content = await executeGmailSend(call)
            
        case "gmail_thread":
            content = await executeGmailThread(call)
            
        case "gmail_forward":
            content = await executeGmailForward(call)
            
        // gmail_attachment handled above with file attachment
            
        default:
            content = "{\"error\": \"Unknown tool: \(call.function.name)}\"}"
        }
        
        return ToolResultMessage(toolCallId: call.id, content: content)
    }
    
    /// Execute multiple tool calls in parallel
    func executeParallel(_ calls: [ToolCall]) async throws -> [ToolResultMessage] {
        try Task.checkCancellation()
        return try await withThrowingTaskGroup(of: ToolResultMessage.self) { group in
            for call in calls {
                group.addTask {
                    try Task.checkCancellation()
                    return try await self.execute(call)
                }
            }
            
            var results: [ToolResultMessage] = []
            for try await result in group {
                results.append(result)
            }
            return results
        }
    }
    
    // MARK: - Tool Implementations
    
    private func executeWebSearch(_ call: ToolCall) async throws -> String {
        // Parse arguments from JSON string
        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(WebSearchArguments.self, from: argsData) else {
            return "{\"error\": \"Failed to parse web_search arguments\"}"
        }
        
        do {
            let result = try await webOrchestrator.executeForTool(query: args.query)
            return result.asJSON()
        } catch {
            return "{\"error\": \"Web search failed: \(error.localizedDescription)\"}"
        }
    }

    private func executeDeepResearch(_ call: ToolCall) async throws -> String {
        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(WebSearchArguments.self, from: argsData) else {
            return "{\"error\": \"Failed to parse deep_research arguments\"}"
        }

        do {
            let result = try await webOrchestrator.executeDeepResearchForTool(query: args.query)
            return result.asJSON()
        } catch {
            return "{\"error\": \"Deep research failed: \(error.localizedDescription)\"}"
        }
    }
    
    private func executeManageReminders(_ call: ToolCall) async throws -> String {
        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(ManageRemindersArguments.self, from: argsData) else {
            return #"{"error":"Failed to parse manage_reminders arguments"}"#
        }

        let action = args.action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch action {
        case "set":
            guard let triggerDatetime = args.triggerDatetime,
                  let prompt = args.prompt,
                  !triggerDatetime.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return #"{"error":"For action 'set', trigger_datetime and prompt are required"}"#
            }

            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var triggerDate = formatter.date(from: triggerDatetime)
            if triggerDate == nil {
                formatter.formatOptions = [.withInternetDateTime]
                triggerDate = formatter.date(from: triggerDatetime)
            }

            guard let date = triggerDate else {
                return #"{"error":"Invalid datetime format. Use ISO 8601 (e.g., '2026-02-01T09:00:00+01:00')"}"#
            }

            guard date > Date() else {
                return #"{"error":"Reminder datetime must be in the future"}"#
            }

            let recurrence = parseRecurrenceType(args.recurrence)

            let reminder = await ReminderService.shared.addReminder(triggerDate: date, prompt: prompt, recurrence: recurrence)
            let dateFormatter = DateFormatter()
            dateFormatter.dateStyle = .full
            dateFormatter.timeStyle = .short
            var message = "Reminder successfully scheduled"
            if let rec = recurrence {
                message += " (recurring: \(rec.description))"
            }
            let result = SetReminderResult(
                success: true,
                reminderId: reminder.id.uuidString,
                scheduledFor: dateFormatter.string(from: date),
                message: message
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            if let data = try? encoder.encode(result), let json = String(data: data, encoding: .utf8) {
                return json
            }
            return #"{"success":true,"message":"Reminder scheduled"}"#

        case "list":
            let reminders = await ReminderService.shared.getPendingReminders()
            if reminders.isEmpty {
                return #"{"success": true, "count": 0, "reminders": [], "message": "No pending reminders"}"#
            }

            let dateFormatter = DateFormatter()
            dateFormatter.dateStyle = .medium
            dateFormatter.timeStyle = .short

            var jsonEntries: [String] = []
            for reminder in reminders {
                let idStr = reminder.id.uuidString
                let triggerDT = ISO8601DateFormatter().string(from: reminder.triggerDate)
                let triggerReadable = dateFormatter.string(from: reminder.triggerDate)
                let promptEscaped = reminder.prompt
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                    .replacingOccurrences(of: "\n", with: "\\n")

                var entryFields = [
                    "\"id\": \"\(idStr)\"",
                    "\"trigger_datetime\": \"\(triggerDT)\"",
                    "\"trigger_datetime_readable\": \"\(triggerReadable)\"",
                    "\"prompt\": \"\(promptEscaped)\""
                ]

                if let rec = reminder.recurrence {
                    entryFields.append("\"recurrence\": \"\(rec.description)\"")
                }
                jsonEntries.append("{\(entryFields.joined(separator: ", "))}")
            }

            let remindersJson = jsonEntries.joined(separator: ", ")
            return "{\"success\": true, \"count\": \(reminders.count), \"reminders\": [\(remindersJson)], \"message\": \"Found \(reminders.count) pending reminder(s)\"}"

        case "delete":
            let pendingReminders = await ReminderService.shared.getPendingReminders()
            var targetIDs: [String] = []
            var deleteMode = "single"

            if args.deleteAll == true {
                targetIDs = pendingReminders.map { $0.id.uuidString }
                deleteMode = "all"
            } else if args.deleteRecurring == true {
                if let recurrenceRaw = args.recurrence?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !recurrenceRaw.isEmpty,
                   parseRecurrenceType(recurrenceRaw) == nil {
                    return #"{"error":"Invalid recurrence filter for delete_recurring. Use daily, weekly, monthly, or every_X_minutes."}"#
                }

                let recurrenceFilter = parseRecurrenceType(args.recurrence)
                targetIDs = pendingReminders.filter { reminder in
                    guard let recurrence = reminder.recurrence else { return false }
                    if let recurrenceFilter {
                        return recurrence == recurrenceFilter
                    }
                    return true
                }.map { $0.id.uuidString }
                deleteMode = "recurring"
            } else if let reminderIds = args.reminderIds, !reminderIds.isEmpty {
                targetIDs = reminderIds
                deleteMode = "batch"
            } else if let reminderId = args.reminderId, !reminderId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                targetIDs = [reminderId]
                deleteMode = "single"
            } else {
                return #"{"error":"For action 'delete', provide one of: reminder_id, reminder_ids, delete_all=true, or delete_recurring=true"}"#
            }

            let normalizedTargetIDs = Array(NSOrderedSet(array: targetIDs.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty })) as? [String] ?? []

            if normalizedTargetIDs.isEmpty {
                return #"{"error":"No valid reminder IDs provided for deletion"}"#
            }

            var deletedCount = 0
            var notFoundCount = 0
            var invalidIDs: [String] = []

            for idString in normalizedTargetIDs {
                guard let uuid = UUID(uuidString: idString) else {
                    invalidIDs.append(idString)
                    continue
                }
                let success = await ReminderService.shared.deleteReminder(id: uuid)
                if success {
                    deletedCount += 1
                } else {
                    notFoundCount += 1
                }
            }

            if deleteMode == "single" && normalizedTargetIDs.count == 1 && invalidIDs.isEmpty {
                if deletedCount == 1 {
                    return #"{"success":true,"message":"Reminder deleted successfully","deleted_count":1}"#
                }
                return #"{"error":"Reminder not found with the specified ID"}"#
            }

            let invalidIDsJSON = invalidIDs
                .map { "\"\($0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\"" }
                .joined(separator: ", ")
            let message = "Deleted \(deletedCount) reminder(s). \(notFoundCount) not found. \(invalidIDs.count) invalid ID(s)."
            return """
            {"success": true, "mode": "\(deleteMode)", "deleted_count": \(deletedCount), "not_found_count": \(notFoundCount), "invalid_ids": [\(invalidIDsJSON)], "message": "\(message)"}
            """

        default:
            return #"{"error":"Invalid action. Supported actions: set, list, delete"}"#
        }
    }
    // MARK: - Calendar Tool Implementations
    
    private func executeManageCalendar(_ call: ToolCall) async -> String {
        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(ManageCalendarArguments.self, from: argsData) else {
            return #"{"error":"Failed to parse manage_calendar arguments"}"#
        }

        let action = args.action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch action {
        case "view":
            let includePast = args.includePast ?? false
            let events = await CalendarService.shared.getEvents(includePast: includePast)

            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short

            let eventList = events.map { event -> CalendarEventResponse in
                CalendarEventResponse(
                    id: event.id.uuidString,
                    title: event.title,
                    datetime: formatter.string(from: event.datetime),
                    datetimeISO: ISO8601DateFormatter().string(from: event.datetime),
                    notes: event.notes,
                    isPast: event.datetime < Date()
                )
            }

            let result = ViewCalendarResult(
                success: true,
                eventCount: eventList.count,
                events: eventList,
                message: eventList.isEmpty ? "No events found" : "Found \(eventList.count) event(s)"
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            if let data = try? encoder.encode(result), let json = String(data: data, encoding: .utf8) {
                return json
            }
            return #"{"success":true,"eventCount":0,"events":[]}"#

        case "add":
            guard let title = args.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let datetime = args.datetime, !datetime.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return #"{"error":"For action 'add', title and datetime are required"}"#
            }
            guard let eventDate = parseISO8601Date(datetime) else {
                return #"{"error":"Invalid datetime format. Use ISO 8601 (e.g., '2026-02-01T15:00:00+01:00')"}"#
            }

            let event = await CalendarService.shared.addEvent(
                title: title,
                datetime: eventDate,
                notes: args.notes
            )

            let formatter = DateFormatter()
            formatter.dateStyle = .full
            formatter.timeStyle = .short

            let result = AddCalendarEventResult(
                success: true,
                eventId: event.id.uuidString,
                scheduledFor: formatter.string(from: eventDate),
                message: "Event '\(title)' successfully added to calendar"
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            if let data = try? encoder.encode(result), let json = String(data: data, encoding: .utf8) {
                return json
            }
            return #"{"success":true,"message":"Event added"}"#

        case "edit":
            guard let eventId = args.eventId, let eventUUID = UUID(uuidString: eventId) else {
                return #"{"error":"For action 'edit', event_id must be a valid UUID"}"#
            }

            var newDatetime: Date? = nil
            if let datetimeString = args.datetime {
                guard let parsed = parseISO8601Date(datetimeString) else {
                    return #"{"error":"Invalid datetime format. Use ISO 8601 (e.g., '2026-02-01T15:00:00+01:00')"}"#
                }
                newDatetime = parsed
            }

            let success = await CalendarService.shared.updateEvent(
                id: eventUUID,
                title: args.title,
                datetime: newDatetime,
                notes: args.notes
            )
            if success {
                return #"{"success":true,"message":"Event updated successfully"}"#
            }
            return #"{"error":"Event not found with the specified ID"}"#

        case "delete":
            guard let eventId = args.eventId, let eventUUID = UUID(uuidString: eventId) else {
                return #"{"error":"For action 'delete', event_id must be a valid UUID"}"#
            }

            let success = await CalendarService.shared.deleteEvent(id: eventUUID)
            if success {
                return #"{"success":true,"message":"Event deleted successfully"}"#
            }
            return #"{"error":"Event not found with the specified ID"}"#

        default:
            return #"{"error":"Invalid action. Supported actions: view, add, edit, delete"}"#
        }
    }
    
    // MARK: - Helpers
    
    private func parseISO8601Date(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    private func parseRecurrenceType(_ rawValue: String?) -> RecurrenceType? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !rawValue.isEmpty else {
            return nil
        }

        switch rawValue {
        case "daily":
            return .daily
        case "weekly":
            return .weekly
        case "monthly":
            return .monthly
        default:
            if rawValue.hasPrefix("every_") && rawValue.hasSuffix("_minutes") {
                let numberPart = rawValue
                    .replacingOccurrences(of: "every_", with: "")
                    .replacingOccurrences(of: "_minutes", with: "")
                if let minutes = Int(numberPart), minutes > 0 {
                    return .custom(minutes: minutes)
                }
            }
            return nil
        }
    }
    
    // MARK: - Conversation History Viewing
    
    private func executeViewConversationChunk(_ call: ToolCall) async -> String {
        // Parse arguments (chunk_id is now optional)
        var chunkIdStr: String? = nil
        if let argsData = call.function.arguments.data(using: .utf8),
           let args = try? JSONDecoder().decode(ViewConversationChunkArguments.self, from: argsData) {
            chunkIdStr = args.chunkId?.trimmingCharacters(in: .whitespaces)
        }
        
        // Get all chunks
        let allChunks = await archiveService.getAllChunks()
        
        // MODE 1: List all chunk summaries (when no chunk_id provided)
        if chunkIdStr == nil || chunkIdStr?.isEmpty == true {
            if allChunks.isEmpty {
                return "{\"success\": true, \"message\": \"No archived conversation chunks yet. Chunks are created as conversations grow.\"}"
            }
            
            let dateFormatter = DateFormatter()
            dateFormatter.dateStyle = .short
            dateFormatter.timeStyle = .short
            
            var output = """
            === ALL ARCHIVED CONVERSATION CHUNKS ===
            Total: \(allChunks.count) chunk(s)
            
            """
            
            for chunk in allChunks.sorted(by: { $0.startDate < $1.startDate }) {
                let shortId = String(chunk.id.uuidString.prefix(8))
                let dateRange = "\(dateFormatter.string(from: chunk.startDate)) - \(dateFormatter.string(from: chunk.endDate))"
                let typeLabel = chunk.type == .consolidated ? "CONSOLIDATED" : "TEMPORARY"
                
                output += """
                
                [\(shortId)] (\(typeLabel), \(chunk.sizeLabel))
                Period: \(dateRange)
                Messages: \(chunk.messageCount)
                Summary: \(chunk.summary)
                
                ---
                """
            }
            
            output += "\n\nTo view full messages from a chunk, call: view_conversation_chunk(chunk_id: \"<8-char ID>\")"
            
            return output
        }
        
        // MODE 2: View specific chunk content (when chunk_id is provided)
        do {
            guard let chunk = allChunks.first(where: { 
                $0.id.uuidString == chunkIdStr || 
                $0.id.uuidString.hasPrefix(chunkIdStr!) ||
                $0.id.uuidString.lowercased().hasPrefix(chunkIdStr!.lowercased())
            }) else {
                return "{\"error\": \"Chunk not found with ID: \(chunkIdStr!). Call view_conversation_chunk() without arguments to see all available chunks.\"}"
            }
            
            // Get the full chunk content
            let content = try await archiveService.getChunkContent(chunkId: chunk.id)
            
            // Format the date range for context
            let dateFormatter = DateFormatter()
            dateFormatter.dateStyle = .medium
            dateFormatter.timeStyle = .short
            
            let header = """
            === CHUNK DETAILS ===
            ID: \(chunk.id.uuidString)
            Type: \(chunk.sizeLabel) (\(chunk.type == .temporary ? "temporary" : "consolidated"))
            Period: \(dateFormatter.string(from: chunk.startDate)) to \(dateFormatter.string(from: chunk.endDate))
            Messages: \(chunk.messageCount)
            
            === CHUNK MESSAGES ===
            
            """
            
            return header + content
        } catch {
            return "{\"error\": \"Failed to load chunk: \(error.localizedDescription)\"}"
        }
    }
    
    // MARK: - User Context Management
    
    private let maxContextCharacters = 20000 // ~5000 tokens
    
    private func executeEditUserContext(_ call: ToolCall) async -> String {
        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(EditUserContextArguments.self, from: argsData) else {
            return #"{"error": "Failed to parse edit_user_context arguments"}"#
        }
        
        let existingContext = KeychainHelper.load(key: KeychainHelper.structuredUserContextKey) ?? ""
        let action = args.action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allMatches = args.allMatches ?? true
        let caseSensitive = args.caseSensitive ?? false
        var updatedContext = existingContext
        var changedCount = 0
        var actionMessage = ""

        switch action {
        case "append":
            let content = (args.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else {
                return #"{"error": "For action 'append', 'content' cannot be empty"}"#
            }
            updatedContext = existingContext.isEmpty ? content : existingContext + "\n" + content
            changedCount = 1
            actionMessage = "Appended content to user context"

        case "delete":
            let target = args.target ?? ""
            guard !target.isEmpty else {
                return #"{"error": "For action 'delete', 'target' cannot be empty"}"#
            }
            let replaceResult = replaceText(
                in: existingContext,
                target: target,
                replacement: "",
                replaceAll: allMatches,
                caseSensitive: caseSensitive
            )
            guard let result = replaceResult.result else {
                return #"{"error": "Failed to apply delete operation"}"#
            }
            updatedContext = result
            changedCount = replaceResult.matchCount
            actionMessage = changedCount == 0 ? "No matches found for delete target" : "Deleted \(changedCount) match(es) from user context"

        case "replace":
            let target = args.target ?? ""
            guard !target.isEmpty else {
                return #"{"error": "For action 'replace', 'target' cannot be empty"}"#
            }
            guard let replacement = args.replacement else {
                return #"{"error": "For action 'replace', 'replacement' is required"}"#
            }
            let replaceResult = replaceText(
                in: existingContext,
                target: target,
                replacement: replacement,
                replaceAll: allMatches,
                caseSensitive: caseSensitive
            )
            guard let result = replaceResult.result else {
                return #"{"error": "Failed to apply replace operation"}"#
            }
            updatedContext = result
            changedCount = replaceResult.matchCount
            actionMessage = changedCount == 0 ? "No matches found for replace target" : "Replaced \(changedCount) match(es) in user context"

        case "rewrite":
            guard let content = args.content else {
                return #"{"error": "For action 'rewrite', 'content' is required"}"#
            }
            updatedContext = content
            changedCount = 1
            actionMessage = "User context rewritten successfully"

        default:
            return #"{"error": "Invalid action. Supported actions: append, delete, replace, rewrite"}"#
        }

        var wasTruncated = false
        if updatedContext.count > maxContextCharacters {
            updatedContext = String(updatedContext.prefix(maxContextCharacters))
            wasTruncated = true
        }

        do {
            try KeychainHelper.save(key: KeychainHelper.structuredUserContextKey, value: updatedContext)

            let tokenEstimate = updatedContext.count / 4
            let remainingTokens = (maxContextCharacters - updatedContext.count) / 4
            var message = actionMessage
            if wasTruncated {
                message += ". Note: truncated to fit 5000 token limit."
            }

            return """
            {"success": true, "action": "\(action)", "message": "\(message)", "changed_count": \(changedCount), "current_tokens": \(tokenEstimate), "remaining_tokens": \(remainingTokens), "max_tokens": 5000}
            """
        } catch {
            return #"{"error": "Failed to save: \#(error.localizedDescription)"}"#
        }
    }

    private func replaceText(
        in text: String,
        target: String,
        replacement: String,
        replaceAll: Bool,
        caseSensitive: Bool
    ) -> (result: String?, matchCount: Int) {
        guard !target.isEmpty else { return (text, 0) }

        let pattern = NSRegularExpression.escapedPattern(for: target)
        let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return (nil, 0)
        }

        let fullRange = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, options: [], range: fullRange)
        guard !matches.isEmpty else { return (text, 0) }

        let template = NSRegularExpression.escapedTemplate(for: replacement)
        if replaceAll {
            let mutable = NSMutableString(string: text)
            regex.replaceMatches(in: mutable, options: [], range: NSRange(location: 0, length: mutable.length), withTemplate: template)
            return (mutable as String, matches.count)
        }

        let firstRange = matches[0].range
        let result = regex.stringByReplacingMatches(in: text, options: [], range: firstRange, withTemplate: template)
        return (result, 1)
    }
    
}

// MARK: - Tool Argument Types

private func normalizeRecipientList(_ recipients: [String]) -> [String] {
    var seen: Set<String> = []
    var normalized: [String] = []
    
    for recipient in recipients {
        let trimmed = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { continue }
        let key = trimmed.lowercased()
        guard seen.insert(key).inserted else { continue }
        normalized.append(trimmed)
    }
    
    return normalized
}

private func parseRecipientsFromString(_ value: String) -> [String] {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    
    if let data = trimmed.data(using: .utf8),
       let parsed = try? JSONDecoder().decode([String].self, from: data) {
        return normalizeRecipientList(parsed)
    }
    
    let split = trimmed.split(whereSeparator: { $0 == "," || $0 == ";" }).map(String.init)
    return normalizeRecipientList(split)
}

private func decodeRecipients<K: CodingKey>(from container: KeyedDecodingContainer<K>, forKey key: K) -> [String] {
    if let array = try? container.decodeIfPresent([String].self, forKey: key) {
        return normalizeRecipientList(array ?? [])
    }
    
    if let value = try? container.decode(String.self, forKey: key) {
        return parseRecipientsFromString(value)
    }
    
    return []
}

private func isLikelyValidEmailAddress(_ address: String) -> Bool {
    let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.contains("@") && trimmed.contains(".")
}

private func allEmailAddressesAreValid(_ addresses: [String]) -> Bool {
    addresses.allSatisfy { isLikelyValidEmailAddress($0) }
}

struct WebSearchArguments: Codable {
    let query: String
}

struct ManageRemindersArguments: Codable {
    let action: String
    let triggerDatetime: String?
    let prompt: String?
    let recurrence: String?
    let reminderId: String?
    let reminderIds: [String]?
    let deleteAll: Bool?
    let deleteRecurring: Bool?
    
    enum CodingKeys: String, CodingKey {
        case action
        case triggerDatetime = "trigger_datetime"
        case prompt
        case recurrence
        case reminderId = "reminder_id"
        case reminderIds = "reminder_ids"
        case deleteAll = "delete_all"
        case deleteRecurring = "delete_recurring"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        action = try container.decode(String.self, forKey: .action)
        triggerDatetime = try container.decodeIfPresent(String.self, forKey: .triggerDatetime)
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt)
        recurrence = try container.decodeIfPresent(String.self, forKey: .recurrence)
        reminderId = try container.decodeIfPresent(String.self, forKey: .reminderId)
        deleteAll = try container.decodeIfPresent(Bool.self, forKey: .deleteAll)
        deleteRecurring = try container.decodeIfPresent(Bool.self, forKey: .deleteRecurring)

        if let array = try? container.decodeIfPresent([String].self, forKey: .reminderIds) {
            reminderIds = array
        } else if let raw = (try? container.decodeIfPresent(String.self, forKey: .reminderIds))?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty {
            if let data = raw.data(using: .utf8),
               let parsed = try? JSONDecoder().decode([String].self, from: data) {
                reminderIds = parsed
            } else {
                let csv = raw
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                reminderIds = csv.isEmpty ? nil : csv
            }
        } else {
            reminderIds = nil
        }
    }
}

struct SetReminderResult: Codable {
    let success: Bool
    let reminderId: String
    let scheduledFor: String
    let message: String
}

struct EditUserContextArguments: Codable {
    let action: String
    let content: String?
    let target: String?
    let replacement: String?
    let allMatches: Bool?
    let caseSensitive: Bool?
    
    enum CodingKeys: String, CodingKey {
        case action
        case content
        case target
        case replacement
        case allMatches = "all_matches"
        case caseSensitive = "case_sensitive"
    }
}



// MARK: - Calendar Tool Argument Types

struct ManageCalendarArguments: Codable {
    let action: String
    let includePast: Bool?
    let eventId: String?
    let title: String?
    let datetime: String?
    let notes: String?
    
    enum CodingKeys: String, CodingKey {
        case action
        case includePast = "include_past"
        case eventId = "event_id"
        case title
        case datetime
        case notes
    }
}

// MARK: - Calendar Tool Result Types

struct CalendarEventResponse: Codable {
    let id: String
    let title: String
    let datetime: String
    let datetimeISO: String
    let notes: String?
    let isPast: Bool
}

struct ViewCalendarResult: Codable {
    let success: Bool
    let eventCount: Int
    let events: [CalendarEventResponse]
    let message: String
}

struct AddCalendarEventResult: Codable {
    let success: Bool
    let eventId: String
    let scheduledFor: String
    let message: String
}

// MARK: - Conversation History View Types

struct ViewConversationChunkArguments: Codable {
    let chunkId: String?
    
    enum CodingKeys: String, CodingKey {
        case chunkId = "chunk_id"
    }
}

// MARK: - Email Tool Types

struct ReadEmailsArguments: Codable {
    let count: Int?
}

struct ReadEmailsResult: Codable {
    let success: Bool
    let emailCount: Int
    let emails: [EmailMessage]
    let message: String
}

struct SearchEmailsArguments: Codable {
    let query: String?
    let from: String?
    let since: String?
    let before: String?
    let folder: String?
    let limit: Int?
}

struct SendEmailArguments: Codable {
    let to: String
    let subject: String
    let body: String
    let cc: [String]
    let bcc: [String]
    
    enum CodingKeys: String, CodingKey {
        case to, subject, body, cc, bcc
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        to = try container.decode(String.self, forKey: .to)
        subject = try container.decode(String.self, forKey: .subject)
        body = try container.decode(String.self, forKey: .body)
        cc = decodeRecipients(from: container, forKey: .cc)
        bcc = decodeRecipients(from: container, forKey: .bcc)
    }
}

struct SendEmailResult: Codable {
    let success: Bool
    let message: String
}

struct ReplyEmailArguments: Codable {
    let messageId: String
    let to: String
    let subject: String
    let body: String
    
    enum CodingKeys: String, CodingKey {
        case messageId = "message_id"
        case to, subject, body
    }
}

// MARK: - Email Tool Execution Extension

extension ToolExecutor {
    func executeReadEmails(_ call: ToolCall) async -> String {
        // Parse arguments (optional count) - default to 10
        var count = 10
        if let argsData = call.function.arguments.data(using: .utf8),
           let args = try? JSONDecoder().decode(ReadEmailsArguments.self, from: argsData),
           let argCount = args.count {
            count = min(max(argCount, 1), 20)
        }
        
        // Check if email is configured
        guard await EmailService.shared.isConfigured else {
            return "{\"error\": \"Email is not configured. Please add IMAP/SMTP settings in the app.\"}"
        }
        
        do {
            let emails = try await EmailService.shared.fetchEmails(count: count)
            
            // Update the cache with fresh data
            await EmailService.shared.updateCache(with: emails)
            
            let result = ReadEmailsResult(
                success: true,
                emailCount: emails.count,
                emails: emails,
                message: emails.isEmpty ? "No emails found" : "Found \(emails.count) email(s)"
            )
            
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            if let data = try? encoder.encode(result), let json = String(data: data, encoding: .utf8) {
                return json
            }
            return "{\"success\": true, \"emailCount\": \(emails.count)}"
        } catch {
            return "{\"error\": \"Failed to read emails: \(error.localizedDescription)\"}"
        }
    }
    
    func executeSearchEmails(_ call: ToolCall) async -> String {
        // Parse arguments
        var query: String? = nil
        var from: String? = nil
        var since: Date? = nil
        var before: Date? = nil
        var folder: String? = nil
        var limit = 10
        
        if let argsData = call.function.arguments.data(using: .utf8),
           let args = try? JSONDecoder().decode(SearchEmailsArguments.self, from: argsData) {
            query = args.query
            from = args.from
            folder = args.folder
            if let argLimit = args.limit {
                limit = min(max(argLimit, 1), 50)
            }
            
            // Parse date strings (YYYY-MM-DD format)
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd"
            dateFormatter.locale = Locale(identifier: "en_US_POSIX")
            
            if let sinceStr = args.since {
                since = dateFormatter.date(from: sinceStr)
            }
            if let beforeStr = args.before {
                before = dateFormatter.date(from: beforeStr)
            }
        }
        
        // Validate at least one search criteria (folder alone is valid for browsing)
        if query == nil && from == nil && since == nil && before == nil && folder == nil {
            return "{\"error\": \"At least one search criteria (query, from, since, before, or folder) is required.\"}"
        }
        
        // Check if email is configured
        guard await EmailService.shared.isConfigured else {
            return "{\"error\": \"Email is not configured. Please add IMAP/SMTP settings in the app.\"}"
        }
        
        do {
            let emails = try await EmailService.shared.searchEmails(
                query: query,
                from: from,
                since: since,
                before: before,
                folder: folder,
                limit: limit
            )
            
            let result = ReadEmailsResult(
                success: true,
                emailCount: emails.count,
                emails: emails,
                message: emails.isEmpty ? "No emails found matching the search criteria" : "Found \(emails.count) email(s) matching your search"
            )
            
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            if let data = try? encoder.encode(result), let json = String(data: data, encoding: .utf8) {
                return json
            }
            return "{\"success\": true, \"emailCount\": \(emails.count)}"
        } catch {
            return "{\"error\": \"Email search failed: \(error.localizedDescription)\"}"
        }
    }
    
    func executeSendEmail(_ call: ToolCall) async -> String {
        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(SendEmailArguments.self, from: argsData) else {
            return "{\"error\": \"Failed to parse send_email arguments\"}"
        }
        
        // Basic email validation
        guard isLikelyValidEmailAddress(args.to) else {
            return "{\"error\": \"Invalid email address format\"}"
        }
        
        guard allEmailAddressesAreValid(args.cc + args.bcc) else {
            return "{\"error\": \"Invalid cc or bcc email address format\"}"
        }
        
        // Check if email is configured
        guard await EmailService.shared.isConfigured else {
            return "{\"error\": \"Email is not configured. Please add IMAP/SMTP settings in the app.\"}"
        }
        
        do {
            let success = try await EmailService.shared.sendEmail(
                to: args.to,
                subject: args.subject,
                body: args.body,
                cc: args.cc,
                bcc: args.bcc
            )
            
            if success {
                let result = SendEmailResult(
                    success: true,
                    message: "Email sent successfully to \(args.to)"
                )
                
                let encoder = JSONEncoder()
                encoder.outputFormatting = .prettyPrinted
                if let data = try? encoder.encode(result), let json = String(data: data, encoding: .utf8) {
                    return json
                }
                return "{\"success\": true, \"message\": \"Email sent\"}"
            } else {
                return "{\"error\": \"Failed to send email\"}"
            }
        } catch {
            return "{\"error\": \"Failed to send email: \(error.localizedDescription)\"}"
        }
    }
    
    func executeReplyEmail(_ call: ToolCall) async -> String {
        print("[ToolExecutor] executeReplyEmail called with arguments: \(call.function.arguments)")
        
        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(ReplyEmailArguments.self, from: argsData) else {
            print("[ToolExecutor] Failed to parse reply_email arguments")
            return "{\"error\": \"Failed to parse reply_email arguments\"}"
        }
        
        print("[ToolExecutor] Parsed args - to: \(args.to), subject: \(args.subject), messageId: \(args.messageId)")
        
        // Basic email validation
        guard args.to.contains("@") && args.to.contains(".") else {
            print("[ToolExecutor] Invalid email address: \(args.to)")
            return "{\"error\": \"Invalid email address format\"}"
        }
        
        // Validate message_id format (should be <...>)
        guard args.messageId.hasPrefix("<") && args.messageId.hasSuffix(">") else {
            print("[ToolExecutor] Invalid message_id format: \(args.messageId)")
            return "{\"error\": \"Invalid message_id format. Must be in format <id@domain>\"}"
        }
        
        // Check if email is configured
        guard await EmailService.shared.isConfigured else {
            print("[ToolExecutor] Email not configured")
            return "{\"error\": \"Email is not configured. Please add IMAP/SMTP settings in the app.\"}"
        }
        
        print("[ToolExecutor] Calling EmailService.replyToEmail...")
        
        do {
            let success = try await EmailService.shared.replyToEmail(
                inReplyTo: args.messageId,
                references: nil,  // For single-level replies, In-Reply-To is sufficient
                to: args.to,
                subject: args.subject,
                body: args.body
            )
            
            print("[ToolExecutor] EmailService.replyToEmail returned: \(success)")
            
            if success {
                let result = SendEmailResult(
                    success: true,
                    message: "Reply sent successfully to \(args.to) (threaded with original email)"
                )
                
                let encoder = JSONEncoder()
                encoder.outputFormatting = .prettyPrinted
                if let data = try? encoder.encode(result), let json = String(data: data, encoding: .utf8) {
                    print("[ToolExecutor] Reply email success, returning result")
                    return json
                }
                return "{\"success\": true, \"message\": \"Reply sent\"}"
            } else {
                print("[ToolExecutor] EmailService.replyToEmail returned false")
                return "{\"error\": \"Failed to send reply\"}"
            }
        } catch {
            print("[ToolExecutor] EmailService.replyToEmail threw error: \(error)")
            return "{\"error\": \"Failed to send reply: \(error.localizedDescription)\"}"
        }
    }
    
    func executeForwardEmail(_ call: ToolCall) async -> String {
        print("[ToolExecutor] executeForwardEmail called with arguments: \(call.function.arguments)")
        
        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(ForwardEmailArguments.self, from: argsData) else {
            print("[ToolExecutor] Failed to parse forward_email arguments")
            return "{\"error\": \"Failed to parse forward_email arguments\"}"
        }
        
        print("[ToolExecutor] Parsed args - to: \(args.to), emailUid: \(args.emailUid), originalSubject: \(args.originalSubject)")
        
        // Basic email validation
        guard args.to.contains("@") && args.to.contains(".") else {
            print("[ToolExecutor] Invalid email address: \(args.to)")
            return "{\"error\": \"Invalid email address format\"}"
        }
        
        // Check if email is configured
        guard await EmailService.shared.isConfigured else {
            print("[ToolExecutor] Email not configured")
            return "{\"error\": \"Email is not configured. Please add IMAP/SMTP settings in the app.\"}"
        }
        
        // Fetch the original email to get attachments info
        print("[ToolExecutor] Fetching original email to check for attachments...")
        var attachments: [EmailService.ForwardAttachment] = []
        
        do {
            let emails = try await EmailService.shared.fetchFullEmailsByUID([args.emailUid])
            if let email = emails.first, !email.attachments.isEmpty {
                print("[ToolExecutor] Found \(email.attachments.count) attachment(s) to forward - downloading in batch...")
                
                // Create a map from partId to correct filename/mimeType from the original attachment list
                var attachmentInfo: [String: (filename: String, mimeType: String)] = [:]
                for attachment in email.attachments {
                    attachmentInfo[attachment.partId] = (filename: attachment.filename, mimeType: attachment.mimeType)
                }
                
                // Get all part IDs for batch download
                let partIds = email.attachments.map { $0.partId }
                
                // Download ALL attachments in a SINGLE IMAP session (much faster!)
                let results = try await EmailService.shared.downloadAllAttachments(
                    emailUid: args.emailUid,
                    partIds: partIds
                )
                
                // Convert to ForwardAttachment format, using correct filenames
                for result in results {
                    let info = attachmentInfo[result.partId]
                    let correctFilename = info?.filename ?? result.filename
                    let correctMimeType = info?.mimeType ?? result.mimeType
                    
                    attachments.append(EmailService.ForwardAttachment(
                        data: result.data,
                        filename: correctFilename,
                        mimeType: correctMimeType
                    ))
                    print("[ToolExecutor] Downloaded attachment: \(correctFilename) (\(correctMimeType), \(result.data.count) bytes)")
                }
                
                print("[ToolExecutor] Successfully downloaded \(attachments.count) of \(email.attachments.count) attachment(s)")
            } else {
                print("[ToolExecutor] No attachments found in original email")
            }
        } catch {
            print("[ToolExecutor] Warning: Could not fetch original email for attachments: \(error)")
            // Continue anyway - we'll forward without attachments
        }
        
        print("[ToolExecutor] Calling EmailService.forwardEmailWithAttachments with \(attachments.count) attachment(s)...")
        
        do {
            let success = try await EmailService.shared.forwardEmailWithAttachments(
                to: args.to,
                originalFrom: args.originalFrom,
                originalDate: args.originalDate,
                originalSubject: args.originalSubject,
                originalBody: args.originalBody,
                comment: args.comment,
                attachments: attachments
            )
            
            print("[ToolExecutor] EmailService.forwardEmailWithAttachments returned: \(success)")
            
            if success {
                let attachmentInfo = attachments.isEmpty 
                    ? "" 
                    : " including \(attachments.count) attachment(s)"
                let result = SendEmailResult(
                    success: true,
                    message: "Email forwarded successfully to \(args.to)\(attachmentInfo)"
                )
                
                let encoder = JSONEncoder()
                encoder.outputFormatting = .prettyPrinted
                if let data = try? encoder.encode(result), let json = String(data: data, encoding: .utf8) {
                    print("[ToolExecutor] Forward email success")
                    return json
                }
                return "{\"success\": true, \"message\": \"Email forwarded with attachments\"}"
            } else {
                print("[ToolExecutor] EmailService.forwardEmailWithAttachments returned false")
                return "{\"error\": \"Failed to forward email\"}"
            }
        } catch {
            print("[ToolExecutor] EmailService.forwardEmailWithAttachments threw error: \(error)")
            return "{\"error\": \"Failed to forward email: \(error.localizedDescription)\"}"
        }
    }
}

struct ForwardEmailArguments: Codable {
    let to: String
    let emailUid: String
    let originalFrom: String
    let originalDate: String
    let originalSubject: String
    let originalBody: String
    let comment: String?
    
    enum CodingKeys: String, CodingKey {
        case to
        case emailUid = "email_uid"
        case originalFrom = "original_from"
        case originalDate = "original_date"
        case originalSubject = "original_subject"
        case originalBody = "original_body"
        case comment
    }
}

// MARK: - Document Tool Types

struct ListDocumentsArguments: Codable {
    let limit: Int?
    let cursor: String?
    
    enum CodingKeys: String, CodingKey {
        case limit
        case cursor
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        if let intLimit = try? container.decodeIfPresent(Int.self, forKey: .limit) {
            limit = intLimit
        } else if let stringLimit = try? container.decodeIfPresent(String.self, forKey: .limit),
                  let parsed = Int(stringLimit.trimmingCharacters(in: .whitespacesAndNewlines)) {
            limit = parsed
        } else {
            limit = nil
        }
        
        if let stringCursor = try? container.decodeIfPresent(String.self, forKey: .cursor) {
            cursor = stringCursor
        } else if let intCursor = try? container.decodeIfPresent(Int.self, forKey: .cursor) {
            cursor = String(intCursor)
        } else {
            cursor = nil
        }
    }
}

struct ListDocumentsResult: Codable {
    let success: Bool
    let documentCount: Int
    let returnedCount: Int
    let hasMore: Bool
    let nextCursor: String?
    let order: String
    let cursorUsed: String?
    let documents: [DocumentInfo]
    let message: String
    
    enum CodingKeys: String, CodingKey {
        case success
        case documentCount
        case returnedCount = "returned_count"
        case hasMore = "has_more"
        case nextCursor = "next_cursor"
        case order
        case cursorUsed = "cursor_used"
        case documents
        case message
    }
}

struct DocumentInfo: Codable {
    let filename: String
    let sizeKB: Int
    let type: String
    let createdAt: String
    let lastOpenedAt: String?
    let createdAtSource: String
    
    enum CodingKeys: String, CodingKey {
        case filename
        case sizeKB
        case type
        case createdAt = "created_at"
        case lastOpenedAt = "last_opened_at"
        case createdAtSource = "created_at_source"
    }
}

struct SendEmailWithAttachmentArguments: Codable {
    let to: String
    let subject: String
    let body: String
    let cc: [String]
    let bcc: [String]
    let documentFilenames: [String]
    
    enum CodingKeys: String, CodingKey {
        case to, subject, body, cc, bcc
        case documentFilenames = "document_filenames"
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        to = try container.decode(String.self, forKey: .to)
        subject = try container.decode(String.self, forKey: .subject)
        body = try container.decode(String.self, forKey: .body)
        cc = decodeRecipients(from: container, forKey: .cc)
        bcc = decodeRecipients(from: container, forKey: .bcc)
        
        // Handle documentFilenames as either an array or a JSON string
        if let array = try? container.decode([String].self, forKey: .documentFilenames) {
            documentFilenames = array
        } else if let jsonString = try? container.decode(String.self, forKey: .documentFilenames),
                  let data = jsonString.data(using: .utf8),
                  let parsed = try? JSONDecoder().decode([String].self, from: data) {
            documentFilenames = parsed
        } else {
            throw DecodingError.dataCorruptedError(forKey: .documentFilenames, in: container, debugDescription: "document_filenames must be a JSON array of strings")
        }
    }
}

struct ReadDocumentArguments: Decodable {
    let documentFilenames: [String]
    
    enum CodingKeys: String, CodingKey {
        case documentFilename = "document_filename"
        case documentFilenames = "document_filenames"
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        let parsedFilenames: [String]
        if let array = try? container.decode([String].self, forKey: .documentFilenames) {
            parsedFilenames = array
        } else if let raw = (try? container.decode(String.self, forKey: .documentFilenames))?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty {
            if let data = raw.data(using: .utf8),
               let parsed = try? JSONDecoder().decode([String].self, from: data) {
                parsedFilenames = parsed
            } else {
                parsedFilenames = raw
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
        } else if let singleFilename = try? container.decode(String.self, forKey: .documentFilename) {
            parsedFilenames = [singleFilename]
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .documentFilenames,
                in: container,
                debugDescription: "Provide document_filenames (array/JSON array string/CSV) or legacy document_filename"
            )
        }
        
        let normalized = parsedFilenames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        var seen: Set<String> = []
        let deduplicated = normalized.filter { seen.insert($0).inserted }
        
        guard !deduplicated.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .documentFilenames,
                in: container,
                debugDescription: "No document filenames provided"
            )
        }
        
        documentFilenames = deduplicated
    }
}

struct ReadDocumentItemResult: Codable {
    let filename: String
    let mimeType: String
    let sizeBytes: Int
    let message: String
    
    enum CodingKeys: String, CodingKey {
        case filename
        case mimeType
        case sizeBytes
        case message
    }
}

struct ReadDocumentResult: Codable {
    let success: Bool
    let loadedCount: Int
    let maxDocumentsPerCall: Int
    let documents: [ReadDocumentItemResult]
    let message: String
    
    enum CodingKeys: String, CodingKey {
        case success
        case loadedCount
        case maxDocumentsPerCall = "max_documents_per_call"
        case documents
        case message
    }
}

// MARK: - Document Tool Execution Extension

extension ToolExecutor {
    private var documentsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport.appendingPathComponent("TelegramConcierge/documents", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private var documentsLastOpenedIndexURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport.appendingPathComponent("TelegramConcierge", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("documents_last_opened.json")
    }

    private func loadDocumentsLastOpenedIndex() -> [String: Int64] {
        guard let data = try? Data(contentsOf: documentsLastOpenedIndexURL) else { return [:] }
        return (try? JSONDecoder().decode([String: Int64].self, from: data)) ?? [:]
    }

    private func saveDocumentsLastOpenedIndex(_ index: [String: Int64]) {
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: documentsLastOpenedIndexURL, options: .atomic)
    }

    private func recordDocumentOpened(filename: String, openedAt: Date = Date()) {
        var index = loadDocumentsLastOpenedIndex()
        index[filename] = Int64((openedAt.timeIntervalSince1970 * 1000.0).rounded())
        saveDocumentsLastOpenedIndex(index)
    }
    
    func executeListDocuments(_ call: ToolCall) async -> String {
        let fileManager = FileManager.default
        let defaultLimit = 40
        let maxLimit = 100
        
        var limit = defaultLimit
        var pageOffset = 0
        var cursorUsed: String?
        
        let rawArguments = call.function.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rawArguments.isEmpty && rawArguments != "{}" {
            guard let argsData = rawArguments.data(using: .utf8),
                  let args = try? JSONDecoder().decode(ListDocumentsArguments.self, from: argsData) else {
                return "{\"error\": \"Failed to parse list_documents arguments\"}"
            }
            
            if let requestedLimit = args.limit {
                limit = min(max(requestedLimit, 1), maxLimit)
            }
            
            if let rawCursor = args.cursor?.trimmingCharacters(in: .whitespacesAndNewlines), !rawCursor.isEmpty {
                guard let parsedOffset = parseListDocumentsCursor(rawCursor) else {
                    return "{\"error\": \"Invalid cursor '\(rawCursor)'. Use next_cursor from the previous list_documents response.\"}"
                }
                pageOffset = parsedOffset
                cursorUsed = rawCursor
            }
        }
        
        do {
            let files = try fileManager.contentsOfDirectory(
                at: documentsDirectory,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey]
            )
            var lastOpenedByFilename = loadDocumentsLastOpenedIndex()
            
            struct IndexedDocument {
                let info: DocumentInfo
                let sortDate: Date
                let hasLastOpened: Bool
            }
            
            let isoFormatter = ISO8601DateFormatter()
            isoFormatter.timeZone = TimeZone(secondsFromGMT: 0)
            isoFormatter.formatOptions = [.withInternetDateTime]
            
            var indexedDocuments: [IndexedDocument] = []
            for file in files {
                // Skip hidden files
                guard !file.lastPathComponent.hasPrefix(".") else { continue }
                
                let resourceValues = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey])
                if let isRegularFile = resourceValues?.isRegularFile, !isRegularFile {
                    continue
                }
                
                let attrs = try? fileManager.attributesOfItem(atPath: file.path)
                let size = resourceValues?.fileSize ?? (attrs?[.size] as? Int) ?? 0
                let sizeKB = size / 1024
                let ext = file.pathExtension.lowercased()
                
                let createdAt = resourceValues?.creationDate ?? (attrs?[.creationDate] as? Date)
                let modifiedAt = resourceValues?.contentModificationDate ?? (attrs?[.modificationDate] as? Date)
                let epoch = Date(timeIntervalSince1970: 0)
                
                let createdAtEffective: Date
                let createdAtSource: String
                if let createdAt {
                    createdAtEffective = createdAt
                    createdAtSource = "creation_date"
                } else if let modifiedAt {
                    createdAtEffective = modifiedAt
                    createdAtSource = "modification_date"
                } else {
                    createdAtEffective = epoch
                    createdAtSource = "epoch_fallback"
                }
                
                let lastOpenedUnixMs = lastOpenedByFilename[file.lastPathComponent]
                let lastOpenedDate = lastOpenedUnixMs.map { Date(timeIntervalSince1970: Double($0) / 1000.0) }
                
                let documentInfo = DocumentInfo(
                    filename: file.lastPathComponent,
                    sizeKB: sizeKB,
                    type: ext.isEmpty ? "unknown" : ext,
                    createdAt: isoFormatter.string(from: createdAtEffective),
                    lastOpenedAt: lastOpenedDate.map { isoFormatter.string(from: $0) },
                    createdAtSource: createdAtSource
                )
                
                indexedDocuments.append(
                    IndexedDocument(
                        info: documentInfo,
                        sortDate: lastOpenedDate ?? createdAtEffective,
                        hasLastOpened: lastOpenedDate != nil
                    )
                )
            }
            
            let knownFilenames = Set(indexedDocuments.map(\.info.filename))
            let cleanedIndex = lastOpenedByFilename.filter { knownFilenames.contains($0.key) }
            if cleanedIndex.count != lastOpenedByFilename.count {
                lastOpenedByFilename = cleanedIndex
                saveDocumentsLastOpenedIndex(cleanedIndex)
            }
            
            indexedDocuments.sort { lhs, rhs in
                if lhs.hasLastOpened != rhs.hasLastOpened {
                    return lhs.hasLastOpened
                }
                if lhs.sortDate != rhs.sortDate {
                    return lhs.sortDate > rhs.sortDate
                }
                return lhs.info.filename.localizedCaseInsensitiveCompare(rhs.info.filename) == .orderedAscending
            }
            
            let totalDocuments = indexedDocuments.count
            let start = min(max(pageOffset, 0), totalDocuments)
            let end = min(start + limit, totalDocuments)
            let pageDocuments = Array(indexedDocuments[start..<end]).map(\.info)
            let hasMore = end < totalDocuments
            let nextCursor = hasMore ? String(end) : nil
            
            let message: String
            if totalDocuments == 0 {
                message = "No documents found"
            } else if pageDocuments.isEmpty {
                message = "No documents found for cursor \(pageOffset). Use a smaller cursor to see available pages."
            } else if let nextCursor {
                message = "Showing \(pageDocuments.count) of \(totalDocuments) documents (most recently opened first; fallback newest created). Use cursor '\(nextCursor)' for the next page."
            } else {
                message = "Showing \(pageDocuments.count) of \(totalDocuments) documents (most recently opened first; fallback newest created). Reached the end of history."
            }
            
            let result = ListDocumentsResult(
                success: true,
                documentCount: totalDocuments,
                returnedCount: pageDocuments.count,
                hasMore: hasMore,
                nextCursor: nextCursor,
                order: "last_opened_desc_then_created_at_desc",
                cursorUsed: cursorUsed,
                documents: pageDocuments,
                message: message
            )
            
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            if let data = try? encoder.encode(result), let json = String(data: data, encoding: .utf8) {
                return json
            }
            return "{\"success\": true, \"documentCount\": \(totalDocuments)}"
        } catch {
            return "{\"error\": \"Failed to list documents: \(error.localizedDescription)\"}"
        }
    }

    private func parseListDocumentsCursor(_ cursor: String) -> Int? {
        let trimmed = cursor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        
        if let offset = Int(trimmed), offset >= 0 {
            return offset
        }
        
        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("offset:") {
            let value = trimmed.dropFirst("offset:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            if let offset = Int(value), offset >= 0 {
                return offset
            }
        }
        
        return nil
    }
    
    func executeReadDocument(_ call: ToolCall) async -> ToolResultMessage {
        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(ReadDocumentArguments.self, from: argsData) else {
            return ToolResultMessage(toolCallId: call.id, content: "{\"error\": \"Failed to parse read_document arguments\"}")
        }
        
        let maxDocumentsPerCall = 10
        if args.documentFilenames.count > maxDocumentsPerCall {
            return ToolResultMessage(
                toolCallId: call.id,
                content: "{\"error\": \"read_document accepts at most \(maxDocumentsPerCall) files per call. Received \(args.documentFilenames.count).\"}"
            )
        }
        
        var fileAttachments: [FileAttachment] = []
        var documents: [ReadDocumentItemResult] = []
        
        for filename in args.documentFilenames {
            let documentURL = documentsDirectory.appendingPathComponent(filename)
            guard FileManager.default.fileExists(atPath: documentURL.path) else {
                return ToolResultMessage(toolCallId: call.id, content: "{\"error\": \"Document not found: \(filename). Use list_documents to see available files.\"}")
            }
            
            do {
                let data = try Data(contentsOf: documentURL)
                recordDocumentOpened(filename: filename)
                
                let mimeType = getMimeType(for: filename)
                fileAttachments.append(FileAttachment(data: data, mimeType: mimeType, filename: filename))
                
                let visibilityMessage: String
                if isInlineMimeTypeSupportedForLLM(mimeType) {
                    visibilityMessage = "Document loaded and visible. You can now analyze its contents."
                } else if mimeType == "application/zip" || filename.lowercased().hasSuffix(".zip") {
                    visibilityMessage = "Document loaded but not viewable inline. Import it into a project with add_project_files to extract and use its contents."
                } else {
                    visibilityMessage = "Document loaded but not viewable inline in this model."
                }
                
                documents.append(
                    ReadDocumentItemResult(
                        filename: filename,
                        mimeType: mimeType,
                        sizeBytes: data.count,
                        message: visibilityMessage
                    )
                )
            } catch {
                return ToolResultMessage(toolCallId: call.id, content: "{\"error\": \"Failed to read document '\(filename)': \(error.localizedDescription)\"}")
            }
        }
        
        let response = ReadDocumentResult(
            success: true,
            loadedCount: documents.count,
            maxDocumentsPerCall: maxDocumentsPerCall,
            documents: documents,
            message: documents.count == 1
                ? "Loaded 1 document."
                : "Loaded \(documents.count) documents."
        )
        
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(response),
           let json = String(data: data, encoding: .utf8) {
            return ToolResultMessage(toolCallId: call.id, content: json, fileAttachments: fileAttachments)
        }
        
        return ToolResultMessage(
            toolCallId: call.id,
            content: "{\"success\": true, \"loadedCount\": \(documents.count), \"max_documents_per_call\": \(maxDocumentsPerCall)}",
            fileAttachments: fileAttachments
        )
    }
    
    func executeSendEmailWithAttachment(_ call: ToolCall) async -> String {
        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(SendEmailWithAttachmentArguments.self, from: argsData) else {
            return "{\"error\": \"Failed to parse send_email_with_attachment arguments\"}"
        }
        
        // Basic email validation
        guard isLikelyValidEmailAddress(args.to) else {
            return "{\"error\": \"Invalid email address format\"}"
        }
        
        guard allEmailAddressesAreValid(args.cc + args.bcc) else {
            return "{\"error\": \"Invalid cc or bcc email address format\"}"
        }
        
        // Check if email is configured
        guard await EmailService.shared.isConfigured else {
            return "{\"error\": \"Email is not configured. Please add IMAP/SMTP settings in the app.\"}"
        }
        
        // Load all attachment files
        var attachments: [(url: URL, name: String)] = []
        for filename in args.documentFilenames {
            let documentURL = documentsDirectory.appendingPathComponent(filename)
            guard FileManager.default.fileExists(atPath: documentURL.path) else {
                return "{\"error\": \"Document not found: \(filename). Use list_documents to see available files.\"}"
            }
            attachments.append((url: documentURL, name: filename))
        }
        
        guard !attachments.isEmpty else {
            return "{\"error\": \"No documents specified. Use list_documents to see available files.\"}"
        }
        
        do {
            let success = try await EmailService.shared.sendEmailWithAttachments(
                to: args.to,
                subject: args.subject,
                body: args.body,
                cc: args.cc,
                bcc: args.bcc,
                attachments: attachments
            )
            
            if success {
                for filename in args.documentFilenames {
                    recordDocumentOpened(filename: filename)
                }
                let filenames = args.documentFilenames.joined(separator: ", ")
                let result = SendEmailResult(
                    success: true,
                    message: "Email with \(attachments.count) attachment(s) (\(filenames)) sent successfully to \(args.to)"
                )
                
                let encoder = JSONEncoder()
                encoder.outputFormatting = .prettyPrinted
                if let data = try? encoder.encode(result), let json = String(data: data, encoding: .utf8) {
                    return json
                }
                return "{\"success\": true, \"message\": \"Email with attachments sent\"}"
            } else {
                return "{\"error\": \"Failed to send email with attachments\"}"
            }
        } catch {
            return "{\"error\": \"Failed to send email with attachments: \(error.localizedDescription)\"}"
        }
    }
    
    func executeDownloadEmailAttachment(_ call: ToolCall) async -> ToolResultMessage {
        print("[ToolExecutor] executeDownloadEmailAttachment called with arguments: \(call.function.arguments)")
        
        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(DownloadEmailAttachmentArguments.self, from: argsData) else {
            print("[ToolExecutor] Failed to parse download_email_attachment arguments")
            return ToolResultMessage(toolCallId: call.id, content: "{\"error\": \"Failed to parse download_email_attachment arguments\"}")
        }
        
        // Check if email is configured
        guard await EmailService.shared.isConfigured else {
            return ToolResultMessage(toolCallId: call.id, content: "{\"error\": \"Email is not configured. Please add IMAP/SMTP settings in the app.\"}")
        }
        
        // Handle download_all mode (batch download with multimodal injection)
        if args.downloadAll == true {
            print("[ToolExecutor] Batch downloading all attachments for email UID: \(args.emailUid)")
            return await downloadAllAttachments(emailUid: args.emailUid, toolCallId: call.id)
        }
        
        // Single attachment download
        guard let partId = args.partId else {
            return ToolResultMessage(toolCallId: call.id, content: "{\"error\": \"Either part_id or download_all=true must be provided\"}")
        }
        
        print("[ToolExecutor] Parsed args - email_uid: \(args.emailUid), part_id: \(partId)")
        
        do {
            let result = try await EmailService.shared.downloadAttachment(
                emailUid: args.emailUid,
                partId: partId
            )
            
            print("[ToolExecutor] Downloaded attachment: \(result.filename) (\(result.mimeType), \(result.data.count) bytes)")
            
            // Save to documents folder
            let savedFilename = await saveAttachmentToDocuments(data: result.data, filename: result.filename, mimeType: result.mimeType)
            
            // Create file attachment for multimodal injection (just like read_document)
            let attachment = FileAttachment(data: result.data, mimeType: result.mimeType, filename: savedFilename)
            
            // Queue for description generation after agentic loop completes
            ToolExecutor.queueFileForDescription(filename: savedFilename, data: result.data, mimeType: result.mimeType)
            
            // Result text (no base64 needed - file will be injected as multimodal content)
            let visibilityMessage: String
            if isInlineMimeTypeSupportedForLLM(result.mimeType) {
                visibilityMessage = "Attachment '\(result.filename)' downloaded and visible. You can now analyze its contents directly."
            } else if result.mimeType == "application/zip" || result.filename.lowercased().hasSuffix(".zip") {
                visibilityMessage = "Attachment '\(result.filename)' downloaded. ZIP files are not viewable inline; import with add_project_files to extract into a project."
            } else {
                visibilityMessage = "Attachment '\(result.filename)' downloaded but not viewable inline in this model."
            }
            let resultJson = """
            {"success": true, "filename": "\(result.filename)", "mimeType": "\(result.mimeType)", "sizeBytes": \(result.data.count), "savedFilename": "\(savedFilename)", "message": "\(visibilityMessage)"}
            """
            
            return ToolResultMessage(toolCallId: call.id, content: resultJson, fileAttachment: attachment)
        } catch {
            print("[ToolExecutor] Error downloading attachment: \(error)")
            return ToolResultMessage(toolCallId: call.id, content: "{\"error\": \"Failed to download attachment: \(error.localizedDescription)\"}")
        }
    }
    
    /// Download all attachments from an email and return with multimodal injection
    private func downloadAllAttachments(emailUid: String, toolCallId: String) async -> ToolResultMessage {
        do {
            // First, fetch the email to get attachment list
            let emails = try await EmailService.shared.fetchFullEmailsByUID([emailUid])
            
            guard let email = emails.first else {
                return ToolResultMessage(toolCallId: toolCallId, content: "{\"error\": \"Email not found with UID \(emailUid)\"}")
            }
            
            guard !email.attachments.isEmpty else {
                return ToolResultMessage(toolCallId: toolCallId, content: "{\"error\": \"No attachments found in this email\"}")
            }
            
            // Create a map from partId to correct filename/mimeType from the original attachment list
            // This is more reliable than parsing from BODYSTRUCTURE which can be buggy
            var attachmentInfo: [String: (filename: String, mimeType: String)] = [:]
            for attachment in email.attachments {
                attachmentInfo[attachment.partId] = (filename: attachment.filename, mimeType: attachment.mimeType)
            }
            
            // Get all part IDs for batch download
            let partIds = email.attachments.map { $0.partId }
            
            // Download ALL attachments in a SINGLE IMAP session (much faster!)
            let results = try await EmailService.shared.downloadAllAttachments(
                emailUid: emailUid,
                partIds: partIds
            )
            
            var downloadedFiles: [BatchAttachmentResult] = []
            var fileAttachments: [FileAttachment] = []
            var errors: [String] = []
            
            // Process downloaded attachments
            for result in results {
                // Use the original filename from the attachment list, not from the download response
                let info = attachmentInfo[result.partId]
                let correctFilename = info?.filename ?? result.filename
                let correctMimeType = info?.mimeType ?? result.mimeType
                
                let savedFilename = await saveAttachmentToDocuments(
                    data: result.data,
                    filename: correctFilename,
                    mimeType: correctMimeType
                )
                
                downloadedFiles.append(BatchAttachmentResult(
                    filename: correctFilename,
                    mimeType: correctMimeType,
                    sizeBytes: result.data.count,
                    savedFilename: savedFilename
                ))
                
                // Create file attachment for multimodal injection
                fileAttachments.append(FileAttachment(
                    data: result.data,
                    mimeType: correctMimeType,
                    filename: savedFilename
                ))
                
                // Queue for description generation after agentic loop completes
                ToolExecutor.queueFileForDescription(filename: savedFilename, data: result.data, mimeType: correctMimeType)
                
                print("[ToolExecutor] Downloaded attachment: \(correctFilename) -> \(savedFilename)")
            }
            
            // Track any attachments that failed (weren't in results)
            let downloadedPartIds = Set(results.map { $0.partId })
            for attachment in email.attachments where !downloadedPartIds.contains(attachment.partId) {
                errors.append("\(attachment.filename): Failed to download")
                print("[ToolExecutor] Failed to download attachment \(attachment.filename) (partId: \(attachment.partId))")
            }
            
            let inlineVisibleCount = downloadedFiles.filter { isInlineMimeTypeSupportedForLLM($0.mimeType) }.count
            let responseMessage: String
            if downloadedFiles.isEmpty {
                responseMessage = "Failed to download attachments"
            } else if inlineVisibleCount == downloadedFiles.count {
                responseMessage = "Downloaded \(downloadedFiles.count) of \(email.attachments.count) attachments. All files are now visible for analysis."
            } else if inlineVisibleCount == 0 {
                responseMessage = "Downloaded \(downloadedFiles.count) of \(email.attachments.count) attachments. Files are saved locally but not viewable inline; use project tools for ZIP/binary workflows."
            } else {
                responseMessage = "Downloaded \(downloadedFiles.count) of \(email.attachments.count) attachments. \(inlineVisibleCount) file(s) are visible inline; others are saved locally for project import."
            }
            
            let response = BatchDownloadResult(
                success: !downloadedFiles.isEmpty,
                totalAttachments: email.attachments.count,
                downloadedCount: downloadedFiles.count,
                files: downloadedFiles,
                errors: errors.isEmpty ? nil : errors,
                message: responseMessage
            )
            
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            if let data = try? encoder.encode(response), let json = String(data: data, encoding: .utf8) {
                return ToolResultMessage(toolCallId: toolCallId, content: json, fileAttachments: fileAttachments)
            }
            
            return ToolResultMessage(toolCallId: toolCallId, content: "{\"success\": true, \"downloadedCount\": \(downloadedFiles.count)}", fileAttachments: fileAttachments)
        } catch {
            print("[ToolExecutor] Error in batch download: \(error)")
            return ToolResultMessage(toolCallId: toolCallId, content: "{\"error\": \"Failed to fetch email attachments: \(error.localizedDescription)\"}")
        }
    }
    
    /// Save attachment to documents folder
    private func saveAttachmentToDocuments(data: Data, filename: String, mimeType: String) async -> String {
        let fileManager = FileManager.default
        
        // Sanitize filename
        var safeFilename = filename.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        
        // Ensure unique filename
        var finalFilename = safeFilename
        var counter = 1
        while fileManager.fileExists(atPath: documentsDirectory.appendingPathComponent(finalFilename).path) {
            let ext = (safeFilename as NSString).pathExtension
            let name = (safeFilename as NSString).deletingPathExtension
            finalFilename = "\(name)_\(counter).\(ext)"
            counter += 1
        }
        
        let fileURL = documentsDirectory.appendingPathComponent(finalFilename)
        
        do {
            try data.write(to: fileURL)
            print("[ToolExecutor] Saved attachment to: \(fileURL.path)")
            
            // Also save to images directory if it's an image
            if mimeType.hasPrefix("image/") {
                let imagesURL = imagesDirectory.appendingPathComponent(finalFilename)
                try? data.write(to: imagesURL)
            }
            
            return finalFilename
        } catch {
            print("[ToolExecutor] Failed to save attachment: \(error)")
            return filename
        }
    }
    
    // MARK: - Gmail API Tool Implementations
    
    private func executeGmailQuery(_ call: ToolCall) async -> String {
        guard await GmailService.shared.isAuthenticated else {
            return #"{"error": "Gmail not authenticated. Please set up Gmail API in Settings and complete OAuth authentication."}"#
        }
        
        var query: String? = nil
        var limit: Int = 10
        
        if let argsData = call.function.arguments.data(using: .utf8),
           let args = try? JSONDecoder().decode(GmailQueryArguments.self, from: argsData) {
            query = args.query
            limit = args.limit ?? 10
        }
        
        do {
            let emails = try await GmailService.shared.queryEmails(query: query, limit: limit)
            
            // Format response for LLM
            var response = "Found \(emails.count) email(s)"
            if let q = query, !q.isEmpty {
                response += " matching '\(q)'"
            }
            response += ":\n\n"
            
            for email in emails {
                let from = email.getHeader("From") ?? "Unknown"
                let subject = email.getHeader("Subject") ?? "(No subject)"
                let date = email.getHeader("Date") ?? ""
                let snippet = email.snippet ?? ""
                
                response += "---\n"
                response += "Message ID: \(email.id)\n"
                response += "Thread ID: \(email.threadId)\n"
                response += "From: \(from)\n"
                response += "Subject: \(subject)\n"
                response += "Date: \(date)\n"
                response += "Preview: \(snippet.prefix(200))...\n"
                
                // List attachments with their attachment IDs (required for gmail_attachment tool)
                let attachments = email.payload?.getAttachmentParts() ?? []
                if !attachments.isEmpty {
                    response += "Attachments:\n"
                    for attachment in attachments {
                        let filename = attachment.filename ?? "unknown"
                        let attachmentId = attachment.body?.attachmentId ?? "N/A"
                        let size = attachment.body?.size ?? 0
                        response += "  - \(filename) (attachment_id: \(attachmentId), size: \(size) bytes)\n"
                    }
                }
            }
            
            return response
        } catch {
            return "{\"error\": \"Gmail query failed: \(error.localizedDescription)\"}"
        }
    }
    
    private func executeGmailSend(_ call: ToolCall) async -> String {
        guard await GmailService.shared.isAuthenticated else {
            return #"{"error": "Gmail not authenticated. Please set up Gmail API in Settings."}"#
        }
        
        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(GmailSendArguments.self, from: argsData) else {
            return #"{"error": "Failed to parse gmail_send arguments"}"#
        }
        
        guard isLikelyValidEmailAddress(args.to) else {
            return #"{"error": "Invalid email address format"}"#
        }
        
        guard allEmailAddressesAreValid(args.cc + args.bcc) else {
            return #"{"error": "Invalid cc or bcc email address format"}"#
        }
        
        do {
            // Load multiple attachments if specified
            var attachments: [(data: Data, name: String, mimeType: String)] = []
            
            if let filenames = args.attachmentFilenames {
                for filename in filenames {
                    let fileURL = documentsDirectory.appendingPathComponent(filename)
                    if FileManager.default.fileExists(atPath: fileURL.path) {
                        let data = try Data(contentsOf: fileURL)
                        let mimeType = getMimeType(for: filename)
                        attachments.append((data: data, name: filename, mimeType: mimeType))
                    } else {
                        return "{\"error\": \"Attachment file not found: \(filename). Use list_documents to see available files.\"}"
                    }
                }
            }
            
            let success = try await GmailService.shared.sendEmail(
                to: args.to,
                subject: args.subject,
                body: args.body,
                threadId: args.threadId,
                inReplyTo: args.inReplyTo,
                cc: args.cc,
                bcc: args.bcc,
                attachments: attachments
            )
            
            if success {
                var message = "Email sent successfully to \(args.to)"
                if args.threadId != nil {
                    message += " (as reply in thread)"
                }
                if !attachments.isEmpty {
                    message += " with \(attachments.count) attachment(s)"
                }
                return "{\"success\": true, \"message\": \"\(message)\"}"
            } else {
                return #"{"error": "Failed to send email"}"#
            }
        } catch {
            return "{\"error\": \"Gmail send failed: \(error.localizedDescription)\"}"
        }
    }
    
    private func executeGmailThread(_ call: ToolCall) async -> String {
        guard await GmailService.shared.isAuthenticated else {
            return #"{"error": "Gmail not authenticated. Please set up Gmail API in Settings."}"#
        }
        
        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(GmailThreadArguments.self, from: argsData) else {
            return #"{"error": "Failed to parse gmail_thread arguments"}"#
        }
        
        do {
            let thread = try await GmailService.shared.getThread(id: args.threadId)
            
            var response = "=== EMAIL THREAD ===\n"
            response += "Thread ID: \(thread.id)\n"
            response += "Messages: \(thread.messages?.count ?? 0)\n\n"
            
            for (index, message) in (thread.messages ?? []).enumerated() {
                let from = message.getHeader("From") ?? "Unknown"
                let to = message.getHeader("To") ?? ""
                let subject = message.getHeader("Subject") ?? "(No subject)"
                let date = message.getHeader("Date") ?? ""
                let body = message.getPlainTextBody()
                
                response += "--- Message \(index + 1) ---\n"
                response += "Message ID: \(message.id)\n"
                response += "From: \(from)\n"
                response += "To: \(to)\n"
                response += "Subject: \(subject)\n"
                response += "Date: \(date)\n"
                
                // List attachments with their attachment IDs (required for gmail_attachment tool)
                let attachments = message.payload?.getAttachmentParts() ?? []
                if !attachments.isEmpty {
                    response += "Attachments:\n"
                    for attachment in attachments {
                        let filename = attachment.filename ?? "unknown"
                        let attachmentId = attachment.body?.attachmentId ?? "N/A"
                        let size = attachment.body?.size ?? 0
                        response += "  - \(filename) (attachment_id: \(attachmentId), size: \(size) bytes)\n"
                    }
                }
                
                response += "Body:\n\(body.prefix(2000))\n\n"
            }
            
            return response
        } catch {
            return "{\"error\": \"Failed to get thread: \(error.localizedDescription)\"}"
        }
    }
    
    private func executeGmailForward(_ call: ToolCall) async -> String {
        guard await GmailService.shared.isAuthenticated else {
            return #"{"error": "Gmail not authenticated. Please set up Gmail API in Settings."}"#
        }
        
        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(GmailForwardArguments.self, from: argsData) else {
            return #"{"error": "Failed to parse gmail_forward arguments"}"#
        }
        
        do {
            let success = try await GmailService.shared.forwardEmail(
                to: args.to,
                messageId: args.messageId,
                comment: args.comment
            )
            
            if success {
                return "{\"success\": true, \"message\": \"Email forwarded to \(args.to)\"}"
            } else {
                return #"{"error": "Failed to forward email"}"#
            }
        } catch {
            return "{\"error\": \"Gmail forward failed: \(error.localizedDescription)\"}"
        }
    }
    
    private func executeGmailAttachment(_ call: ToolCall) async -> ToolResultMessage {
        print("[ToolExecutor] executeGmailAttachment called")
        guard await GmailService.shared.isAuthenticated else {
            print("[ToolExecutor] Gmail not authenticated")
            return ToolResultMessage(toolCallId: call.id, content: #"{"error": "Gmail not authenticated. Please set up Gmail API in Settings."}"#)
        }
        
        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(GmailAttachmentArguments.self, from: argsData) else {
            print("[ToolExecutor] Failed to parse gmail_attachment arguments")
            return ToolResultMessage(toolCallId: call.id, content: #"{"error": "Failed to parse gmail_attachment arguments. Make sure to include message_id, attachment_id, and filename."}"#)
        }
        
        print("[ToolExecutor] Downloading attachment: messageId=\(args.messageId), attachmentId=\(args.attachmentId), filename=\(args.filename)")
        do {
            let result = try await GmailService.shared.downloadAttachment(
                messageId: args.messageId,
                attachmentId: args.attachmentId
            )
            
            // Use the filename from the LLM arguments (more reliable than the lookup in GmailService)
            let filename = args.filename
            let mimeType = getMimeType(for: filename)
            
            // Save to documents folder
            let savedFilename = await saveAttachmentToDocuments(
                data: result.data,
                filename: filename,
                mimeType: mimeType
            )
            
            // Create file attachment for multimodal injection (just like read_document)
            let attachment = FileAttachment(data: result.data, mimeType: mimeType, filename: savedFilename)
            print("[ToolExecutor] Created FileAttachment: \(filename) (\(mimeType), \(result.data.count) bytes)")
            
            // Queue for description generation after agentic loop completes
            ToolExecutor.queueFileForDescription(filename: savedFilename, data: result.data, mimeType: mimeType)
            
            // Result text (no base64 needed - file will be injected as multimodal content)
            let visibilityMessage: String
            if isInlineMimeTypeSupportedForLLM(mimeType) {
                visibilityMessage = "Attachment '\(filename)' downloaded and visible. You can now analyze its contents directly."
            } else if mimeType == "application/zip" || filename.lowercased().hasSuffix(".zip") {
                visibilityMessage = "Attachment '\(filename)' downloaded. ZIP files are not viewable inline; import with add_project_files to extract into a project."
            } else {
                visibilityMessage = "Attachment '\(filename)' downloaded but not viewable inline in this model."
            }
            let resultJson = """
            {"success": true, "filename": "\(filename)", "mimeType": "\(mimeType)", "sizeBytes": \(result.data.count), "savedFilename": "\(savedFilename)", "message": "\(visibilityMessage)"}
            """
            
            let resultMessage = ToolResultMessage(toolCallId: call.id, content: resultJson, fileAttachment: attachment)
            print("[ToolExecutor] Created ToolResultMessage with \(resultMessage.fileAttachments.count) attachment(s)")
            return resultMessage
        } catch {
            print("[ToolExecutor] Gmail attachment download ERROR: \(error)")
            return ToolResultMessage(toolCallId: call.id, content: "{\"error\": \"Gmail attachment download failed: \(error.localizedDescription)\"}")
        }
    }
    
    private func getMimeType(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf": return "application/pdf"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "doc": return "application/msword"
        case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xls": return "application/vnd.ms-excel"
        case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "txt": return "text/plain"
        case "md": return "text/markdown"
        case "json": return "application/json"
        case "html", "htm": return "text/html"
        case "xml": return "application/xml"
        case "csv": return "text/csv"
        case "zip": return "application/zip"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "wav": return "audio/wav"
        case "ogg", "oga": return "audio/ogg"
        case "aac": return "audio/aac"
        case "flac": return "audio/flac"
        default: return "application/octet-stream"
        }
    }
    
    private func isInlineMimeTypeSupportedForLLM(_ mimeType: String) -> Bool {
        let normalized = mimeType
            .lowercased()
            .split(separator: ";")
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? mimeType.lowercased()
        
        if normalized.hasPrefix("image/") {
            return true
        }
        
        let supported: Set<String> = [
            "application/pdf",
            "text/plain",
            "text/markdown",
            "application/json",
            "text/csv",
            "text/html",
            "application/xml"
        ]
        return supported.contains(normalized)
    }
}

// MARK: - Download Email Attachment Types

struct DownloadEmailAttachmentArguments: Codable {
    let emailUid: String
    let partId: String?  // Optional when download_all is true
    let downloadAll: Bool?  // If true, download all attachments from the email
    
    enum CodingKeys: String, CodingKey {
        case emailUid = "email_uid"
        case partId = "part_id"
        case downloadAll = "download_all"
    }
}

struct DownloadEmailAttachmentResult: Codable {
    let success: Bool
    let filename: String
    let mimeType: String
    let sizeBytes: Int
    let contentType: String  // "image", "pdf", "text", "binary"
    let base64Data: String   // Raw data for Gemini to process natively
    let savedFilename: String  // Filename saved to documents folder
    let message: String
}

// MARK: - Batch Download Types

struct BatchAttachmentResult: Codable {
    let filename: String
    let mimeType: String
    let sizeBytes: Int
    let savedFilename: String
}

struct BatchDownloadResult: Codable {
    let success: Bool
    let totalAttachments: Int
    let downloadedCount: Int
    let files: [BatchAttachmentResult]
    let errors: [String]?
    let message: String
}

// MARK: - Get Email Thread Types

struct GetEmailThreadArguments: Codable {
    let messageId: String
    
    enum CodingKeys: String, CodingKey {
        case messageId = "message_id"
    }
}

struct GetEmailThreadResult: Codable {
    let success: Bool
    let threadEmailCount: Int
    let emails: [EmailMessage]
    let message: String
}

// MARK: - Get Email Thread Execution

extension ToolExecutor {
    func executeGetEmailThread(_ call: ToolCall) async -> String {
        print("[ToolExecutor] executeGetEmailThread called with arguments: \(call.function.arguments)")
        
        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(GetEmailThreadArguments.self, from: argsData) else {
            print("[ToolExecutor] Failed to parse get_email_thread arguments")
            return "{\"error\": \"Failed to parse get_email_thread arguments\"}"
        }
        
        print("[ToolExecutor] Parsed args - message_id: \(args.messageId)")
        
        // Validate message_id format (should be <...>)
        guard args.messageId.hasPrefix("<") && args.messageId.hasSuffix(">") else {
            print("[ToolExecutor] Invalid message_id format: \(args.messageId)")
            return "{\"error\": \"Invalid message_id format. Must be in format <id@domain>\"}"
        }
        
        // Check if email is configured
        guard await EmailService.shared.isConfigured else {
            return "{\"error\": \"Email is not configured. Please add IMAP/SMTP settings in the app.\"}"
        }
        
        do {
            let emails = try await EmailService.shared.fetchEmailThread(messageId: args.messageId)
            
            print("[ToolExecutor] fetchEmailThread returned \(emails.count) emails")
            
            let result = GetEmailThreadResult(
                success: true,
                threadEmailCount: emails.count,
                emails: emails,
                message: emails.isEmpty ? "No emails found in thread" : "Found \(emails.count) email(s) in thread (sorted oldest first)"
            )
            
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            if let data = try? encoder.encode(result), let json = String(data: data, encoding: .utf8) {
                return json
            }
            return "{\"success\": true, \"threadEmailCount\": \(emails.count)}"
        } catch {
            print("[ToolExecutor] Error fetching email thread: \(error)")
            return "{\"error\": \"Failed to fetch email thread: \(error.localizedDescription)\"}"
        }
    }
    
    // MARK: - Contact Tool Execution
    
    func executeManageContacts(_ call: ToolCall) async -> String {
        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(ManageContactsArguments.self, from: argsData) else {
            return #"{"error":"Failed to parse manage_contacts arguments"}"#
        }

        let action = args.action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch action {
        case "find":
            guard let query = args.query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return #"{"error":"For action 'find', query is required"}"#
            }

            let contacts = await ContactsService.shared.searchContacts(query: query)
            let contactResponses = contacts.prefix(20).map { contact in
                ContactResponse(
                    id: contact.id.uuidString,
                    firstName: contact.firstName,
                    lastName: contact.lastName,
                    fullName: contact.fullName,
                    email: contact.email,
                    phone: contact.phone,
                    organization: contact.organization
                )
            }

            let result = FindContactResult(
                success: true,
                contactCount: contactResponses.count,
                contacts: Array(contactResponses),
                message: contactResponses.isEmpty ? "No contacts found matching '\(query)'" : "Found \(contactResponses.count) contact(s) matching '\(query)'"
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            if let data = try? encoder.encode(result), let json = String(data: data, encoding: .utf8) {
                return json
            }
            return "{\"success\": true, \"contactCount\": \(contactResponses.count)}"

        case "add":
            guard let firstName = args.firstName,
                  !firstName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return #"{"error":"For action 'add', first_name is required"}"#
            }

            let contact = await ContactsService.shared.addContact(
                firstName: firstName,
                lastName: args.lastName,
                email: args.email,
                phone: args.phone,
                organization: args.organization
            )

            let result = AddContactResult(
                success: true,
                contactId: contact.id.uuidString,
                fullName: contact.fullName,
                message: "Contact '\(contact.fullName)' added successfully"
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            if let data = try? encoder.encode(result), let json = String(data: data, encoding: .utf8) {
                return json
            }
            return #"{"success":true,"message":"Contact added"}"#

        case "list":
            let contacts = await ContactsService.shared.getAllContacts()
            let contactResponses = contacts.prefix(50).map { contact in
                ContactResponse(
                    id: contact.id.uuidString,
                    firstName: contact.firstName,
                    lastName: contact.lastName,
                    fullName: contact.fullName,
                    email: contact.email,
                    phone: contact.phone,
                    organization: contact.organization
                )
            }

            let result = ListContactsResult(
                success: true,
                totalCount: contacts.count,
                contacts: Array(contactResponses),
                message: contacts.isEmpty ? "No contacts found. Import contacts via Settings or use manage_contacts with action='add' to create one." : "Showing \(contactResponses.count) of \(contacts.count) contact(s)"
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            if let data = try? encoder.encode(result), let json = String(data: data, encoding: .utf8) {
                return json
            }
            return "{\"success\": true, \"totalCount\": \(contacts.count)}"

        default:
            return #"{"error":"Invalid action. Supported actions: find, add, list"}"#
        }
    }
}

// MARK: - Contact Tool Argument Types

struct ManageContactsArguments: Codable {
    let action: String
    let query: String?
    let firstName: String?
    let lastName: String?
    let email: String?
    let phone: String?
    let organization: String?
    
    enum CodingKeys: String, CodingKey {
        case action
        case query
        case firstName = "first_name"
        case lastName = "last_name"
        case email, phone, organization
    }
}

// MARK: - Contact Tool Result Types

struct ContactResponse: Codable {
    let id: String
    let firstName: String
    let lastName: String?
    let fullName: String
    let email: String?
    let phone: String?
    let organization: String?
}

struct FindContactResult: Codable {
    let success: Bool
    let contactCount: Int
    let contacts: [ContactResponse]
    let message: String
}

struct AddContactResult: Codable {
    let success: Bool
    let contactId: String
    let fullName: String
    let message: String
}

struct ListContactsResult: Codable {
    let success: Bool
    let totalCount: Int
    let contacts: [ContactResponse]
    let message: String
}

// MARK: - Image Generation Tool

extension ToolExecutor {
    /// Store for generated images to be sent after tool execution
    private static var pendingImages: [(data: Data, mimeType: String, prompt: String)] = []
    
    /// Store for documents to be sent after tool execution
    private static var pendingDocuments: [(data: Data, filename: String, mimeType: String, caption: String?)] = []
    
    /// Store for downloaded attachments that need description generation
    private static var pendingFilesForDescription: [(filename: String, data: Data, mimeType: String)] = []
    
    /// Store for downloaded filenames to add to Message history
    private static var pendingDownloadedFilenames: [String] = []
    
    /// Get and clear pending images
    static func getPendingImages() -> [(data: Data, mimeType: String, prompt: String)] {
        let images = pendingImages
        pendingImages = []
        return images
    }
    
    /// Get and clear pending documents
    static func getPendingDocuments() -> [(data: Data, filename: String, mimeType: String, caption: String?)] {
        let documents = pendingDocuments
        pendingDocuments = []
        return documents
    }
    
    /// Get and clear files that need description generation
    static func getPendingFilesForDescription() -> [(filename: String, data: Data, mimeType: String)] {
        let files = pendingFilesForDescription
        pendingFilesForDescription = []
        return files
    }
    
    /// Get and clear downloaded filenames to store in Message history
    static func getPendingDownloadedFilenames() -> [String] {
        let filenames = pendingDownloadedFilenames
        pendingDownloadedFilenames = []
        return filenames
    }
    
    /// Clear all pending tool outputs (used for cancellation / interruption)
    static func clearPendingToolOutputs() {
        pendingImages = []
        pendingDocuments = []
        pendingFilesForDescription = []
        pendingDownloadedFilenames = []
    }
    
    /// Queue a file for description generation after the agentic loop completes
    static func queueFileForDescription(filename: String, data: Data, mimeType: String) {
        pendingFilesForDescription.append((filename: filename, data: data, mimeType: mimeType))
        // Also track filename for Message history
        pendingDownloadedFilenames.append(filename)
    }
    
    /// Images directory for loading source images
    private var imagesDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("TelegramConcierge/images", isDirectory: true)
    }
    
    func executeGenerateImage(_ call: ToolCall) async -> ToolResultMessage {
        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(GenerateImageArguments.self, from: argsData) else {
            return ToolResultMessage(toolCallId: call.id, content: "{\"error\": \"Failed to parse generate_image arguments\"}")
        }
        
        // Check if Gemini API is configured
        guard await GeminiImageService.shared.isConfigured() else {
            return ToolResultMessage(toolCallId: call.id, content: "{\"error\": \"Gemini API key is not configured. Please add your Google API key in Settings.\"}")
        }
        
        // Load source image if provided
        var sourceImageData: Data? = nil
        var sourceMimeType: String? = nil
        
        if let sourceImage = args.sourceImage, !sourceImage.isEmpty {
            let imageURL = imagesDirectory.appendingPathComponent(sourceImage)
            
            guard FileManager.default.fileExists(atPath: imageURL.path) else {
                return ToolResultMessage(toolCallId: call.id, content: "{\"error\": \"Source image not found: \(sourceImage). Make sure the filename is correct.\"}")
            }
            
            do {
                sourceImageData = try Data(contentsOf: imageURL)
                // Determine MIME type from extension
                let ext = imageURL.pathExtension.lowercased()
                switch ext {
                case "jpg", "jpeg":
                    sourceMimeType = "image/jpeg"
                case "png":
                    sourceMimeType = "image/png"
                case "gif":
                    sourceMimeType = "image/gif"
                case "webp":
                    sourceMimeType = "image/webp"
                default:
                    sourceMimeType = "image/jpeg"
                }
            } catch {
                return ToolResultMessage(toolCallId: call.id, content: "{\"error\": \"Failed to load source image: \(error.localizedDescription)\"}")
            }
        }
        
        do {
            let (imageData, mimeType) = try await GeminiImageService.shared.generateImage(
                prompt: args.prompt,
                sourceImageData: sourceImageData,
                sourceMimeType: sourceMimeType
            )
            
            // Save generated image to documents folder so Gemini can reference it later
            let fileExtension = mimeType.contains("png") ? "png" : "jpg"
            let fileName = "generated_\(UUID().uuidString).\(fileExtension)"
            let documentsURL = documentsDirectory.appendingPathComponent(fileName)
            let imagesURL = imagesDirectory.appendingPathComponent(fileName)
            
            do {
                try imageData.write(to: documentsURL)
                try imageData.write(to: imagesURL)
                print("[ToolExecutor] Saved generated image: \(fileName) (\(imageData.count) bytes)")
            } catch {
                print("[ToolExecutor] Failed to save generated image: \(error)")
                // Continue anyway - we can still send to Telegram and inject multimodally
            }
            
            // Store the image for sending to Telegram after the tool response
            ToolExecutor.pendingImages.append((imageData, mimeType, args.prompt))
            
            // Queue file for description generation (like email attachments)
            ToolExecutor.queueFileForDescription(filename: fileName, data: imageData, mimeType: mimeType)
            
            let isEdit = sourceImageData != nil
            
            // Create file attachment for multimodal injection (LLM can see the generated image)
            let attachment = FileAttachment(data: imageData, mimeType: mimeType, filename: fileName)
            print("[ToolExecutor] Created FileAttachment for generated image: \(fileName) (\(mimeType), \(imageData.count) bytes)")
            
            // Result text (image will be injected as multimodal content)
            let result = """
            {"success": true, "filename": "\(fileName)", "mimeType": "\(mimeType)", "sizeBytes": \(imageData.count), "message": "\(isEdit ? "Image transformed" : "Image generated") successfully. You can now see and analyze the result."}
            """
            
            return ToolResultMessage(toolCallId: call.id, content: result, fileAttachment: attachment)
        } catch {
            return ToolResultMessage(toolCallId: call.id, content: "{\"error\": \"Image generation failed: \(error.localizedDescription)\"}")
        }
    }
    
    // MARK: - macOS Shortcuts Tool Implementations
    
    private func executeListShortcuts(_ call: ToolCall) async -> String {
        if Task.isCancelled {
            return #"{"error": "Shortcut listing cancelled"}"#
        }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["list"]
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        do {
            try process.run()
            ToolExecutor.registerRunningProcess(process)
            defer { ToolExecutor.unregisterRunningProcess(process) }
            
            while process.isRunning {
                if Task.isCancelled {
                    process.terminate()
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    if process.isRunning {
                        process.interrupt()
                    }
                    break
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            
            process.waitUntilExit()
            
            if Task.isCancelled {
                return #"{"error": "Shortcut listing cancelled"}"#
            }
            
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outputData, encoding: .utf8) ?? ""
            
            if process.terminationStatus != 0 {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
                return "{\"error\": \"Failed to list shortcuts: \(errorOutput.isEmpty ? "Unknown error" : errorOutput)\"}"
            }
            
            // Parse the output - each line is a shortcut name
            let shortcuts = output.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            
            if shortcuts.isEmpty {
                return "{\"success\": true, \"count\": 0, \"shortcuts\": [], \"message\": \"No shortcuts found. Create shortcuts in the Shortcuts app.\"}"
            }
            
            let shortcutList = shortcuts.map { "\"\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" }.joined(separator: ", ")
            return "{\"success\": true, \"count\": \(shortcuts.count), \"shortcuts\": [\(shortcutList)], \"message\": \"Found \(shortcuts.count) shortcut(s). Use run_shortcut with the exact name to execute.\"}"
        } catch {
            return "{\"error\": \"Failed to execute shortcuts command: \(error.localizedDescription)\"}"
        }
    }
    
    private func executeRunShortcut(_ call: ToolCall) async -> ToolResultMessage {
        if Task.isCancelled {
            return ToolResultMessage(toolCallId: call.id, content: #"{"error":"Shortcut execution cancelled"}"#)
        }
        
        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(RunShortcutArguments.self, from: argsData) else {
            return ToolResultMessage(toolCallId: call.id, content: "{\"error\": \"Failed to parse run_shortcut arguments\"}")
        }
        
        let shortcutName = args.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !shortcutName.isEmpty else {
            return ToolResultMessage(toolCallId: call.id, content: "{\"error\": \"Shortcut name cannot be empty\"}")
        }
        
        let sandboxedTempDir = FileManager.default.temporaryDirectory
        
        // If input is provided, write it to the sandboxed temp dir (app owns it, CLI can read it)
        var inputFile: URL? = nil
        if let input = args.input, !input.isEmpty {
            inputFile = sandboxedTempDir.appendingPathComponent("shortcut_input_\(UUID().uuidString).txt")
            do {
                try input.write(to: inputFile!, atomically: true, encoding: .utf8)
                print("[ToolExecutor] Input file written to: \(inputFile!.path)")
            } catch {
                print("[ToolExecutor] Failed to write input file: \(error)")
                return ToolResultMessage(toolCallId: call.id, content: "{\"error\": \"Failed to write input file: \(error.localizedDescription)\"}")
            }
        }
        
        let timeoutSeconds: Double = 120
        
        var finalOutputData = Data()
        var exitCode: Int32 = 0
        var appleEventsPermissionDenied = false
        var appleScriptErrorText = ""
        
        // PRIMARY: Use Shortcuts Events (AppleScript), which is working on this machine.
        print("[ToolExecutor] Starting shortcut '\(shortcutName)' via AppleScript Shortcuts Events")
        let appleScriptPrimary = await runShortcutViaAppleScript(name: shortcutName, input: args.input, timeoutSeconds: timeoutSeconds)
        exitCode = appleScriptPrimary.exitCode
        
        if appleScriptPrimary.exitCode == 0, !appleScriptPrimary.outputData.isEmpty {
            finalOutputData = appleScriptPrimary.outputData
            print("[ToolExecutor] AppleScript primary captured: \(finalOutputData.count) bytes")
        } else {
            appleScriptErrorText = appleScriptPrimary.errorText
            let normalizedAppleScriptError = appleScriptPrimary.errorText.lowercased()
            appleEventsPermissionDenied =
                normalizedAppleScriptError.contains("privilege violation") ||
                normalizedAppleScriptError.contains("(-10004)") ||
                normalizedAppleScriptError.contains("error -10004")
            
            if !appleScriptPrimary.errorText.isEmpty {
                print("[ToolExecutor] AppleScript primary error: \(appleScriptPrimary.errorText.prefix(500))")
                if appleEventsPermissionDenied {
                    print("[ToolExecutor] AppleScript indicates AppleEvents permission denial (-10004)")
                }
            } else {
                print("[ToolExecutor] AppleScript primary returned empty output; falling back to shortcuts CLI capture...")
            }
            
            // FALLBACK: CLI output capture paths (file, stdout, then pipe).
            let outputFilename = "shortcut_output_\(UUID().uuidString).txt"
            let outputFileURL = FileManager.default.temporaryDirectory.appendingPathComponent(outputFilename)
            let didCreateOutputFile = FileManager.default.createFile(
                atPath: outputFileURL.path,
                contents: Data(),
                attributes: [.posixPermissions: 0o666]
            )
            print("[ToolExecutor] Output file precreate at \(outputFileURL.path): \(didCreateOutputFile ? "ok" : "failed")")
            
            var processArguments = ["run", shortcutName]
            if let inputFile = inputFile {
                processArguments.append(contentsOf: ["--input-path", inputFile.path])
            }
            processArguments.append(contentsOf: ["--output-path", outputFileURL.path])
            
            print("[ToolExecutor] CLI fallback command: /usr/bin/shortcuts run '<shortcut name>' --output-path '<sandbox temp file>'")
            
            let primaryResult: (exitCode: Int32, stdoutData: Data, stderrData: Data) = await withCheckedContinuation { continuation in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
                process.arguments = processArguments
                
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe
                
                process.terminationHandler = { proc in
                    ToolExecutor.unregisterRunningProcess(proc)
                    let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    continuation.resume(returning: (proc.terminationStatus, outData, errData))
                }
                
                do {
                    try process.run()
                    ToolExecutor.registerRunningProcess(process)
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) {
                        if process.isRunning {
                            process.terminate()
                            print("[ToolExecutor] Shortcut '\(shortcutName)' TIMED OUT")
                        }
                    }
                } catch {
                    print("[ToolExecutor] Failed to launch: \(error)")
                    continuation.resume(returning: (-1, Data(), Data(error.localizedDescription.utf8)))
                }
            }
            
            exitCode = primaryResult.exitCode
            print("[ToolExecutor] CLI fallback exit code: \(primaryResult.exitCode)")
            print("[ToolExecutor] CLI fallback stdout bytes: \(primaryResult.stdoutData.count)")
            print("[ToolExecutor] CLI fallback stderr bytes: \(primaryResult.stderrData.count)")
            if let stderrText = String(data: primaryResult.stderrData, encoding: .utf8), !stderrText.isEmpty {
                print("[ToolExecutor] CLI fallback stderr: \(stderrText.prefix(500))")
            }
            
            var fileOutputData = Data()
            for _ in 0..<20 {
                if let data = try? Data(contentsOf: outputFileURL), !data.isEmpty {
                    fileOutputData = data
                    break
                }
                try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
            }
            
            if !fileOutputData.isEmpty {
                finalOutputData = fileOutputData
                print("[ToolExecutor] CLI fallback file captured: \(fileOutputData.count) bytes")
            } else if !primaryResult.stdoutData.isEmpty {
                finalOutputData = primaryResult.stdoutData
                print("[ToolExecutor] CLI fallback stdout captured: \(primaryResult.stdoutData.count) bytes")
            } else {
                print("[ToolExecutor] CLI fallback returned no output in file or stdout")
            }
            
            // Known CLI quirk fallback: omit --output-path and force a pipe (| cat).
            if finalOutputData.isEmpty && primaryResult.exitCode == 0 {
                let escapedName = shortcutName.replacingOccurrences(of: "'", with: "'\\''")
                var noOutputPathCommand = "/usr/bin/shortcuts run '\(escapedName)'"
                if let inputFile = inputFile {
                    let escapedPath = inputFile.path.replacingOccurrences(of: "'", with: "'\\''")
                    noOutputPathCommand += " --input-path '\(escapedPath)'"
                }
                noOutputPathCommand += " | /bin/cat"
                print("[ToolExecutor] Retrying CLI with no --output-path + pipe fallback...")
                
                let pipedFallback = await withCheckedContinuation { (continuation: CheckedContinuation<(exitCode: Int32, stdoutData: Data, stderrData: Data), Never>) in
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/bin/sh")
                    process.arguments = ["-c", noOutputPathCommand]
                    
                    let stdoutPipe = Pipe()
                    let stderrPipe = Pipe()
                    process.standardOutput = stdoutPipe
                    process.standardError = stderrPipe
                    
                    process.terminationHandler = { proc in
                        ToolExecutor.unregisterRunningProcess(proc)
                        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                        continuation.resume(returning: (proc.terminationStatus, outData, errData))
                    }
                    
                    do {
                        try process.run()
                        ToolExecutor.registerRunningProcess(process)
                        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) {
                            if process.isRunning {
                                process.terminate()
                            }
                        }
                    } catch {
                        continuation.resume(returning: (-1, Data(), Data(error.localizedDescription.utf8)))
                    }
                }
                
                if !pipedFallback.stdoutData.isEmpty {
                    finalOutputData = pipedFallback.stdoutData
                    print("[ToolExecutor] Piped CLI fallback captured: \(finalOutputData.count) bytes")
                } else {
                    print("[ToolExecutor] Piped CLI fallback returned empty output")
                    if let fallbackErr = String(data: pipedFallback.stderrData, encoding: .utf8), !fallbackErr.isEmpty {
                        print("[ToolExecutor] Piped CLI fallback stderr: \(fallbackErr.prefix(500))")
                    }
                }
            }
            
            try? FileManager.default.removeItem(at: outputFileURL)
        }
        
        // Clean up input file
        if let inputFile = inputFile { try? FileManager.default.removeItem(at: inputFile) }
        
        print("[ToolExecutor] Shortcut '\(shortcutName)' finished with exit code: \(exitCode)")
        print("[ToolExecutor] Final output: \(finalOutputData.count) bytes")
        
        // Check if output contains binary media (image) by checking magic bytes
        var fileAttachment: FileAttachment? = nil
        var outputInfo = ""
        
        if finalOutputData.count > 0 {
            let mimeType = detectMimeType(from: finalOutputData)
            
            if mimeType.hasPrefix("image/") {
                // Binary image output — save and create attachment for multimodal injection
                let fileExtension: String
                switch mimeType {
                case "image/png": fileExtension = "png"
                case "image/gif": fileExtension = "gif"
                case "image/webp": fileExtension = "webp"
                default: fileExtension = "jpg"
                }
                
                let savedFilename = "shortcut_\(UUID().uuidString).\(fileExtension)"
                let savedPath = documentsDirectory.appendingPathComponent(savedFilename)
                let imagePath = imagesDirectory.appendingPathComponent(savedFilename)
                
                try? finalOutputData.write(to: savedPath)
                try? finalOutputData.write(to: imagePath)
                
                fileAttachment = FileAttachment(data: finalOutputData, mimeType: mimeType, filename: savedFilename)
                outputInfo = ", \"output_file\": {\"filename\": \"\(savedFilename)\", \"mimeType\": \"\(mimeType)\", \"sizeBytes\": \(finalOutputData.count), \"message\": \"Image output saved and visible for analysis\"}"
                
                print("[ToolExecutor] Shortcut produced image output: \(savedFilename) (\(finalOutputData.count) bytes)")
            } else {
                // Text output from stdout
                let textOutput = String(data: finalOutputData, encoding: .utf8) ?? ""
                if !textOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let escapedOutput = textOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "\"", with: "\\\"")
                        .replacingOccurrences(of: "\n", with: "\\n")
                        .replacingOccurrences(of: "\r", with: "")
                    outputInfo = ", \"output\": \"\(escapedOutput)\""
                    print("[ToolExecutor] Shortcut text output: \(textOutput.prefix(200))")
                }
            }
        }
        
        // Build result
        let permissionDeniedNoOutput = appleEventsPermissionDenied && finalOutputData.isEmpty
        let success = (exitCode == 0) && !permissionDeniedNoOutput
        
        var result = "{\"success\": \(success), \"exit_code\": \(exitCode), \"shortcut\": \"\(shortcutName.replacingOccurrences(of: "\"", with: "\\\""))\""
        
        result += outputInfo
        
        if permissionDeniedNoOutput {
            result += ", \"error_code\": \"apple_events_permission_denied\""
        } else if success && finalOutputData.isEmpty {
            result += ", \"warning\": \"Shortcut executed but returned no output\""
        }
        
        if permissionDeniedNoOutput {
            let errorMessage = "AppleEvents permission denied while running Shortcuts Events (-10004). In System Settings > Privacy & Security > Automation, allow this app to control Shortcuts Events, then retry."
            let escapedMessage = errorMessage
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            result += ", \"message\": \"\(escapedMessage)\""
            
            if !appleScriptErrorText.isEmpty {
                let escapedDetails = appleScriptErrorText
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                    .replacingOccurrences(of: "\n", with: "\\n")
                    .replacingOccurrences(of: "\r", with: "")
                result += ", \"details\": \"\(escapedDetails)\""
            }
        } else if success {
            result += ", \"message\": \"Shortcut '\(shortcutName)' executed successfully\""
        } else {
            result += ", \"message\": \"Shortcut '\(shortcutName)' failed with exit code \(exitCode)\""
        }
        
        result += "}"
        
        return ToolResultMessage(toolCallId: call.id, content: result, fileAttachment: fileAttachment)
    }
    
    /// Detect MIME type from file data by checking magic bytes
    private func detectMimeType(from data: Data) -> String {
        guard data.count >= 12 else { return "application/octet-stream" }
        
        let bytes = [UInt8](data.prefix(12))
        
        // PNG: 89 50 4E 47 0D 0A 1A 0A
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return "image/png"
        }
        
        // JPEG: FF D8 FF
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) {
            return "image/jpeg"
        }
        
        // GIF: 47 49 46 38
        if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) {
            return "image/gif"
        }
        
        // WebP: 52 49 46 46 ... 57 45 42 50
        if bytes.starts(with: [0x52, 0x49, 0x46, 0x46]) && data.count >= 12 {
            let webpBytes = [UInt8](data[8..<12])
            if webpBytes == [0x57, 0x45, 0x42, 0x50] {
                return "image/webp"
            }
        }
        
        // PDF: 25 50 44 46 (%PDF)
        if bytes.starts(with: [0x25, 0x50, 0x44, 0x46]) {
            return "application/pdf"
        }
        
        // Check if it looks like text
        let textBytes = data.prefix(1024)
        if let _ = String(data: textBytes, encoding: .utf8) {
            // Appears to be valid UTF-8 text
            return "text/plain"
        }
        
        return "application/octet-stream"
    }
    
    private func runShortcutViaAppleScript(name: String, input: String?, timeoutSeconds: Double) async -> (exitCode: Int32, outputData: Data, errorText: String) {
        // Prefer in-process AppleScript so sandbox/TCC permissions apply to this app directly.
        let inProcessResult = await runShortcutViaInProcessAppleScript(name: name, input: input)
        if inProcessResult.exitCode == 0 || !inProcessResult.errorText.isEmpty {
            return inProcessResult
        }
        
        print("[ToolExecutor] In-process AppleScript returned empty output; trying osascript fallback...")
        let osascriptResult = await runShortcutViaOSAScript(name: name, input: input, timeoutSeconds: timeoutSeconds)
        if osascriptResult.exitCode == 0, !osascriptResult.outputData.isEmpty {
            return osascriptResult
        }
        if !osascriptResult.errorText.isEmpty {
            return osascriptResult
        }
        
        return inProcessResult
    }
    
    private func runShortcutViaInProcessAppleScript(name: String, input: String?) async -> (exitCode: Int32, outputData: Data, errorText: String) {
        await MainActor.run {
            let escapedName = name
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            
            let command: String
            if let input, !input.isEmpty {
                let escapedInput = input
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                command = "tell application id \"com.apple.shortcuts\" to run shortcut \"\(escapedName)\" with input \"\(escapedInput)\""
            } else {
                command = "tell application id \"com.apple.shortcuts\" to run shortcut \"\(escapedName)\""
            }
            
            guard let script = NSAppleScript(source: command) else {
                return (-1, Data(), "Failed to create AppleScript object")
            }
            
            var errorInfo: NSDictionary?
            let resultDescriptor = script.executeAndReturnError(&errorInfo)
            if let errorInfo {
                let message = (errorInfo[NSAppleScript.errorMessage] as? String)
                    ?? (errorInfo["NSAppleScriptErrorMessage"] as? String)
                    ?? "Unknown AppleScript error"
                let number = (errorInfo[NSAppleScript.errorNumber] as? Int)
                    ?? (errorInfo["NSAppleScriptErrorNumber"] as? Int)
                    ?? -1
                return (Int32(number), Data(), "\(message) (\(number))")
            }
            
            if let text = resultDescriptor.stringValue, !text.isEmpty {
                return (0, Data(text.utf8), "")
            }
            
            let rawData = resultDescriptor.data
            if !rawData.isEmpty {
                return (0, rawData, "")
            }
            
            return (0, Data(), "")
        }
    }
    
    private func runShortcutViaOSAScript(name: String, input: String?, timeoutSeconds: Double) async -> (exitCode: Int32, outputData: Data, errorText: String) {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            
            let escapedName = name
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let scriptLine: String
            if let input, !input.isEmpty {
                let escapedInput = input
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                scriptLine = "tell application id \"com.apple.shortcuts\" to run shortcut \"\(escapedName)\" with input \"\(escapedInput)\""
            } else {
                scriptLine = "tell application id \"com.apple.shortcuts\" to run shortcut \"\(escapedName)\""
            }
            
            let arguments = ["-l", "AppleScript", "-e", scriptLine]
            process.arguments = arguments
            
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            
            process.terminationHandler = { proc in
                ToolExecutor.unregisterRunningProcess(proc)
                let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let errText = String(data: errData, encoding: .utf8) ?? ""
                continuation.resume(returning: (proc.terminationStatus, outData, errText))
            }
            
            do {
                try process.run()
                ToolExecutor.registerRunningProcess(process)
                DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) {
                    if process.isRunning {
                        process.terminate()
                    }
                }
            } catch {
                continuation.resume(returning: (-1, Data(), error.localizedDescription))
            }
        }
    }
}

// MARK: - Image Generation Argument Types

struct GenerateImageArguments: Codable {
    let prompt: String
    let sourceImage: String?
    
    enum CodingKeys: String, CodingKey {
        case prompt
        case sourceImage = "source_image"
    }
}

struct GenerateImageResult: Codable {
    let success: Bool
    let message: String
    let imageSize: Int
    let mimeType: String
    let generatedFilename: String
    
    enum CodingKeys: String, CodingKey {
        case success, message, mimeType
        case imageSize = "image_size"
        case generatedFilename = "generated_filename"
    }
}

// MARK: - Shortcuts Tool Argument Types

struct RunShortcutArguments: Codable {
    let name: String
    let input: String?
}

// MARK: - URL Viewing and Download Tool Implementations

extension ToolExecutor {
    func executeViewUrl(_ call: ToolCall) async -> String {
        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(ViewUrlArguments.self, from: argsData) else {
            return "{\"error\": \"Failed to parse view_url arguments\"}"
        }
        
        // Validate URL format
        guard args.url.hasPrefix("http://") || args.url.hasPrefix("https://") else {
            return "{\"error\": \"Invalid URL format. URL must start with http:// or https://\"}"
        }
        
        do {
            let result = try await webOrchestrator.readUrlContent(url: args.url)
            // Returns page content with image metadata (captions, URLs)
            // LLM can use view_page_image tool to download specific images it wants to see
            return result.asJSON()
        } catch {
            return "{\"error\": \"Failed to read URL: \(error.localizedDescription)\"}"
        }
    }
    
    /// Download a specific image from a URL for multimodal injection
    /// LLM uses this after viewing page metadata to selectively download interesting images
    func executeViewPageImage(_ call: ToolCall) async -> ToolResultMessage {
        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(ViewPageImageArguments.self, from: argsData) else {
            return ToolResultMessage(toolCallId: call.id, content: "{\"error\": \"Failed to parse view_page_image arguments\"}")
        }
        
        // Validate URL format
        guard args.imageUrl.hasPrefix("http://") || args.imageUrl.hasPrefix("https://") else {
            return ToolResultMessage(toolCallId: call.id, content: "{\"error\": \"Invalid URL format. URL must start with http:// or https://\"}")
        }
        
        // Download the image
        guard let downloadedImage = await webOrchestrator.downloadImage(url: args.imageUrl, caption: args.caption ?? "") else {
            return ToolResultMessage(toolCallId: call.id, content: "{\"error\": \"Failed to download image from URL. It may be inaccessible, too large, or not an image.\"}")
        }
        
        // Create file attachment for multimodal injection
        let filename = "page_image_\(UUID().uuidString.prefix(8)).jpg"
        let attachment = FileAttachment(data: downloadedImage.data, mimeType: downloadedImage.mimeType, filename: filename)
        
        print("[ToolExecutor] Downloaded page image for multimodal injection: \(downloadedImage.data.count) bytes from \(args.imageUrl)")
        
        let result = """
        {"success": true, "mimeType": "\(downloadedImage.mimeType)", "sizeBytes": \(downloadedImage.data.count), "message": "Image downloaded successfully. You can now see and analyze it."}
        """
        
        return ToolResultMessage(toolCallId: call.id, content: result, fileAttachment: attachment)
    }
    
    func executeDownloadFromUrl(_ call: ToolCall) async -> String {
        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(DownloadFromUrlArguments.self, from: argsData) else {
            return "{\"error\": \"Failed to parse download_from_url arguments\"}"
        }
        
        // Validate URL format
        guard let url = URL(string: args.url),
              let scheme = url.scheme,
              ["http", "https"].contains(scheme.lowercased()) else {
            return "{\"error\": \"Invalid URL format. URL must start with http:// or https://\"}"
        }
        
        do {
            // Download the file
            var request = URLRequest(url: url)
            request.timeoutInterval = 120
            
            // Add common headers to avoid blocks
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                return "{\"error\": \"Download failed with HTTP status \(statusCode)\"}"
            }
            
            // Determine filename
            let filename: String
            if let preferredFilename = args.filename, !preferredFilename.isEmpty {
                filename = preferredFilename
            } else {
                // Try to derive from Content-Disposition header or URL
                if let contentDisposition = httpResponse.value(forHTTPHeaderField: "Content-Disposition"),
                   let filenameMatch = contentDisposition.range(of: "filename=\"([^\"]+)\"", options: .regularExpression) {
                    filename = String(contentDisposition[filenameMatch]).replacingOccurrences(of: "filename=\"", with: "").replacingOccurrences(of: "\"", with: "")
                } else if let lastComponent = url.pathComponents.last, lastComponent.contains(".") {
                    filename = lastComponent
                } else {
                    // Generate filename based on content type
                    let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
                    let ext = extensionForMimeType(contentType)
                    filename = "download_\(UUID().uuidString.prefix(8)).\(ext)"
                }
            }
            
            // Save to the same documents directory used by list_documents and Telegram uploads
            let fileURL = documentsDirectory.appendingPathComponent(filename)
            
            try data.write(to: fileURL)
            
            // Also save to images directory if it's an image (for Gemini vision access)
            let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""
            if contentType.hasPrefix("image/") {
                let imageFileURL = imagesDirectory.appendingPathComponent(filename)
                try? data.write(to: imageFileURL)
            }
            
            print("[ToolExecutor] Downloaded file: \(filename) (\(data.count) bytes)")
            
            let result = DownloadFromUrlResult(
                success: true,
                filename: filename,
                fileSize: data.count,
                contentType: contentType,
                message: "File downloaded successfully. You can reference it as '\(filename)' or attach it to emails."
            )
            
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            if let resultData = try? encoder.encode(result), let json = String(data: resultData, encoding: .utf8) {
                return json
            }
            return "{\"success\": true, \"filename\": \"\(filename)\", \"message\": \"File downloaded\"}"
        } catch {
            return "{\"error\": \"Download failed: \(error.localizedDescription)\"}"
        }
    }
    
    private func extensionForMimeType(_ mimeType: String) -> String {
        let type = mimeType.lowercased().components(separatedBy: ";").first ?? mimeType.lowercased()
        switch type {
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "application/pdf": return "pdf"
        case "text/html": return "html"
        case "text/plain": return "txt"
        case "application/json": return "json"
        case "application/xml", "text/xml": return "xml"
        case "application/zip": return "zip"
        default: return "bin"
        }
    }
}

// MARK: - URL Tool Argument Types

struct ViewUrlArguments: Codable {
    let url: String
}

struct ViewPageImageArguments: Codable {
    let imageUrl: String
    let caption: String?
    
    enum CodingKeys: String, CodingKey {
        case imageUrl = "image_url"
        case caption
    }
}

struct DownloadFromUrlArguments: Codable {
    let url: String
    let filename: String?
}

struct DownloadFromUrlResult: Codable {
    let success: Bool
    let filename: String
    let fileSize: Int
    let contentType: String
    let message: String
    
    enum CodingKeys: String, CodingKey {
        case success, filename, message, contentType
        case fileSize = "file_size"
    }
}

// MARK: - Send Document to Chat Tool

extension ToolExecutor {
    func executeSendDocumentToChat(_ call: ToolCall) async -> String {
        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(SendDocumentToChatArguments.self, from: argsData) else {
            return "{\"error\": \"Failed to parse send_document_to_chat arguments\"}"
        }
        
        // Find the document file
        let documentURL = documentsDirectory.appendingPathComponent(args.documentFilename)
        guard FileManager.default.fileExists(atPath: documentURL.path) else {
            return "{\"error\": \"Document not found: \(args.documentFilename). Use list_documents to see available files.\"}"
        }
        
        do {
            let documentData = try Data(contentsOf: documentURL)
            recordDocumentOpened(filename: args.documentFilename)
            
            // Determine MIME type from extension
            let ext = documentURL.pathExtension.lowercased()
            let mimeType: String
            switch ext {
            case "pdf":
                mimeType = "application/pdf"
            case "jpg", "jpeg":
                mimeType = "image/jpeg"
            case "png":
                mimeType = "image/png"
            case "gif":
                mimeType = "image/gif"
            case "webp":
                mimeType = "image/webp"
            case "txt":
                mimeType = "text/plain"
            case "json":
                mimeType = "application/json"
            case "html":
                mimeType = "text/html"
            case "xml":
                mimeType = "application/xml"
            case "zip":
                mimeType = "application/zip"
            case "doc", "docx":
                mimeType = "application/msword"
            case "xls", "xlsx":
                mimeType = "application/vnd.ms-excel"
            default:
                mimeType = "application/octet-stream"
            }
            
            // Store the document for sending after the tool response
            ToolExecutor.pendingDocuments.append((
                data: documentData,
                filename: args.documentFilename,
                mimeType: mimeType,
                caption: args.caption
            ))
            
            print("[ToolExecutor] Queued document for sending: \(args.documentFilename) (\(documentData.count) bytes)")
            
            let result = SendDocumentToChatResult(
                success: true,
                documentFilename: args.documentFilename,
                sizeBytes: documentData.count,
                message: "Document '\(args.documentFilename)' will be sent to the chat."
            )
            
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            if let data = try? encoder.encode(result), let json = String(data: data, encoding: .utf8) {
                return json
            }
            return "{\"success\": true, \"message\": \"Document queued for sending\"}"
        } catch {
            return "{\"error\": \"Failed to read document: \(error.localizedDescription)\"}"
        }
    }
}

// MARK: - Send Document to Chat Types

struct SendDocumentToChatArguments: Codable {
    let documentFilename: String
    let caption: String?
    
    enum CodingKeys: String, CodingKey {
        case documentFilename = "document_filename"
        case caption
    }
}

struct SendDocumentToChatResult: Codable {
    let success: Bool
    let documentFilename: String
    let sizeBytes: Int
    let message: String
    
    enum CodingKeys: String, CodingKey {
        case success, message
        case documentFilename = "document_filename"
        case sizeBytes = "size_bytes"
    }
}

// MARK: - Document Generation Tool

extension ToolExecutor {
    func executeGenerateDocument(_ call: ToolCall) async -> String {
        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(GenerateDocumentArguments.self, from: argsData) else {
            return #"{"error": "Failed to parse generate_document arguments"}"#
        }
        
        do {
            // Generate the document using the document service
            let (data, filename, mimeType) = try await DocumentGeneratorService.shared.generate(args: args)
            
            // Save to documents directory
            let fileURL = documentsDirectory.appendingPathComponent(filename)
            try data.write(to: fileURL)
            
            print("[ToolExecutor] Generated document: \(filename) (\(data.count) bytes)")
            
            // Queue for sending via Telegram (like generate_image does)
            ToolExecutor.pendingDocuments.append((
                data: data,
                filename: filename,
                mimeType: mimeType,
                caption: "📄 \(args.title ?? "Document")"
            ))
            
            let result = GenerateDocumentResult(
                success: true,
                message: "Document '\(filename)' generated successfully and will be sent to the chat.",
                filename: filename,
                fileSize: data.count,
                documentType: args.documentType
            )
            
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            if let resultData = try? encoder.encode(result), let json = String(data: resultData, encoding: .utf8) {
                return json
            }
            return #"{"success": true, "message": "Document generated", "filename": "\#(filename)"}"#
        } catch {
            return #"{"error": "Document generation failed: \#(error.localizedDescription)"}"#
        }
    }
}

// MARK: - Claude Code Project Workspace Tools

struct CreateProjectArguments: Codable {
    let projectName: String
    let initialNotes: String?
    
    enum CodingKeys: String, CodingKey {
        case projectName = "project_name"
        case initialNotes = "initial_notes"
    }
}

struct BrowseProjectArguments: Codable {
    let projectId: String
    let relativePath: String?
    let recursive: Bool?
    let maxEntries: Int?
    
    enum CodingKeys: String, CodingKey {
        case projectId = "project_id"
        case relativePath = "relative_path"
        case recursive
        case maxEntries = "max_entries"
    }
}

struct ReadProjectFileArguments: Codable {
    let projectId: String
    let relativePath: String
    let maxChars: Int?
    
    enum CodingKeys: String, CodingKey {
        case projectId = "project_id"
        case relativePath = "relative_path"
        case maxChars = "max_chars"
    }
}

struct RunClaudeCodeArguments: Codable {
    let projectId: String
    let prompt: String
    let timeoutSeconds: Int?
    let maxOutputChars: Int?
    let cliArgs: String?
    
    enum CodingKeys: String, CodingKey {
        case projectId = "project_id"
        case prompt
        case timeoutSeconds = "timeout_seconds"
        case maxOutputChars = "max_output_chars"
        case cliArgs = "cli_args"
    }
}

struct ViewProjectHistoryArguments: Codable {
    let projectId: String
    let maxTokens: Int?
    
    enum CodingKeys: String, CodingKey {
        case projectId = "project_id"
        case maxTokens = "max_tokens"
    }
}

struct AddProjectFilesArguments: Codable {
    let projectId: String
    let documentFilenames: [String]
    let relativePath: String?
    let overwrite: Bool?
    let sourceDirectory: String?
    
    enum CodingKeys: String, CodingKey {
        case projectId = "project_id"
        case documentFilenames = "document_filenames"
        case relativePath = "relative_path"
        case overwrite
        case sourceDirectory = "source_directory"
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projectId = try container.decode(String.self, forKey: .projectId)
        relativePath = try container.decodeIfPresent(String.self, forKey: .relativePath)
        overwrite = try container.decodeIfPresent(Bool.self, forKey: .overwrite)
        sourceDirectory = try container.decodeIfPresent(String.self, forKey: .sourceDirectory)
        
        if let array = try? container.decode([String].self, forKey: .documentFilenames) {
            documentFilenames = array
        } else if let raw = (try? container.decode(String.self, forKey: .documentFilenames))?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty {
            if let data = raw.data(using: .utf8),
               let parsed = try? JSONDecoder().decode([String].self, from: data) {
                documentFilenames = parsed
            } else {
                let csv = raw
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                documentFilenames = csv
            }
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .documentFilenames,
                in: container,
                debugDescription: "document_filenames must be an array, JSON array string, or CSV string"
            )
        }
    }
}

struct SendProjectResultArguments: Codable {
    let projectId: String
    let destination: String
    let to: String?
    let subject: String?
    let body: String?
    let filePaths: [String]?
    let packageAs: String?
    let archiveName: String?
    let useLastChangedFiles: Bool?
    let maxFiles: Int?
    let caption: String?
    
    enum CodingKeys: String, CodingKey {
        case projectId = "project_id"
        case destination
        case to
        case subject
        case body
        case filePaths = "file_paths"
        case packageAs = "package_as"
        case archiveName = "archive_name"
        case useLastChangedFiles = "use_last_changed_files"
        case maxFiles = "max_files"
        case caption
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projectId = try container.decode(String.self, forKey: .projectId)
        destination = try container.decode(String.self, forKey: .destination)
        to = try container.decodeIfPresent(String.self, forKey: .to)
        subject = try container.decodeIfPresent(String.self, forKey: .subject)
        body = try container.decodeIfPresent(String.self, forKey: .body)
        packageAs = try container.decodeIfPresent(String.self, forKey: .packageAs)
        archiveName = try container.decodeIfPresent(String.self, forKey: .archiveName)
        useLastChangedFiles = try container.decodeIfPresent(Bool.self, forKey: .useLastChangedFiles)
        maxFiles = try container.decodeIfPresent(Int.self, forKey: .maxFiles)
        caption = try container.decodeIfPresent(String.self, forKey: .caption)
        
        if let array = try? container.decodeIfPresent([String].self, forKey: .filePaths) {
            filePaths = array
        } else if let raw = (try? container.decodeIfPresent(String.self, forKey: .filePaths))?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty {
            if let data = raw.data(using: .utf8),
               let parsed = try? JSONDecoder().decode([String].self, from: data) {
                filePaths = parsed
            } else {
                let csv = raw
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                filePaths = csv.isEmpty ? nil : csv
            }
        } else {
            filePaths = nil
        }
    }
}

struct DeployProjectToVercelArguments: Codable {
    let projectId: String
    let relativePath: String?
    let production: Bool?
    let projectName: String?
    let teamScope: String?
    let forceRelink: Bool?
    let timeoutSeconds: Int?
    let maxOutputChars: Int?
    
    enum CodingKeys: String, CodingKey {
        case projectId = "project_id"
        case relativePath = "relative_path"
        case production
        case projectName = "project_name"
        case teamScope = "team_scope"
        case forceRelink = "force_relink"
        case timeoutSeconds = "timeout_seconds"
        case maxOutputChars = "max_output_chars"
    }
}

struct ProvisionProjectDatabaseArguments: Codable {
    let projectId: String
    let provider: String?
    let databaseTitle: String?
    let instantToken: String?
    let useTemporaryApp: Bool?
    let timeoutSeconds: Int?
    let maxOutputChars: Int?
    
    enum CodingKeys: String, CodingKey {
        case projectId = "project_id"
        case provider
        case databaseTitle = "database_title"
        case instantToken = "instant_token"
        case useTemporaryApp = "use_temporary_app"
        case timeoutSeconds = "timeout_seconds"
        case maxOutputChars = "max_output_chars"
    }
}

struct PushProjectDatabaseSchemaArguments: Codable {
    let projectId: String
    let provider: String?
    let relativePath: String?
    let schemaFilePath: String?
    let permsFilePath: String?
    let instantToken: String?
    let timeoutSeconds: Int?
    let maxOutputChars: Int?
    
    enum CodingKeys: String, CodingKey {
        case projectId = "project_id"
        case provider
        case relativePath = "relative_path"
        case schemaFilePath = "schema_file_path"
        case permsFilePath = "perms_file_path"
        case instantToken = "instant_token"
        case timeoutSeconds = "timeout_seconds"
        case maxOutputChars = "max_output_chars"
    }
}

struct SyncProjectDatabaseEnvToVercelArguments: Codable {
    let projectId: String
    let relativePath: String?
    let includeSavedDatabaseEnv: Bool?
    let includeAdminToken: Bool?
    let envVars: [String: String]?
    let targets: [String]?
    let projectName: String?
    let teamId: String?
    let timeoutSeconds: Int?
    let maxOutputChars: Int?
    
    enum CodingKeys: String, CodingKey {
        case projectId = "project_id"
        case relativePath = "relative_path"
        case includeSavedDatabaseEnv = "include_saved_database_env"
        case includeAdminToken = "include_admin_token"
        case envVars = "env_vars"
        case targets
        case projectName = "project_name"
        case teamId = "team_id"
        case timeoutSeconds = "timeout_seconds"
        case maxOutputChars = "max_output_chars"
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projectId = try container.decode(String.self, forKey: .projectId)
        relativePath = try container.decodeIfPresent(String.self, forKey: .relativePath)
        includeSavedDatabaseEnv = try container.decodeIfPresent(Bool.self, forKey: .includeSavedDatabaseEnv)
        includeAdminToken = try container.decodeIfPresent(Bool.self, forKey: .includeAdminToken)
        projectName = try container.decodeIfPresent(String.self, forKey: .projectName)
        teamId = try container.decodeIfPresent(String.self, forKey: .teamId)
        timeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .timeoutSeconds)
        maxOutputChars = try container.decodeIfPresent(Int.self, forKey: .maxOutputChars)
        
        if let dict = try? container.decodeIfPresent([String: String].self, forKey: .envVars) {
            envVars = dict
        } else if let raw = (try? container.decodeIfPresent(String.self, forKey: .envVars))?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty,
                  let data = raw.data(using: .utf8),
                  let parsed = try? JSONDecoder().decode([String: String].self, from: data) {
            envVars = parsed
        } else {
            envVars = nil
        }
        
        if let array = try? container.decodeIfPresent([String].self, forKey: .targets) {
            targets = array
        } else if let raw = (try? container.decodeIfPresent(String.self, forKey: .targets))?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty {
            if let data = raw.data(using: .utf8),
               let parsed = try? JSONDecoder().decode([String].self, from: data) {
                targets = parsed
            } else {
                let csv = raw
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                targets = csv
            }
        } else {
            targets = nil
        }
    }
}

struct GenerateProjectMCPConfigArguments: Codable {
    let projectId: String
    let provider: String?
    let relativePath: String?
    let mode: String?
    let outputPath: String?
    
    enum CodingKeys: String, CodingKey {
        case projectId = "project_id"
        case provider
        case relativePath = "relative_path"
        case mode
        case outputPath = "output_path"
    }
}

private struct ClaudeProjectMetadata: Codable {
    let id: String
    let name: String
    let createdAt: Date
    let initialNotes: String?
    var projectDescription: String?
    var projectDescriptionSource: String?
    var lastEditedAt: Date?
    var sessionUuid: String?
    var codeCLISessionIds: [String: String]?
}

private enum CodeCLIProvider: String {
    case claude
    case gemini
    
    static func fromStoredValue(_ value: String?) -> CodeCLIProvider {
        guard let normalized = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() else {
            return .claude
        }
        return CodeCLIProvider(rawValue: normalized) ?? .claude
    }
    
    var displayName: String {
        switch self {
        case .claude:
            return "Claude Code"
        case .gemini:
            return "Gemini CLI"
        }
    }
}

private struct ClaudeRunRecord: Codable {
    let timestamp: Date
    let prompt: String
    let command: String
    let arguments: [String]
    let exitCode: Int32
    let timedOut: Bool
    let durationSeconds: Double
    let createdFiles: [String]
    let modifiedFiles: [String]
    let deletedFiles: [String]
    let stdoutPreview: String
    let stderrPreview: String
}

private struct ProjectSnapshotEntry {
    let size: UInt64
    let modifiedAt: Date
}

private struct ProjectDiscoveryContentSummary {
    let scannedFileCount: Int
    let reachedScanLimit: Bool
    let topExtensions: [String]
    let topAreas: [String]
}

private struct ListProjectsArguments: Codable {
    let limit: Int?
    let cursor: String?
    let query: String?
    
    enum CodingKeys: String, CodingKey {
        case limit
        case cursor
        case query
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        if let intLimit = try? container.decodeIfPresent(Int.self, forKey: .limit) {
            limit = intLimit
        } else if let stringLimit = try? container.decodeIfPresent(String.self, forKey: .limit),
                  let parsed = Int(stringLimit.trimmingCharacters(in: .whitespacesAndNewlines)) {
            limit = parsed
        } else {
            limit = nil
        }
        
        if let stringCursor = try? container.decodeIfPresent(String.self, forKey: .cursor) {
            cursor = stringCursor
        } else if let intCursor = try? container.decodeIfPresent(Int.self, forKey: .cursor) {
            cursor = String(intCursor)
        } else {
            cursor = nil
        }
        
        query = try? container.decodeIfPresent(String.self, forKey: .query)
    }
}

private struct ClaudeProjectListItem: Codable {
    let id: String
    let name: String
    let description: String?
    let createdAt: String
    let fileCount: Int
    let lastRunAt: String?
    let lastModifiedAt: String
    
    enum CodingKeys: String, CodingKey {
        case id, name, description
        case createdAt = "created_at"
        case fileCount = "file_count"
        case lastRunAt = "last_run_at"
        case lastModifiedAt = "last_modified_at"
    }
}

private struct ClaudeProjectListResult: Codable {
    let success: Bool
    let projectCount: Int
    let returnedCount: Int
    let hasMore: Bool
    let nextCursor: String?
    let order: String
    let cursorUsed: String?
    let projects: [ClaudeProjectListItem]
    let message: String
    
    enum CodingKeys: String, CodingKey {
        case success, projects, message, order
        case projectCount = "project_count"
        case returnedCount = "returned_count"
        case hasMore = "has_more"
        case nextCursor = "next_cursor"
        case cursorUsed = "cursor_used"
    }
}

private struct ClaudeProjectBrowseEntry: Codable {
    let relativePath: String
    let type: String
    let sizeBytes: Int?
    let modifiedAt: String?
    
    enum CodingKeys: String, CodingKey {
        case type
        case relativePath = "relative_path"
        case sizeBytes = "size_bytes"
        case modifiedAt = "modified_at"
    }
}

private struct ClaudeProjectBrowseResult: Codable {
    let success: Bool
    let projectId: String
    let basePath: String
    let recursive: Bool
    let entryCount: Int
    let entries: [ClaudeProjectBrowseEntry]
    let message: String
    
    enum CodingKeys: String, CodingKey {
        case success, recursive, entries, message
        case projectId = "project_id"
        case basePath = "base_path"
        case entryCount = "entry_count"
    }
}

private struct ClaudeReadProjectTextResult: Codable {
    let success: Bool
    let projectId: String
    let relativePath: String
    let content: String
    let truncated: Bool
    let totalCharacters: Int
    let message: String
    
    enum CodingKeys: String, CodingKey {
        case success, content, truncated, message
        case projectId = "project_id"
        case relativePath = "relative_path"
        case totalCharacters = "total_characters"
    }
}

private struct ClaudeProjectImportedFile: Codable {
    let sourceFilename: String
    let destinationRelativePath: String
    let sizeBytes: Int
    
    enum CodingKeys: String, CodingKey {
        case sourceFilename = "source_filename"
        case destinationRelativePath = "destination_relative_path"
        case sizeBytes = "size_bytes"
    }
}

private struct ClaudeAddProjectFilesResult: Codable {
    let success: Bool
    let projectId: String
    let destinationPath: String
    let requestedCount: Int
    let addedCount: Int
    let addedFiles: [ClaudeProjectImportedFile]
    let missingDocuments: [String]
    let rejectedFilenames: [String]
    let projectDescription: String?
    let projectLastEditedAt: String?
    let message: String
    
    enum CodingKeys: String, CodingKey {
        case success, message
        case projectId = "project_id"
        case destinationPath = "destination_path"
        case requestedCount = "requested_count"
        case addedCount = "added_count"
        case addedFiles = "added_files"
        case missingDocuments = "missing_documents"
        case rejectedFilenames = "rejected_filenames"
        case projectDescription = "project_description"
        case projectLastEditedAt = "project_last_edited_at"
    }
}

private struct ClaudeRunResult: Codable {
    let success: Bool
    let projectId: String
    let command: String
    let exitCode: Int32
    let timedOut: Bool
    let permissionBlocked: Bool
    let durationSeconds: Double
    let createdFiles: [String]
    let modifiedFiles: [String]
    let deletedFiles: [String]
    let fileChangesDetected: Bool
    let projectDescription: String?
    let projectLastEditedAt: String?
    let stdout: String
    let stderr: String
    let logFile: String
    let message: String
    
    enum CodingKeys: String, CodingKey {
        case success, command, stdout, stderr, message
        case projectId = "project_id"
        case exitCode = "exit_code"
        case timedOut = "timed_out"
        case permissionBlocked = "permission_blocked"
        case durationSeconds = "duration_seconds"
        case createdFiles = "created_files"
        case modifiedFiles = "modified_files"
        case deletedFiles = "deleted_files"
        case fileChangesDetected = "file_changes_detected"
        case projectDescription = "project_description"
        case projectLastEditedAt = "project_last_edited_at"
        case logFile = "log_file"
    }
}

private struct ClaudeProjectHistoryResult: Codable {
    let success: Bool
    let projectId: String
    let history: String
    let message: String
    
    enum CodingKeys: String, CodingKey {
        case success, history, message
        case projectId = "project_id"
    }
}

private struct ClaudeInvocation {
    let executableURL: URL
    let arguments: [String]
    let displayCommand: String
}

private struct ClaudeExecutionOutput {
    let exitCode: Int32
    let timedOut: Bool
    let stdout: String
    let stderr: String
}

private struct GeminiJSONError: Decodable {
    let type: String?
    let message: String?
    let code: String?
}

private struct GeminiJSONOutput: Decodable {
    let sessionId: String?
    let response: String?
    let error: GeminiJSONError?
    
    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case response
        case error
    }
}

private struct SendProjectResultOutput: Codable {
    let success: Bool
    let projectId: String
    let destination: String
    let fileCount: Int
    let files: [String]
    let packageAs: String
    let packagedFileCount: Int?
    let message: String
    
    enum CodingKeys: String, CodingKey {
        case success, destination, files, message
        case projectId = "project_id"
        case fileCount = "file_count"
        case packageAs = "package_as"
        case packagedFileCount = "packaged_file_count"
    }
}

private struct VercelDeployResult: Codable {
    let success: Bool
    let projectId: String
    let relativePath: String
    let mode: String
    let deploymentUrl: String?
    let projectName: String?
    let teamScope: String?
    let linked: Bool
    let command: String?
    let exitCode: Int32?
    let timedOut: Bool?
    let stdout: String?
    let stderr: String?
    let message: String
    
    enum CodingKeys: String, CodingKey {
        case success, mode, message, linked, stdout, stderr, command
        case projectId = "project_id"
        case relativePath = "relative_path"
        case deploymentUrl = "deployment_url"
        case projectName = "project_name"
        case teamScope = "team_scope"
        case exitCode = "exit_code"
        case timedOut = "timed_out"
    }
}

private struct ProjectDatabaseMetadata: Codable {
    let provider: String
    var databaseTitle: String
    var appId: String?
    var createdAt: Date?
    var schemaLastPushedAt: Date?
    var lastUpdatedAt: Date
}

private struct ShowProjectDeploymentToolsResult: Codable {
    let success: Bool
    let unlockedForCurrentTurn: Bool
    let tools: [String]
    let message: String
    
    enum CodingKeys: String, CodingKey {
        case success, tools, message
        case unlockedForCurrentTurn = "unlocked_for_current_turn"
    }
}

private struct ProvisionProjectDatabaseResult: Codable {
    let success: Bool
    let projectId: String
    let provider: String
    let databaseTitle: String
    let appId: String?
    let savedAdminToken: Bool
    let command: String?
    let exitCode: Int32?
    let timedOut: Bool?
    let diagnosticExcerpt: String?
    let logFile: String?
    let message: String
    
    enum CodingKeys: String, CodingKey {
        case success, provider, command, message
        case projectId = "project_id"
        case databaseTitle = "database_title"
        case appId = "app_id"
        case savedAdminToken = "saved_admin_token"
        case exitCode = "exit_code"
        case timedOut = "timed_out"
        case diagnosticExcerpt = "diagnostic_excerpt"
        case logFile = "log_file"
    }
}

private struct PushProjectDatabaseSchemaResult: Codable {
    let success: Bool
    let projectId: String
    let provider: String
    let appId: String?
    let command: String?
    let exitCode: Int32?
    let timedOut: Bool?
    let diagnosticExcerpt: String?
    let logFile: String?
    let message: String
    
    enum CodingKeys: String, CodingKey {
        case success, provider, command, message
        case projectId = "project_id"
        case appId = "app_id"
        case exitCode = "exit_code"
        case timedOut = "timed_out"
        case diagnosticExcerpt = "diagnostic_excerpt"
        case logFile = "log_file"
    }
}

private struct SyncProjectDatabaseEnvToVercelResult: Codable {
    let success: Bool
    let projectId: String
    let relativePath: String
    let projectIdentifier: String
    let targets: [String]
    let requestedCount: Int
    let syncedCount: Int
    let failedKeys: [String]
    let message: String
    
    enum CodingKeys: String, CodingKey {
        case success, targets, message
        case projectId = "project_id"
        case relativePath = "relative_path"
        case projectIdentifier = "project_identifier"
        case requestedCount = "requested_count"
        case syncedCount = "synced_count"
        case failedKeys = "failed_keys"
    }
}

private struct GenerateProjectMCPConfigResult: Codable {
    let success: Bool
    let projectId: String
    let provider: String
    let mode: String
    let relativePath: String
    let outputPath: String
    let message: String
    
    enum CodingKeys: String, CodingKey {
        case success, provider, mode, message
        case projectId = "project_id"
        case relativePath = "relative_path"
        case outputPath = "output_path"
    }
}

extension ToolExecutor {
    private var projectsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport.appendingPathComponent("TelegramConcierge/projects", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
    
    private var isoFormatter: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }
    
    private func encodeJSON<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value),
              let json = String(data: data, encoding: .utf8) else {
            return #"{"error":"Failed to encode result"}"#
        }
        return json
    }
    
    private func executeCreateProject(_ call: ToolCall) async -> String {
        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(CreateProjectArguments.self, from: argsData) else {
            return #"{"error":"Failed to parse create_project arguments"}"#
        }
        
        let baseName = sanitizeProjectName(args.projectName)
        let projectId = "\(baseName)-\(String(UUID().uuidString.prefix(8)).lowercased())"
        let projectURL = projectsDirectory.appendingPathComponent(projectId, isDirectory: true)
        
        do {
            try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
            
                var metadata = ClaudeProjectMetadata(
                    id: projectId,
                    name: args.projectName.trimmingCharacters(in: .whitespacesAndNewlines),
                    createdAt: Date(),
                    initialNotes: args.initialNotes,
                    projectDescription: nil,
                    projectDescriptionSource: nil,
                    lastEditedAt: nil
                )
            
                metadata.projectDescription = await generateProjectDescriptionOnCreate(
                    projectName: metadata.name,
                    initialNotes: metadata.initialNotes
                )
                metadata.projectDescriptionSource = "create_generated"
            let metadataURL = projectURL.appendingPathComponent(".project.json")
            let metadataData = try JSONEncoder().encode(metadata)
            try metadataData.write(to: metadataURL)
            
            let notes = args.initialNotes?.trimmingCharacters(in: .whitespacesAndNewlines)
            let readmeContent = """
            # \(args.projectName)
            
            Project ID: \(projectId)
            Created: \(isoFormatter.string(from: Date()))
            
            \(notes?.isEmpty == false ? "## Initial Notes\n\n\(notes!)\n" : "")
            """
            try readmeContent.write(
                to: projectURL.appendingPathComponent("README.md"),
                atomically: true,
                encoding: .utf8
            )
            
            return """
            {
              "success": true,
              "project_id": "\(projectId)",
              "project_name": "\(args.projectName.replacingOccurrences(of: "\"", with: "\\\""))",
              "path": "\(projectURL.path.replacingOccurrences(of: "\"", with: "\\\""))",
              "message": "Project created. Use run_claude_code with this project_id."
            }
            """
        } catch {
            return #"{"error":"Failed to create project: \#(error.localizedDescription)"}"#
        }
    }
    
    private func executeListProjects(_ call: ToolCall) async -> String {
        let fileManager = FileManager.default
        let defaultLimit = 20
        let maxLimit = 100
        
        var limit = defaultLimit
        var pageOffset = 0
        var cursorUsed: String?
        var searchQuery: String?
        
        let rawArguments = call.function.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rawArguments.isEmpty && rawArguments != "{}" {
            guard let argsData = rawArguments.data(using: .utf8),
                  let args = try? JSONDecoder().decode(ListProjectsArguments.self, from: argsData) else {
                return #"{"error":"Failed to parse list_projects arguments"}"#
            }
            
            if let requestedLimit = args.limit {
                limit = min(max(requestedLimit, 1), maxLimit)
            }
            
            if let rawCursor = args.cursor?.trimmingCharacters(in: .whitespacesAndNewlines), !rawCursor.isEmpty {
                guard let parsedOffset = parseListDocumentsCursor(rawCursor) else {
                    return #"{"error":"Invalid cursor '\(rawCursor)'. Use next_cursor from the previous list_projects response."}"#
                }
                pageOffset = parsedOffset
                cursorUsed = rawCursor
            }
            
            if let q = args.query?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty {
                searchQuery = q.lowercased()
            }
        }
        
        do {
            let urls = try fileManager.contentsOfDirectory(
                at: projectsDirectory,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            
            struct IndexedProject {
                let item: ClaudeProjectListItem
                let createdAt: Date
                let lastModifiedAt: Date
            }
            
            var indexedProjects: [IndexedProject] = []
            for url in urls {
                var isDir: ObjCBool = false
                guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
                    continue
                }
                
                var metadata = ensureProjectMetadata(projectURL: url)
                let hasDescription = !(metadata.projectDescription?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty ?? true)
                if !hasDescription {
                    metadata.projectDescription = buildDiscoveryProjectDescription(
                        projectURL: url,
                        projectName: metadata.name
                    )
                    metadata.projectDescriptionSource = "discovery_scan"
                    saveProjectMetadata(metadata, projectURL: url)
                }
                let runRecord = loadLastRunRecord(projectURL: url)
                let resourceValues = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                let attrs = try? fileManager.attributesOfItem(atPath: url.path)
                let createdAt = (attrs?[.creationDate] as? Date) ?? metadata.createdAt
                let directoryModifiedAt = resourceValues?.contentModificationDate ?? (attrs?[.modificationDate] as? Date)
                let lastModifiedAt = [metadata.lastEditedAt, directoryModifiedAt, createdAt]
                    .compactMap { $0 }
                    .max() ?? createdAt
                let item = ClaudeProjectListItem(
                    id: metadata.id,
                    name: metadata.name,
                    description: metadata.projectDescription,
                    createdAt: isoFormatter.string(from: createdAt),
                    fileCount: countProjectFiles(projectURL: url),
                    lastRunAt: runRecord.map { isoFormatter.string(from: $0.timestamp) },
                    lastModifiedAt: isoFormatter.string(from: lastModifiedAt)
                )
                
                if let query = searchQuery {
                    let textToSearch = [item.name, item.id, item.description ?? ""].joined(separator: " ").lowercased()
                    if !textToSearch.contains(query) {
                        continue // Skip if doesn't match query
                    }
                }
                
                indexedProjects.append(IndexedProject(item: item, createdAt: createdAt, lastModifiedAt: lastModifiedAt))
            }
            
            indexedProjects.sort { lhs, rhs in
                if lhs.lastModifiedAt != rhs.lastModifiedAt {
                    return lhs.lastModifiedAt > rhs.lastModifiedAt
                }
                if lhs.createdAt != rhs.createdAt {
                    return lhs.createdAt > rhs.createdAt
                }
                return lhs.item.name.localizedCaseInsensitiveCompare(rhs.item.name) == .orderedAscending
            }
            
            let totalProjects = indexedProjects.count
            let start = min(max(pageOffset, 0), totalProjects)
            let end = min(start + limit, totalProjects)
            let pageProjects = Array(indexedProjects[start..<end]).map(\.item)
            let hasMore = end < totalProjects
            let nextCursor = hasMore ? String(end) : nil
            
            let message: String
            if totalProjects == 0 {
                if searchQuery != nil {
                    message = "No projects found matching the search query."
                } else {
                    message = "No projects found. Use create_project to create a workspace."
                }
            } else if pageProjects.isEmpty {
                message = "No projects found for cursor \(pageOffset). Use a smaller cursor to see available pages."
            } else if let nextCursor {
                message = "Showing \(pageProjects.count) of \(totalProjects) projects sorted by last_modified_at (newest first). Use cursor '\(nextCursor)' for the next page."
            } else {
                message = "Showing \(pageProjects.count) of \(totalProjects) projects sorted by last_modified_at (newest first). Reached the end."
            }
            
            let result = ClaudeProjectListResult(
                success: true,
                projectCount: totalProjects,
                returnedCount: pageProjects.count,
                hasMore: hasMore,
                nextCursor: nextCursor,
                order: "last_modified_at_desc",
                cursorUsed: cursorUsed,
                projects: pageProjects,
                message: message
            )
            return encodeJSON(result)
        } catch {
            return #"{"error":"Failed to list projects: \#(error.localizedDescription)"}"#
        }
    }
    
    private func executeBrowseProject(_ call: ToolCall) async -> String {
        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(BrowseProjectArguments.self, from: argsData) else {
            return #"{"error":"Failed to parse browse_project arguments"}"#
        }
        
        guard let projectURL = resolveProjectDirectory(projectId: args.projectId) else {
            return #"{"error":"Project not found. Use list_projects first."}"#
        }
        
        let relativeBase = (args.relativePath ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL = resolvePath(in: projectURL, relativePath: relativeBase.isEmpty ? "." : relativeBase) else {
            return #"{"error":"Invalid relative_path. Path must stay inside the project."}"#
        }
        
        let recursive = args.recursive ?? false
        let maxEntries = min(max(args.maxEntries ?? 200, 1), 1000)
        
        do {
            let entries = try listProjectEntries(
                projectURL: projectURL,
                baseURL: baseURL,
                recursive: recursive,
                maxEntries: maxEntries
            )
            
            let result = ClaudeProjectBrowseResult(
                success: true,
                projectId: args.projectId,
                basePath: relativeBase.isEmpty ? "." : relativeBase,
                recursive: recursive,
                entryCount: entries.count,
                entries: entries,
                message: entries.isEmpty ? "No files found in the selected path." : "Listed \(entries.count) entr\(entries.count == 1 ? "y" : "ies")."
            )
            return encodeJSON(result)
        } catch {
            return #"{"error":"Failed to browse project: \#(error.localizedDescription)"}"#
        }
    }
    
    private func executeReadProjectFile(_ call: ToolCall) async -> ToolResultMessage {
        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(ReadProjectFileArguments.self, from: argsData) else {
            return ToolResultMessage(toolCallId: call.id, content: #"{"error":"Failed to parse read_project_file arguments"}"#)
        }
        
        guard let projectURL = resolveProjectDirectory(projectId: args.projectId) else {
            return ToolResultMessage(toolCallId: call.id, content: #"{"error":"Project not found. Use list_projects first."}"#)
        }
        
        guard let fileURL = resolvePath(in: projectURL, relativePath: args.relativePath) else {
            return ToolResultMessage(toolCallId: call.id, content: #"{"error":"Invalid relative_path. Path must stay inside the project."}"#)
        }
        
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir), !isDir.boolValue else {
            return ToolResultMessage(toolCallId: call.id, content: #"{"error":"File not found at relative_path."}"#)
        }
        
        do {
            let data = try Data(contentsOf: fileURL)
            if data.count > 8_000_000 {
                return ToolResultMessage(toolCallId: call.id, content: #"{"error":"File is too large to load (>8MB)."}"#)
            }
            
            let maxChars = min(max(args.maxChars ?? 12_000, 500), 200_000)
            let relativePath = relativePath(from: projectURL, to: fileURL)
            
            if let text = String(data: data, encoding: .utf8) {
                let truncated = text.count > maxChars
                let content = truncated ? String(text.prefix(maxChars)) : text
                let result = ClaudeReadProjectTextResult(
                    success: true,
                    projectId: args.projectId,
                    relativePath: relativePath,
                    content: content,
                    truncated: truncated,
                    totalCharacters: text.count,
                    message: truncated ? "Text file loaded (truncated)." : "Text file loaded."
                )
                return ToolResultMessage(toolCallId: call.id, content: encodeJSON(result))
            }
            
            let mimeType = getMimeType(for: fileURL.lastPathComponent)
            let attachment = FileAttachment(
                data: data,
                mimeType: mimeType,
                filename: "\(args.projectId)_\(fileURL.lastPathComponent)"
            )
            
            let result = """
            {"success": true, "project_id": "\(args.projectId)", "relative_path": "\(relativePath.replacingOccurrences(of: "\"", with: "\\\""))", "mime_type": "\(mimeType)", "size_bytes": \(data.count), "message": "Binary file loaded and visible for analysis."}
            """
            return ToolResultMessage(toolCallId: call.id, content: result, fileAttachment: attachment)
        } catch {
            return ToolResultMessage(toolCallId: call.id, content: #"{"error":"Failed to read project file: \#(error.localizedDescription)"}"#)
        }
    }
    
    private func executeAddProjectFiles(_ call: ToolCall) async -> String {
        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(AddProjectFilesArguments.self, from: argsData) else {
            return #"{"error":"Failed to parse add_project_files arguments"}"#
        }
        
        guard !args.documentFilenames.isEmpty else {
            return #"{"error":"No document_filenames provided. Use list_documents first."}"#
        }
        
        guard let projectURL = resolveProjectDirectory(projectId: args.projectId) else {
            return #"{"error":"Project not found. Use list_projects first."}"#
        }
        
        let sourceDirectoryName = (args.sourceDirectory ?? "documents")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let sourceRootURL: URL
        switch sourceDirectoryName {
        case "documents":
            sourceRootURL = documentsDirectory
        case "images":
            sourceRootURL = imagesDirectory
        default:
            return #"{"error":"source_directory must be 'documents' or 'images'."}"#
        }
        
        let destinationRelative = (args.relativePath ?? ".").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let destinationURL = resolvePath(in: projectURL, relativePath: destinationRelative.isEmpty ? "." : destinationRelative) else {
            return #"{"error":"Invalid relative_path. Path must stay inside the project."}"#
        }
        
        let fileManager = FileManager.default
        do {
            if fileManager.fileExists(atPath: destinationURL.path) {
                var isDir: ObjCBool = false
                guard fileManager.fileExists(atPath: destinationURL.path, isDirectory: &isDir), isDir.boolValue else {
                    return #"{"error":"relative_path exists but is not a directory."}"#
                }
            } else {
                try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
            }
        } catch {
            return #"{"error":"Failed to prepare destination folder: \#(error.localizedDescription)"}"#
        }
        
        let shouldOverwrite = args.overwrite ?? false
        var addedFiles: [ClaudeProjectImportedFile] = []
        var missingDocuments: [String] = []
        var rejectedFilenames: [String] = []
        var extractedArchiveCount = 0
        
        for rawFilename in args.documentFilenames {
            let filename = rawFilename.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isSafeDocumentFilename(filename) else {
                rejectedFilenames.append(rawFilename)
                continue
            }
            
            let sourceURL = sourceRootURL.appendingPathComponent(filename)
            var sourceIsDir: ObjCBool = false
            guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &sourceIsDir), !sourceIsDir.boolValue else {
                missingDocuments.append(filename)
                continue
            }
            
            if sourceURL.pathExtension.lowercased() == "zip" {
                do {
                    let imported = try await importZipArchive(
                        sourceArchiveURL: sourceURL,
                        sourceFilename: filename,
                        destinationURL: destinationURL,
                        projectURL: projectURL,
                        overwriteExisting: shouldOverwrite
                    )
                    
                    if imported.isEmpty {
                        rejectedFilenames.append(filename)
                        continue
                    }
                    
                    addedFiles.append(contentsOf: imported)
                    extractedArchiveCount += 1
                } catch {
                    print("[ToolExecutor] Failed to import ZIP archive \(filename): \(error)")
                    rejectedFilenames.append(filename)
                }
                continue
            }
            
            let destinationFileURL: URL
            if shouldOverwrite {
                destinationFileURL = destinationURL.appendingPathComponent(sourceURL.lastPathComponent)
                if fileManager.fileExists(atPath: destinationFileURL.path) {
                    try? fileManager.removeItem(at: destinationFileURL)
                }
            } else {
                destinationFileURL = nextAvailableFileURL(
                    in: destinationURL,
                    preferredFilename: sourceURL.lastPathComponent
                )
            }
            
            do {
                try fileManager.copyItem(at: sourceURL, to: destinationFileURL)
                let attrs = try? fileManager.attributesOfItem(atPath: destinationFileURL.path)
                let sizeBytes = (attrs?[.size] as? NSNumber)?.intValue ?? 0
                let destinationRelativePath = relativePath(from: projectURL, to: destinationFileURL)
                addedFiles.append(ClaudeProjectImportedFile(
                    sourceFilename: filename,
                    destinationRelativePath: destinationRelativePath,
                    sizeBytes: sizeBytes
                ))
            } catch {
                rejectedFilenames.append(filename)
            }
        }
        
        let updatedMetadata: ClaudeProjectMetadata?
        if !addedFiles.isEmpty {
            let changePrompt = "Imported user-provided files into project folder at \(destinationRelative.isEmpty ? "." : destinationRelative)."
            updatedMetadata = await updateProjectMetadataAfterRun(
                projectURL: projectURL,
                projectId: args.projectId,
                prompt: changePrompt,
                createdFiles: addedFiles.map { $0.destinationRelativePath },
                modifiedFiles: [],
                deletedFiles: [],
                stdout: "",
                stderr: "",
                fileChangesDetected: true
            )
        } else {
            updatedMetadata = loadProjectMetadata(projectURL: projectURL)
        }
        
        let result = ClaudeAddProjectFilesResult(
            success: !addedFiles.isEmpty,
            projectId: args.projectId,
            destinationPath: destinationRelative.isEmpty ? "." : destinationRelative,
            requestedCount: args.documentFilenames.count,
            addedCount: addedFiles.count,
            addedFiles: addedFiles,
            missingDocuments: missingDocuments,
            rejectedFilenames: rejectedFilenames,
            projectDescription: updatedMetadata?.projectDescription,
            projectLastEditedAt: updatedMetadata?.lastEditedAt.map { isoFormatter.string(from: $0) },
            message: addedFiles.isEmpty
                ? "No files were added. Use list_documents to confirm filenames."
                : (extractedArchiveCount > 0
                   ? "Added \(addedFiles.count) file(s) to project workspace (extracted \(extractedArchiveCount) ZIP archive(s))."
                   : "Added \(addedFiles.count) file(s) to project workspace.")
        )
        
        return encodeJSON(result)
    }
    
    private func executeViewProjectHistory(_ call: ToolCall) async -> String {
        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(ViewProjectHistoryArguments.self, from: argsData) else {
            return #"{"error":"Failed to parse view_project_history arguments"}"#
        }
        
        guard let projectURL = resolveProjectDirectory(projectId: args.projectId) else {
            return #"{"error":"Project not found. Use list_projects first."}"#
        }
        
        let maxTokens = min(max(args.maxTokens ?? 10_000, 500), 20_000)
        guard let historyContext = buildProjectHistoryContext(
            projectURL: projectURL,
            projectId: args.projectId,
            maxTokens: maxTokens
        ) else {
            return #"{"error":"No run history found for this project yet."}"#
        }
        
        let result = ClaudeProjectHistoryResult(
            success: true,
            projectId: args.projectId,
            history: historyContext,
            message: "Loaded recent project run history."
        )
        
        return encodeJSON(result)
    }
    
    private func executeRunClaudeCode(_ call: ToolCall) async -> String {
        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(RunClaudeCodeArguments.self, from: argsData) else {
            return #"{"error":"Failed to parse run_claude_code arguments"}"#
        }
        
        guard let projectURL = resolveProjectDirectory(projectId: args.projectId) else {
            return #"{"error":"Project not found. Use list_projects first."}"#
        }
        
        let provider = resolvedCodeCLIProvider()
        let configuredCommand = loadCodeCLICommand(for: provider)
        let command = configuredCommand.isEmpty
            ? (provider == .gemini ? KeychainHelper.defaultGeminiCodeCommand : "claude")
            : configuredCommand
        
        var configuredArgs = loadCodeCLIArguments(for: provider)
        if provider == .claude, isLegacyAcceptEditsArgumentString(configuredArgs) {
            configuredArgs = KeychainHelper.defaultClaudeCodeArgs
            try? KeychainHelper.save(key: KeychainHelper.claudeCodeArgsKey, value: configuredArgs)
        }
        
        let rawArgString = args.cliArgs?.trimmingCharacters(in: .whitespacesAndNewlines)
        let argString = (rawArgString?.isEmpty == false) ? rawArgString! : configuredArgs
        let hasPerCallCliOverride = rawArgString?.isEmpty == false
        var parsedArgs = parseCommandLineArguments(argString)
        
        var metadata = ensureProjectMetadata(projectURL: projectURL)
        if provider == .claude {
            if !parsedArgs.contains("-p") && !parsedArgs.contains("--print") {
                parsedArgs.insert("-p", at: 0)
            }
            
            if let existingSession = codeCLISessionID(for: .claude, metadata: metadata) {
                parsedArgs.insert(contentsOf: ["-r", existingSession], at: 0)
            } else {
                let newSession = UUID().uuidString
                setCodeCLISessionID(newSession, for: .claude, metadata: &metadata)
                saveProjectMetadata(metadata, projectURL: projectURL)
                parsedArgs.insert(contentsOf: ["--session-id", newSession], at: 0)
            }
        } else {
            ensureGeminiHeadlessArguments(&parsedArgs)
            if let existingSession = codeCLISessionID(for: .gemini, metadata: metadata) {
                parsedArgs.insert(contentsOf: ["-r", existingSession], at: 0)
            }
        }
        
        let configuredTimeout = loadCodeCLITimeout(for: provider)
        let timeoutSeconds = min(max(args.timeoutSeconds ?? configuredTimeout, 30), 3600)
        let maxOutputChars = min(max(args.maxOutputChars ?? 12_000, 500), 100_000)
        
        let preSnapshot = snapshotProjectFiles(projectURL: projectURL)
        let startTime = Date()
        let baseEnvironment = codeCLIBaseEnvironment(for: provider)
        let invocations = buildCodeCLIInvocations(
            command: command,
            cliArgs: parsedArgs,
            prompt: args.prompt,
            provider: provider
        )
        
        guard !invocations.isEmpty else {
            let providerName = provider.displayName.replacingOccurrences(of: "\"", with: "\\\"")
            return #"{"error":"No valid \#(providerName) command invocation was generated. Check Code CLI settings."}"#
        }
        
        var launchErrors: [String] = []
        var selectedInvocation: ClaudeInvocation?
        var execution: ClaudeExecutionOutput?
        
        for invocation in invocations {
            do {
                var activeInvocation = invocation
                var activeEnvironment = baseEnvironment
                var result = try await runCodeCLIInvocation(
                    activeInvocation,
                    projectURL: projectURL,
                    environment: activeEnvironment,
                    timeoutSeconds: timeoutSeconds,
                    maxOutputChars: maxOutputChars
                )
                
                if provider == .claude {
                    // Sandboxed contexts can block writes to ~/.claude.
                    // If that happens, retry with an app-local config directory.
                    if shouldRetryClaudeWithAppConfig(stderr: result.stderr) && baseEnvironment["CLAUDE_CONFIG_DIR"] == nil {
                        var retryEnvironment = baseEnvironment
                        retryEnvironment["CLAUDE_CONFIG_DIR"] = claudeConfigDirectory.path
                        
                        do {
                            let retryResult = try await runCodeCLIInvocation(
                                activeInvocation,
                                projectURL: projectURL,
                                environment: retryEnvironment,
                                timeoutSeconds: timeoutSeconds,
                                maxOutputChars: maxOutputChars
                            )
                            result = ClaudeExecutionOutput(
                                exitCode: retryResult.exitCode,
                                timedOut: retryResult.timedOut,
                                stdout: retryResult.stdout,
                                stderr: retryResult.stderr + "\n[TelegramConcierge] Retried with CLAUDE_CONFIG_DIR=\(claudeConfigDirectory.path)"
                            )
                            activeEnvironment = retryEnvironment
                        } catch {
                            launchErrors.append("\(invocation.displayCommand) (retry with CLAUDE_CONFIG_DIR): \(error.localizedDescription)")
                        }
                    }
                    
                    if !hasPerCallCliOverride,
                       shouldRetryClaudeWithBypassPermissions(
                        stdout: result.stdout,
                        stderr: result.stderr,
                        arguments: activeInvocation.arguments
                       ) {
                        let bypassArgs = applyBypassPermissionMode(to: activeInvocation.arguments)
                        if bypassArgs != activeInvocation.arguments {
                            let bypassInvocation = ClaudeInvocation(
                                executableURL: activeInvocation.executableURL,
                                arguments: bypassArgs,
                                displayCommand: displayCodeCLIInvocationCommand(
                                    executable: activeInvocation.executableURL.path,
                                    arguments: bypassArgs
                                )
                            )
                            
                            do {
                                let retryResult = try await runCodeCLIInvocation(
                                    bypassInvocation,
                                    projectURL: projectURL,
                                    environment: activeEnvironment,
                                    timeoutSeconds: timeoutSeconds,
                                    maxOutputChars: maxOutputChars
                                )
                                result = ClaudeExecutionOutput(
                                    exitCode: retryResult.exitCode,
                                    timedOut: retryResult.timedOut,
                                    stdout: retryResult.stdout,
                                    stderr: retryResult.stderr + "\n[TelegramConcierge] Retried with --permission-mode bypassPermissions after detecting approval deadlock."
                                )
                                activeInvocation = bypassInvocation
                            } catch {
                                launchErrors.append("\(invocation.displayCommand) (retry with bypassPermissions): \(error.localizedDescription)")
                            }
                        }
                    }
                } else if shouldRetryGeminiWithoutResume(
                    stdout: result.stdout,
                    stderr: result.stderr,
                    arguments: activeInvocation.arguments
                ) {
                    let retryArgs = removingGeminiResumeArguments(from: activeInvocation.arguments)
                    if retryArgs != activeInvocation.arguments {
                        let retryInvocation = ClaudeInvocation(
                            executableURL: activeInvocation.executableURL,
                            arguments: retryArgs,
                            displayCommand: displayCodeCLIInvocationCommand(
                                executable: activeInvocation.executableURL.path,
                                arguments: retryArgs
                            )
                        )
                        
                        do {
                            let retryResult = try await runCodeCLIInvocation(
                                retryInvocation,
                                projectURL: projectURL,
                                environment: activeEnvironment,
                                timeoutSeconds: timeoutSeconds,
                                maxOutputChars: maxOutputChars
                            )
                            result = ClaudeExecutionOutput(
                                exitCode: retryResult.exitCode,
                                timedOut: retryResult.timedOut,
                                stdout: retryResult.stdout,
                                stderr: retryResult.stderr + "\n[TelegramConcierge] Retried without --resume after an invalid/missing session reference."
                            )
                            activeInvocation = retryInvocation
                            clearCodeCLISessionID(for: .gemini, metadata: &metadata)
                            saveProjectMetadata(metadata, projectURL: projectURL)
                        } catch {
                            launchErrors.append("\(invocation.displayCommand) (retry without --resume): \(error.localizedDescription)")
                        }
                    }
                }
                
                selectedInvocation = activeInvocation
                execution = result
                break
            } catch {
                launchErrors.append("\(invocation.displayCommand): \(error.localizedDescription)")
            }
        }
        
        guard let finalInvocation = selectedInvocation, let finalExecution = execution else {
            let details = launchErrors.isEmpty
                ? "No launch diagnostics available."
                : launchErrors.joined(separator: " | ")
            let safeDetails = redactSensitiveContextForModel(details).replacingOccurrences(of: "\"", with: "\\\"")
            let safeCommand = redactSensitiveContextForModel(command).replacingOccurrences(of: "\"", with: "\\\"")
            let providerName = provider.displayName.replacingOccurrences(of: "\"", with: "\\\"")
            return #"{"error":"Failed to launch \#(providerName) command '\#(safeCommand)'. Attempts: \#(safeDetails)"}"#
        }
        
        var normalizedStdout = finalExecution.stdout
        var normalizedStderr = finalExecution.stderr
        var providerReportedErrorMessage: String?
        
        if provider == .gemini {
            if let parsedOutput = parseGeminiJSONOutput(finalExecution.stdout) {
                if let sessionId = parsedOutput.sessionId?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !sessionId.isEmpty {
                    if codeCLISessionID(for: .gemini, metadata: metadata) != sessionId {
                        setCodeCLISessionID(sessionId, for: .gemini, metadata: &metadata)
                        saveProjectMetadata(metadata, projectURL: projectURL)
                    }
                }
                
                if let response = parsedOutput.response?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !response.isEmpty {
                    normalizedStdout = response
                }
                
                if let errorMessage = parsedOutput.error?.message?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !errorMessage.isEmpty {
                    providerReportedErrorMessage = errorMessage
                    if normalizedStderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        normalizedStderr = errorMessage
                    } else if !normalizedStderr.contains(errorMessage) {
                        normalizedStderr += "\n\(errorMessage)"
                    }
                }
            }
        }
        
        let postSnapshot = snapshotProjectFiles(projectURL: projectURL)
        let (createdFiles, modifiedFiles, deletedFiles) = diffSnapshots(before: preSnapshot, after: postSnapshot)
        let fileChangesDetected = !(createdFiles.isEmpty && modifiedFiles.isEmpty && deletedFiles.isEmpty)
        
        let updatedMetadata = await updateProjectMetadataAfterRun(
            projectURL: projectURL,
            projectId: args.projectId,
            prompt: args.prompt,
            createdFiles: createdFiles,
            modifiedFiles: modifiedFiles,
            deletedFiles: deletedFiles,
            stdout: normalizedStdout,
            stderr: normalizedStderr,
            fileChangesDetected: fileChangesDetected
        )
        let duration = Date().timeIntervalSince(startTime)
        
        let runRecord = ClaudeRunRecord(
            timestamp: Date(),
            prompt: args.prompt,
            command: finalInvocation.displayCommand,
            arguments: finalInvocation.arguments,
            exitCode: finalExecution.exitCode,
            timedOut: finalExecution.timedOut,
            durationSeconds: duration,
            createdFiles: createdFiles,
            modifiedFiles: modifiedFiles,
            deletedFiles: deletedFiles,
            stdoutPreview: normalizedStdout,
            stderrPreview: normalizedStderr
        )
        
        let logFile = persistRunRecord(runRecord, projectURL: projectURL)
        
        let permissionBlocked = containsCodeCLIPermissionPromptSignal(
            provider: provider,
            text: normalizedStdout + "\n" + normalizedStderr
        )
        let providerReturnedError = providerReportedErrorMessage != nil
        let success = finalExecution.exitCode == 0 && !finalExecution.timedOut && !permissionBlocked && !providerReturnedError
        let safeCommand = redactSensitiveContextForModel(finalInvocation.displayCommand)
        let safeStdout = redactSensitiveContextForModel(normalizedStdout)
        let safeStderr = redactSensitiveContextForModel(normalizedStderr)
        let modelOutputRedacted = safeStdout != normalizedStdout || safeStderr != normalizedStderr
        
        let baseMessage: String
        if success {
            baseMessage = fileChangesDetected
                ? "\(provider.displayName) run completed with file changes."
                : "\(provider.displayName) run completed, but no file changes were detected. Verify prompt/permission mode and inspect stdout."
        } else if permissionBlocked {
            baseMessage = "\(provider.displayName) run was blocked by command approval prompts."
        } else if providerReturnedError, let providerReportedErrorMessage {
            baseMessage = "\(provider.displayName) returned an error: \(providerReportedErrorMessage)"
        } else if finalExecution.timedOut {
            baseMessage = "\(provider.displayName) run timed out after \(timeoutSeconds)s."
        } else {
            baseMessage = "\(provider.displayName) run failed with exit code \(finalExecution.exitCode)."
        }
        
        let resultMessage = modelOutputRedacted
            ? baseMessage + " Sensitive-looking values were redacted before sharing output with the model."
            : baseMessage
        
        let result = ClaudeRunResult(
            success: success,
            projectId: args.projectId,
            command: safeCommand,
            exitCode: finalExecution.exitCode,
            timedOut: finalExecution.timedOut,
            permissionBlocked: permissionBlocked,
            durationSeconds: duration,
            createdFiles: createdFiles,
            modifiedFiles: modifiedFiles,
            deletedFiles: deletedFiles,
            fileChangesDetected: fileChangesDetected,
            projectDescription: updatedMetadata?.projectDescription,
            projectLastEditedAt: updatedMetadata?.lastEditedAt.map { isoFormatter.string(from: $0) },
            stdout: safeStdout,
            stderr: safeStderr,
            logFile: logFile,
            message: resultMessage
        )
        
        return encodeJSON(result)
    }
    
    private func executeSendProjectResult(_ call: ToolCall) async -> String {
        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(SendProjectResultArguments.self, from: argsData) else {
            return #"{"error":"Failed to parse send_project_result arguments"}"#
        }
        
        guard let projectURL = resolveProjectDirectory(projectId: args.projectId) else {
            return #"{"error":"Project not found. Use list_projects first."}"#
        }
        
        let destination = args.destination.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard destination == "chat" || destination == "email" else {
            return #"{"error":"destination must be either 'chat' or 'email'."}"#
        }
        
        let packageAs = (args.packageAs?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().isEmpty == false)
            ? args.packageAs!.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            : "files"
        let validPackageModes: Set<String> = ["files", "zip_selection", "zip_project"]
        guard validPackageModes.contains(packageAs) else {
            return #"{"error":"package_as must be one of: files, zip_selection, zip_project."}"#
        }
        
        var relativePaths: [String] = []
        
        if packageAs == "zip_project" {
            relativePaths = snapshotProjectFiles(projectURL: projectURL).keys.sorted()
        } else {
            if let requested = args.filePaths, !requested.isEmpty {
                relativePaths = requested
            } else if args.useLastChangedFiles ?? true {
                if let record = loadLastRunRecord(projectURL: projectURL) {
                    relativePaths = Array(Set(record.createdFiles + record.modifiedFiles)).sorted()
                }
            }
        }
        
        if relativePaths.isEmpty {
            if packageAs == "zip_project" {
                return #"{"error":"Project contains no deliverable files to package."}"#
            }
            return #"{"error":"No files selected. Provide file_paths or run_claude_code first and use use_last_changed_files=true."}"#
        }
        
        let maxFiles: Int
        if packageAs == "zip_project" {
            if let explicitMax = args.maxFiles {
                maxFiles = min(max(explicitMax, 1), 5000)
            } else {
                maxFiles = Int.max
            }
        } else {
            maxFiles = min(max(args.maxFiles ?? 10, 1), 50)
        }
        
        var resolvedFiles: [(url: URL, relativePath: String)] = []
        
        for path in relativePaths {
            guard let fileURL = resolvePath(in: projectURL, relativePath: path) else { continue }
            
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir), !isDir.boolValue else {
                continue
            }
            
            let normalized = relativePath(from: projectURL, to: fileURL)
            resolvedFiles.append((url: fileURL, relativePath: normalized))
            if resolvedFiles.count >= maxFiles { break }
        }
        
        guard !resolvedFiles.isEmpty else {
            return #"{"error":"None of the requested files were found."}"#
        }
        
        var temporaryArtifacts: [URL] = []
        defer {
            for url in temporaryArtifacts {
                try? FileManager.default.removeItem(at: url)
            }
        }
        
        let filesToSend: [(url: URL, relativePath: String, attachmentName: String)]
        let packagedFileCount: Int?
        
        if packageAs == "files" {
            filesToSend = resolvedFiles.map { file in
                (
                    url: file.url,
                    relativePath: file.relativePath,
                    attachmentName: projectAttachmentName(projectId: args.projectId, relativePath: file.relativePath)
                )
            }
            packagedFileCount = nil
        } else {
            let defaultArchiveBase = packageAs == "zip_project"
                ? "\(args.projectId)-project"
                : "\(args.projectId)-selection"
            let archiveBaseName = sanitizeArchiveBaseName(args.archiveName ?? defaultArchiveBase)
            
            let archiveURL: URL
            do {
                archiveURL = try await createProjectZipArchive(
                    projectURL: projectURL,
                    relativePaths: resolvedFiles.map { $0.relativePath },
                    archiveBaseName: archiveBaseName
                )
            } catch {
                return #"{"error":"Failed to create ZIP archive: \#(error.localizedDescription)"}"#
            }
            
            temporaryArtifacts.append(archiveURL)
            let archiveRelativePath = archiveURL.lastPathComponent
            filesToSend = [(
                url: archiveURL,
                relativePath: archiveRelativePath,
                attachmentName: projectAttachmentName(projectId: args.projectId, relativePath: archiveRelativePath)
            )]
            packagedFileCount = resolvedFiles.count
        }
        
        if destination == "chat" {
            var queuedFiles: [String] = []
            
            for file in filesToSend {
                do {
                    let data = try Data(contentsOf: file.url)
                    let outputName = file.attachmentName
                    let outputURL = documentsDirectory.appendingPathComponent(outputName)
                    try data.write(to: outputURL)
                    
                    let defaultCaption: String
                    if packageAs == "files" {
                        defaultCaption = "Project \(args.projectId): \(file.relativePath)"
                    } else {
                        let countText = packagedFileCount.map { " (\($0) file(s))" } ?? ""
                        defaultCaption = "Project \(args.projectId) archive\(countText): \(file.relativePath)"
                    }
                    
                    ToolExecutor.pendingDocuments.append((
                        data: data,
                        filename: outputName,
                        mimeType: getMimeType(for: outputName),
                        caption: args.caption ?? defaultCaption
                    ))
                    ToolExecutor.queueFileForDescription(filename: outputName, data: data, mimeType: getMimeType(for: outputName))
                    queuedFiles.append(file.relativePath)
                } catch {
                    print("[ToolExecutor] Failed to queue project file \(file.relativePath): \(error)")
                }
            }
            
            guard !queuedFiles.isEmpty else {
                return #"{"error":"Failed to prepare files for chat delivery."}"#
            }
            
            let result = SendProjectResultOutput(
                success: true,
                projectId: args.projectId,
                destination: destination,
                fileCount: queuedFiles.count,
                files: queuedFiles,
                packageAs: packageAs,
                packagedFileCount: packagedFileCount,
                message: packageAs == "files"
                    ? "Project files queued for Telegram delivery."
                    : "Project archive queued for Telegram delivery."
            )
            return encodeJSON(result)
        }
        
        guard let to = args.to?.trimmingCharacters(in: .whitespacesAndNewlines), to.contains("@"), to.contains(".") else {
            return #"{"error":"A valid 'to' email address is required for destination='email'."}"#
        }
        
        let subject = args.subject?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? args.subject!.trimmingCharacters(in: .whitespacesAndNewlines)
            : "Project results: \(args.projectId)"
        let body = args.body?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? args.body!.trimmingCharacters(in: .whitespacesAndNewlines)
            : "Attached are project files from \(args.projectId)."
        
        do {
            if await GmailService.shared.isAuthenticated {
                var attachments: [(data: Data, name: String, mimeType: String)] = []
                for file in filesToSend {
                    let data = try Data(contentsOf: file.url)
                    let name = file.attachmentName
                    attachments.append((data: data, name: name, mimeType: getMimeType(for: name)))
                }
                
                let success = try await GmailService.shared.sendEmail(
                    to: to,
                    subject: subject,
                    body: body,
                    threadId: nil,
                    inReplyTo: nil,
                    attachments: attachments
                )
                
                guard success else {
                    return #"{"error":"Failed to send project files via Gmail."}"#
                }
            } else {
                guard await EmailService.shared.isConfigured else {
                    return #"{"error":"Email is not configured. Configure Gmail or IMAP first."}"#
                }
                
                var attachmentURLs: [(url: URL, name: String)] = []
                for file in filesToSend {
                    attachmentURLs.append((url: file.url, name: file.attachmentName))
                }
                
                let success = try await EmailService.shared.sendEmailWithAttachments(
                    to: to,
                    subject: subject,
                    body: body,
                    attachments: attachmentURLs
                )
                
                guard success else {
                    return #"{"error":"Failed to send project files via IMAP/SMTP."}"#
                }
            }
        } catch {
            return #"{"error":"Failed to send project result: \#(error.localizedDescription)"}"#
        }
        
        let result = SendProjectResultOutput(
            success: true,
            projectId: args.projectId,
            destination: destination,
            fileCount: filesToSend.count,
            files: filesToSend.map { $0.relativePath },
            packageAs: packageAs,
            packagedFileCount: packagedFileCount,
            message: packageAs == "files"
                ? "Project files sent via email."
                : "Project archive sent via email."
        )
        return encodeJSON(result)
    }
    
    private func executeDeployProjectToVercel(_ call: ToolCall) async -> String {
        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(DeployProjectToVercelArguments.self, from: argsData) else {
            return #"{"error":"Failed to parse deploy_project_to_vercel arguments"}"#
        }
        
        guard let projectURL = resolveProjectDirectory(projectId: args.projectId) else {
            return #"{"error":"Project not found. Use list_projects first."}"#
        }
        
        let requestedRelativePath = (args.relativePath ?? ".").trimmingCharacters(in: .whitespacesAndNewlines)
        let deployRelativePath = requestedRelativePath.isEmpty ? "." : requestedRelativePath
        
        guard let deployDirectoryURL = resolvePath(in: projectURL, relativePath: deployRelativePath) else {
            return #"{"error":"Invalid relative_path. Path must stay inside the project."}"#
        }
        
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: deployDirectoryURL.path, isDirectory: &isDir), isDir.boolValue else {
            return #"{"error":"relative_path does not exist or is not a directory."}"#
        }
        
        let token = (KeychainHelper.load(key: KeychainHelper.vercelApiTokenKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            return #"{"error":"Vercel API token is not configured. Add it in Settings > Vercel Deployment."}"#
        }
        
        let command = (KeychainHelper.load(key: KeychainHelper.vercelCommandKey) ?? KeychainHelper.defaultVercelCommand)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let vercelCommand = command.isEmpty ? KeychainHelper.defaultVercelCommand : command
        
        let defaultScope = (KeychainHelper.load(key: KeychainHelper.vercelTeamScopeKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultProjectName = (KeychainHelper.load(key: KeychainHelper.vercelProjectNameKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        let explicitTeamScope = args.teamScope?.trimmingCharacters(in: .whitespacesAndNewlines)
        let explicitProjectName = args.projectName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let teamScope = (explicitTeamScope?.isEmpty == false)
            ? explicitTeamScope
            : (defaultScope.isEmpty ? nil : defaultScope)
        let projectName = (explicitProjectName?.isEmpty == false)
            ? explicitProjectName
            : (defaultProjectName.isEmpty ? nil : defaultProjectName)
        
        let configuredTimeout = Int(KeychainHelper.load(key: KeychainHelper.vercelTimeoutKey) ?? "") ?? Int(KeychainHelper.defaultVercelTimeout) ?? 1200
        let timeoutSeconds = min(max(args.timeoutSeconds ?? configuredTimeout, 60), 3600)
        let maxOutputChars = min(max(args.maxOutputChars ?? 12_000, 500), 100_000)
        
        let production = args.production ?? false
        let mode = production ? "production" : "preview"
        let forceRelink = args.forceRelink ?? false
        let sensitiveValues = [token]
        
        var stdoutParts: [String] = []
        var stderrParts: [String] = []
        let environment = claudeBaseEnvironment()
        
        var linked = hasVercelProjectLink(at: deployDirectoryURL)
        let shouldRelink = projectName != nil && ((explicitProjectName?.isEmpty == false) || forceRelink || !linked)
        if let projectName, shouldRelink {
            var linkArgs = ["link", "--yes", "--token", token, "--project", projectName]
            if let teamScope {
                linkArgs.append(contentsOf: ["--scope", teamScope])
            }
            
            do {
                let (linkInvocation, linkOutput) = try await executeVercelCommand(
                    command: vercelCommand,
                    arguments: linkArgs,
                    workingDirectory: deployDirectoryURL,
                    environment: environment,
                    timeoutSeconds: timeoutSeconds,
                    maxOutputChars: maxOutputChars,
                    sensitiveValues: sensitiveValues
                )
                
                let linkStdout = redactSensitiveValues(in: linkOutput.stdout, values: sensitiveValues)
                let linkStderr = redactSensitiveValues(in: linkOutput.stderr, values: sensitiveValues)
                if !linkStdout.isEmpty {
                    stdoutParts.append("[link] \(linkInvocation.displayCommand)\n\(linkStdout)")
                }
                if !linkStderr.isEmpty {
                    stderrParts.append("[link] \(linkInvocation.displayCommand)\n\(linkStderr)")
                }
                
                guard linkOutput.exitCode == 0, !linkOutput.timedOut else {
                    let result = VercelDeployResult(
                        success: false,
                        projectId: args.projectId,
                        relativePath: deployRelativePath,
                        mode: mode,
                        deploymentUrl: nil,
                        projectName: projectName,
                        teamScope: teamScope,
                        linked: false,
                        command: linkInvocation.displayCommand,
                        exitCode: linkOutput.exitCode,
                        timedOut: linkOutput.timedOut,
                        stdout: stdoutParts.joined(separator: "\n\n"),
                        stderr: stderrParts.joined(separator: "\n\n"),
                        message: linkOutput.timedOut
                            ? "Vercel link timed out after \(timeoutSeconds)s."
                            : "Vercel link failed with exit code \(linkOutput.exitCode)."
                    )
                    return encodeJSON(result)
                }
                
                linked = hasVercelProjectLink(at: deployDirectoryURL)
            } catch {
                let result = VercelDeployResult(
                    success: false,
                    projectId: args.projectId,
                    relativePath: deployRelativePath,
                    mode: mode,
                    deploymentUrl: nil,
                    projectName: projectName,
                    teamScope: teamScope,
                    linked: false,
                    command: nil,
                    exitCode: nil,
                    timedOut: nil,
                    stdout: stdoutParts.joined(separator: "\n\n"),
                    stderr: truncateForToolOutput(redactSensitiveValues(in: error.localizedDescription, values: sensitiveValues), maxChars: maxOutputChars),
                    message: "Failed to run `vercel link`. Check CLI configuration and token permissions."
                )
                return encodeJSON(result)
            }
        }
        
        ensureVercelIgnore(at: deployDirectoryURL)
        
        var deployArgs = ["deploy", "--yes", "--token", token]
        if let teamScope {
            deployArgs.append(contentsOf: ["--scope", teamScope])
        }
        if production {
            deployArgs.append("--prod")
        }
        deployArgs.append(".")
        
        do {
            let (deployInvocation, deployOutput) = try await executeVercelCommand(
                command: vercelCommand,
                arguments: deployArgs,
                workingDirectory: deployDirectoryURL,
                environment: environment,
                timeoutSeconds: timeoutSeconds,
                maxOutputChars: maxOutputChars,
                sensitiveValues: sensitiveValues
            )
            
            let deployStdout = redactSensitiveValues(in: deployOutput.stdout, values: sensitiveValues)
            let deployStderr = redactSensitiveValues(in: deployOutput.stderr, values: sensitiveValues)
            if !deployStdout.isEmpty {
                stdoutParts.append("[deploy] \(deployInvocation.displayCommand)\n\(deployStdout)")
            }
            if !deployStderr.isEmpty {
                stderrParts.append("[deploy] \(deployInvocation.displayCommand)\n\(deployStderr)")
            }
            
            let combinedOutput = stdoutParts.joined(separator: "\n\n") + "\n" + stderrParts.joined(separator: "\n\n")
            let deploymentURL = extractVercelDeploymentURL(from: combinedOutput)
            let success = deployOutput.exitCode == 0 && !deployOutput.timedOut
            
            let message: String
            if success {
                if let deploymentURL {
                    message = "Vercel \(mode) deployment completed successfully."
                } else {
                    message = "Vercel \(mode) deployment completed, but deployment URL could not be parsed from CLI output."
                }
            } else if deployOutput.timedOut {
                message = "Vercel deploy timed out after \(timeoutSeconds)s."
            } else {
                message = "Vercel deploy failed with exit code \(deployOutput.exitCode)."
            }
            
            let result = VercelDeployResult(
                success: success,
                projectId: args.projectId,
                relativePath: deployRelativePath,
                mode: mode,
                deploymentUrl: deploymentURL,
                projectName: projectName,
                teamScope: teamScope,
                linked: linked,
                command: deployInvocation.displayCommand,
                exitCode: deployOutput.exitCode,
                timedOut: deployOutput.timedOut,
                stdout: truncateForToolOutput(stdoutParts.joined(separator: "\n\n"), maxChars: maxOutputChars),
                stderr: truncateForToolOutput(stderrParts.joined(separator: "\n\n"), maxChars: maxOutputChars),
                message: message
            )
            return encodeJSON(result)
        } catch {
            let result = VercelDeployResult(
                success: false,
                projectId: args.projectId,
                relativePath: deployRelativePath,
                mode: mode,
                deploymentUrl: nil,
                projectName: projectName,
                teamScope: teamScope,
                linked: linked,
                command: nil,
                exitCode: nil,
                timedOut: nil,
                stdout: truncateForToolOutput(stdoutParts.joined(separator: "\n\n"), maxChars: maxOutputChars),
                stderr: truncateForToolOutput(redactSensitiveValues(in: error.localizedDescription, values: sensitiveValues), maxChars: maxOutputChars),
                message: "Failed to execute Vercel deploy command. Ensure Vercel CLI is installed and configured."
            )
            return encodeJSON(result)
        }
    }
    
    private func executeShowProjectDeploymentTools(_ call: ToolCall) async -> String {
        let result = ShowProjectDeploymentToolsResult(
            success: true,
            unlockedForCurrentTurn: true,
            tools: AvailableTools.gatedProjectDeploymentTools.map { $0.function.name },
            message: "Deployment and database tools are now visible for this turn."
        )
        return encodeJSON(result)
    }
    
    private func executeProvisionProjectDatabase(_ call: ToolCall) async -> String {
        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(ProvisionProjectDatabaseArguments.self, from: argsData) else {
            return #"{"error":"Failed to parse provision_project_database arguments"}"#
        }
        
        guard let projectURL = resolveProjectDirectory(projectId: args.projectId) else {
            return #"{"error":"Project not found. Use list_projects first."}"#
        }
        
        let provider = (args.provider?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().isEmpty == false)
            ? args.provider!.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            : "instantdb"
        guard provider == "instantdb" else {
            return #"{"error":"Unsupported provider. Supported providers: instantdb."}"#
        }
        
        let metadata = loadProjectMetadata(projectURL: projectURL)
        let fallbackTitle = metadata?.name ?? args.projectId
        let rawTitle = args.databaseTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let databaseTitle = (rawTitle?.isEmpty == false) ? rawTitle! : fallbackTitle
        
        let useTemporary = args.useTemporaryApp ?? false
        let configuredCommand = (KeychainHelper.load(key: KeychainHelper.instantCLICommandKey) ?? KeychainHelper.defaultInstantCLICommand)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let command = configuredCommand.isEmpty ? KeychainHelper.defaultInstantCLICommand : configuredCommand
        
        let token = (args.instantToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? args.instantToken!.trimmingCharacters(in: .whitespacesAndNewlines)
            : (KeychainHelper.load(key: KeychainHelper.instantApiTokenKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        
        if !useTemporary && token.isEmpty {
            return #"{"error":"Instant token is missing. Add Instant CLI auth token in Settings or pass instant_token."}"#
        }
        
        let timeoutSeconds = min(max(args.timeoutSeconds ?? 120, 30), 1800)
        let maxOutputChars = min(max(args.maxOutputChars ?? 12_000, 500), 100_000)
        
        var commandArgs = ["init-without-files", "--title", databaseTitle]
        if useTemporary {
            commandArgs.append("--temp")
        } else {
            commandArgs.append(contentsOf: ["--token", token])
        }
        
        do {
            let (invocation, output) = try await executeVercelCommand(
                command: command,
                arguments: commandArgs,
                workingDirectory: projectURL,
                environment: claudeBaseEnvironment(),
                timeoutSeconds: timeoutSeconds,
                maxOutputChars: maxOutputChars,
                sensitiveValues: token.isEmpty ? [] : [token]
            )
            
            let redactedStdout = redactSensitiveValues(in: output.stdout, values: token.isEmpty ? [] : [token])
            let redactedStderr = redactSensitiveValues(in: output.stderr, values: token.isEmpty ? [] : [token])
            
            let parsed = parseJSONObject(in: output.stdout) ?? parseJSONObject(in: output.stderr)
            let appId = extractString(
                from: parsed,
                candidatePaths: [
                    ["appId"],
                    ["app_id"],
                    ["app", "id"],
                    ["id"]
                ]
            )
            let adminToken = extractString(
                from: parsed,
                candidatePaths: [
                    ["adminToken"],
                    ["admin_token"],
                    ["app", "admin_token"],
                    ["app", "adminToken"]
                ]
            )
            
            if let adminToken, !adminToken.isEmpty {
                try? KeychainHelper.save(
                    key: instantAdminTokenKey(projectId: args.projectId),
                    value: adminToken
                )
            }
            
            let additionalSensitive = [token, adminToken ?? ""].filter { !$0.isEmpty }
            let fullyRedactedStdout = redactSensitiveValues(in: redactedStdout, values: additionalSensitive)
            let fullyRedactedStderr = redactSensitiveValues(in: redactedStderr, values: additionalSensitive)
            let logFile = persistProjectDatabaseCommandLog(
                projectURL: projectURL,
                toolName: "provision_project_database",
                command: invocation.displayCommand,
                exitCode: output.exitCode,
                timedOut: output.timedOut,
                stdout: fullyRedactedStdout,
                stderr: fullyRedactedStderr
            )
            
            let metadataToSave = ProjectDatabaseMetadata(
                provider: provider,
                databaseTitle: databaseTitle,
                appId: appId,
                createdAt: Date(),
                schemaLastPushedAt: nil,
                lastUpdatedAt: Date()
            )
            saveProjectDatabaseMetadata(metadataToSave, projectURL: projectURL)
            
            let success = output.exitCode == 0 && !output.timedOut
            let message: String
            if success {
                if appId == nil || appId?.isEmpty == true {
                    message = "Database provisioning command succeeded, but app_id could not be parsed from output."
                } else {
                    message = "Database provisioned successfully."
                }
            } else if output.timedOut {
                message = "Database provisioning timed out after \(timeoutSeconds)s."
            } else {
                message = "Database provisioning failed with exit code \(output.exitCode)."
            }
            
            let result = ProvisionProjectDatabaseResult(
                success: success,
                projectId: args.projectId,
                provider: provider,
                databaseTitle: databaseTitle,
                appId: appId,
                savedAdminToken: adminToken?.isEmpty == false,
                command: invocation.displayCommand,
                exitCode: output.exitCode,
                timedOut: output.timedOut,
                diagnosticExcerpt: success
                    ? nil
                    : diagnosticExcerpt(stdout: fullyRedactedStdout, stderr: fullyRedactedStderr, maxChars: min(600, maxOutputChars)),
                logFile: logFile,
                message: message
            )
            return encodeJSON(result)
        } catch {
            let result = ProvisionProjectDatabaseResult(
                success: false,
                projectId: args.projectId,
                provider: provider,
                databaseTitle: databaseTitle,
                appId: nil,
                savedAdminToken: false,
                command: nil,
                exitCode: nil,
                timedOut: nil,
                diagnosticExcerpt: truncateForToolOutput(error.localizedDescription, maxChars: min(600, maxOutputChars)),
                logFile: nil,
                message: "Failed to execute database provisioning command. Check Instant CLI setup."
            )
            return encodeJSON(result)
        }
    }
    
    private func executePushProjectDatabaseSchema(_ call: ToolCall) async -> String {
        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(PushProjectDatabaseSchemaArguments.self, from: argsData) else {
            return #"{"error":"Failed to parse push_project_database_schema arguments"}"#
        }
        
        guard let projectURL = resolveProjectDirectory(projectId: args.projectId) else {
            return #"{"error":"Project not found. Use list_projects first."}"#
        }
        
        let provider = (args.provider?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().isEmpty == false)
            ? args.provider!.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            : "instantdb"
        guard provider == "instantdb" else {
            return #"{"error":"Unsupported provider. Supported providers: instantdb."}"#
        }
        
        guard var databaseMetadata = loadProjectDatabaseMetadata(projectURL: projectURL) else {
            return #"{"error":"No saved project database metadata. Run provision_project_database first."}"#
        }
        
        guard let appId = databaseMetadata.appId, !appId.isEmpty else {
            return #"{"error":"Saved database metadata does not contain app_id. Re-run provision_project_database."}"#
        }
        
        let tokenOverride = args.instantToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        let savedAdminToken = KeychainHelper.load(key: instantAdminTokenKey(projectId: args.projectId))
        let defaultToken = KeychainHelper.load(key: KeychainHelper.instantApiTokenKey)
        let token = (tokenOverride?.isEmpty == false)
            ? tokenOverride!
            : (savedAdminToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
               ? savedAdminToken!.trimmingCharacters(in: .whitespacesAndNewlines)
               : (defaultToken ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        
        guard !token.isEmpty else {
            return #"{"error":"Instant token is missing. Add Instant CLI auth token in Settings or pass instant_token."}"#
        }
        
        let requestedRelativePath = (args.relativePath ?? ".").trimmingCharacters(in: .whitespacesAndNewlines)
        let relativePath = requestedRelativePath.isEmpty ? "." : requestedRelativePath
        guard let workingDirectory = resolvePath(in: projectURL, relativePath: relativePath) else {
            return #"{"error":"Invalid relative_path. Path must stay inside the project."}"#
        }
        
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workingDirectory.path, isDirectory: &isDir), isDir.boolValue else {
            return #"{"error":"relative_path does not exist or is not a directory."}"#
        }
        
        let configuredCommand = (KeychainHelper.load(key: KeychainHelper.instantCLICommandKey) ?? KeychainHelper.defaultInstantCLICommand)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let command = configuredCommand.isEmpty ? KeychainHelper.defaultInstantCLICommand : configuredCommand
        
        let timeoutSeconds = min(max(args.timeoutSeconds ?? 120, 30), 1800)
        let maxOutputChars = min(max(args.maxOutputChars ?? 12_000, 500), 100_000)
        
        let commandArgs = ["push", "schema", "--token", token]
        var environment = claudeBaseEnvironment()
        environment["INSTANT_APP_ID"] = appId
        if let schemaPath = args.schemaFilePath?.trimmingCharacters(in: .whitespacesAndNewlines), !schemaPath.isEmpty {
            environment["INSTANT_SCHEMA_FILE_PATH"] = schemaPath
        }
        if let permsPath = args.permsFilePath?.trimmingCharacters(in: .whitespacesAndNewlines), !permsPath.isEmpty {
            environment["INSTANT_PERMS_FILE_PATH"] = permsPath
        }
        
        do {
            let (invocation, output) = try await executeVercelCommand(
                command: command,
                arguments: commandArgs,
                workingDirectory: workingDirectory,
                environment: environment,
                timeoutSeconds: timeoutSeconds,
                maxOutputChars: maxOutputChars,
                sensitiveValues: [token]
            )
            
            let redactedStdout = redactSensitiveValues(in: output.stdout, values: [token])
            let redactedStderr = redactSensitiveValues(in: output.stderr, values: [token])
            let logFile = persistProjectDatabaseCommandLog(
                projectURL: projectURL,
                toolName: "push_project_database_schema",
                command: invocation.displayCommand,
                exitCode: output.exitCode,
                timedOut: output.timedOut,
                stdout: redactedStdout,
                stderr: redactedStderr
            )
            
            let success = output.exitCode == 0 && !output.timedOut
            if success {
                databaseMetadata.schemaLastPushedAt = Date()
                databaseMetadata.lastUpdatedAt = Date()
                saveProjectDatabaseMetadata(databaseMetadata, projectURL: projectURL)
            }
            
            let message: String
            if success {
                message = "Database schema push completed successfully."
            } else if output.timedOut {
                message = "Database schema push timed out after \(timeoutSeconds)s."
            } else {
                message = "Database schema push failed with exit code \(output.exitCode)."
            }
            
            let result = PushProjectDatabaseSchemaResult(
                success: success,
                projectId: args.projectId,
                provider: provider,
                appId: appId,
                command: invocation.displayCommand,
                exitCode: output.exitCode,
                timedOut: output.timedOut,
                diagnosticExcerpt: success
                    ? nil
                    : diagnosticExcerpt(stdout: redactedStdout, stderr: redactedStderr, maxChars: min(600, maxOutputChars)),
                logFile: logFile,
                message: message
            )
            return encodeJSON(result)
        } catch {
            let result = PushProjectDatabaseSchemaResult(
                success: false,
                projectId: args.projectId,
                provider: provider,
                appId: appId,
                command: nil,
                exitCode: nil,
                timedOut: nil,
                diagnosticExcerpt: truncateForToolOutput(error.localizedDescription, maxChars: min(600, maxOutputChars)),
                logFile: nil,
                message: "Failed to execute database schema push command."
            )
            return encodeJSON(result)
        }
    }
    
    private func executeSyncProjectDatabaseEnvToVercel(_ call: ToolCall) async -> String {
        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(SyncProjectDatabaseEnvToVercelArguments.self, from: argsData) else {
            return #"{"error":"Failed to parse sync_project_database_env_to_vercel arguments"}"#
        }
        
        guard let projectURL = resolveProjectDirectory(projectId: args.projectId) else {
            return #"{"error":"Project not found. Use list_projects first."}"#
        }
        
        let requestedRelativePath = (args.relativePath ?? ".").trimmingCharacters(in: .whitespacesAndNewlines)
        let relativePath = requestedRelativePath.isEmpty ? "." : requestedRelativePath
        
        guard let deployDirectoryURL = resolvePath(in: projectURL, relativePath: relativePath) else {
            return #"{"error":"Invalid relative_path. Path must stay inside the project."}"#
        }
        
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: deployDirectoryURL.path, isDirectory: &isDir), isDir.boolValue else {
            return #"{"error":"relative_path does not exist or is not a directory."}"#
        }
        
        let token = (KeychainHelper.load(key: KeychainHelper.vercelApiTokenKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            return #"{"error":"Vercel API token is not configured. Add it in Settings > Vercel Deployment."}"#
        }
        
        let defaultProjectName = (KeychainHelper.load(key: KeychainHelper.vercelProjectNameKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        let projectLink = loadVercelProjectLink(at: deployDirectoryURL)
        let explicitProjectName = args.projectName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let projectIdentifier =
            projectLink?.projectId ??
            ((explicitProjectName?.isEmpty == false) ? explicitProjectName! : (defaultProjectName.isEmpty ? nil : defaultProjectName))
        
        guard let projectIdentifier, !projectIdentifier.isEmpty else {
            return #"{"error":"Could not determine Vercel project identifier. Link the folder with deploy_project_to_vercel first or pass project_name."}"#
        }
        
        let teamId = (args.teamId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? args.teamId!.trimmingCharacters(in: .whitespacesAndNewlines)
            : projectLink?.orgId
        
        let includeSaved = args.includeSavedDatabaseEnv ?? true
        let includeAdminToken = args.includeAdminToken ?? false
        let targets = normalizeVercelTargets(args.targets)
        let timeoutSeconds = min(max(args.timeoutSeconds ?? 30, 5), 120)
        let maxOutputChars = min(max(args.maxOutputChars ?? 12_000, 500), 100_000)
        
        var envVars: [String: String] = [:]
        if includeSaved, let db = loadProjectDatabaseMetadata(projectURL: projectURL) {
            if db.provider == "instantdb", let appId = db.appId, !appId.isEmpty {
                envVars["NEXT_PUBLIC_INSTANT_APP_ID"] = appId
                envVars["INSTANT_APP_ID"] = appId
                
                if includeAdminToken,
                   let adminToken = KeychainHelper.load(key: instantAdminTokenKey(projectId: args.projectId))?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !adminToken.isEmpty {
                    envVars["INSTANT_ADMIN_TOKEN"] = adminToken
                }
            }
        }
        
        if let provided = args.envVars {
            for (key, value) in provided {
                let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalizedKey.isEmpty else { continue }
                envVars[normalizedKey] = value
            }
        }
        
        guard !envVars.isEmpty else {
            return #"{"error":"No env vars to sync. Enable include_saved_database_env or provide env_vars."}"#
        }
        
        let orderedKeys = envVars.keys.sorted()
        var failedKeys: [String] = []
        
        for key in orderedKeys {
            guard let value = envVars[key] else { continue }
            do {
                try await upsertVercelEnvVar(
                    projectIdentifier: projectIdentifier,
                    teamId: teamId,
                    key: key,
                    value: value,
                    targets: targets,
                    token: token,
                    timeoutSeconds: timeoutSeconds
                )
            } catch {
                print("[ToolExecutor] Failed to sync Vercel env \(key): \(error)")
                failedKeys.append(key)
            }
        }
        
        let syncedCount = orderedKeys.count - failedKeys.count
        let success = failedKeys.isEmpty
        let message: String
        if success {
            message = "Synced \(syncedCount) environment variable(s) to Vercel."
        } else {
            message = "Synced \(syncedCount) env var(s), failed \(failedKeys.count). Check token/project/team and retry."
        }
        
        let result = SyncProjectDatabaseEnvToVercelResult(
            success: success,
            projectId: args.projectId,
            relativePath: relativePath,
            projectIdentifier: truncateForToolOutput(projectIdentifier, maxChars: maxOutputChars),
            targets: targets,
            requestedCount: orderedKeys.count,
            syncedCount: syncedCount,
            failedKeys: failedKeys,
            message: message
        )
        return encodeJSON(result)
    }
    
    private func executeGenerateProjectMCPConfig(_ call: ToolCall) async -> String {
        guard let argsData = call.function.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(GenerateProjectMCPConfigArguments.self, from: argsData) else {
            return #"{"error":"Failed to parse generate_project_mcp_config arguments"}"#
        }
        
        guard let projectURL = resolveProjectDirectory(projectId: args.projectId) else {
            return #"{"error":"Project not found. Use list_projects first."}"#
        }
        
        let provider = (args.provider?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().isEmpty == false)
            ? args.provider!.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            : "instantdb"
        guard provider == "instantdb" else {
            return #"{"error":"Unsupported provider. Supported providers: instantdb."}"#
        }
        
        let requestedRelativePath = (args.relativePath ?? ".").trimmingCharacters(in: .whitespacesAndNewlines)
        let targetRelativePath = requestedRelativePath.isEmpty ? "." : requestedRelativePath
        guard let targetDirectory = resolvePath(in: projectURL, relativePath: targetRelativePath) else {
            return #"{"error":"Invalid relative_path. Path must stay inside the project."}"#
        }
        
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: targetDirectory.path, isDirectory: &isDir), isDir.boolValue else {
            return #"{"error":"relative_path does not exist or is not a directory."}"#
        }
        
        let mode = (args.mode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().isEmpty == false)
            ? args.mode!.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            : "remote"
        guard mode == "remote" || mode == "local" else {
            return #"{"error":"mode must be 'remote' or 'local'."}"#
        }
        
        let outputPath = (args.outputPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? args.outputPath!.trimmingCharacters(in: .whitespacesAndNewlines)
            : ".mcp.json"
        
        guard let outputURL = resolvePath(in: targetDirectory, relativePath: outputPath) else {
            return #"{"error":"Invalid output_path. Path must stay inside the selected folder."}"#
        }
        
        let serverConfig: [String: Any]
        if mode == "remote" {
            serverConfig = [
                "type": "http",
                "url": "https://mcp.instantdb.com/mcp"
            ]
        } else {
            serverConfig = [
                "command": "npx",
                "args": ["-y", "@instantdb/mcp"]
            ]
        }
        
        let configObject: [String: Any] = [
            "mcpServers": [
                "instant": serverConfig
            ]
        ]
        
        do {
            let data = try JSONSerialization.data(withJSONObject: configObject, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: outputURL, options: .atomic)
            
            let result = GenerateProjectMCPConfigResult(
                success: true,
                projectId: args.projectId,
                provider: provider,
                mode: mode,
                relativePath: targetRelativePath,
                outputPath: relativePath(from: projectURL, to: outputURL),
                message: "MCP config generated successfully."
            )
            return encodeJSON(result)
        } catch {
            return #"{"error":"Failed to write MCP config: \#(error.localizedDescription)"}"#
        }
    }
    
    private func instantAdminTokenKey(projectId: String) -> String {
        "instant_admin_token_\(projectId)"
    }
    
    private func projectDatabaseMetadataURL(projectURL: URL) -> URL {
        projectURL.appendingPathComponent(".project_database.json")
    }
    
    private func loadProjectDatabaseMetadata(projectURL: URL) -> ProjectDatabaseMetadata? {
        let url = projectDatabaseMetadataURL(projectURL: projectURL)
        guard let data = try? Data(contentsOf: url) else { return nil }
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ProjectDatabaseMetadata.self, from: data)
    }
    
    private func saveProjectDatabaseMetadata(_ metadata: ProjectDatabaseMetadata, projectURL: URL) {
        let url = projectDatabaseMetadataURL(projectURL: projectURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601
        
        guard let data = try? encoder.encode(metadata) else { return }
        try? data.write(to: url, options: .atomic)
    }
    
    private func parseJSONObject(in text: String) -> [String: Any]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        
        if let data = trimmed.data(using: .utf8),
           let direct = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return direct
        }
        
        let open = trimmed.firstIndex(of: "{")
        let close = trimmed.lastIndex(of: "}")
        guard let open, let close, open <= close else { return nil }
        let candidate = String(trimmed[open...close])
        guard let data = candidate.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return parsed
    }
    
    private func extractString(from object: [String: Any]?, candidatePaths: [[String]]) -> String? {
        guard let object else { return nil }
        
        for path in candidatePaths {
            var current: Any? = object
            for segment in path {
                guard let dict = current as? [String: Any] else {
                    current = nil
                    break
                }
                current = dict[segment]
            }
            
            if let value = current as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        
        return nil
    }
    
    private struct VercelProjectLink: Codable {
        let projectId: String?
        let orgId: String?
        
        enum CodingKeys: String, CodingKey {
            case projectId
            case orgId
        }
    }
    
    private func loadVercelProjectLink(at directoryURL: URL) -> VercelProjectLink? {
        let linkFileURL = directoryURL.appendingPathComponent(".vercel/project.json")
        guard let data = try? Data(contentsOf: linkFileURL) else { return nil }
        return try? JSONDecoder().decode(VercelProjectLink.self, from: data)
    }
    
    private func normalizeVercelTargets(_ rawTargets: [String]?) -> [String] {
        let allowed = Set(["development", "preview", "production"])
        let defaults = ["development", "preview", "production"]
        
        guard let rawTargets, !rawTargets.isEmpty else { return defaults }
        
        var seen: Set<String> = []
        let normalized = rawTargets
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { allowed.contains($0) }
            .filter { seen.insert($0).inserted }
        
        return normalized.isEmpty ? defaults : normalized
    }
    
    private struct VercelEnvUpsertRequest: Encodable {
        let key: String
        let value: String
        let target: [String]
        let type: String
    }
    
    private func upsertVercelEnvVar(
        projectIdentifier: String,
        teamId: String?,
        key: String,
        value: String,
        targets: [String],
        token: String,
        timeoutSeconds: Int
    ) async throws {
        let escapedProject = projectIdentifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? projectIdentifier
        guard var components = URLComponents(string: "https://api.vercel.com/v10/projects/\(escapedProject)/env") else {
            throw NSError(domain: "ToolExecutor", code: 1001, userInfo: [
                NSLocalizedDescriptionKey: "Failed to construct Vercel env API URL."
            ])
        }
        
        var queryItems = [URLQueryItem(name: "upsert", value: "true")]
        if let teamId, !teamId.isEmpty {
            queryItems.append(URLQueryItem(name: "teamId", value: teamId))
        }
        components.queryItems = queryItems
        
        guard let url = components.url else {
            throw NSError(domain: "ToolExecutor", code: 1002, userInfo: [
                NSLocalizedDescriptionKey: "Failed to resolve Vercel env API URL."
            ])
        }
        
        let payload = VercelEnvUpsertRequest(
            key: key,
            value: value,
            target: targets,
            type: "encrypted"
        )
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = TimeInterval(timeoutSeconds)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "ToolExecutor", code: 1003, userInfo: [
                NSLocalizedDescriptionKey: "Vercel env API returned a non-HTTP response."
            ])
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "ToolExecutor", code: httpResponse.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "Vercel env upsert failed (\(httpResponse.statusCode)) for key \(key): \(truncateForToolOutput(body, maxChars: 600))"
            ])
        }
    }
    
    private struct ProjectDatabaseCommandLog: Codable {
        let timestamp: Date
        let toolName: String
        let command: String?
        let exitCode: Int32?
        let timedOut: Bool?
        let stdout: String
        let stderr: String
        
        enum CodingKeys: String, CodingKey {
            case timestamp, command, stdout, stderr
            case toolName = "tool_name"
            case exitCode = "exit_code"
            case timedOut = "timed_out"
        }
    }
    
    private func persistProjectDatabaseCommandLog(
        projectURL: URL,
        toolName: String,
        command: String?,
        exitCode: Int32?,
        timedOut: Bool?,
        stdout: String,
        stderr: String
    ) -> String? {
        let logDirectory = projectURL.appendingPathComponent(".db_runs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let filename = "\(toolName)-\(formatter.string(from: Date())).json"
        let logURL = logDirectory.appendingPathComponent(filename)
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601
        
        let record = ProjectDatabaseCommandLog(
            timestamp: Date(),
            toolName: toolName,
            command: command,
            exitCode: exitCode,
            timedOut: timedOut,
            stdout: truncateForToolOutput(stdout, maxChars: 60_000),
            stderr: truncateForToolOutput(stderr, maxChars: 60_000)
        )
        
        guard let data = try? encoder.encode(record) else { return nil }
        guard (try? data.write(to: logURL, options: .atomic)) != nil else { return nil }
        return relativePath(from: projectURL, to: logURL)
    }
    
    private func diagnosticExcerpt(stdout: String, stderr: String, maxChars: Int) -> String {
        let combined = (stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? stdout : stderr)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if combined.isEmpty {
            return "Command failed without diagnostic output."
        }
        return truncateForToolOutput(combined, maxChars: maxChars)
    }
    
    private func sanitizeProjectName(_ name: String) -> String {
        let lower = name.lowercased()
        let allowed = lower.map { char -> Character in
            if char.isLetter || char.isNumber {
                return char
            }
            return "-"
        }
        let collapsed = String(allowed)
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return collapsed.isEmpty ? "project" : String(collapsed.prefix(40))
    }
    
    private func sanitizeArchiveBaseName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutExtension = (trimmed as NSString).deletingPathExtension
        let base = withoutExtension.isEmpty ? trimmed : withoutExtension
        let cleaned = base
            .replacingOccurrences(of: #"[^A-Za-z0-9._-]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-._"))
        if cleaned.isEmpty {
            return "project"
        }
        return String(cleaned.prefix(80))
    }
    
    private func createProjectZipArchive(
        projectURL: URL,
        relativePaths: [String],
        archiveBaseName: String
    ) async throws -> URL {
        guard !relativePaths.isEmpty else {
            throw NSError(domain: "ToolExecutor", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No files available for ZIP packaging."
            ])
        }
        
        let fileManager = FileManager.default
        let archiveURL = fileManager.temporaryDirectory
            .appendingPathComponent("\(archiveBaseName)-\(String(UUID().uuidString.prefix(8))).zip")
        
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
                process.currentDirectoryURL = projectURL
                process.arguments = ["-r", "-q", archiveURL.path] + relativePaths
                
                let errorPipe = Pipe()
                process.standardError = errorPipe
                
                do {
                    try process.run()
                    ToolExecutor.registerRunningProcess(process)
                    process.waitUntilExit()
                    ToolExecutor.unregisterRunningProcess(process)
                    
                    if process.terminationStatus != 0 {
                        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                        let errorOutput = String(data: errorData, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        let message = errorOutput?.isEmpty == false ? errorOutput! : "zip exited with code \(process.terminationStatus)."
                        continuation.resume(throwing: NSError(domain: "ToolExecutor", code: Int(process.terminationStatus), userInfo: [
                            NSLocalizedDescriptionKey: message
                        ]))
                        return
                    }
                    
                    guard fileManager.fileExists(atPath: archiveURL.path) else {
                        continuation.resume(throwing: NSError(domain: "ToolExecutor", code: 2, userInfo: [
                            NSLocalizedDescriptionKey: "ZIP file was not created."
                        ]))
                        return
                    }
                    
                    continuation.resume(returning: archiveURL)
                } catch {
                    ToolExecutor.unregisterRunningProcess(process)
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    private func resolveProjectDirectory(projectId: String) -> URL? {
        let trimmed = projectId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != ".",
              trimmed != "..",
              !trimmed.contains("/"),
              !trimmed.contains("\\"),
              !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        
        let projectURL = projectsDirectory.appendingPathComponent(trimmed, isDirectory: true).standardizedFileURL
        let rootURL = projectsDirectory.standardizedFileURL
        guard projectURL.path.hasPrefix(rootURL.path) else { return nil }
        
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: projectURL.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        
        var metadata = ensureProjectMetadata(projectURL: projectURL)
        let hasDescription = !(metadata.projectDescription?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty ?? true)
        if !hasDescription {
            metadata.projectDescription = buildDiscoveryProjectDescription(
                projectURL: projectURL,
                projectName: metadata.name
            )
            metadata.projectDescriptionSource = "discovery_scan"
            saveProjectMetadata(metadata, projectURL: projectURL)
        }
        return projectURL
    }
    
    private func resolvePath(in projectURL: URL, relativePath: String) -> URL? {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.isEmpty ? "." : trimmed
        guard !normalized.hasPrefix("/") else { return nil }
        
        let targetURL = projectURL.appendingPathComponent(normalized).standardizedFileURL
        let rootPath = projectURL.standardizedFileURL.path
        guard targetURL.path.hasPrefix(rootPath) else { return nil }
        return targetURL
    }
    
    private func isSafeDocumentFilename(_ filename: String) -> Bool {
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard !trimmed.contains("/"), !trimmed.contains("\\") else { return false }
        guard trimmed != ".", trimmed != ".." else { return false }
        return true
    }
    
    private func nextAvailableFileURL(in directoryURL: URL, preferredFilename: String) -> URL {
        let fileManager = FileManager.default
        let safeName = preferredFilename.trimmingCharacters(in: .whitespacesAndNewlines)
        let ext = (safeName as NSString).pathExtension
        var base = (safeName as NSString).deletingPathExtension
        if base.isEmpty { base = "file" }
        
        var candidate = ext.isEmpty ? base : "\(base).\(ext)"
        var candidateURL = directoryURL.appendingPathComponent(candidate)
        var counter = 1
        
        while fileManager.fileExists(atPath: candidateURL.path) {
            candidate = ext.isEmpty ? "\(base)_\(counter)" : "\(base)_\(counter).\(ext)"
            candidateURL = directoryURL.appendingPathComponent(candidate)
            counter += 1
        }
        
        return candidateURL
    }
    
    private func importZipArchive(
        sourceArchiveURL: URL,
        sourceFilename: String,
        destinationURL: URL,
        projectURL: URL,
        overwriteExisting: Bool
    ) async throws -> [ClaudeProjectImportedFile] {
        let fileManager = FileManager.default
        let archiveEntries = try await listZipEntries(archiveURL: sourceArchiveURL)
        
        guard !archiveEntries.isEmpty else {
            throw NSError(domain: "ToolExecutor", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "ZIP archive is empty."
            ])
        }
        
        guard archiveEntries.allSatisfy({ isSafeArchiveEntryPath($0) }) else {
            throw NSError(domain: "ToolExecutor", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "ZIP archive contains unsafe paths."
            ])
        }
        
        let extractionRoot = fileManager.temporaryDirectory
            .appendingPathComponent("telegramconcierge-zip-import-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: extractionRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: extractionRoot) }
        
        try await unzipArchive(archiveURL: sourceArchiveURL, destinationURL: extractionRoot)
        
        guard let enumerator = fileManager.enumerator(
            at: extractionRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }
        
        var extractedFiles: [(url: URL, relativePath: String)] = []
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { continue }
            guard values?.isRegularFile == true else { continue }
            
            let relative = relativePath(from: extractionRoot, to: fileURL)
            guard isSafeArchiveEntryPath(relative) else { continue }
            if shouldIgnoreArchiveArtifact(relativePath: relative) { continue }
            
            extractedFiles.append((fileURL, relative))
        }
        
        guard !extractedFiles.isEmpty else {
            return []
        }
        
        let stripRoot = commonArchiveRootPrefix(paths: extractedFiles.map { $0.relativePath })
        let destinationRootPath = destinationURL.standardizedFileURL.path
        var importedFiles: [ClaudeProjectImportedFile] = []
        
        for file in extractedFiles.sorted(by: { $0.relativePath < $1.relativePath }) {
            var relative = file.relativePath
            if let root = stripRoot, relative.hasPrefix(root + "/") {
                relative = String(relative.dropFirst(root.count + 1))
            }
            guard !relative.isEmpty else { continue }
            
            let candidateURL = destinationURL.appendingPathComponent(relative).standardizedFileURL
            guard candidateURL.path.hasPrefix(destinationRootPath) else { continue }
            
            let parentURL = candidateURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
            
            let finalURL: URL
            if overwriteExisting {
                finalURL = candidateURL
                if fileManager.fileExists(atPath: finalURL.path) {
                    try? fileManager.removeItem(at: finalURL)
                }
            } else if fileManager.fileExists(atPath: candidateURL.path) {
                finalURL = nextAvailableFileURL(in: parentURL, preferredFilename: candidateURL.lastPathComponent)
            } else {
                finalURL = candidateURL
            }
            
            try fileManager.copyItem(at: file.url, to: finalURL)
            let attrs = try? fileManager.attributesOfItem(atPath: finalURL.path)
            let sizeBytes = (attrs?[.size] as? NSNumber)?.intValue ?? 0
            let destinationRelativePath = relativePath(from: projectURL, to: finalURL)
            
            importedFiles.append(ClaudeProjectImportedFile(
                sourceFilename: sourceFilename,
                destinationRelativePath: destinationRelativePath,
                sizeBytes: sizeBytes
            ))
        }
        
        return importedFiles
    }
    
    private func listZipEntries(archiveURL: URL) async throws -> [String] {
        let stdout = try await runProcessForZip(
            executablePath: "/usr/bin/unzip",
            arguments: ["-Z1", archiveURL.path],
            context: "Failed to inspect ZIP archive."
        )
        
        return stdout
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
    
    private func unzipArchive(archiveURL: URL, destinationURL: URL) async throws {
        _ = try await runProcessForZip(
            executablePath: "/usr/bin/unzip",
            arguments: ["-qq", archiveURL.path, "-d", destinationURL.path],
            context: "Failed to extract ZIP archive."
        )
    }
    
    private func runProcessForZip(
        executablePath: String,
        arguments: [String],
        context: String
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executablePath)
                process.arguments = arguments
                
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe
                
                var stdoutBuffer = Data()
                var stderrBuffer = Data()
                let stdoutLock = NSLock()
                let stderrLock = NSLock()
                
                stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    guard !chunk.isEmpty else { return }
                    stdoutLock.lock()
                    stdoutBuffer.append(chunk)
                    stdoutLock.unlock()
                }
                
                stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    guard !chunk.isEmpty else { return }
                    stderrLock.lock()
                    stderrBuffer.append(chunk)
                    stderrLock.unlock()
                }
                
                do {
                    try process.run()
                    ToolExecutor.registerRunningProcess(process)
                    defer { ToolExecutor.unregisterRunningProcess(process) }
                    
                    process.waitUntilExit()
                    
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    
                    let remainingStdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    if !remainingStdout.isEmpty {
                        stdoutLock.lock()
                        stdoutBuffer.append(remainingStdout)
                        stdoutLock.unlock()
                    }
                    
                    let remainingStderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    if !remainingStderr.isEmpty {
                        stderrLock.lock()
                        stderrBuffer.append(remainingStderr)
                        stderrLock.unlock()
                    }
                    
                    let stdout = String(data: stdoutBuffer, encoding: .utf8) ?? ""
                    let stderr = String(data: stderrBuffer, encoding: .utf8) ?? ""
                    
                    guard process.terminationStatus == 0 else {
                        let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                        continuation.resume(throwing: NSError(domain: "ToolExecutor", code: Int(process.terminationStatus), userInfo: [
                            NSLocalizedDescriptionKey: "\(context) \(message.isEmpty ? "Process exited with code \(process.terminationStatus)." : message)"
                        ]))
                        return
                    }
                    
                    continuation.resume(returning: stdout)
                } catch {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    ToolExecutor.unregisterRunningProcess(process)
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    private func isSafeArchiveEntryPath(_ path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        
        let normalized = trimmed.replacingOccurrences(of: "\\", with: "/")
        if normalized.hasPrefix("/") || normalized.hasPrefix("~") { return false }
        
        let components = normalized.split(separator: "/")
        guard !components.isEmpty else { return false }
        
        for component in components {
            if component == "." || component == ".." || component.isEmpty {
                return false
            }
        }
        
        return true
    }
    
    private func commonArchiveRootPrefix(paths: [String]) -> String? {
        guard !paths.isEmpty else { return nil }
        let splitPaths = paths.map { $0.split(separator: "/").map(String.init) }
        guard splitPaths.allSatisfy({ $0.count >= 2 }) else { return nil }
        guard let candidate = splitPaths.first?.first else { return nil }
        guard splitPaths.allSatisfy({ $0.first == candidate }) else { return nil }
        return candidate
    }
    
    private func shouldIgnoreArchiveArtifact(relativePath: String) -> Bool {
        let normalized = relativePath.replacingOccurrences(of: "\\", with: "/")
        if normalized.hasPrefix("__MACOSX/") {
            return true
        }
        
        let lastComponent = (normalized as NSString).lastPathComponent
        return lastComponent == ".DS_Store"
    }
    
    private func listProjectEntries(
        projectURL: URL,
        baseURL: URL,
        recursive: Bool,
        maxEntries: Int
    ) throws -> [ClaudeProjectBrowseEntry] {
        let fileManager = FileManager.default
        var entries: [ClaudeProjectBrowseEntry] = []
        
        if recursive {
            guard let enumerator = fileManager.enumerator(
                at: baseURL,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                return []
            }
            
            for case let url as URL in enumerator {
                let relative = relativePath(from: projectURL, to: url)
                if shouldIgnoreProjectPath(relative) { continue }
                
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
                let isDirectory = values?.isDirectory ?? false
                let size = isDirectory ? nil : values?.fileSize
                let modified = values?.contentModificationDate.map { isoFormatter.string(from: $0) }
                
                entries.append(ClaudeProjectBrowseEntry(
                    relativePath: relative,
                    type: isDirectory ? "directory" : "file",
                    sizeBytes: size,
                    modifiedAt: modified
                ))
                
                if entries.count >= maxEntries { break }
            }
        } else {
            let children = try fileManager.contentsOfDirectory(
                at: baseURL,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            
            for url in children.prefix(maxEntries) {
                let relative = relativePath(from: projectURL, to: url)
                if shouldIgnoreProjectPath(relative) { continue }
                
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
                let isDirectory = values?.isDirectory ?? false
                let size = isDirectory ? nil : values?.fileSize
                let modified = values?.contentModificationDate.map { isoFormatter.string(from: $0) }
                
                entries.append(ClaudeProjectBrowseEntry(
                    relativePath: relative,
                    type: isDirectory ? "directory" : "file",
                    sizeBytes: size,
                    modifiedAt: modified
                ))
            }
        }
        
        return entries.sorted { lhs, rhs in
            if lhs.type != rhs.type {
                return lhs.type == "directory"
            }
            return lhs.relativePath < rhs.relativePath
        }
    }
    
    private func loadProjectMetadata(projectURL: URL) -> ClaudeProjectMetadata? {
        let metadataURL = projectURL.appendingPathComponent(".project.json")
        guard let data = try? Data(contentsOf: metadataURL) else { return nil }
        
        let decoder = JSONDecoder()
        if let metadata = try? decoder.decode(ClaudeProjectMetadata.self, from: data) {
            return metadata
        }
        
        let isoDecoder = JSONDecoder()
        isoDecoder.dateDecodingStrategy = .iso8601
        return try? isoDecoder.decode(ClaudeProjectMetadata.self, from: data)
    }
    
    private func ensureProjectMetadata(projectURL: URL) -> ClaudeProjectMetadata {
        if let metadata = loadProjectMetadata(projectURL: projectURL) {
            return metadata
        }
        
        let folderName = projectURL.lastPathComponent
        let metadata = makeFallbackProjectMetadata(projectURL: projectURL, projectId: folderName)
        saveProjectMetadata(metadata, projectURL: projectURL)
        return metadata
    }
    
    private func makeFallbackProjectMetadata(projectURL: URL, projectId: String) -> ClaudeProjectMetadata {
        let attrs = try? FileManager.default.attributesOfItem(atPath: projectURL.path)
        let createdAt = (attrs?[.creationDate] as? Date) ?? Date()
        return ClaudeProjectMetadata(
            id: projectId,
            name: projectURL.lastPathComponent,
            createdAt: createdAt,
            initialNotes: nil,
            projectDescription: nil,
            projectDescriptionSource: nil,
            lastEditedAt: nil
        )
    }
    
    private func saveProjectMetadata(_ metadata: ClaudeProjectMetadata, projectURL: URL) {
        let metadataURL = projectURL.appendingPathComponent(".project.json")
        guard let data = try? JSONEncoder().encode(metadata) else { return }
        try? data.write(to: metadataURL)
    }
    
    private func updateProjectMetadataAfterRun(
        projectURL: URL,
        projectId: String,
        prompt: String,
        createdFiles: [String],
        modifiedFiles: [String],
        deletedFiles: [String],
        stdout: String,
        stderr: String,
        fileChangesDetected: Bool
    ) async -> ClaudeProjectMetadata? {
        var metadata = loadProjectMetadata(projectURL: projectURL) ??
            makeFallbackProjectMetadata(projectURL: projectURL, projectId: projectId)
        
        if fileChangesDetected {
            metadata.lastEditedAt = Date()
        }
        
        let currentDescription = metadata.projectDescription?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasDiscoveryDescription = metadata.projectDescriptionSource == "discovery_scan" ||
            isLikelyDiscoveryGeneratedDescription(currentDescription)
        let shouldRegenerateDescription = fileChangesDetected || currentDescription.isEmpty || hasDiscoveryDescription
        
        if shouldRegenerateDescription {
            if let generatedDescription = await generateProjectDescriptionAfterRun(
                metadata: metadata,
                prompt: prompt,
                createdFiles: createdFiles,
                modifiedFiles: modifiedFiles,
                deletedFiles: deletedFiles,
                stdout: stdout,
                stderr: stderr,
                fileChangesDetected: fileChangesDetected
            ) {
                metadata.projectDescription = generatedDescription
                metadata.projectDescriptionSource = "llm_after_run"
            } else if fileChangesDetected || currentDescription.isEmpty || hasDiscoveryDescription {
                metadata.projectDescription = fallbackProjectDescription(
                    projectName: metadata.name,
                    initialNotes: metadata.initialNotes,
                    prompt: prompt,
                    createdFiles: createdFiles,
                    modifiedFiles: modifiedFiles
                )
                metadata.projectDescriptionSource = "heuristic_after_run"
            }
        }
        
        saveProjectMetadata(metadata, projectURL: projectURL)
        return metadata
    }
    
    private func generateProjectDescriptionOnCreate(
        projectName: String,
        initialNotes: String?
    ) async -> String? {
        let trimmedNotes = initialNotes?.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = """
        Create a concise project catalog description.
        Project name: \(projectName)
        Initial notes: \(trimmedNotes?.isEmpty == false ? trimmedNotes! : "None")
        
        Keep it under 180 characters. Focus on intent and expected output.
        IMPORTANT: If the notes or name indicate this is an internal tool, script, or automation for the AI agent's own use to help the user, start the description with "[AGENT AUTOMATION]". Otherwise, start it with "[USER PROJECT]".
        """
        
        if let generated = await requestGeminiProjectDescription(prompt: prompt) {
            return generated
        }
        
        return fallbackProjectDescription(
            projectName: projectName,
            initialNotes: initialNotes,
            prompt: nil,
            createdFiles: [],
            modifiedFiles: []
        )
    }
    
    private func generateProjectDescriptionAfterRun(
        metadata: ClaudeProjectMetadata,
        prompt: String,
        createdFiles: [String],
        modifiedFiles: [String],
        deletedFiles: [String],
        stdout: String,
        stderr: String,
        fileChangesDetected: Bool
    ) async -> String? {
        let changedFiles = (createdFiles + modifiedFiles).sorted()
        let changedSummary = changedFiles.isEmpty ? "None" : changedFiles.prefix(12).joined(separator: ", ")
        let deletedSummary = deletedFiles.isEmpty ? "None" : deletedFiles.prefix(8).joined(separator: ", ")
        let previousDescription = metadata.projectDescription ?? "None"
        
        let safePrompt = redactSensitiveContextForModel(prompt)
        let safeStdout = redactSensitiveContextForModel(stdout)
        let safeStderr = redactSensitiveContextForModel(stderr)
        
        let promptSnippet = String(safePrompt.prefix(700))
        let stdoutSnippet = String(safeStdout.prefix(500))
        let stderrSnippet = String(safeStderr.prefix(300))
        
        let promptText = """
        Update this project catalog description after a Claude Code run.
        
        Project name: \(metadata.name)
        Previous description: \(previousDescription)
        Initial notes: \(metadata.initialNotes ?? "None")
        Latest run prompt: \(promptSnippet)
        File changes detected: \(fileChangesDetected ? "Yes" : "No")
        Created/Modified files: \(changedSummary)
        Deleted files: \(deletedSummary)
        Stdout excerpt: \(stdoutSnippet.isEmpty ? "None" : stdoutSnippet)
        Stderr excerpt: \(stderrSnippet.isEmpty ? "None" : stderrSnippet)
        
        Produce a single compact description (<180 chars) that helps choose this project later.
        IMPORTANT: Maintain the "[AGENT AUTOMATION]" or "[USER PROJECT]" prefix from the previous description, or infer it if missing. An "[AGENT AUTOMATION]" is an internal script/tool for the AI's own use to help the user; a "[USER PROJECT]" is regular software built for the user.
        """
        
        if let generated = await requestGeminiProjectDescription(prompt: promptText) {
            return generated
        }
        
        return nil
    }
    
    private func fallbackProjectDescription(
        projectName: String,
        initialNotes: String?,
        prompt: String?,
        createdFiles: [String],
        modifiedFiles: [String]
    ) -> String {
        if let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return trimProjectDescription("Project '\(projectName)': \(prompt)")
        }
        
        if !createdFiles.isEmpty || !modifiedFiles.isEmpty {
            let fileHint = (createdFiles + modifiedFiles).prefix(2).joined(separator: ", ")
            return trimProjectDescription("Project '\(projectName)' with recent work on \(fileHint).")
        }
        
        let noteSnippet = initialNotes?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let noteSnippet, !noteSnippet.isEmpty {
            return trimProjectDescription(noteSnippet)
        }
        
        return trimProjectDescription("Project '\(projectName)' workspace.")
    }
    
    private func requestGeminiProjectDescription(prompt: String) async -> String? {
        let apiKey = (KeychainHelper.load(key: KeychainHelper.openRouterApiKeyKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { return nil }
        
        let body: [String: Any] = [
            "model": "google/gemini-3-flash-preview",
            "messages": [
                [
                    "role": "system",
                    "content": """
                    You generate project catalog descriptions for local coding workspaces.
                    Return strict JSON only: {"description":"..."}.
                    Rules:
                    - max 180 characters
                    - one sentence
                    - include purpose and current progress
                    - no markdown, no code fences
                    """
                ],
                ["role": "user", "content": prompt]
            ]
        ]
        
        guard let requestBody = try? JSONSerialization.data(withJSONObject: body) else {
            return nil
        }
        
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = requestBody
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let firstChoice = choices.first,
                  let message = firstChoice["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                return nil
            }
            
            return extractProjectDescription(from: content)
        } catch {
            return nil
        }
    }
    
    private func extractProjectDescription(from content: String) -> String? {
        var cleaned = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        
        if cleaned.hasPrefix("```") {
            cleaned = cleaned
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        if let data = cleaned.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let description = json["description"] as? String,
           !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return trimProjectDescription(description)
        }
        
        return trimProjectDescription(cleaned)
    }
    
    private func trimProjectDescription(_ text: String) -> String {
        let squashed = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        if squashed.count <= 180 {
            return squashed
        }
        return String(squashed.prefix(177)) + "..."
    }

    private func isLikelyDiscoveryGeneratedDescription(_ description: String) -> Bool {
        let lowered = description.lowercased()
        return lowered.contains(" files;") && lowered.contains("types:") && lowered.contains("areas:")
    }

    private func buildDiscoveryProjectDescription(
        projectURL: URL,
        projectName: String
    ) -> String {
        let summary = summarizeProjectContentsForDiscovery(projectURL: projectURL)

        guard summary.scannedFileCount > 0 else {
            return trimProjectDescription("Project '\(projectName)' workspace (empty folder).")
        }

        let countLabel = summary.reachedScanLimit
            ? "\(summary.scannedFileCount)+ files"
            : "\(summary.scannedFileCount) files"
        var parts: [String] = [countLabel]

        if !summary.topExtensions.isEmpty {
            parts.append("types: \(summary.topExtensions.joined(separator: ", "))")
        }
        if !summary.topAreas.isEmpty {
            parts.append("areas: \(summary.topAreas.joined(separator: ", "))")
        }

        return trimProjectDescription("Project '\(projectName)' with \(parts.joined(separator: "; ")).")
    }

    private func summarizeProjectContentsForDiscovery(projectURL: URL) -> ProjectDiscoveryContentSummary {
        let scanLimit = 400
        guard let enumerator = FileManager.default.enumerator(
            at: projectURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return ProjectDiscoveryContentSummary(
                scannedFileCount: 0,
                reachedScanLimit: false,
                topExtensions: [],
                topAreas: []
            )
        }

        var scannedFileCount = 0
        var reachedScanLimit = false
        var extensionCounts: [String: Int] = [:]
        var areaCounts: [String: Int] = [:]

        for case let url as URL in enumerator {
            let relative = relativePath(from: projectURL, to: url)
            if shouldIgnoreProjectPath(relative) { continue }

            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else {
                continue
            }

            scannedFileCount += 1
            if scannedFileCount > scanLimit {
                reachedScanLimit = true
                scannedFileCount = scanLimit
                break
            }

            let ext = url.pathExtension.lowercased()
            let normalizedExt = ext.isEmpty ? "no-ext" : ext
            extensionCounts[normalizedExt, default: 0] += 1

            let components = relative.split(separator: "/", omittingEmptySubsequences: true)
            let area = components.count > 1 ? String(components[0]) : "root"
            areaCounts[area, default: 0] += 1
        }

        func topLabels(from counts: [String: Int], limit: Int) -> [String] {
            counts
                .sorted { lhs, rhs in
                    if lhs.value != rhs.value { return lhs.value > rhs.value }
                    return lhs.key < rhs.key
                }
                .prefix(limit)
                .map { key, value in
                    value > 1 ? "\(key)(\(value))" : key
                }
        }

        return ProjectDiscoveryContentSummary(
            scannedFileCount: scannedFileCount,
            reachedScanLimit: reachedScanLimit,
            topExtensions: topLabels(from: extensionCounts, limit: 3),
            topAreas: topLabels(from: areaCounts, limit: 3)
        )
    }
    
    private func countProjectFiles(projectURL: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: projectURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return 0
        }
        
        var count = 0
        for case let url as URL in enumerator {
            let relative = relativePath(from: projectURL, to: url)
            if shouldIgnoreProjectPath(relative) { continue }
            
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true {
                count += 1
            }
        }
        return count
    }
    
    private func snapshotProjectFiles(projectURL: URL) -> [String: ProjectSnapshotEntry] {
        guard let enumerator = FileManager.default.enumerator(
            at: projectURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return [:]
        }
        
        var snapshot: [String: ProjectSnapshotEntry] = [:]
        
        for case let url as URL in enumerator {
            let relative = relativePath(from: projectURL, to: url)
            if shouldIgnoreProjectPath(relative) { continue }
            
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                  values.isRegularFile == true else {
                continue
            }
            
            let size = UInt64(values.fileSize ?? 0)
            let modified = values.contentModificationDate ?? .distantPast
            snapshot[relative] = ProjectSnapshotEntry(size: size, modifiedAt: modified)
        }
        
        return snapshot
    }
    
    private func diffSnapshots(
        before: [String: ProjectSnapshotEntry],
        after: [String: ProjectSnapshotEntry]
    ) -> (created: [String], modified: [String], deleted: [String]) {
        let beforeKeys = Set(before.keys)
        let afterKeys = Set(after.keys)
        
        let created = Array(afterKeys.subtracting(beforeKeys)).sorted()
        let deleted = Array(beforeKeys.subtracting(afterKeys)).sorted()
        
        let shared = beforeKeys.intersection(afterKeys)
        var modified: [String] = []
        
        for key in shared {
            guard let pre = before[key], let post = after[key] else { continue }
            if pre.size != post.size || pre.modifiedAt != post.modifiedAt {
                modified.append(key)
            }
        }
        
        return (created, modified.sorted(), deleted)
    }
    
    private func shouldIgnoreProjectPath(_ relativePath: String) -> Bool {
        if relativePath == ".project.json" || relativePath == ".claude_last_run.json" || relativePath == ".project_database.json" {
            return true
        }
        if relativePath.hasPrefix(".claude_runs/") {
            return true
        }
        if relativePath.hasPrefix(".db_runs/") {
            return true
        }
        return false
    }
    
    private func buildProjectHistoryContext(
        projectURL: URL,
        projectId: String,
        maxTokens: Int
    ) -> String? {
        let maxHistoryTokens = max(maxTokens, 500)
        let maxHistoryCharacters = maxHistoryTokens * 4
        let maxPromptCharsPerTurn = 1_400
        let maxStdoutCharsPerTurn = 2_200
        let maxStderrCharsPerTurn = 700
        
        let runHistory = loadProjectRunHistory(projectURL: projectURL)
        guard !runHistory.isEmpty else { return nil }
        
        var selectedHistorySections: [String] = []
        var usedChars = 0
        
        for run in runHistory.reversed() {
            let section = formatProjectHistorySection(
                run: run,
                maxPromptChars: maxPromptCharsPerTurn,
                maxStdoutChars: maxStdoutCharsPerTurn,
                maxStderrChars: maxStderrCharsPerTurn
            )
            
            guard !section.isEmpty else { continue }
            if usedChars + section.count > maxHistoryCharacters {
                break
            }
            
            selectedHistorySections.append(section)
            usedChars += section.count
        }
        
        guard !selectedHistorySections.isEmpty else { return nil }
        
        let chronologicalHistory = selectedHistorySections.reversed().joined(separator: "\n\n")
        return """
        === RECENT PROJECT HISTORY (\(projectId), oldest to newest) ===
        \(chronologicalHistory)
        === END PROJECT HISTORY ===
        """
    }
    
    private func loadProjectRunHistory(projectURL: URL) -> [ClaudeRunRecord] {
        let runsDirectory = projectURL.appendingPathComponent(".claude_runs", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: runsDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return []
        }
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        guard let runURLs = try? FileManager.default.contentsOfDirectory(
            at: runsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        
        var runs: [ClaudeRunRecord] = []
        for runURL in runURLs where runURL.pathExtension.lowercased() == "json" {
            guard let data = try? Data(contentsOf: runURL),
                  let run = try? decoder.decode(ClaudeRunRecord.self, from: data) else {
                continue
            }
            runs.append(run)
        }
        
        return runs.sorted { $0.timestamp < $1.timestamp }
    }
    
    private func formatProjectHistorySection(
        run: ClaudeRunRecord,
        maxPromptChars: Int,
        maxStdoutChars: Int,
        maxStderrChars: Int
    ) -> String {
        let prompt = redactSensitiveContextForModel(run.prompt).trimmingCharacters(in: .whitespacesAndNewlines)
        let stdout = redactSensitiveContextForModel(run.stdoutPreview).trimmingCharacters(in: .whitespacesAndNewlines)
        let stderr = redactSensitiveContextForModel(run.stderrPreview).trimmingCharacters(in: .whitespacesAndNewlines)
        
        if prompt.isEmpty && stdout.isEmpty && stderr.isEmpty {
            return ""
        }
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let timestamp = dateFormatter.string(from: run.timestamp)
        
        let promptExcerpt = snippetForProjectHistory(prompt, maxChars: maxPromptChars)
        let stdoutExcerpt = stdout.isEmpty ? "[no stdout]" : snippetForProjectHistory(stdout, maxChars: maxStdoutChars)
        let stderrExcerpt = stderr.isEmpty ? "[no stderr]" : snippetForProjectHistory(stderr, maxChars: maxStderrChars)
        
        var fileSummaryParts: [String] = []
        if !run.createdFiles.isEmpty {
            fileSummaryParts.append("created: \(run.createdFiles.prefix(6).joined(separator: ", "))")
        }
        if !run.modifiedFiles.isEmpty {
            fileSummaryParts.append("modified: \(run.modifiedFiles.prefix(6).joined(separator: ", "))")
        }
        if !run.deletedFiles.isEmpty {
            fileSummaryParts.append("deleted: \(run.deletedFiles.prefix(6).joined(separator: ", "))")
        }
        let fileSummary = fileSummaryParts.isEmpty ? "none" : fileSummaryParts.joined(separator: " | ")
        
        return """
        [\(timestamp)] exit=\(run.exitCode) timed_out=\(run.timedOut ? "yes" : "no") changes=\(fileSummary)
        Gemini prompt:
        \(promptExcerpt)
        CLI stdout:
        \(stdoutExcerpt)
        CLI stderr:
        \(stderrExcerpt)
        """
    }
    
    private func snippetForProjectHistory(_ text: String, maxChars: Int) -> String {
        guard maxChars > 0 else { return "" }
        let compact = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard compact.count > maxChars else { return compact }
        return String(compact.prefix(maxChars)) + "\n...[truncated]..."
    }
    
    private func resolvedCodeCLIProvider() -> CodeCLIProvider {
        let storedProvider = KeychainHelper.load(key: KeychainHelper.codeCLIProviderKey)
        return CodeCLIProvider.fromStoredValue(storedProvider)
    }
    
    private func loadCodeCLICommand(for provider: CodeCLIProvider) -> String {
        let value: String?
        switch provider {
        case .claude:
            value = KeychainHelper.load(key: KeychainHelper.claudeCodeCommandKey)
        case .gemini:
            value = KeychainHelper.load(key: KeychainHelper.geminiCodeCommandKey)
        }
        
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            return trimmed
        }
        
        switch provider {
        case .claude:
            return "claude"
        case .gemini:
            return KeychainHelper.defaultGeminiCodeCommand
        }
    }
    
    private func loadCodeCLIArguments(for provider: CodeCLIProvider) -> String {
        let value: String?
        switch provider {
        case .claude:
            value = KeychainHelper.load(key: KeychainHelper.claudeCodeArgsKey)
        case .gemini:
            value = KeychainHelper.load(key: KeychainHelper.geminiCodeArgsKey)
        }
        
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            return trimmed
        }
        
        switch provider {
        case .claude:
            return KeychainHelper.defaultClaudeCodeArgs
        case .gemini:
            return KeychainHelper.defaultGeminiCodeArgs
        }
    }
    
    private func loadCodeCLITimeout(for provider: CodeCLIProvider) -> Int {
        let rawValue: String?
        let defaultValue: String
        
        switch provider {
        case .claude:
            rawValue = KeychainHelper.load(key: KeychainHelper.claudeCodeTimeoutKey)
            defaultValue = KeychainHelper.defaultClaudeCodeTimeout
        case .gemini:
            rawValue = KeychainHelper.load(key: KeychainHelper.geminiCodeTimeoutKey)
            defaultValue = KeychainHelper.defaultGeminiCodeTimeout
        }
        
        return Int(rawValue ?? "") ?? Int(defaultValue) ?? 300
    }
    
    private func normalizedSessionID(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
    
    private func codeCLISessionID(for provider: CodeCLIProvider, metadata: ClaudeProjectMetadata) -> String? {
        if let stored = normalizedSessionID(metadata.codeCLISessionIds?[provider.rawValue]) {
            return stored
        }
        
        // Backward compatibility with legacy single-session storage.
        guard let legacy = normalizedSessionID(metadata.sessionUuid) else {
            return nil
        }
        
        let isUUID = UUID(uuidString: legacy) != nil
        switch provider {
        case .claude:
            return isUUID ? legacy : nil
        case .gemini:
            return isUUID ? nil : legacy
        }
    }
    
    private func setCodeCLISessionID(
        _ sessionID: String,
        for provider: CodeCLIProvider,
        metadata: inout ClaudeProjectMetadata
    ) {
        guard let normalized = normalizedSessionID(sessionID) else { return }
        var sessions = metadata.codeCLISessionIds ?? [:]
        sessions[provider.rawValue] = normalized
        metadata.codeCLISessionIds = sessions
        
        // Keep legacy field populated for Claude backward compatibility.
        if provider == .claude {
            metadata.sessionUuid = normalized
        } else if let legacy = normalizedSessionID(metadata.sessionUuid),
                  UUID(uuidString: legacy) == nil {
            metadata.sessionUuid = nil
        }
    }
    
    private func clearCodeCLISessionID(for provider: CodeCLIProvider, metadata: inout ClaudeProjectMetadata) {
        if var sessions = metadata.codeCLISessionIds {
            sessions.removeValue(forKey: provider.rawValue)
            metadata.codeCLISessionIds = sessions.isEmpty ? nil : sessions
        }
        
        if provider == .claude {
            metadata.sessionUuid = nil
        } else if let legacy = normalizedSessionID(metadata.sessionUuid),
                  UUID(uuidString: legacy) == nil {
            metadata.sessionUuid = nil
        }
    }
    
    private func ensureGeminiHeadlessArguments(_ arguments: inout [String]) {
        var cleanedArgs: [String] = []
        var index = 0
        
        while index < arguments.count {
            let token = arguments[index]
            let lowerToken = token.lowercased()
            
            if lowerToken == "--output-format" {
                index += min(2, arguments.count - index)
                continue
            }
            
            if lowerToken.hasPrefix("--output-format=") {
                index += 1
                continue
            }
            
            if lowerToken == "-p" || lowerToken == "--prompt" {
                if index + 1 < arguments.count {
                    let next = arguments[index + 1]
                    if !next.hasPrefix("-") {
                        index += 2
                        continue
                    }
                }
                index += 1
                continue
            }
            
            if lowerToken.hasPrefix("--prompt=") {
                index += 1
                continue
            }
            
            cleanedArgs.append(token)
            index += 1
        }
        
        // Keep Gemini in deterministic headless mode and ensure `-p` sits
        // immediately before the injected prompt argument.
        arguments = ["--output-format", "json"] + cleanedArgs + ["-p"]
    }
    
    private func parseGeminiJSONOutput(_ raw: String) -> GeminiJSONOutput? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        
        func decode(_ candidate: String) -> GeminiJSONOutput? {
            guard let data = candidate.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(GeminiJSONOutput.self, from: data)
        }
        
        if let parsed = decode(trimmed) {
            return parsed
        }
        
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}") else {
            return nil
        }
        
        let candidate = String(trimmed[start...end])
        return decode(candidate)
    }
    
    private func codeCLIBaseEnvironment(for provider: CodeCLIProvider) -> [String: String] {
        var environment = claudeBaseEnvironment()
        if provider == .gemini {
            let storedGeminiApiKey = KeychainHelper.load(key: KeychainHelper.geminiApiKeyKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !storedGeminiApiKey.isEmpty {
                environment["GEMINI_API_KEY"] = storedGeminiApiKey
            }
        }
        return environment
    }
    
    private var claudeConfigDirectory: URL {
        let path = projectsDirectory.deletingLastPathComponent().appendingPathComponent("claude-config", isDirectory: true)
        try? FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }
    
    private func claudeBaseEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let requiredPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        let existing = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        var merged = existing
        
        for path in requiredPaths where !merged.contains(path) {
            merged.append(path)
        }
        
        environment["PATH"] = merged.joined(separator: ":")
        return environment
    }
    
    private func buildCodeCLIInvocations(
        command: String,
        cliArgs: [String],
        prompt: String,
        provider: CodeCLIProvider
    ) -> [ClaudeInvocation] {
        let commandTokens = parseCommandLineArguments(command)
        let primaryCommand = commandTokens.first ?? (provider == .gemini ? "gemini" : "claude")
        let commandPrefixArgs = Array(commandTokens.dropFirst())
        let taskArgs = commandPrefixArgs + cliArgs + [prompt]
        
        let fileManager = FileManager.default
        var invocations: [ClaudeInvocation] = []
        var seen: Set<String> = []
        
        func appendInvocation(executable: String, args: [String]) {
            let key = executable + "\u{1f}" + args.joined(separator: "\u{1f}")
            guard !seen.contains(key) else { return }
            seen.insert(key)
            
            let displayArgs: [String]
            if args.isEmpty {
                displayArgs = []
            } else {
                displayArgs = Array(args.dropLast()) + ["<prompt>"]
            }
            let display = ([executable] + displayArgs).joined(separator: " ")
            invocations.append(
                ClaudeInvocation(
                    executableURL: URL(fileURLWithPath: executable),
                    arguments: args,
                    displayCommand: display
                )
            )
        }
        
        if primaryCommand.contains("/") {
            appendInvocation(executable: primaryCommand, args: taskArgs)
        } else {
            appendInvocation(executable: "/usr/bin/env", args: [primaryCommand] + taskArgs)
        }
        
        let knownLaunchers: [String]
        switch provider {
        case .claude:
            knownLaunchers = ["/opt/homebrew/bin/claude", "/usr/local/bin/claude", "/usr/bin/claude"]
        case .gemini:
            knownLaunchers = ["/opt/homebrew/bin/gemini", "/usr/local/bin/gemini", "/usr/bin/gemini"]
        }
        
        if primaryCommand == provider.rawValue {
            for launcher in knownLaunchers {
                if fileManager.fileExists(atPath: launcher) {
                    appendInvocation(executable: launcher, args: taskArgs)
                }
            }
        }
        
        var launcherCandidates: [String] = []
        if primaryCommand.contains("/") {
            launcherCandidates.append(primaryCommand)
        } else if primaryCommand == provider.rawValue {
            launcherCandidates += knownLaunchers
        }
        
        if provider == .claude {
            for launcher in launcherCandidates {
                guard let scriptPath = resolveClaudeScriptPath(launcherPath: launcher) else { continue }
                
                if let nodePath = resolveNodeExecutablePath() {
                    appendInvocation(executable: nodePath, args: [scriptPath] + taskArgs)
                }
                appendInvocation(executable: "/usr/bin/env", args: ["node", scriptPath] + taskArgs)
            }
        }
        
        return invocations
    }
    
    private func executeVercelCommand(
        command: String,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String],
        timeoutSeconds: Int,
        maxOutputChars: Int,
        sensitiveValues: [String]
    ) async throws -> (ClaudeInvocation, ClaudeExecutionOutput) {
        let invocations = buildVercelInvocations(
            command: command,
            arguments: arguments,
            sensitiveValues: sensitiveValues
        )
        
        guard !invocations.isEmpty else {
            throw NSError(domain: "ToolExecutor", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No valid Vercel command invocation was generated. Check Vercel CLI settings."
            ])
        }
        
        var launchErrors: [String] = []
        
        for invocation in invocations {
            do {
                let output = try await runClaudeInvocation(
                    invocation,
                    projectURL: workingDirectory,
                    environment: environment,
                    timeoutSeconds: timeoutSeconds,
                    maxOutputChars: maxOutputChars
                )
                return (invocation, output)
            } catch {
                launchErrors.append("\(invocation.displayCommand): \(error.localizedDescription)")
            }
        }
        
        let details = launchErrors.isEmpty
            ? "No launch diagnostics available."
            : launchErrors.joined(separator: " | ")
        
        throw NSError(domain: "ToolExecutor", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "Failed to launch Vercel command. Attempts: \(details)"
        ])
    }
    
    private func buildVercelInvocations(
        command: String,
        arguments: [String],
        sensitiveValues: [String]
    ) -> [ClaudeInvocation] {
        let commandTokens = parseCommandLineArguments(command)
        let primaryCommand = commandTokens.first ?? KeychainHelper.defaultVercelCommand
        let commandPrefixArgs = Array(commandTokens.dropFirst())
        let taskArgs = commandPrefixArgs + arguments
        
        let fileManager = FileManager.default
        var invocations: [ClaudeInvocation] = []
        var seen: Set<String> = []
        
        func appendInvocation(executable: String, args: [String]) {
            let key = executable + "\u{1f}" + args.joined(separator: "\u{1f}")
            guard !seen.contains(key) else { return }
            seen.insert(key)
            
            invocations.append(
                ClaudeInvocation(
                    executableURL: URL(fileURLWithPath: executable),
                    arguments: args,
                    displayCommand: displayExternalInvocationCommand(
                        executable: executable,
                        arguments: args,
                        sensitiveValues: sensitiveValues
                    )
                )
            )
        }
        
        if primaryCommand.contains("/") {
            appendInvocation(executable: primaryCommand, args: taskArgs)
        } else {
            appendInvocation(executable: "/usr/bin/env", args: [primaryCommand] + taskArgs)
        }
        
        if primaryCommand == "vercel" {
            for launcher in ["/opt/homebrew/bin/vercel", "/usr/local/bin/vercel", "/usr/bin/vercel"] where fileManager.fileExists(atPath: launcher) {
                appendInvocation(executable: launcher, args: taskArgs)
            }
        }
        
        return invocations
    }
    
    private func displayExternalInvocationCommand(
        executable: String,
        arguments: [String],
        sensitiveValues: [String]
    ) -> String {
        let sanitizedArgs = arguments.map { sanitizeArgumentForDisplay($0, sensitiveValues: sensitiveValues) }
        return ([executable] + sanitizedArgs).joined(separator: " ")
    }
    
    private func sanitizeArgumentForDisplay(_ argument: String, sensitiveValues: [String]) -> String {
        if argument.hasPrefix("--token=") {
            return "--token=<redacted>"
        }
        
        for value in sensitiveValues where !value.isEmpty {
            if argument == value {
                return "<redacted>"
            }
            if argument.contains(value) {
                return argument.replacingOccurrences(of: value, with: "<redacted>")
            }
        }
        
        return argument
    }
    
    private func redactSensitiveValues(in text: String, values: [String]) -> String {
        var redacted = text
        for value in values where !value.isEmpty {
            redacted = redacted.replacingOccurrences(of: value, with: "<redacted>")
        }
        return redacted
    }
    
    /// Redacts common secret patterns before forwarding text to external models.
    /// This keeps Claude/Gemini context useful while reducing accidental secret exposure.
    private func redactSensitiveContextForModel(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        
        var redacted = text
        
        let rules: [(pattern: String, template: String, options: NSRegularExpression.Options)] = [
            (pattern: #"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----"#, template: "<redacted-private-key>", options: [.caseInsensitive]),
            (pattern: #"(?i)(authorization\s*:\s*bearer)\s+[A-Za-z0-9._\-+/=]+"#, template: "$1 <redacted>", options: []),
            (pattern: #"(?i)\bbearer\s+[A-Za-z0-9._\-+/=]{16,}"#, template: "Bearer <redacted>", options: []),
            (pattern: #"([A-Za-z][A-Za-z0-9+.\-]*://[^/\s:@]+:)[^@/\s]+@"#, template: "$1<redacted>@", options: []),
            (pattern: #"(?i)(\"[^\"]*(token|secret|password|passwd|api[_-]?key|client[_-]?secret|access[_-]?token|refresh[_-]?token)[^\"]*\"\s*:\s*\")([^\"]*)(\")"#, template: "$1<redacted>$4", options: []),
            (pattern: #"(?im)\b([A-Za-z0-9_.-]*(token|secret|password|passwd|api[_-]?key|client[_-]?secret|access[_-]?token|refresh[_-]?token)[A-Za-z0-9_.-]*)\b\s*([=:])\s*([^\s\"'`]+)"#, template: "$1$3<redacted>", options: []),
            (pattern: #"\b(sk-or-v1|sk-live|sk-test)-[A-Za-z0-9_-]{16,}\b"#, template: "<redacted-token>", options: [.caseInsensitive]),
            (pattern: #"\bgh[pousr]_[A-Za-z0-9]{20,}\b"#, template: "<redacted-token>", options: []),
            (pattern: #"\bAIza[0-9A-Za-z_-]{20,}\b"#, template: "<redacted-google-key>", options: []),
            (pattern: #"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"#, template: "<redacted-jwt>", options: [])
        ]
        
        for rule in rules {
            redacted = redactRegexMatches(
                in: redacted,
                pattern: rule.pattern,
                template: rule.template,
                options: rule.options
            )
        }
        
        return redacted
    }
    
    private func redactRegexMatches(
        in text: String,
        pattern: String,
        template: String,
        options: NSRegularExpression.Options = []
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return text
        }
        
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: template
        )
    }
    
    private func hasVercelProjectLink(at directoryURL: URL) -> Bool {
        let linkFileURL = directoryURL.appendingPathComponent(".vercel/project.json")
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: linkFileURL.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }
    
    /// Ensures `.vercelignore` excludes internal metadata files and common secret-bearing env files.
    /// Creates the file if it doesn't exist, or appends missing entries if it does.
    private func ensureVercelIgnore(at directoryURL: URL) {
        let requiredEntries = [
            // Internal app metadata/logs
            ".project.json",
            ".project_database.json",
            ".claude_runs",
            ".claude_last_run.json",
            ".db_runs",
            ".mcp.json",
            ".vercel",
            // Environment files often contain secrets. Keep explicit examples/templates deployable.
            ".env",
            ".env.*",
            "!.env.example",
            "!.env.sample",
            "!.env.template",
            "!.env*.example",
            "!.env*.sample",
            "!.env*.template"
        ]
        
        let ignoreURL = directoryURL.appendingPathComponent(".vercelignore")
        var existingContent = (try? String(contentsOf: ignoreURL, encoding: .utf8)) ?? ""
        let existingLines = Set(existingContent.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) })
        
        let missingEntries = requiredEntries.filter { !existingLines.contains($0) }
        guard !missingEntries.isEmpty else { return }
        
        if !existingContent.isEmpty && !existingContent.hasSuffix("\n") {
            existingContent += "\n"
        }
        existingContent += missingEntries.joined(separator: "\n") + "\n"
        try? existingContent.write(to: ignoreURL, atomically: true, encoding: .utf8)
    }
    
    private func extractVercelDeploymentURL(from output: String) -> String? {
        if let exact = firstRegexMatch(in: output, pattern: #"https://[A-Za-z0-9][A-Za-z0-9.-]*\.vercel\.app(?:/[^\s"'<>]*)?"#) {
            return exact
        }
        
        if let exact = firstRegexMatch(in: output, pattern: #"https://[A-Za-z0-9][A-Za-z0-9.-]*\.vercel\.com/[^\s"'<>]*"#) {
            return exact
        }
        
        if let domain = firstRegexMatch(in: output, pattern: #"\b[A-Za-z0-9][A-Za-z0-9.-]*\.vercel\.app\b"#) {
            return "https://\(domain)"
        }
        
        return nil
    }
    
    private func firstRegexMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let matchRange = Range(match.range, in: text) else {
            return nil
        }
        return String(text[matchRange])
    }
    
    private func resolveClaudeScriptPath(launcherPath: String) -> String? {
        let fileManager = FileManager.default
        let launcherURL = URL(fileURLWithPath: launcherPath)
        
        if launcherURL.pathExtension == "js", fileManager.fileExists(atPath: launcherURL.path) {
            return launcherURL.standardizedFileURL.path
        }
        
        guard fileManager.fileExists(atPath: launcherPath) else { return nil }
        
        if let destination = try? fileManager.destinationOfSymbolicLink(atPath: launcherPath) {
            let resolvedURL: URL
            if destination.hasPrefix("/") {
                resolvedURL = URL(fileURLWithPath: destination)
            } else {
                resolvedURL = launcherURL.deletingLastPathComponent().appendingPathComponent(destination)
            }
            let standardized = resolvedURL.standardizedFileURL.path
            if standardized.hasSuffix(".js"), fileManager.fileExists(atPath: standardized) {
                return standardized
            }
        }
        
        return nil
    }
    
    private func resolveNodeExecutablePath() -> String? {
        let candidates = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }
    
    private func runCodeCLIInvocation(
        _ invocation: ClaudeInvocation,
        projectURL: URL,
        environment: [String: String],
        timeoutSeconds: Int,
        maxOutputChars: Int
    ) async throws -> ClaudeExecutionOutput {
        try await runClaudeInvocation(
            invocation,
            projectURL: projectURL,
            environment: environment,
            timeoutSeconds: timeoutSeconds,
            maxOutputChars: maxOutputChars
        )
    }
    
    private func runClaudeInvocation(
        _ invocation: ClaudeInvocation,
        projectURL: URL,
        environment: [String: String],
        timeoutSeconds: Int,
        maxOutputChars: Int
    ) async throws -> ClaudeExecutionOutput {
        try Task.checkCancellation()
        
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        
        process.currentDirectoryURL = projectURL
        process.environment = environment
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.executableURL = invocation.executableURL
        process.arguments = invocation.arguments
        
        try process.run()
        ToolExecutor.registerRunningProcess(process)
        defer { ToolExecutor.unregisterRunningProcess(process) }
        
        var timedOut = false
        var wasCancelled = false
        let timeoutNanos = UInt64(timeoutSeconds) * 1_000_000_000
        let pollNanos: UInt64 = 200_000_000
        var elapsedNanos: UInt64 = 0
        
        while process.isRunning && elapsedNanos < timeoutNanos {
            if Task.isCancelled {
                wasCancelled = true
                break
            }
            try? await Task.sleep(nanoseconds: pollNanos)
            elapsedNanos += pollNanos
        }
        
        if process.isRunning {
            timedOut = !wasCancelled
            process.terminate()
            try? await Task.sleep(nanoseconds: 500_000_000)
            if process.isRunning {
                process.interrupt()
            }
        }
        
        process.waitUntilExit()
        
        let stdoutData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        
        if wasCancelled {
            throw CancellationError()
        }
        
        return ClaudeExecutionOutput(
            exitCode: process.terminationStatus,
            timedOut: timedOut,
            stdout: truncateForToolOutput(stringFromData(stdoutData), maxChars: maxOutputChars),
            stderr: truncateForToolOutput(stringFromData(stderrData), maxChars: maxOutputChars)
        )
    }
    
    private func shouldRetryClaudeWithAppConfig(stderr: String) -> Bool {
        let lower = stderr.lowercased()
        let permissionSignal = lower.contains("eperm") || lower.contains("operation not permitted") || lower.contains("permission denied")
        let claudeHomeSignal = lower.contains(".claude")
        return permissionSignal && claudeHomeSignal
    }
    
    private func shouldRetryClaudeWithBypassPermissions(
        stdout: String,
        stderr: String,
        arguments: [String]
    ) -> Bool {
        guard !claudeArgumentsUseBypassPermissions(arguments) else { return false }
        return containsClaudePermissionPromptSignal(text: stdout + "\n" + stderr)
    }
    
    private func claudeArgumentsUseBypassPermissions(_ arguments: [String]) -> Bool {
        let lowerArgs = arguments.map { $0.lowercased() }
        if lowerArgs.contains("--dangerously-skip-permissions") {
            return true
        }
        
        for (index, token) in lowerArgs.enumerated() {
            if token == "--permission-mode", index + 1 < lowerArgs.count {
                let mode = lowerArgs[index + 1]
                if mode == "bypasspermissions" || mode == "dontask" {
                    return true
                }
            } else if token.hasPrefix("--permission-mode=") {
                let mode = token.replacingOccurrences(of: "--permission-mode=", with: "")
                if mode == "bypasspermissions" || mode == "dontask" {
                    return true
                }
            }
        }
        
        return false
    }
    
    private func applyBypassPermissionMode(to arguments: [String]) -> [String] {
        guard !arguments.isEmpty else { return ["--permission-mode", "bypassPermissions"] }
        
        let prompt = arguments.last!
        let preArgs = Array(arguments.dropLast())
        
        var cleaned: [String] = []
        var skipNext = false
        
        for token in preArgs {
            if skipNext {
                skipNext = false
                continue
            }
            
            if token == "--permission-mode" {
                skipNext = true
                continue
            }
            
            if token.hasPrefix("--permission-mode=") {
                continue
            }
            
            cleaned.append(token)
        }
        
        cleaned.append("--permission-mode")
        cleaned.append("bypassPermissions")
        cleaned.append(prompt)
        return cleaned
    }
    
    private func displayClaudeInvocationCommand(executable: String, arguments: [String]) -> String {
        let displayArgs: [String]
        if arguments.isEmpty {
            displayArgs = []
        } else {
            displayArgs = Array(arguments.dropLast()) + ["<prompt>"]
        }
        return ([executable] + displayArgs).joined(separator: " ")
    }
    
    private func displayCodeCLIInvocationCommand(executable: String, arguments: [String]) -> String {
        displayClaudeInvocationCommand(executable: executable, arguments: arguments)
    }
    
    private func containsCodeCLIPermissionPromptSignal(provider: CodeCLIProvider, text: String) -> Bool {
        switch provider {
        case .claude:
            return containsClaudePermissionPromptSignal(text: text)
        case .gemini:
            return containsGeminiPermissionPromptSignal(text: text)
        }
    }
    
    private func containsClaudePermissionPromptSignal(text: String) -> Bool {
        let lower = text.lowercased()
        let signals = [
            "needs your approval",
            "please approve",
            "could you approve",
            "permission prompt",
            "blocked by your permission settings",
            "approval isn't going through",
            "allow me to run",
            "approve the command",
            "requires approval"
        ]
        
        if signals.contains(where: { lower.contains($0) }) {
            return true
        }
        
        let permissionErrors = lower.contains("permission denied") || lower.contains("operation not permitted")
        let approvalContext = lower.contains("approval") || lower.contains("permission settings")
        return permissionErrors && approvalContext
    }
    
    private func containsGeminiPermissionPromptSignal(text: String) -> Bool {
        let lower = text.lowercased()
        let signals = [
            "confirmation prompt requested by the command",
            "requires confirmation",
            "requires approval",
            "please confirm",
            "blocked by approval mode",
            "agent execution blocked"
        ]
        return signals.contains(where: { lower.contains($0) })
    }
    
    private func shouldRetryGeminiWithoutResume(
        stdout: String,
        stderr: String,
        arguments: [String]
    ) -> Bool {
        guard geminiArgumentsContainResume(arguments) else { return false }
        let lower = (stdout + "\n" + stderr).lowercased()
        let signals = [
            "invalid session identifier",
            "no previous sessions found",
            "failed to find session",
            "use --list-sessions",
            "could not resume"
        ]
        return signals.contains(where: { lower.contains($0) })
    }
    
    private func geminiArgumentsContainResume(_ arguments: [String]) -> Bool {
        let lowerArgs = arguments.map { $0.lowercased() }
        for token in lowerArgs {
            if token == "-r" || token == "--resume" || token.hasPrefix("--resume=") {
                return true
            }
        }
        return false
    }
    
    private func removingGeminiResumeArguments(from arguments: [String]) -> [String] {
        var cleaned: [String] = []
        var skipNext = false
        
        for token in arguments {
            if skipNext {
                skipNext = false
                continue
            }
            
            let lower = token.lowercased()
            if lower == "-r" || lower == "--resume" {
                skipNext = true
                continue
            }
            if lower.hasPrefix("--resume=") {
                continue
            }
            
            cleaned.append(token)
        }
        
        return cleaned
    }
    
    private func isLegacyAcceptEditsArgumentString(_ argString: String) -> Bool {
        let args = parseCommandLineArguments(argString)
        let lowerArgs = args.map { $0.lowercased() }
        
        for (index, token) in lowerArgs.enumerated() {
            if token == "--permission-mode", index + 1 < lowerArgs.count {
                if lowerArgs[index + 1] == "acceptedits" {
                    return true
                }
            } else if token.hasPrefix("--permission-mode=") {
                let mode = token.replacingOccurrences(of: "--permission-mode=", with: "")
                if mode == "acceptedits" {
                    return true
                }
            }
        }
        
        return false
    }
    
    private func relativePath(from root: URL, to child: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let childPath = child.standardizedFileURL.path
        if childPath == rootPath { return "." }
        if childPath.hasPrefix(rootPath + "/") {
            return String(childPath.dropFirst(rootPath.count + 1))
        }
        return child.lastPathComponent
    }
    
    private func parseCommandLineArguments(_ raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        
        var args: [String] = []
        var current = ""
        var quote: Character? = nil
        var isEscaping = false
        
        for char in trimmed {
            if isEscaping {
                current.append(char)
                isEscaping = false
                continue
            }
            
            if char == "\\" {
                isEscaping = true
                continue
            }
            
            if let activeQuote = quote {
                if char == activeQuote {
                    quote = nil
                } else {
                    current.append(char)
                }
                continue
            }
            
            if char == "\"" || char == "'" {
                quote = char
                continue
            }
            
            if char.isWhitespace {
                if !current.isEmpty {
                    args.append(current)
                    current = ""
                }
            } else {
                current.append(char)
            }
        }
        
        if !current.isEmpty {
            args.append(current)
        }
        
        return args
    }
    
    private func truncateForToolOutput(_ text: String, maxChars: Int) -> String {
        if text.count <= maxChars {
            return text
        }
        return String(text.prefix(maxChars)) + "\n...[truncated]..."
    }
    
    private func stringFromData(_ data: Data) -> String {
        if let string = String(data: data, encoding: .utf8) {
            return string
        }
        return "[binary output: \(data.count) bytes]"
    }
    
    private func persistRunRecord(_ record: ClaudeRunRecord, projectURL: URL) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601
        
        let latestURL = projectURL.appendingPathComponent(".claude_last_run.json")
        if let data = try? encoder.encode(record) {
            try? data.write(to: latestURL)
        }
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let runFolder = projectURL.appendingPathComponent(".claude_runs", isDirectory: true)
        try? FileManager.default.createDirectory(at: runFolder, withIntermediateDirectories: true)
        let logURL = runFolder.appendingPathComponent("run-\(formatter.string(from: record.timestamp)).json")
        if let data = try? encoder.encode(record) {
            try? data.write(to: logURL)
        }
        
        return relativePath(from: projectURL, to: logURL)
    }
    
    private func loadLastRunRecord(projectURL: URL) -> ClaudeRunRecord? {
        let url = projectURL.appendingPathComponent(".claude_last_run.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ClaudeRunRecord.self, from: data)
    }
    
    private func projectAttachmentName(projectId: String, relativePath: String) -> String {
        let sanitized = relativePath
            .replacingOccurrences(of: "/", with: "__")
            .replacingOccurrences(of: "\\", with: "__")
        return "\(projectId)__\(sanitized)"
    }
}

// MARK: - Gmail Tool Argument Types

struct GmailQueryArguments: Codable {
    let query: String?
    let limit: Int?
}

struct GmailSendArguments: Codable {
    let to: String
    let subject: String
    let body: String
    let threadId: String?
    let inReplyTo: String?
    let cc: [String]
    let bcc: [String]
    let attachmentFilenames: [String]?
    
    enum CodingKeys: String, CodingKey {
        case to, subject, body, cc, bcc
        case threadId = "thread_id"
        case inReplyTo = "in_reply_to"
        case attachmentFilenames = "attachment_filenames"
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        to = try container.decode(String.self, forKey: .to)
        subject = try container.decode(String.self, forKey: .subject)
        body = try container.decode(String.self, forKey: .body)
        threadId = try container.decodeIfPresent(String.self, forKey: .threadId)
        inReplyTo = try container.decodeIfPresent(String.self, forKey: .inReplyTo)
        cc = decodeRecipients(from: container, forKey: .cc)
        bcc = decodeRecipients(from: container, forKey: .bcc)
        
        // Handle attachmentFilenames as either an array or a JSON string
        if let array = try? container.decodeIfPresent([String].self, forKey: .attachmentFilenames) {
            attachmentFilenames = array
        } else if let jsonString = try? container.decodeIfPresent(String.self, forKey: .attachmentFilenames),
                  let data = jsonString.data(using: .utf8),
                  let parsed = try? JSONDecoder().decode([String].self, from: data) {
            attachmentFilenames = parsed
        } else {
            attachmentFilenames = nil
        }
    }
}

struct GmailThreadArguments: Codable {
    let threadId: String
    
    enum CodingKeys: String, CodingKey {
        case threadId = "thread_id"
    }
}

struct GmailForwardArguments: Codable {
    let to: String
    let messageId: String
    let comment: String?
    
    enum CodingKeys: String, CodingKey {
        case to
        case messageId = "message_id"
        case comment
    }
}

struct GmailAttachmentArguments: Codable {
    let messageId: String
    let attachmentId: String
    let filename: String
    
    enum CodingKeys: String, CodingKey {
        case messageId = "message_id"
        case attachmentId = "attachment_id"
        case filename
    }
}
