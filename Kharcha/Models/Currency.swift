import Foundation

enum Currency: String, CaseIterable, Sendable {
    case inr
    case usd
    case eur
    case gbp
    case zar
    case krw
    case jpy
    case cad
    case isk

    var code: String {
        rawValue.uppercased()
    }

    var symbol: String {
        switch self {
        case .inr: return "₹"
        case .usd: return "$"
        case .eur: return "€"
        case .gbp: return "£"
        case .zar: return "R"
        case .krw: return "₩"
        case .jpy: return "¥"
        case .cad: return "C$"
        case .isk: return "kr"
        }
    }
}
