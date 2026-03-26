import SwiftUI
import GoogleSignIn

@main
struct KharchaApp: App {
    @StateObject private var db: DatabaseService
    @StateObject private var auth: GoogleAuthService
    @StateObject private var sync: SyncService

    init() {
        let database = (try? DatabaseService()) ?? DatabaseService.empty()
        let authService = GoogleAuthService()
        let syncService = SyncService(db: database, auth: authService)

        _db = StateObject(wrappedValue: database)
        _auth = StateObject(wrappedValue: authService)
        _sync = StateObject(wrappedValue: syncService)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(db)
                .environmentObject(auth)
                .environmentObject(sync)
                .onOpenURL { url in
                    GIDSignIn.sharedInstance.handle(url)
                }
                .task {
                    await auth.restorePreviousSignIn()
                }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var auth: GoogleAuthService

    var body: some View {
        if auth.isRestoring {
            Color.clear
        } else {
            MainTabView()
        }
    }
}

struct MainTabView: View {
    var body: some View {
        TabView {
            NavigationStack {
                CaptureView()
            }
            .tabItem {
                Label("Bills", systemImage: "doc.text")
            }

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label("Settings", systemImage: "gear")
            }
        }
    }
}
