import Foundation
import GRDB

@MainActor
final class DatabaseService: ObservableObject {
    private let dbQueue: DatabaseQueue

    init() throws {
        let fileManager = FileManager.default
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dbURL = appSupport.appendingPathComponent("kharcha.sqlite")
        dbQueue = try DatabaseQueue(path: dbURL.path)
        try migrate()
    }

    /// In-memory fallback if disk DB fails
    static func empty() -> DatabaseService {
        try! self.init(queue: DatabaseQueue())
    }

    private init(queue: DatabaseQueue) throws {
        dbQueue = queue
        try migrate()
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "bills") { t in
                t.column("id", .text).primaryKey()
                t.column("imagePath", .text).notNull()
                t.column("vendor", .text)
                t.column("date", .text)
                t.column("amount", .double)
                t.column("currency", .text).notNull().defaults(to: "INR")
                t.column("gstAmount", .double)
                t.column("gstin", .text)
                t.column("billNo", .text)
                t.column("rawText", .text)
                t.column("status", .text).notNull().defaults(to: "draft")
                t.column("driveURL", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
        }

        try migrator.migrate(dbQueue)
    }

    // MARK: - CRUD

    func insert(_ bill: Bill) throws {
        try dbQueue.write { db in
            try bill.insert(db)
        }
    }

    func update(_ bill: Bill) throws {
        var updated = bill
        updated.updatedAt = Date()
        try dbQueue.write { db in
            try updated.update(db)
        }
    }

    func fetchAll() throws -> [Bill] {
        try dbQueue.read { db in
            try Bill.order(Bill.Columns.createdAt.desc).fetchAll(db)
        }
    }

    func fetchPendingSync() throws -> [Bill] {
        try dbQueue.read { db in
            try Bill
                .filter(Bill.Columns.status == BillStatus.saved.rawValue)
                .fetchAll(db)
        }
    }

    func fetch(id: String) throws -> Bill? {
        try dbQueue.read { db in
            try Bill.fetchOne(db, key: id)
        }
    }

    func delete(id: String) throws {
        try dbQueue.write { db in
            _ = try Bill.deleteOne(db, key: id)
        }
    }

    func search(query: String) throws -> [Bill] {
        let pattern = "%\(query)%"
        return try dbQueue.read { db in
            try Bill
                .filter(
                    Bill.Columns.vendor.like(pattern) ||
                    Bill.Columns.rawText.like(pattern) ||
                    Bill.Columns.billNo.like(pattern) ||
                    Bill.Columns.gstin.like(pattern)
                )
                .order(Bill.Columns.createdAt.desc)
                .fetchAll(db)
        }
    }
}
