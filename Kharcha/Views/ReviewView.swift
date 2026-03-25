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
    @State private var ocrInProgress = true

    private let currencies = Currency.allCases

    private var isLocked: Bool {
        ocrInProgress || bill?.status == .uploaded
    }

    var body: some View {
        Form {
            if let bill {
                if let image = UIImage(contentsOfFile: bill.imagePath) {
                    Section {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxHeight: 250)
                            .frame(maxWidth: .infinity)
                    }
                }

                if ocrInProgress {
                    Section {
                        HStack {
                            ProgressView()
                            Text("Reading bill...")
                                .foregroundStyle(.secondary)
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

                Section("Tax") {
                    TextField("GST Amount", text: $gstAmount)
                        .keyboardType(.decimalPad)
                        .disabled(isLocked)
                    TextField("GSTIN", text: $gstin)
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
                    .disabled(ocrInProgress)
                }
            }
        }
        .navigationTitle("Review Bill")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: billId) { @MainActor in await loadBill() }
    }

    private func loadBill() async {
        guard let fetched = try? db.fetch(id: billId) else { return }

        bill = fetched
        populateFields(from: fetched)

        // If OCR already done, no need to wait
        if fetched.rawText != nil {
            ocrInProgress = false
            return
        }

        // Poll until OCR completes
        for _ in 0..<30 {
            try? await Task.sleep(for: .milliseconds(500))
            if let fresh = try? db.fetch(id: billId), fresh.rawText != nil {
                bill = fresh
                ocrInProgress = false
                return
            }
        }
        ocrInProgress = false
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
    }

    private func saveBill() {
        guard let bill else { return }

        // Re-check DB — might have been uploaded in the background
        if let fresh = try? db.fetch(id: bill.id), fresh.status == .uploaded {
            self.bill = fresh
            return
        }

        var updated = bill
        updated.vendor = vendor.isEmpty ? nil : vendor
        updated.date = Self.dateFormatter.string(from: date)
        updated.amount = Double(amount)
        updated.currency = currency
        updated.gstAmount = Double(gstAmount)
        updated.gstin = gstin.isEmpty ? nil : gstin
        updated.billNo = billNo.isEmpty ? nil : billNo
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
