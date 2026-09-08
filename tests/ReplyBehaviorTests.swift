import Foundation
import NaturalLanguage

enum AppState {
    enum ReplyLanguage: Equatable {
        case german
        case usEnglish
        case spanish
    }
}

@main
struct ReplyBehaviorTests {
    static func main() {
        checkLanguageDetection()
        checkReplyControlMatching()
        print("PASS: newest-message language detection and Reply/Reply All control matching")
    }

    private static func checkLanguageDetection() {
        precondition(MailLanguageDetector.detect(in: "Hallo Peter, vielen Dank für deine Nachricht. Der vorgeschlagene Termin passt mir sehr gut.") == .german)
        precondition(MailLanguageDetector.detect(in: "Hi Peter, thanks for your message. The proposed time works well for me and I look forward to speaking.") == .usEnglish)
        precondition(MailLanguageDetector.detect(in: "Hola Pedro, muchas gracias por tu mensaje. La hora propuesta me viene muy bien y nos vemos pronto.") == .spanish)

        let mixedEnglish = """
        Thanks for the update. Friday morning works well for me.

        From: Hans Beispiel <hans@example.com>
        Sent: Monday, September 7
        To: Lennard <lennard@example.com>
        Hallo Lennard, der vorgeschlagene Termin am Donnerstag passt gut.
        """
        precondition(MailLanguageDetector.detect(in: mixedEnglish) == .usEnglish)

        let mixedSpanish = """
        Gracias por la información. El martes por la mañana me viene perfecto.

        El lunes, John Smith escribió:
        Thanks for the update. Tuesday morning would work for me.
        """
        precondition(MailLanguageDetector.detect(in: mixedSpanish) == .spanish)

        precondition(MailLanguageDetector.detect(in: "Bonjour, merci pour votre message. Je suis disponible demain matin pour en discuter.") == nil)
    }

    private static func checkReplyControlMatching() {
        precondition(OutlookReplyControlMatcher.score(metadata: "Reply", replyAll: false) > 0)
        precondition(OutlookReplyControlMatcher.score(metadata: "Reply All", replyAll: false) == 0)
        precondition(OutlookReplyControlMatcher.score(metadata: "Reply All", replyAll: true) > 0)
        precondition(OutlookReplyControlMatcher.score(metadata: "Allen antworten", replyAll: true) > 0)
        precondition(OutlookReplyControlMatcher.score(metadata: "Responder a todos", replyAll: true) > 0)
        precondition(OutlookReplyControlMatcher.score(metadata: "Responder", replyAll: false) > 0)
        precondition(OutlookReplyControlMatcher.score(metadata: "Forward", replyAll: false) == 0)
    }
}
