import Foundation
import Network
import UIKit

@MainActor
final class SyncService: ObservableObject {
    private let db: DatabaseService
    private let auth: GoogleAuthService
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.kharcha.network")

    @Published var isSyncing = false
    @Published var lastError: String?

    init(db: DatabaseService, auth: GoogleAuthService) {
        self.db = db
        self.auth = auth
        startNetworkMonitoring()
    }

    deinit {
        monitor.cancel()
    }

    private nonisolated func startNetworkMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            if path.status == .satisfied {
                Task { @MainActor in await self?.syncPending() }
            }
        }
        monitor.start(queue: monitorQueue)
    }

    func syncPending() async {
        guard auth.isSignedIn, !isSyncing else { return }

        // Nothing to sync — clear any stale error (e.g. the failing bill was
        // deleted) and skip the network work entirely
        let bills = (try? db.fetchPendingSync()) ?? []
        guard !bills.isEmpty else {
            lastError = nil
            return
        }

        isSyncing = true
        lastError = nil
        defer { isSyncing = false }

        // Ask for extra runtime so in-flight uploads can finish if the user
        // backgrounds the app mid-sync
        let bgTask = UIApplication.shared.beginBackgroundTask(withName: "com.kharcha.sync")
        defer {
            if bgTask != .invalid {
                UIApplication.shared.endBackgroundTask(bgTask)
            }
        }

        do {
            try await auth.refreshTokenIfNeeded()
        } catch {
            lastError = userMessage(for: error)
            return
        }
        guard let token = auth.accessToken else { return }

        let folderId: String
        let sheetId: String
        do {
            folderId = try await ensureAppFolder(token: token)
            sheetId = try await ensureAppSheet(folderId: folderId, token: token)
        } catch {
            print("Drive setup failed: \(error)")
            lastError = userMessage(for: error)
            return
        }

        var firstError: Error?

        for var bill in bills {
            do {
                // Re-fetch to pick up any OCR that completed after save
                if let fresh = try? db.fetch(id: bill.id) {
                    bill = fresh
                }

                // Upload image to Drive (skip if already uploaded on a previous attempt)
                if bill.driveURL == nil {
                    bill.driveURL = try await uploadToDrive(
                        imagePath: bill.absoluteImagePath,
                        folderId: folderId,
                        token: token
                    )
                    try db.update(bill) // persist driveURL so we don't re-upload on retry
                }

                // Append row to Sheet (skip if already appended — prevents
                // duplicate rows when a previous attempt died before the
                // status update landed)
                if !bill.sheetAppended {
                    try await appendToSheet(bill: bill, sheetId: sheetId, token: token)
                    bill.sheetAppended = true
                }

                bill.status = .uploaded
                try db.update(bill)
            } catch {
                // One bad bill shouldn't block the rest — unless the error
                // would hit every bill the same way
                print("Sync failed for bill \(bill.id): \(error)")
                invalidateCaches(for: error)
                if firstError == nil { firstError = error }
                if affectsAllBills(error) { break }
            }
        }

        if let firstError {
            lastError = userMessage(for: firstError)
        }
    }

    private func affectsAllBills(_ error: Error) -> Bool {
        switch error {
        case SyncError.driveUploadFailed(let code, _),
             SyncError.sheetsAppendFailed(let code, _):
            return [401, 403, 404].contains(code)
        default:
            return false
        }
    }

    /// The folder and spreadsheet are app-managed: when one vanished (404),
    /// drop its cached ID so the next sync recreates it.
    private func invalidateCaches(for error: Error) {
        switch error {
        case SyncError.driveUploadFailed(404, _):
            UserDefaults.standard.removeObject(forKey: Self.folderIdKey)
        case SyncError.sheetsAppendFailed(404, _):
            UserDefaults.standard.removeObject(forKey: Self.sheetIdKey)
        default:
            break
        }
    }

    /// Maps sync errors to short user-facing text. Pure — side effects live
    /// in `invalidateCaches(for:)`.
    private func userMessage(for error: Error) -> String {
        guard let syncError = error as? SyncError else {
            return error.localizedDescription
        }
        if syncError.statusCode == 401 {
            return "Google sign-in expired. Sign in again in Settings."
        }
        switch syncError {
        case .driveSetupFailed(let code, _):
            return "Couldn't set up the Drive folder and spreadsheet (error \(code))."
        case .driveUploadFailed(404, _):
            return "The Drive folder went missing. It will be recreated, retry sync."
        case .driveUploadFailed(let code, _):
            return "Google Drive upload failed (error \(code))."
        case .sheetsAppendFailed(404, _):
            return "The spreadsheet went missing. It will be recreated, retry sync."
        case .sheetsAppendFailed(let code, _):
            return "Google Sheets append failed (error \(code))."
        }
    }

    // MARK: - App-owned Drive folder + spreadsheet

    static let appFolderName = "Kharcha Bills"
    static let appSheetName = "List"
    static let folderIdKey = "app_folder_id"
    static let sheetIdKey = "app_sheet_id"
    private static let paymentMethodHeaderKey = "sheet_payment_method_header_added"

    private static let roleKey = "kharcha_role"
    private static let folderMimeType = "application/vnd.google-apps.folder"
    private static let sheetMimeType = "application/vnd.google-apps.spreadsheet"

    /// Returns the ID of the app-created "Kharcha Bills" folder, creating it
    /// on first sync. drive.file scope fully manages files the app created,
    /// so this folder is verifiable — unlike a user-supplied folder ID. The
    /// user can move or rename the folder freely; it's tracked by ID.
    private func ensureAppFolder(token: String) async throws -> String {
        try await ensureAppFile(
            cacheKey: Self.folderIdKey,
            name: Self.appFolderName,
            mimeType: Self.folderMimeType,
            role: "folder",
            parentId: nil,
            token: token
        )
    }

    /// Returns the ID of the app-created "List" spreadsheet inside the
    /// Kharcha Bills folder, creating it (with a header row) on first sync.
    private func ensureAppSheet(folderId: String, token: String) async throws -> String {
        let sheetId = try await ensureAppFile(
            cacheKey: Self.sheetIdKey,
            name: Self.appSheetName,
            mimeType: Self.sheetMimeType,
            role: "sheet",
            parentId: folderId,
            token: token
        )
        try await addPaymentMethodHeader(sheetId: sheetId, token: token)
        return sheetId
    }

    /// Sheets created before the Payment Method column exists have an 11-column
    /// header, leaving the new column unlabelled. Write just that one cell, once.
    private func addPaymentMethodHeader(sheetId: String, token: String) async throws {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.paymentMethodHeaderKey) else { return }

        let url = URL(string: "https://sheets.googleapis.com/v4/spreadsheets/\(sheetId)/values/L1?valueInputOption=RAW")!
        let (_, http) = try await googleRequest(
            url: url,
            method: "PUT",
            jsonBody: ["values": [["Payment Method"]]],
            token: token
        )
        guard (200...299).contains(http.statusCode) else { return }
        defaults.set(true, forKey: Self.paymentMethodHeaderKey)
    }

    private func ensureAppFile(
        cacheKey: String,
        name: String,
        mimeType: String,
        role: String,
        parentId: String?,
        token: String
    ) async throws -> String {
        let defaults = UserDefaults.standard

        // The existence check also catches a *trashed* file, which later
        // uploads would NOT catch (uploading into a trashed folder succeeds,
        // silently landing the file in the trash)
        if let cached = defaults.string(forKey: cacheKey),
           try await fileExists(id: cached, token: token) {
            return cached
        }

        // Cache miss or file deleted — recover a previously created one via
        // its kharcha_role tag (survives rename/move; e.g. after reinstall)
        // before creating fresh
        let fileId: String
        if let tagged = try await findAppFile(role: role, token: token) {
            fileId = tagged
        } else {
            fileId = try await createAppFile(named: name, mimeType: mimeType, role: role, parentId: parentId, token: token)
            if mimeType == Self.sheetMimeType {
                try await appendRow(Self.headerRow, sheetId: fileId, token: token)
            }
        }
        defaults.set(fileId, forKey: cacheKey)
        return fileId
    }

    private func fileExists(id: String, token: String) async throws -> Bool {
        let url = URL(string: "https://www.googleapis.com/drive/v3/files/\(id)?fields=id,trashed")!
        let (data, http) = try await googleRequest(url: url, token: token)
        switch http.statusCode {
        case 200:
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            return (json?["trashed"] as? Bool) != true
        case 404:
            return false
        default:
            throw SyncError.driveSetupFailed(statusCode: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
    }

    private func findAppFile(role: String, token: String) async throws -> String? {
        // drive.file scope only lists app-created files, so this can't match
        // unrelated files the user happens to have
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        components.queryItems = [
            URLQueryItem(name: "q", value: "appProperties has { key='\(Self.roleKey)' and value='\(role)' } and trashed = false"),
            URLQueryItem(name: "fields", value: "files(id)"),
            URLQueryItem(name: "pageSize", value: "1"),
        ]
        let (data, http) = try await googleRequest(url: components.url!, token: token)
        guard http.statusCode == 200 else {
            throw SyncError.driveSetupFailed(statusCode: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let files = json?["files"] as? [[String: Any]]
        return files?.first?["id"] as? String
    }

    private func createAppFile(named name: String, mimeType: String, role: String, parentId: String?, token: String) async throws -> String {
        var metadata: [String: Any] = [
            "name": name,
            "mimeType": mimeType,
            "appProperties": [Self.roleKey: role]
        ]
        if let parentId {
            metadata["parents"] = [parentId]
        }

        let url = URL(string: "https://www.googleapis.com/drive/v3/files?fields=id")!
        let (data, http) = try await googleRequest(url: url, method: "POST", jsonBody: metadata, token: token)
        guard (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String else {
            throw SyncError.driveSetupFailed(statusCode: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        return id
    }

    // MARK: - Google Drive upload

    private func uploadToDrive(imagePath: String, folderId: String, token: String) async throws -> String {
        let imageURL = URL(fileURLWithPath: imagePath)

        // Step 1: Initiate resumable upload
        var initRequest = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&fields=id,webViewLink")!)
        initRequest.httpMethod = "POST"
        initRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        initRequest.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        initRequest.setValue("image/jpeg", forHTTPHeaderField: "X-Upload-Content-Type")
        initRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "name": imageURL.lastPathComponent,
            "parents": [folderId]
        ])

        let (_, initResponse) = try await URLSession.shared.data(for: initRequest)
        guard let httpInit = initResponse as? HTTPURLResponse,
              let uploadURL = httpInit.value(forHTTPHeaderField: "Location"),
              let uploadURLParsed = URL(string: uploadURL) else {
            throw SyncError.driveUploadFailed(statusCode: (initResponse as? HTTPURLResponse)?.statusCode ?? 0, body: "No upload URI returned")
        }

        // Step 2: Upload file to the resumable URI
        var uploadRequest = URLRequest(url: uploadURLParsed)
        uploadRequest.httpMethod = "PUT"
        uploadRequest.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.upload(for: uploadRequest, fromFile: imageURL)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw SyncError.driveUploadFailed(
                statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["webViewLink"] as? String ?? ""
    }

    // MARK: - Google Sheets append

    /// Column order must match `appendToSheet`'s row below.
    private static let headerRow: [Any] = [
        "Upload Date", "File", "Vendor", "Bill Date", "Bill Amount", "Currency",
        "Tax Amount", "Tax Number", "Bill number", "Category", "Raw OCR data",
        // Appended at the end on purpose: inserting it next to Category would
        // shift Raw OCR data for new rows only, misaligning every older row.
        "Payment Method"
    ]

    private func appendToSheet(bill: Bill, sheetId: String, token: String) async throws {
        let row: [Any] = [
            ISO8601DateFormatter().string(from: bill.createdAt),
            bill.driveURL ?? "",
            bill.vendor ?? "",
            bill.date ?? "",
            bill.amount ?? 0,
            bill.currency,
            bill.gstAmount ?? 0,
            bill.gstin ?? "",
            bill.billNo ?? "",
            bill.category ?? "Miscellaneous",
            String((bill.rawText ?? "").prefix(5000)),
            bill.paymentMethod ?? ""
        ]
        try await appendRow(row, sheetId: sheetId, token: token)
    }

    private func appendRow(_ values: [Any], sheetId: String, token: String) async throws {
        // Use RAW so Sheets doesn't auto-interpret dates as serial numbers
        var components = URLComponents(string: "https://sheets.googleapis.com/v4/spreadsheets/\(sheetId)/values/A1:append")!
        components.queryItems = [
            URLQueryItem(name: "valueInputOption", value: "RAW"),
            URLQueryItem(name: "insertDataOption", value: "INSERT_ROWS"),
        ]
        let (data, http) = try await googleRequest(
            url: components.url!,
            method: "POST",
            jsonBody: ["values": [values]],
            token: token
        )
        guard (200...299).contains(http.statusCode) else {
            throw SyncError.sheetsAppendFailed(statusCode: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
    }

    // MARK: - Shared request plumbing

    private func googleRequest(
        url: URL,
        method: String = "GET",
        jsonBody: [String: Any]? = nil,
        token: String
    ) async throws -> (data: Data, http: HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let jsonBody {
            request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SyncError.driveSetupFailed(statusCode: 0, body: "No response")
        }
        return (data, http)
    }
}

enum SyncError: LocalizedError {
    case driveSetupFailed(statusCode: Int, body: String)
    case driveUploadFailed(statusCode: Int, body: String)
    case sheetsAppendFailed(statusCode: Int, body: String)

    var statusCode: Int {
        switch self {
        case .driveSetupFailed(let code, _),
             .driveUploadFailed(let code, _),
             .sheetsAppendFailed(let code, _):
            return code
        }
    }

    var errorDescription: String? {
        switch self {
        case .driveSetupFailed(let code, let body):
            return "Drive setup failed (\(code)): \(body)"
        case .driveUploadFailed(let code, let body):
            return "Drive upload failed (\(code)): \(body)"
        case .sheetsAppendFailed(let code, let body):
            return "Sheets append failed (\(code)): \(body)"
        }
    }
}
