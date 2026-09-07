import Foundation
import Combine

final class CommandStore: ObservableObject {
    @Published private(set) var commands: [ReplyCommand] = []

    private let defaults = UserDefaults.standard
    private let storageKey = "Replyzen.CustomCommands.v1"

    init() {
        load()
    }

    func command(id: UUID?) -> ReplyCommand? {
        guard let id else { return nil }
        return commands.first(where: { $0.id == id })
    }

    @discardableResult
    func addCommand() -> ReplyCommand {
        let command = ReplyCommand(
            name: "New Command",
            prompt: "Write a short, clear reply based on the email thread.",
            tone: .professional
        )
        commands.append(command)
        save()
        return command
    }

    func update(_ command: ReplyCommand) {
        guard let index = commands.firstIndex(where: { $0.id == command.id }) else { return }
        commands[index] = command
        save()
    }

    func delete(id: UUID) {
        commands.removeAll(where: { $0.id == id })
        if commands.isEmpty {
            commands = Self.defaultCommands
        }
        save()
    }

    func resetToDefaults() {
        commands = Self.defaultCommands
        save()
    }

    private func load() {
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([ReplyCommand].self, from: data),
           !decoded.isEmpty {
            commands = decoded
        } else {
            commands = Self.defaultCommands
            save()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(commands) else { return }
        defaults.set(data, forKey: storageKey)
    }

    static let defaultCommands: [ReplyCommand] = [
        ReplyCommand(
            name: "Reminder",
            prompt: "Write a short follow-up that politely reminds the recipient about the open topic.",
            tone: .friendly
        ),
        ReplyCommand(
            name: "Danke",
            prompt: "Thank the recipient briefly and confirm the message. Keep it concise.",
            tone: .friendly
        ),
        ReplyCommand(
            name: "Kurz & direkt",
            prompt: "Reply very briefly and directly. Include only what is necessary.",
            tone: .direct
        )
    ]
}
