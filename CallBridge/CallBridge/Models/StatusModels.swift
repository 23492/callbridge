import Foundation

// MARK: - Status Models

struct ProcessingJob: Codable {
    let job_id: String
    let contact_name: String
    let step: String

    var stepLabel: String {
        switch step {
        case "starting": return "Starten..."
        case "transcribing": return "Transcriberen..."
        case "summarizing": return "Samenvatten..."
        case "extracting_actions": return "Acties extraheren..."
        case "saving_to_salesforce": return "Opslaan in Salesforce..."
        default: return step
        }
    }
}

struct FutureTask: Codable {
    let task_id: String
    let subject: String
    let activity_date: String

    var taskURL: URL? {
        URL(string: "https://welisa.lightning.force.com/lightning/r/Task/\(task_id)/view")
    }

    var subjectShort: String {
        subject.count > 20 ? String(subject.prefix(20)) + "…" : subject
    }

    var dateFormatted: String {
        let fmtIn = DateFormatter()
        fmtIn.dateFormat = "yyyy-MM-dd"
        let fmtOut = DateFormatter()
        fmtOut.dateFormat = "dd-MM-yy"
        if let date = fmtIn.date(from: activity_date) {
            return fmtOut.string(from: date)
        }
        return activity_date
    }
}

struct CompletedJob: Codable {
    let contact_name: String
    // Optional: a null here (Account-only call logs) used to fail decoding of the
    // whole /status payload, so the menu claimed the server was unreachable.
    let contact_id: String?
    let contact_type: String
    let task_id: String
    let future_tasks: [FutureTask]?

    var contactURL: URL? {
        guard let id = contact_id, !id.isEmpty else { return nil }
        return URL(string: "https://welisa.lightning.force.com/lightning/r/\(contact_type)/\(id)/view")
    }
    var taskURL: URL? {
        URL(string: "https://welisa.lightning.force.com/lightning/r/Task/\(task_id)/view")
    }
}

struct StatusResponse: Codable {
    let processing: [ProcessingJob]
    let completed: [CompletedJob]
}
