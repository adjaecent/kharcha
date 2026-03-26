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

        isSyncing = true
        lastError = nil
        defer { isSyncing = false }

        do {
            try await auth.refreshTokenIfNeeded()
            let bills = try db.fetchPendingSync()

            for var bill in bills {
                guard let token = auth.accessToken else { break }

                let sheetId = UserDefaults.standard.string(forKey: "sheet_id") ?? ""
                let folderId = UserDefaults.standard.string(forKey: "folder_id") ?? ""

                guard !sheetId.isEmpty, !folderId.isEmpty else { break }

                // Re-fetch to pick up any OCR that completed after save
                if let fresh = try? db.fetch(id: bill.id) {
                    bill.rawText = fresh.rawText
                }

                // Upload image to Drive (skip if already uploaded on a previous attempt)
                if bill.driveURL == nil {
                    let driveURL = try await uploadToDrive(
                        imagePath: bill.imagePath,
                        folderId: folderId,
                        token: token
                    )
                    bill.driveURL = driveURL
                    try db.update(bill) // persist driveURL so we don't re-upload on retry
                }

                // Append row to Sheet
                try await appendToSheet(
                    bill: bill,
                    sheetId: sheetId,
                    token: token
                )

                bill.status = .uploaded
                try db.update(bill)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Google Drive upload

    private func uploadToDrive(imagePath: String, folderId: String, token: String) async throws -> String {
        let imageURL = URL(fileURLWithPath: imagePath)
        let fileName = imageURL.lastPathComponent

        // Step 1: Initiate resumable upload
        let metadata: [String: Any] = [
            "name": fileName,
            "parents": [folderId]
        ]
        let metadataData = try JSONSerialization.data(withJSONObject: metadata)

        var initRequest = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&fields=id,webViewLink")!)
        initRequest.httpMethod = "POST"
        initRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        initRequest.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        initRequest.setValue("image/jpeg", forHTTPHeaderField: "X-Upload-Content-Type")
        initRequest.httpBody = metadataData

        let (_, initResponse) = try await URLSession.shared.data(for: initRequest)
        guard let httpInit = initResponse as? HTTPURLResponse,
              let uploadURL = httpInit.value(forHTTPHeaderField: "Location") else {
            throw SyncError.driveUploadFailed(statusCode: (initResponse as? HTTPURLResponse)?.statusCode ?? 0, body: "No upload URI returned")
        }

        // Step 2: Upload file to the resumable URI
        guard let uploadURLParsed = URL(string: uploadURL) else {
            throw SyncError.driveUploadFailed(statusCode: 0, body: "Invalid upload URI")
        }
        var uploadRequest = URLRequest(url: uploadURLParsed)
        uploadRequest.httpMethod = "PUT"
        uploadRequest.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.upload(for: uploadRequest, fromFile: imageURL)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let http = response as? HTTPURLResponse
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SyncError.driveUploadFailed(statusCode: http?.statusCode ?? 0, body: body)
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["webViewLink"] as? String ?? ""
    }

    // MARK: - Google Sheets append

    private func appendToSheet(bill: Bill, sheetId: String, token: String) async throws {
        // Use RAW so Sheets doesn't auto-interpret dates as serial numbers
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
            String((bill.rawText ?? "").prefix(5000))
        ]

        let body: [String: Any] = ["values": [row]]
        let bodyData = try JSONSerialization.data(withJSONObject: body)

        var components = URLComponents(string: "https://sheets.googleapis.com/v4/spreadsheets/\(sheetId)/values/A1:append")!
        components.queryItems = [
            URLQueryItem(name: "valueInputOption", value: "RAW"),
            URLQueryItem(name: "insertDataOption", value: "INSERT_ROWS"),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let http = response as? HTTPURLResponse
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SyncError.sheetsAppendFailed(statusCode: http?.statusCode ?? 0, body: body)
        }
    }
}

enum SyncError: LocalizedError {
    case driveUploadFailed(statusCode: Int, body: String)
    case sheetsAppendFailed(statusCode: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .driveUploadFailed(let code, let body):
            return "Drive upload failed (\(code)): \(body)"
        case .sheetsAppendFailed(let code, let body):
            return "Sheets append failed (\(code)): \(body)"
        }
    }
}
