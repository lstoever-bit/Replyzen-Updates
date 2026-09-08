import Foundation

@main
struct ResponseJSONChecks {
    static func main() throws {
        let cases: [(String, String)] = [
            ("", ""),
            (" \n\t", ""),
            ("  {\"body\":\"Hello\"}  ", "{\"body\":\"Hello\"}"),
            ("```json\n{\"body\":\"Hello\"}\n```", "{\"body\":\"Hello\"}"),
            ("```\n{}\n```", "{}"),
            ("```JSON\n{}\n```", "{}"),
            ("```json\njson\n{}\n```", "{}"),
            ("```json\n{}", "```json\n{}"),
            ("{\"body\":\"Gr\u{00FC}\u{00DF}e\"}", "{\"body\":\"Gr\u{00FC}\u{00DF}e\"}"),
            ("not JSON", "not JSON")
        ]
        for (input, expected) in cases {
            precondition(ResponseJSON.cleanedText(input) == expected)
        }
        for payload in [
            "{\"body\":\"Hello\",\"html\":null}",
            "{\"subject\":\"Test\",\"body\":\"Hello\",\"html\":null}",
            "{\"title\":\"Test\",\"description\":\"Test\",\"start\":null,\"end\":null}",
        ] {
            let value = ResponseJSON.cleanedText("```json\n" + payload + "\n```")
            _ = try JSONSerialization.jsonObject(with: Data(value.utf8))
        }
        print("PASS: 10 JSON normalization cases and 3 output schemas")
    }
}
