import SwiftUI

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
        .onChange(of: searchText) { _, query in
            loadBills(query: query)
        }
        .onAppear {
            loadBills()
        }
        .refreshable {
            loadBills(query: searchText)
        }
    }

    private func deleteBills(at offsets: IndexSet) {
        for index in offsets {
            let bill = bills[index]
            try? FileManager.default.removeItem(atPath: bill.imagePath)
            try? db.delete(id: bill.id)
        }
        bills.remove(atOffsets: offsets)
    }

    private func loadBills(query: String = "") {
        do {
            if query.isEmpty {
                bills = try db.fetchAll()
            } else {
                bills = try db.search(query: query)
            }
        } catch {
            print("Failed to load bills: \(error)")
        }
    }
}

struct BillRow: View {
    let bill: Bill

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd/MM/yyyy"
        return f
    }()

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let image = UIImage(contentsOfFile: bill.imagePath) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Image(systemName: "doc.text.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .frame(width: 40, height: 40)
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
            }

            Spacer()

            StatusIndicator(status: bill.status)
        }
    }
}

struct StatusIndicator: View {
    let status: BillStatus

    var body: some View {
        switch status {
        case .draft:
            Image(systemName: "pencil.circle.fill")
                .foregroundStyle(.orange)
        case .saved:
            Image(systemName: "arrow.up.circle.fill")
                .foregroundStyle(.blue)
        case .uploaded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }
}
