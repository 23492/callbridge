import Foundation

// MARK: - Data Models

struct ContactInfo: Codable, Identifiable, Hashable {
    let id: String?
    let name: String
    let type: String
    let phone: String?
    let account_name: String?
    let account_id: String?

    var displayName: String {
        if let acct = account_name, !acct.isEmpty, type != "Account" {
            return "\(name) (\(acct))"
        }
        return name
    }

    var typeLabel: String {
        switch type {
        case "Contact": return "Contact"
        case "Account": return "Account"
        case "Lead": return "Lead"
        default: return type
        }
    }
}

struct SearchResponse: Codable {
    let results: [ContactInfo]
}
