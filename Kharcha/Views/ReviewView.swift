import SwiftUI

struct ReviewView: View {
    let billId: String

    @EnvironmentObject var db: DatabaseService
    @EnvironmentObject var sync: SyncService
    @Environment(\.dismiss) private var dismiss

    @State private var bill: Bill?
    @State private var vendor = ""
    @State private var date = Date()
    @State private var amount = ""
    @State private var currency = "INR"
    @State private var gstAmount = ""
    @State private var gstin = ""
    @State private var billNo = ""
    @State private var category = "Miscellaneous"
    @State private var timedOut = false

    enum ProcessingPhase {
        case ocr
        case extracting
        case done
    }

    /// Derived from the observed bill row, so it can't drift out of sync.
    private var processingPhase: ProcessingPhase {
        guard let bill else { return .ocr }
        if bill.extractionDone || timedOut { return .done }
        return bill.rawText != nil ? .extracting : .ocr
    }

    private let currencies = Currency.allCases

    static let categories = [
        "Purchases (Goods)",
        "Direct Expenses",
        "Rent & Utilities",
        "Software & SaaS",
        "Professional Fees",
        "Marketing & Ads",
        "Travel",
        "Meals",
        "Bank Charges",
        "Capital Assets",
        "Taxes",

        "Miscellaneous",
    ]

    private var isLocked: Bool {
        processingPhase != .done || bill?.status == .uploaded
    }

    var body: some View {
        Form {
            if let bill {
                if let image = UIImage(contentsOfFile: bill.absoluteImagePath) {
                    Section {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxHeight: 250)
                            .frame(maxWidth: .infinity)
                    }
                }

                if processingPhase != .done {
                    Section {
                        HStack {
                            ProgressView()
                            switch processingPhase {
                            case .ocr:
                                Text("Reading bill...")
                                    .foregroundStyle(.secondary)
                            case .extracting:
                                Text("Extracting details...")
                                    .foregroundStyle(.secondary)
                            case .done:
                                EmptyView()
                            }
                        }
                    }
                }

                Section("Vendor") {
                    TextField("Vendor name", text: $vendor)
                        .disabled(isLocked)
                }

                Section("Amount") {
                    HStack {
                        TextField("0.00", text: $amount)
                            .keyboardType(.decimalPad)
                        Picker("Currency", selection: $currency) {
                            ForEach(currencies, id: \.self) { c in
                                Text("\(c.symbol) \(c.code)").tag(c.code)
                            }
                        }
                        .labelsHidden()
                    }
                    .disabled(isLocked)
                }

                Section("Date") {
                    DatePicker("Bill Date", selection: $date, displayedComponents: .date)
                        .datePickerStyle(.compact)
                        .disabled(isLocked)
                }

                Section("Category") {
                    Picker("Category", selection: $category) {
                        ForEach(Self.categories, id: \.self) { cat in
                            Text(cat).tag(cat)
                        }
                    }
                    .disabled(isLocked)
                }

                Section("Tax") {
                    TextField("Tax Amount", text: $gstAmount)
                        .keyboardType(.decimalPad)
                        .disabled(isLocked)
                    TextField("Tax ID", text: $gstin)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .disabled(isLocked)
                }

                Section("Reference") {
                    TextField("Bill / Invoice No", text: $billNo)
                        .autocorrectionDisabled()
                        .disabled(isLocked)
                }
            } else {
                ProgressView("Loading...")
            }
        }
        .toolbar {
            if let bill, bill.status != .uploaded {
                ToolbarItem(placement: .confirmationAction) {
                    Button(bill.status == .draft ? "Save" : "Update") {
                        saveBill()
                    }
                    .disabled(isLocked)
                }
            }
        }
        .navigationTitle("Review Bill")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: billId) { await loadBill() }
        .task {
            // Unlock the form for manual entry if extraction never finishes
            try? await Task.sleep(for: .seconds(30))
            timedOut = true
        }
    }

    private func loadBill() async {
        guard let fetched = try? db.fetch(id: billId) else { return }

        bill = fetched
        populateFields(from: fetched)
        guard !fetched.extractionDone else { return }

        // Follow the pipeline's progress; phase indicators derive from the row
        do {
            for try await fresh in db.observeBill(id: billId) {
                guard let fresh else { return }
                bill = fresh
                if fresh.extractionDone {
                    // Don't clobber edits the user made after a timeout unlock
                    if !timedOut {
                        populateFields(from: fresh)
                    }
                    return
                }
            }
        } catch {
            print("Failed to observe bill: \(error)")
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd/MM/yyyy"
        return f
    }()

    private func populateFields(from bill: Bill) {
        vendor = bill.vendor ?? ""
        date = bill.date.flatMap { Self.dateFormatter.date(from: $0) } ?? bill.createdAt
        amount = bill.amount.map { String(format: "%.2f", $0) } ?? ""
        currency = bill.currency
        gstAmount = bill.gstAmount.map { String(format: "%.2f", $0) } ?? ""
        gstin = bill.gstin ?? ""
        billNo = bill.billNo ?? ""
        category = bill.category ?? "Miscellaneous"
    }

    /// The decimal pad inserts the locale's separator (e.g. "," in many
    /// locales), which `Double(_:)` rejects — fall back to locale parsing.
    private static func parseAmount(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let value = Double(trimmed) { return value }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.number(from: trimmed)?.doubleValue
    }

    private func saveBill() {
        guard let bill else { return }

        if let fresh = try? db.fetch(id: bill.id), fresh.status == .uploaded {
            self.bill = fresh
            return
        }

        var updated = bill
        updated.vendor = vendor.isEmpty ? nil : vendor
        updated.date = Self.dateFormatter.string(from: date)
        updated.amount = Self.parseAmount(amount)
        updated.currency = currency
        updated.gstAmount = Self.parseAmount(gstAmount)
        updated.gstin = gstin.isEmpty ? nil : gstin
        updated.billNo = billNo.isEmpty ? nil : billNo
        updated.category = category
        updated.status = .saved

        do {
            try db.update(updated)
            Task { await sync.syncPending() }
            dismiss()
        } catch {
            print("Failed to save bill: \(error)")
        }
    }
}
