import Foundation

enum ReplyTone: String, Codable, CaseIterable, Identifiable, Equatable, Hashable {
    case friendly
    case direct
    case professional
    case formal
    case casual
    case neutral

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .friendly: return L10n.tr("Friendly")
        case .direct: return L10n.tr("Direct")
        case .professional: return L10n.tr("Professional")
        case .formal: return L10n.tr("Formal")
        case .casual: return L10n.tr("Casual")
        case .neutral: return L10n.tr("Neutral")
        }
    }

    var apiInstruction: String {
        switch self {
        case .friendly:
            return "Use a warm, friendly, helpful tone without sounding overly enthusiastic."
        case .direct:
            return "Use a direct, concise tone. Be clear and avoid unnecessary filler."
        case .professional:
            return "Use a polished, professional business tone that still sounds natural."
        case .formal:
            return "Use a formal, respectful business tone."
        case .casual:
            return "Use a relaxed, conversational tone while remaining appropriate for email."
        case .neutral:
            return "Use a neutral, matter-of-fact tone."
        }
    }
}

struct ReplyCommand: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var prompt: String
    var tone: ReplyTone

    init(id: UUID = UUID(), name: String, prompt: String, tone: ReplyTone) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.tone = tone
    }
}
