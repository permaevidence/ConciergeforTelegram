import SwiftUI

@main
struct TelegramConciergeApp: App {
    @StateObject private var conversationManager = ConversationManager()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(conversationManager)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 500, height: 700)
        
        Settings {
            SettingsView()
                .environmentObject(conversationManager)
        }
    }
}
