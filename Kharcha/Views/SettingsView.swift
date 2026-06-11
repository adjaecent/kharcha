import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var auth: GoogleAuthService
    @EnvironmentObject var sync: SyncService
    @AppStorage(SyncService.folderIdKey) private var appFolderId = ""
    @AppStorage(SyncService.sheetIdKey) private var appSheetId = ""

    private var hasDriveArtifacts: Bool {
        !appFolderId.isEmpty || !appSheetId.isEmpty
    }

    var body: some View {
        Form {
            Section("Google Account") {
                if auth.isSignedIn {
                    LabeledContent("Account") {
                        Text(auth.currentUser?.profile?.email ?? "Signed in")
                            .foregroundStyle(.secondary)
                    }

                    Button("Sign Out", role: .destructive) {
                        auth.signOut()
                    }
                } else {
                    Button("Sign in with Google") {
                        signIn()
                    }
                }
            }

            if auth.isSignedIn {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: "externaldrive.fill.badge.icloud")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .frame(width: 56, height: 56)
                            .background(.gray.gradient, in: RoundedRectangle(cornerRadius: 12))

                        Text("Your Data")
                            .font(.title3.bold())

                        Text(hasDriveArtifacts
                            ? "Bill photos are saved to a folder in your Google Drive, and every bill is added to a spreadsheet inside it. You can move or rename them, the app keeps track."
                            : "Bill photos will be saved to a folder in your Google Drive, with every bill added to a spreadsheet inside it. They'll be created on your first sync.")
                            .foregroundStyle(.secondary)
                        
                        Text("Removing items from the sheet will not update in the app. Similarly, removing items from the app will not destroy any rows on the sheet. Uploads are one-time.").foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)

                    if !appSheetId.isEmpty,
                       let url = URL(string: "https://docs.google.com/spreadsheets/d/\(appSheetId)") {
                        Link(destination: url) {
                            Label("Open \"\(SyncService.appSheetName)\" Spreadsheet", systemImage: "tablecells")
                        }
                    }
                    if !appFolderId.isEmpty,
                       let url = URL(string: "https://drive.google.com/drive/folders/\(appFolderId)") {
                        Link(destination: url) {
                            Label("Open \"\(SyncService.appFolderName)\" Folder", systemImage: "folder")
                        }
                    }
                }
            }
        }
        .navigationTitle("Settings")
    }

    private func signIn() {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = windowScene.windows.first?.rootViewController else { return }

        Task {
            try? await auth.signIn(presenting: rootVC)
            if auth.isSignedIn {
                await sync.syncPending()
            }
        }
    }
}
