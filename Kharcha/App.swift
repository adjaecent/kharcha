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
    @AppStorage("sheet_id") private var sheetId = ""
    @AppStorage("folder_id") private var folderId = ""

    private var isConfigured: Bool {
        auth.isSignedIn && !sheetId.isEmpty && !folderId.isEmpty
    }

    var body: some View {
        if isConfigured {
            MainTabView()
        } else {
            NavigationStack {
                SettingsView()
            }
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
