import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var auth: GoogleAuthService
    @EnvironmentObject var sync: SyncService
    @AppStorage("sheet_id") private var sheetId = ""
    @AppStorage("folder_id") private var folderId = ""
    @AppStorage("sheet_valid") private var sheetValid = false
    @AppStorage("folder_valid") private var folderValid = false

    @State private var showSheetEditor = false
    @State private var showFolderEditor = false

    var body: some View {
        Form {
            Section("Google Account") {
                if auth.isSignedIn {
                    LabeledContent("Account") {
                        Text(auth.currentUser?.profile?.email ?? "Signed in")
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        showFolderEditor = true
                    } label: {
                        HStack {
                            Text("Drive Folder")
                                .foregroundStyle(.primary)
                            Spacer()
                            if folderId.isEmpty {
                                Text("Not Set")
                                    .foregroundStyle(.secondary)
                            } else {
                                Image(systemName: folderValid ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(folderValid ? .green : .red)
                            }
                        }
                    }

                    Button {
                        showSheetEditor = true
                    } label: {
                        HStack {
                            Text("Spreadsheet")
                                .foregroundStyle(.primary)
                            Spacer()
                            if sheetId.isEmpty {
                                Text("Not Set")
                                    .foregroundStyle(.secondary)
                            } else {
                                Image(systemName: sheetValid ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(sheetValid ? .green : .red)
                            }
                        }
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
        }
        .navigationTitle("Settings")
        .sheet(isPresented: $showSheetEditor) {
            IDEditorSheet(
                title: "Spreadsheet ID",
                hint: "Paste the ID from your Google Sheets URL\nhttps://docs.google.com/spreadsheets/d/[THIS_PART]/edit",
                kind: .sheet,
                value: $sheetId,
                isValid: $sheetValid
            )
        }
        .sheet(isPresented: $showFolderEditor) {
            IDEditorSheet(
                title: "Drive Folder ID",
                hint: "Paste the ID from your Google Drive folder URL\nhttps://drive.google.com/drive/folders/[THIS_PART]",
                kind: .driveFolder,
                value: $folderId,
                isValid: $folderValid
            )
        }
        .onChange(of: sheetId) { _, _ in trySyncIfReady() }
        .onChange(of: folderId) { _, _ in trySyncIfReady() }
    }

    private func trySyncIfReady() {
        guard auth.isSignedIn, !sheetId.isEmpty, !folderId.isEmpty else { return }
        Task { await sync.syncPending() }
    }

    private func signIn() {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = windowScene.windows.first?.rootViewController else { return }

        Task {
            try? await auth.signIn(presenting: rootVC)
            trySyncIfReady()
        }
    }
}

enum IDKind {
    case sheet
    case driveFolder
}

struct IDEditorSheet: View {
    let title: String
    let hint: String
    let kind: IDKind
    @Binding var value: String
    @Binding var isValid: Bool
    @State private var draft = ""
    @State private var validationState: ValidationState = .idle
    @EnvironmentObject var auth: GoogleAuthService
    @Environment(\.dismiss) private var dismiss

    enum ValidationState {
        case idle, checking, valid, invalid(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(title, text: $draft)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: draft) { _, _ in
                            validationState = .idle
                        }
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(hint)
                        switch validationState {
                        case .idle:
                            EmptyView()
                        case .checking:
                            HStack(spacing: 4) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Checking access...")
                            }
                            .foregroundStyle(.secondary)
                        case .valid:
                            Label("Accessible", systemImage: "checkmark.circle")
                                .foregroundStyle(.green)
                        case .invalid(let msg):
                            Label(msg, systemImage: "xmark.circle")
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        Task { await validateAndSave() }
                    }
                    .disabled(draft.isEmpty)
                }
            }
        }
        .onAppear { draft = value }
        .presentationDetents([.medium])
    }

    private func validateAndSave() async {
        let cleanId = cleanID(from: draft)

        // Drive folders can't be validated with drive.file scope — just save
        if kind == .driveFolder {
            value = cleanId
            isValid = true
            dismiss()
            return
        }

        // Validate sheets
        validationState = .checking
        let token = auth.accessToken ?? ""

        guard !token.isEmpty else {
            validationState = .invalid("Not signed in")
            return
        }

        let url = URL(string: "https://sheets.googleapis.com/v4/spreadsheets/\(cleanId)?fields=spreadsheetId")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                validationState = .invalid("Connection failed")
                return
            }

            if http.statusCode == 200 {
                validationState = .valid
                value = cleanId
                isValid = true
                dismiss()
            } else if http.statusCode == 404 {
                validationState = .invalid("Not found")
                isValid = false
            } else if http.statusCode == 403 {
                validationState = .invalid("No access — check sharing")
                isValid = false
            } else {
                validationState = .invalid("Error (\(http.statusCode))")
                isValid = false
            }
        } catch {
            validationState = .invalid("Connection failed")
            isValid = false
        }
    }

    private func cleanID(from input: String) -> String {
        input.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
