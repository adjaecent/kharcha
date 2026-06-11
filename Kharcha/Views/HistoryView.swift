import SwiftUI
import ImageIO

struct HistoryView: View {
    @EnvironmentObject var db: DatabaseService
    @State private var bills: [Bill] = []
    @State private var searchText = ""

    var body: some View {
        List {
            Section("\(bills.count) bill\(bills.count == 1 ? "" : "s")") {
                ForEach(bills) { bill in
                    NavigationLink(destination: ReviewView(billId: bill.id)) {
                        BillRow(bill: bill)
                    }
                }
                .onDelete(perform: deleteBills)
            }
            .listSectionSeparator(.hidden, edges: .top)
        }
        .listStyle(.plain)
        .overlay {
            if bills.isEmpty && searchText.isEmpty {
                ContentUnavailableView(
                    "No Bills",
                    systemImage: "doc.text",
                    description: Text("Capture a bill to get started")
                )
            } else if bills.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
        .task(id: searchText) {
            // Live-updates the list as OCR, extraction, and sync mutate rows
            do {
                for try await fresh in db.observeBills(matching: searchText) {
                    bills = fresh
                }
            } catch {
                print("Failed to observe bills: \(error)")
            }
        }
    }

    private func deleteBills(at offsets: IndexSet) {
        for index in offsets {
            let bill = bills[index]
            try? db.delete(id: bill.id)
            try? FileManager.default.removeItem(atPath: bill.absoluteImagePath)
        }
    }
}

struct BillRow: View {
    let bill: Bill
    @EnvironmentObject var auth: GoogleAuthService

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd/MM/yyyy"
        return f
    }()

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let image = Self.thumbnail(atPath: bill.absoluteImagePath) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 44, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Image(systemName: "doc.text.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 56)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(bill.vendor ?? "Untitled bill")
                    .font(.body)
                    .lineLimit(1)

                HStack(spacing: 0) {
                    if let date = bill.date {
                        Text(date)
                    } else {
                        Text(Self.dateFormatter.string(from: bill.createdAt))
                    }

                    if let amount = bill.amount {
                        Text(" · ")
                        let symbol = Currency(rawValue: bill.currency.lowercased())?.symbol ?? "₹"
                        Text("\(symbol)\(amount, specifier: "%.2f")")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)

                if let category = bill.category {
                    Text(category)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            StatusIndicator(status: bill.status, syncable: auth.isSignedIn)
        }
    }

    /// Decodes a small thumbnail instead of the full bitmap — stored images
    /// can be up to 2048×8192 (stitched PDFs), far too big to decode per row.
    private static func thumbnail(atPath path: String) -> UIImage? {
        let url = URL(fileURLWithPath: path)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 168,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}

struct StatusIndicator: View {
    let status: BillStatus
    let syncable: Bool

    var body: some View {
        switch status {
        case .draft:
            Image(systemName: "pencil.circle.fill")
                .foregroundStyle(.orange)
        case .saved:
            if syncable {
                Image(systemName: "arrow.up.circle.fill")
                    .foregroundStyle(.blue)
            } else {
                Image(systemName: "icloud.slash")
                    .foregroundStyle(.secondary)
            }
        case .uploaded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }
}
