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
        case .friendly: return "Friendly"
        case .direct: return "Direct"
        case .professional: return "Professional"
        case .formal: return "Formal"
        case .casual: return "Casual"
        case .neutral: return "Neutral"
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
