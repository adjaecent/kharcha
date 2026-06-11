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

    @Guide(description: "Total tax amount. On Indian bills: sum of CGST + SGST, or IGST. On other bills: the VAT, sales tax, or service tax amount. Look for lines labeled CGST/SGST/IGST/VAT/Tax with amounts smaller than the total. Do not use item prices or subtotals.")
    var gstAmount: Double?

    @Guide(description: "The seller's tax registration number. On Indian bills this is the 15-character GSTIN (format: 2 digits + 5 letters + 4 digits + 1 letter + 1 alphanumeric + the letter Z + 1 alphanumeric); it is NOT the FSSAI number. On other bills, use the VAT or tax registration number.")
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
        The tax amount is labeled CGST/SGST/IGST on Indian bills, or VAT/sales tax elsewhere. \
        The tax registration number on Indian bills is the 15-character GSTIN starting with 2 digits — do not confuse with FSSAI license numbers; \
        elsewhere it is the VAT or tax registration number. \
        If a field cannot be confidently determined, leave it null.

        \(String(ocrText.prefix(4000)))
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
