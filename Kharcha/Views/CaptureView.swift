import SwiftUI

struct CaptureView: View {
    @EnvironmentObject var db: DatabaseService
    @EnvironmentObject var sync: SyncService
    @State private var showCamera = false
    @State private var showPhotoPicker = false
    @State private var capturedBillId: String?
    @State private var navigateToReview = false

    var body: some View {
        HistoryView()
            .safeAreaInset(edge: .bottom) {
                if let error = sync.lastError {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text("Sync failed: \(error)")
                            .lineLimit(2)
                        Spacer()
                        Button("Retry") {
                            Task { await sync.syncPending() }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .font(.caption)
                    .padding(12)
                    .background(.red.opacity(0.1))
                    .foregroundStyle(.red)
                }
            }
            .navigationTitle("Kharcha")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Take Photo", systemImage: "camera") { showCamera = true }
                        Button("Choose from Library", systemImage: "photo.on.rectangle") { showPhotoPicker = true }
                    } label: {
                        Image(systemName: "plus")
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker(onCapture: handleCapture)
                    .ignoresSafeArea()
            }
            .sheet(isPresented: $showPhotoPicker) {
                PhotoLibraryPicker(onCapture: handleCapture)
            }
            .navigationDestination(isPresented: $navigateToReview) {
                if let billId = capturedBillId {
                    ReviewView(billId: billId)
                }
            }
    }

    private static let filenameDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func handleCapture(_ image: UIImage) {
        let maxDimension: CGFloat = 2048
        let resized: UIImage
        if max(image.size.width, image.size.height) > maxDimension {
            let scale = maxDimension / max(image.size.width, image.size.height)
            let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let renderer = UIGraphicsImageRenderer(size: newSize)
            resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
        } else {
            resized = image
        }
        guard let data = resized.jpegData(compressionQuality: 0.80) else { return }

        let dateStr = Self.filenameDateFormatter.string(from: Date())
        let shortId = UUID().uuidString.prefix(8).lowercased()
        let fileName = "\(dateStr)_\(shortId).jpg"
        let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let imagesDir = docsDir.appendingPathComponent("bill_images", isDirectory: true)
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        let filePath = imagesDir.appendingPathComponent(fileName)

        do {
            try data.write(to: filePath)
            let bill = Bill(imagePath: filePath.path)
            try db.insert(bill)
            capturedBillId = bill.id

            Task {
                var updated = bill

                // Phase 1: OCR
                let ocr = OCRService()
                if let rawText = try? await ocr.recognizeText(from: image) {
                    updated.rawText = rawText
                    try? db.update(updated)
                }

                // Phase 2: Field extraction (if Apple Intelligence available)
                if ExtractionService.isAvailable, let rawText = updated.rawText {
                    let extractor = ExtractionService()
                    if let fields = await extractor.extract(from: rawText) {
                        updated.vendor = fields.vendor
                        updated.date = fields.date
                        updated.amount = fields.amount
                        updated.currency = fields.currency ?? "INR"
                        updated.gstAmount = fields.gstAmount
                        updated.gstin = fields.gstin
                        updated.billNo = fields.billNo
                        updated.category = fields.category
                    }
                }

                updated.extractionDone = true
                try? db.update(updated)
            }

            navigateToReview = true
        } catch {
            print("Failed to save bill: \(error)")
        }
    }
}

