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

        migrator.registerMigration("v2") { db in
            try db.alter(table: "bills") { t in
                t.add(column: "extractionDone", .boolean).notNull().defaults(to: false)
            }
        }

        migrator.registerMigration("v3") { db in
            try db.alter(table: "bills") { t in
                t.add(column: "category", .text)
            }
        }

        migrator.registerMigration("v4") { db in
            try db.alter(table: "bills") { t in
                t.add(column: "sheetAppended", .boolean).notNull().defaults(to: false)
            }
            // Uploaded bills have already been appended to the sheet
            try db.execute(sql: "UPDATE bills SET sheetAppended = 1 WHERE status = 'uploaded'")
            // Convert absolute image paths to Documents-relative so they
            // survive container path changes
            try db.execute(sql: """
                UPDATE bills SET imagePath = substr(imagePath, instr(imagePath, '/Documents/') + 11)
                WHERE instr(imagePath, '/Documents/') > 0
                """)
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

    /// Bills whose OCR/extraction pipeline never finished (e.g. the app was
    /// killed mid-processing).
    func fetchUnprocessed() throws -> [Bill] {
        try dbQueue.read { db in
            try Bill.filter(Bill.Columns.extractionDone == false).fetchAll(db)
        }
    }

    /// Async sequence that emits the matching bills whenever the table
    /// changes — keeps the list live as OCR/extraction/sync update rows.
    func observeBills(matching query: String = "") -> AsyncValueObservation<[Bill]> {
        ValueObservation
            .tracking { db in try Self.billsRequest(matching: query).fetchAll(db) }
            .values(in: dbQueue)
    }

    /// Async sequence that emits one bill's row whenever it changes.
    func observeBill(id: String) -> AsyncValueObservation<Bill?> {
        ValueObservation
            .tracking { db in try Bill.fetchOne(db, key: id) }
            .values(in: dbQueue)
    }

    private nonisolated static func billsRequest(matching query: String) -> QueryInterfaceRequest<Bill> {
        var request = Bill.order(Bill.Columns.createdAt.desc)
        if !query.isEmpty {
            let pattern = "%\(query)%"
            request = request.filter(
                Bill.Columns.vendor.like(pattern) ||
                Bill.Columns.rawText.like(pattern) ||
                Bill.Columns.billNo.like(pattern) ||
                Bill.Columns.gstin.like(pattern)
            )
        }
        return request
    }
}
