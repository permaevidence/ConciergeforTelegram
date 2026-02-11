import SwiftUI

@main
struct TelegramConciergeApp: App {
    @StateObject private var conversationManager = ConversationManager()

    init() {
        ProjectsZipAutoExtractor.shared.start()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(conversationManager)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 560, height: 700)
        
        Settings {
            SettingsView()
                .environmentObject(conversationManager)
        }
    }
}
