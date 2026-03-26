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
    var rawText: String?
    var extractionDone: Bool
    var status: BillStatus
    var driveURL: String?
    var createdAt: Date
    var updatedAt: Date

    static let databaseTableName = "bills"

    enum Columns: String, ColumnExpression {
        case id, imagePath, vendor, date, amount, currency
        case gstAmount, gstin, billNo, category, rawText, extractionDone, status, driveURL
        case createdAt, updatedAt
    }

    init(imagePath: String) {
        self.id = UUID().uuidString
        self.imagePath = imagePath
        self.currency = Currency.inr.code
        self.extractionDone = false
        self.status = .draft
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}
