import UIKit

/// Runs the two-phase pipeline (Vision OCR → Foundation Models extraction)
/// for a bill, and tracks in-flight work so a pipeline interrupted by an app
/// kill can be detected and resumed from the image on disk.
@MainActor
enum BillProcessor {
    private static var inFlight: Set<String> = []

    static func process(billId: String, image: UIImage, db: DatabaseService) async {
        guard !inFlight.contains(billId) else { return }
        inFlight.insert(billId)
        defer { inFlight.remove(billId) }

        guard var bill = try? db.fetch(id: billId) else { return }

        // Phase 1: OCR (already done if resuming a bill killed mid-extraction)
        if bill.rawText == nil {
            let ocr = OCRService()
            if let rawText = try? await ocr.recognizeText(from: image) {
                bill.rawText = rawText
                try? db.update(bill)
            }
        }

        // Phase 2: Field extraction (if Apple Intelligence available)
        if ExtractionService.isAvailable, let rawText = bill.rawText {
            let extractor = ExtractionService()
            if let fields = await extractor.extract(from: rawText) {
                bill.vendor = fields.vendor
                bill.date = fields.date
                bill.amount = fields.amount
                bill.currency = fields.currency ?? "INR"
                bill.gstAmount = fields.gstAmount
                bill.gstin = fields.gstin
                bill.billNo = fields.billNo
                bill.category = fields.category
            }
        }

        bill.extractionDone = true
        try? db.update(bill)
    }

    /// Restarts processing for a draft whose pipeline never finished (app was
    /// killed mid-OCR or mid-extraction). No-op if the pipeline is running.
    static func resumeIfNeeded(bill: Bill, db: DatabaseService) {
        guard !bill.extractionDone,
              !inFlight.contains(bill.id),
              let image = UIImage(contentsOfFile: bill.absoluteImagePath) else { return }
        Task { await process(billId: bill.id, image: image, db: db) }
    }

    /// Sweeps all stranded bills at launch so recovery doesn't depend on the
    /// user happening to reopen the affected bill.
    static func resumeAllPending(db: DatabaseService) {
        guard let stranded = try? db.fetchUnprocessed() else { return }
        for bill in stranded {
            resumeIfNeeded(bill: bill, db: db)
        }
    }
}
