import Foundation
import GRDB

enum BillStatus: String, Codable, DatabaseValueConvertible {
    case draft
    case saved
    case uploaded
}

struct Bill: Identifiable, Codable, FetchableRecord, PersistableRecord, Sendable {
    var id: String
    var imagePath: String
    var vendor: String?
    var date: String?
    var amount: Double?
    var currency: String
    var gstAmount: Double?
    var gstin: String?
    var billNo: String?
    var category: String?
    var paymentMethod: String?
    var rawText: String?
    var extractionDone: Bool
    var status: BillStatus
    var driveURL: String?
    var sheetAppended: Bool
    var createdAt: Date
    var updatedAt: Date

    static let databaseTableName = "bills"

    enum Columns: String, ColumnExpression {
        case id, imagePath, vendor, date, amount, currency
        case gstAmount, gstin, billNo, category, paymentMethod, rawText, extractionDone, status, driveURL, sheetAppended
        case createdAt, updatedAt
    }

    init(imagePath: String) {
        self.id = UUID().uuidString
        self.imagePath = imagePath
        self.currency = Currency.inr.code
        self.extractionDone = false
        self.status = .draft
        self.sheetAppended = false
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    private static let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    /// `imagePath` is stored relative to the Documents directory so it
    /// survives container path changes (device restore, simulator reinstall).
    /// Absolute paths are tolerated for pre-migration rows.
    var absoluteImagePath: String {
        if imagePath.hasPrefix("/") { return imagePath }
        return Self.documentsURL.appendingPathComponent(imagePath).path
    }
}
