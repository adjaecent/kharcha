import Foundation
import FoundationModels

@Generable
struct ExtractedBillFields: Sendable {
    @Guide(description: "The vendor or store name")
    var vendor: String?

    @Guide(description: "The bill date in DD/MM/YYYY format. Convert 2-digit years to 4-digit (26 -> 2026)")
    var date: String?

    @Guide(description: "The Grand Total or final payable amount. This is the largest total on the bill, after tax. Do not use subtotals or item prices.")
    var amount: Double?

    @Guide(description: "Three-letter currency code", .anyOf(["INR", "USD", "EUR", "GBP", "ZAR", "KRW", "JPY", "CAD", "ISK"]))
    var currency: String?

    @Guide(description: "Total tax amount. Sum of CGST + SGST, or IGST. Look for lines labeled CGST/SGST/IGST with small amounts. Do not use item prices or subtotals.")
    var gstAmount: Double?

    @Guide(description: "The 15-character GSTIN number (format: 2 digits + 5 letters + 4 digits + 1 letter + 1 alphanumeric + 1 alphanumeric). This is NOT the FSSAI number.")
    var gstin: String?

    @Guide(description: "The bill number or invoice number")
    var billNo: String?

    @Guide(description: "Expense category based on what was purchased. Meals/restaurants/cafes/food = 'Meals'. Software/subscriptions = 'Software & SaaS'. Office supplies/goods = 'Purchases (Goods)'. Travel/flights/hotels = 'Travel'. Consulting/legal = 'Professional Fees'. Ads/marketing = 'Marketing & Ads'.",
           .anyOf([
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

               "Miscellaneous"
           ]))
    var category: String?
}

final class ExtractionService {
    static var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    func extract(from ocrText: String) async -> ExtractedBillFields? {
        guard Self.isAvailable else { return nil }

        let prompt = """
        Extract bill details from the following receipt text. \
        The amount should be the Grand Total (final amount paid). \
        GSTIN is a 15-character tax ID starting with 2 digits — do not confuse with FSSAI license numbers. \
        If a field cannot be confidently determined, leave it null.

        \(String(ocrText.prefix(2000)))
        """

        do {
            let session = LanguageModelSession()
            let response = try await session.respond(
                to: prompt,
                generating: ExtractedBillFields.self
            )
            return response.content
        } catch {
            print("Extraction failed: \(error)")
            return nil
        }
    }
}
