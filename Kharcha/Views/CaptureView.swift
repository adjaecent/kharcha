import SwiftUI

struct CaptureView: View {
    @EnvironmentObject var db: DatabaseService
    @EnvironmentObject var sync: SyncService
    @State private var showCamera = false
    @State private var showPhotoPicker = false
    @State private var showFilePicker = false
    @State private var capturedBillId: String?
    @State private var navigateToReview = false
    @State private var showSyncErrorAlert = false

    var body: some View {
        HistoryView()
            .navigationTitle("Kharcha")
            .toolbar {
                if sync.lastError != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            showSyncErrorAlert = true
                        } label: {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundStyle(.red)
                        }
                        .accessibilityLabel("Sync error")
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Take Photo", systemImage: "camera") { showCamera = true }
                        Button("Choose Photo", systemImage: "photo.on.rectangle") { showPhotoPicker = true }
                        Button("Choose File", systemImage: "doc") { showFilePicker = true }
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
            .sheet(isPresented: $showFilePicker) {
                DocumentPicker(onCapture: handleCapture)
            }
            .navigationDestination(isPresented: $navigateToReview) {
                if let billId = capturedBillId {
                    ReviewView(billId: billId)
                }
            }
            .alert("Sync Failed", isPresented: $showSyncErrorAlert) {
                Button("Retry") {
                    Task { await sync.syncPending() }
                }
                Button("OK", role: .cancel) {}
            } message: {
                Text(sync.lastError ?? "")
            }
    }

    private static let filenameDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func handleCapture(_ image: UIImage) {
        let dateStr = Self.filenameDateFormatter.string(from: Date())
        let shortId = UUID().uuidString.prefix(8).lowercased()
        let fileName = "\(dateStr)_\(shortId).jpg"
        let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let imagesDir = docsDir.appendingPathComponent("bill_images", isDirectory: true)
        let filePath = imagesDir.appendingPathComponent(fileName)

        Task {
            // Resize + JPEG encode + write off the main thread so a large
            // capture (e.g. a stitched multi-page PDF) doesn't freeze the UI.
            // Returns the resized image so the processor reuses it without a
            // second decode, and the original `image` is never read on main.
            let resized = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                let resized = Self.resizeForStorage(image)
                guard let data = resized.jpegData(compressionQuality: 0.80) else { return nil }
                do {
                    try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
                    try data.write(to: filePath)
                } catch {
                    return nil
                }
                return resized
            }.value

            guard let resized else {
                print("Failed to save bill image")
                return
            }

            do {
                let bill = Bill(imagePath: "bill_images/\(fileName)")
                try db.insert(bill)
                capturedBillId = bill.id

                Task { await BillProcessor.process(billId: bill.id, image: resized, db: db) }

                navigateToReview = true
            } catch {
                print("Failed to save bill: \(error)")
            }
        }
    }

    /// Caps the longest edge at 2048px, except for very tall images (stitched
    /// multi-page PDFs, long thermal receipts) where capping the height would
    /// destroy text resolution — those cap width at 2048 and height at 8192.
    nonisolated private static func resizeForStorage(_ image: UIImage) -> UIImage {
        let maxDimension: CGFloat = 2048
        let maxHeight: CGFloat = 8192
        let w = image.size.width
        let h = image.size.height

        let scale: CGFloat
        if h / w > 2.5 {
            scale = min(1, maxDimension / w, maxHeight / h)
        } else {
            scale = min(1, maxDimension / max(w, h))
        }
        guard scale < 1 else { return image }

        let newSize = CGSize(width: w * scale, height: h * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
    }
}

