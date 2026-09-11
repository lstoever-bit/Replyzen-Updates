import Foundation

/// Raw data used to build the model prompt for email writing.
/// userText is kept verbatim; mailThread is context only.
struct ChatGPTTransferPayload: Equatable {
    let mailThread: String?
    let userText: String
    let tone: String
    let language: String
    let compact: Bool
}
