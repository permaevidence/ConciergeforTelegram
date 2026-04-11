import SwiftUI

@main
struct TelegramConciergeApp: App {
    @StateObject private var conversationManager = ConversationManager()
    @State private var onboardingComplete = !OnboardingView.shouldShowOnboarding

    init() {
        ProjectsZipAutoExtractor.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            if onboardingComplete {
                ContentView()
                    .environmentObject(conversationManager)
            } else {
                OnboardingView(isComplete: $onboardingComplete)
                    .environmentObject(conversationManager)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 560, height: 700)

        Settings {
            SettingsView()
                .environmentObject(conversationManager)
        }
    }
}
