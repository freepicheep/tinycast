import Foundation
import Tinycast

/// One translation, as the screens show it.
struct Translation {
    let originalText: String
    let translatedText: String
    /// The target's romanization, or the source's pronunciation when the target needs none.
    let pronunciation: String?
    /// What Google detected when the source was auto-detect.
    let langFrom: String
    let langTo: String
}

enum TranslateError: Error, CustomStringConvertible {
    case tooManyRequests
    case status(Int)
    case unreadable

    var description: String {
        switch self {
        case .tooManyRequests: "Too many requests, please try again later"
        case .status(let code): "Google Translate answered \(code)"
        case .unreadable: "Google Translate's answer couldn't be read"
        }
    }
}

/// A loose JSON value: Google's answer is nested arrays of mixed types.
enum JSON: Decodable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSON].self))
        }
    }

    subscript(index: Int) -> JSON {
        if case .array(let items) = self, items.indices.contains(index) { return items[index] }
        return .null
    }

    var string: String? { if case .string(let value) = self { value } else { nil } }
    var array: [JSON] { if case .array(let items) = self { items } else { [] } }
}

/// Unreserved characters only, as Node's `querystring.stringify` leaves them.
private let unreserved = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")

private func encoded(_ text: String) -> String {
    text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
}

/// The endpoint Google's Chrome dictionary extension uses, as `@iamtraction/google-translate` calls it.
private func requestTranslation(_ text: String, from: String, to: String) async throws -> JSON {
    var query = [
        "client=dict-chrome-ex", "sl=" + encoded(from), "tl=" + encoded(to), "hl=" + encoded(to)
    ]
    for part in ["at", "bd", "ex", "ld", "md", "qca", "rw", "rm", "ss", "t"] { query.append("dt=" + part) }
    query += ["ie=UTF-8", "oe=UTF-8", "otf=1", "ssel=0", "tsel=0", "kc=7"]
    let base = "https://translate.google.com/translate_a/single?" + query.joined(separator: "&")
    let get = base + "&q=" + encoded(text)
    // A long text goes in a POST body, as the original does past 2048 characters.
    var request: URLRequest
    if get.count > 2048, let url = URL(string: base) {
        request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(("q=" + encoded(text)).utf8)
        request.setValue("application/x-www-form-urlencoded;charset=UTF-8", forHTTPHeaderField: "Content-Type")
    } else if let url = URL(string: get) {
        request = URLRequest(url: url)
    } else {
        throw TranslateError.unreadable
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    if response.statusCode == 429 { throw TranslateError.tooManyRequests }
    guard response.statusCode == 200 else { throw TranslateError.status(response.statusCode) }
    return try JSONDecoder().decode(JSON.self, from: data)
}

/// The translated text, the detected source and the pronunciation, from Google's raw answer.
private func translate(_ text: String, from: String, to: String) async throws -> (String, String, String?) {
    let body = try await requestTranslation(text, from: from, to: to)
    var translated = ""
    for segment in body[0].array {
        if let part = segment[0].string { translated += part }
    }
    // body[2] is the detected language; body[8][0][0] wins when they differ ("did you mean").
    let detected = body[8][0][0].string ?? body[2].string ?? from
    let romanization = body[0][1][2].string ?? body[0][1][3].string
    return (translated, detected, romanization)
}

private func isSameLanguage(_ first: String, _ second: String) -> Bool {
    if first.isEmpty || second.isEmpty { return false }
    let a = first.lowercased()
    let b = second.lowercased()
    if a == b { return true }
    return a.split(separator: "-").first == b.split(separator: "-").first
}

/// One translation into the set's first target, or its second when the text is already in the first.
func simpleTranslate(_ text: String, _ set: LanguageSet) async throws -> Translation {
    let first = set.to.first ?? "en"
    guard !text.isEmpty else {
        return Translation(originalText: text, translatedText: "", pronunciation: nil, langFrom: set.from, langTo: first)
    }
    var target = first
    if set.from != autoDetect, isSameLanguage(set.from, target), set.to.count > 1 { target = set.to[1] }
    var (translated, detected, pronunciation) = try await translate(text, from: set.from, to: target)
    if set.from == autoDetect, isSameLanguage(detected, target), set.to.count > 1 {
        target = set.to[1]
        (translated, detected, pronunciation) = try await translate(text, from: detected, to: target)
    }
    return Translation(
        originalText: text, translatedText: translated, pronunciation: pronunciation, langFrom: detected,
        langTo: target)
}

/// One translation per target, in the set's order; same-language results last when asked.
func multiTranslate(_ text: String, _ set: LanguageSet, prioritizeCrossLanguage: Bool) async throws -> [Translation] {
    guard !text.isEmpty else { return [] }
    var results: [Translation] = []
    for target in set.to {
        results.append(try await simpleTranslate(text, LanguageSet(from: set.from, to: [target])))
    }
    guard prioritizeCrossLanguage else { return results }
    let cross = results.filter { !isSameLanguage($0.langFrom, $0.langTo) }
    let same = results.filter { isSameLanguage($0.langFrom, $0.langTo) }
    return cross + same
}

/// The text there and back: into the target, and the translation into the source again.
func doubleWayTranslate(_ text: String, _ set: LanguageSet) async throws -> [Translation] {
    guard !text.isEmpty else { return [] }
    if set.from == autoDetect {
        let there = try await simpleTranslate(text, set)
        let back = try await simpleTranslate(there.translatedText, LanguageSet(from: there.langTo, to: [there.langFrom]))
        return [there, back]
    }
    var target = set.to.first ?? "en"
    if isSameLanguage(set.from, target), set.to.count > 1 { target = set.to[1] }
    let there = try await simpleTranslate(text, LanguageSet(from: set.from, to: [target]))
    let back = try await simpleTranslate(text, LanguageSet(from: target, to: [set.from]))
    return [there, back]
}

/// The page on translate.google.com for this text and pair.
func googleTranslateURL(_ text: String, from: String, to: String) -> String {
    "https://translate.google.com/?sl=" + from + "&tl=" + to + "&text=" + encoded(text) + "&op=translate"
}
