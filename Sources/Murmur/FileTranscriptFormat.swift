import Foundation

/// Turns a Nemotron speaker-tagged transcript into labeled turns.
enum FileTranscriptFormat {
    struct Turn: Identifiable, Equatable {
        let id: Int
        let speakerID: Int?
        let speaker: String
        let text: String
    }

    /// Official punctuated speaker prompt, extended to the model's eight-speaker limit.
    static let quickInstruction = """
    Transcribe this audio with punctuation and capitalization. Include all spoken words and verbal fillers. \
    Write numbers in their standard written form. Put speaker tags <spk:0> <spk:1> <spk:2> <spk:3> <spk:4> \
    <spk:5> <spk:6> <spk:7> on the transcription.
    """

    /// Readable wording, still tagged so names can be applied after the user hears each voice.
    static let namedInstruction = """
    Audio transcription. Language: as spoken. Wording: omit fillers and accidental repetitions; keep the \
    remaining spoken wording unchanged. Formatting: punctuation and capitalization. Start every speaker turn \
    with a speaker tag such as <spk:0>, <spk:1>, <spk:2>, <spk:3>, <spk:4>, <spk:5>, <spk:6>, <spk:7>. \
    Assign one stable tag per speaker and keep speaker identities consistent. Output: transcript only.
    """

    static func instruction(naming names: [Int: String]) -> String {
        let terms = names.values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return namedInstruction }
        return namedInstruction + " Context terms: \(terms.joined(separator: ", "))."
    }

    static func turns(transcript: String, words: [[String: Any]], names: [Int: String]?) -> [Turn] {
        let cleaned = stripThinking(transcript)
        let tagged = turnsFromTags(cleaned)
        let source = tagged.isEmpty ? turnsFromWords(words) : tagged
        guard !source.isEmpty else { return [] }

        var order: [Int] = []
        for turn in source {
            if let id = turn.speakerID, !order.contains(id) { order.append(id) }
        }
        var fallback: [Int: String] = [:]
        for (index, id) in order.enumerated() {
            fallback[id] = "Voice \(index + 1)"
        }
        return source.enumerated().map { index, turn in
            let label: String
            if let id = turn.speakerID {
                let custom = names?[id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                label = custom.isEmpty ? (fallback[id] ?? "Voice") : custom
            } else {
                label = ""
            }
            return Turn(id: index, speakerID: turn.speakerID, speaker: label, text: turn.text)
        }
    }

    static func plainText(_ turns: [Turn]) -> String {
        turns.map { turn in
            turn.speaker.isEmpty ? turn.text : "\(turn.speaker): \(turn.text)"
        }.joined(separator: "\n\n")
    }

    static func stripThinking(_ text: String) -> String {
        var result = text
        if let regex = try? NSRegularExpression(pattern: "<think>[\\s\\S]*?</think>", options: [.caseInsensitive]) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }
        for token in ["<|im_end|>", "<|im_start|>", "<|end|>"] {
            result = result.replacingOccurrences(of: token, with: "")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Parsing

    private struct RawTurn {
        let speakerID: Int?
        let text: String
    }

    private static func turnsFromTags(_ text: String) -> [RawTurn] {
        guard let regex = try? NSRegularExpression(pattern: "<spk:\\s*(\\d+)\\s*>", options: []) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: range)
        guard !matches.isEmpty else { return [] }

        var raw: [RawTurn] = []
        if let first = Range(matches[0].range, in: text), first.lowerBound > text.startIndex {
            let preface = String(text[..<first.lowerBound]).cleanedUtterance
            if !preface.isEmpty { raw.append(RawTurn(speakerID: nil, text: preface)) }
        }
        for (index, match) in matches.enumerated() {
            guard let idRange = Range(match.range(at: 1), in: text), let id = Int(text[idRange]) else { continue }
            let start = Range(match.range, in: text)?.upperBound ?? text.endIndex
            let end = index + 1 < matches.count ? (Range(matches[index + 1].range, in: text)?.lowerBound ?? text.endIndex) : text.endIndex
            let utterance = String(text[start..<end]).cleanedUtterance
            guard !utterance.isEmpty else { continue }
            if raw.last?.speakerID == id, var last = raw.popLast() {
                last = RawTurn(speakerID: id, text: last.text + " " + utterance)
                raw.append(last)
            } else {
                raw.append(RawTurn(speakerID: id, text: utterance))
            }
        }
        return raw
    }

    private static func turnsFromWords(_ words: [[String: Any]]) -> [RawTurn] {
        var raw: [RawTurn] = []
        var currentID: Int?
        var buffer: [String] = []
        func flush() {
            let text = joinWords(buffer)
            buffer.removeAll()
            guard !text.isEmpty else { return }
            if raw.last?.speakerID == currentID, var last = raw.popLast() {
                last = RawTurn(speakerID: currentID, text: last.text + " " + text)
                raw.append(last)
            } else {
                raw.append(RawTurn(speakerID: currentID, text: text))
            }
        }
        for word in words {
            let token = (word["word"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !token.isEmpty else { continue }
            let id = speakerIndex(word["speaker"])
            if buffer.isEmpty {
                currentID = id
            } else if id != currentID {
                flush()
                currentID = id
            }
            buffer.append(token)
        }
        flush()
        return raw
    }

    static func joinWords(_ words: [String]) -> String {
        var out = ""
        for word in words {
            if out.isEmpty {
                out = word
            } else if word.count == 1, ".,!?;:)]}".contains(word) || word == "…" {
                out += word
            } else if word.hasPrefix("'") || word.hasPrefix("’") {
                out += word
            } else {
                out += " " + word
            }
        }
        return out.cleanedUtterance
    }

    static func speakerIndex(_ value: Any?) -> Int? {
        switch value {
        case let number as Int:
            return number
        case let number as NSNumber:
            return number.intValue
        case let text as String:
            guard let match = text.range(of: #"\d+"#, options: .regularExpression) else { return nil }
            return Int(text[match])
        default:
            return nil
        }
    }

    /// Diarization endpoints number speakers from 1; chat timestamps number them from 0.
    static func zeroBasedSpeaker(_ raw: Int, sawZero: Bool) -> Int {
        sawZero ? raw : raw - 1
    }

    static func selfCheck() {
        let swapped = turns(transcript: "<spk:1> Hello there. <spk:0> Hi.", words: [], names: nil)
        precondition(swapped.map(\.speaker) == ["Voice 1", "Voice 2"])
        precondition(swapped.map(\.text) == ["Hello there.", "Hi."])

        let named = turns(
            transcript: "<think>draft</think> <spk:0> Um hello. <spk:1> Hey.",
            words: [],
            names: [0: "Ada", 1: " "]
        )
        precondition(named.first?.speaker == "Ada")
        precondition(named.last?.speaker == "Voice 2")
        precondition(!named.map(\.text).joined().contains("think"))

        let joined = joinWords(["Hello", ",", "there", "world"])
        precondition(joined == "Hello, there world")
        precondition(zeroBasedSpeaker(1, sawZero: false) == 0)
        precondition(zeroBasedSpeaker(0, sawZero: true) == 0)
        precondition(instruction(naming: [0: "Ada"]).contains("Context terms: Ada."))
    }
}

private extension String {
    var cleanedUtterance: String {
        var text = trimmingCharacters(in: .whitespacesAndNewlines)
        while text.contains("  ") { text = text.replacingOccurrences(of: "  ", with: " ") }
        return text
    }
}
