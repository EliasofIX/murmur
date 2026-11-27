import AppKit
import AVFoundation
import CryptoKit
import Darwin
import Foundation
import Observation

extension Notification.Name {
    static let showFileTranscript = Notification.Name("murmur.showFileTranscript")
}

/// File transcription: Parakeet writes the words, Sortformer keeps the voices.
/// Live dictation keeps its own Parakeet and never starts this engine.
@MainActor @Observable
final class FileTranscriptModel {
    static let shared = FileTranscriptModel()

    static let minimumMemory: UInt64 = 8 * 1024 * 1024 * 1024
    static let asrName = "parakeet-tdt-0.6b-v3.q8_0.gguf"
    static let diarName = "Nemotron-3-Diarization.q8_0.gguf"
    private static let runtimeVersion = "0.3.0"
    private static let port = 52847
    /// Parakeet transcribes a whole utterance, so a long file is cut into pieces of this length.
    private static let asrPiece = 20 * 60.0
    private static let asrOverlap = 2.0

    private(set) var memoryBytes: UInt64 = 0
    private(set) var installed = false
    private(set) var phase: Phase = .needsDownload
    private(set) var fileURL: URL?
    private(set) var fileDuration: Double?
    var voices: [VoiceDraft] = []
    var turns: [FileTranscriptFormat.Turn] = []
    var playingVoiceID: Int?
    private(set) var serverReady = false

    private var work: Task<Void, Never>?
    private var downloader: ChunkedDownload?
    private var server: Process?
    private var serverStopping = false
    private var serverLog = ""
    private var modelID = ""
    private var wavURL: URL?
    private var sampleDirectory: URL?
    private var scopedURL: URL?
    private var player: AVAudioPlayer?
    private let playback = Playback()
    private var names: [Int: String] = [:]
    /// One Sortformer pass over the current file. Speaker numbers stay stable for every later piece.
    private var speakerSpans: [SpeechSpan] = []

    private init() {
        memoryBytes = Self.physicalMemory()
        playback.onFinish = { [weak self] in self?.playingVoiceID = nil }
        refreshInstallState()
    }

    var memoryGigabytes: Int { Int(memoryBytes / (1024 * 1024 * 1024)) }
    var canRun: Bool { memoryBytes >= Self.minimumMemory }

    // MARK: - Phase

    enum Phase: Equatable {
        case unavailable
        case needsDownload
        case downloading(title: String, fraction: Double?, detail: String)
        case choose
        case working(title: String, detail: String)
        case naming
        case result
    }

    struct VoiceDraft: Identifiable, Equatable {
        let id: Int
        var name: String
        let sampleURL: URL
        let seconds: Double
        let placeholder: String
        let peaks: [Float]
    }

    func refreshInstallState() {
        installed = Self.ggufIsComplete(Self.asrURL) && Self.ggufIsComplete(Self.diarURL) && Self.runtimeBinary() != nil
        if !canRun {
            phase = .unavailable
        } else if installed {
            if phase == .needsDownload || phase == .unavailable { phase = .choose }
        } else if case .downloading = phase {
        } else {
            phase = .needsDownload
        }
    }

    func openRequested() {
        refreshInstallState()
        NSApp.activate()
    }

    // MARK: - Download

    func download() {
        guard canRun, work == nil else { return }
        clearNotice()
        work = Task { [weak self] in
            await self?.runDownload()
            self?.work = nil
        }
    }

    func cancel() {
        let downloading: Bool
        if case .downloading = phase { downloading = true } else { downloading = false }
        work?.cancel()
        downloader?.cancel()
        serverStopping = true
        server?.terminate()
        server = nil
        serverReady = false
        stopPlayback()
        if installed { phase = (!downloading && !voices.isEmpty) ? .naming : .choose }
        else if downloading { phase = .needsDownload }
    }

    func removeDownload() {
        cancel()
        try? FileManager.default.removeItem(at: Self.modelDirectory)
        installed = false
        phase = canRun ? .needsDownload : .unavailable
    }

    private func runDownload() async {
        do {
            let free = try Self.freeBytes(at: Self.supportRoot)
            if free < 2 * 1024 * 1024 * 1024 {
                throw Failure("This disk has \(Self.format(free)) free. The models need about 1 GB.")
            }
            try FileManager.default.createDirectory(at: Self.modelDirectory, withIntermediateDirectories: true)
            if Self.runtimeBinary() == nil {
                try await fetchRuntime()
            }
            for artifact in Self.artifacts {
                try Task.checkCancellation()
                let destination = Self.modelDirectory.appendingPathComponent(artifact.name)
                if !Self.ggufIsComplete(destination) {
                    try await fetchGGUF(artifact)
                }
            }
            installed = true
            phase = .choose
        } catch is CancellationError {
            phase = installed ? .choose : .needsDownload
        } catch {
            phase = .needsDownload
            phaseNote(error.localizedDescription)
        }
    }

    private var banner: String?
    private func phaseNote(_ text: String) { banner = text }
    var notice: String? { banner }

    func clearNotice() { banner = nil }

    private func fetchRuntime() async throws {
        let archive = Self.supportRoot.appendingPathComponent("nemo-speech-\(Self.runtimeVersion).tar.gz")
        let base = "https://github.com/NVIDIA/NeMo-Speech.cpp/releases/download/v\(Self.runtimeVersion)"
        let name = "nemo-speech-\(Self.runtimeVersion)-macos-aarch64-metal.tar.gz"
        phase = .downloading(title: "Transcription runtime", fraction: nil, detail: "Checking the download…")
        let checksumURL = URL(string: "\(base)/\(name).sha256")!
        let (checksumData, _) = try await URLSession.shared.data(from: checksumURL)
        let expected = String(decoding: checksumData, as: UTF8.self)
            .split(whereSeparator: \.isWhitespace).first.map(String.init)?.lowercased() ?? ""
        guard expected.count == 64 else { throw Failure("The runtime checksum was not published.") }
        try await download(
            from: URL(string: "\(base)/\(name)")!,
            to: archive,
            title: "Transcription runtime",
            about: "a few megabytes"
        )
        let digest = try Self.sha256File(archive)
        guard digest == expected else {
            try? FileManager.default.removeItem(at: archive)
            throw Failure("The runtime download didn't match its checksum.")
        }
        try Self.installRuntime(archive: archive)
        try? FileManager.default.removeItem(at: archive)
    }

    private func fetchGGUF(_ artifact: Artifact) async throws {
        let destination = Self.modelDirectory.appendingPathComponent(artifact.name)
        let partial = destination.appendingPathExtension("partial")
        guard let url = URL(string: artifact.url) else { throw Failure("The model address is missing.") }
        try await download(from: url, to: partial, title: artifact.title, about: artifact.about)
        let digest = try Self.sha256File(partial)
        guard digest == artifact.sha256, Self.hasGGUFMagic(partial) else {
            try? FileManager.default.removeItem(at: partial)
            throw Failure("\(artifact.title) didn't finish as a model file. Try the download again.")
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: partial, to: destination)
    }

    private func download(from url: URL, to destination: URL, title: String, about: String) async throws {
        if !FileManager.default.fileExists(atPath: destination.path) {
            FileManager.default.createFile(atPath: destination.path, contents: nil)
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Murmur/1.0", forHTTPHeaderField: "User-Agent")
        let existing = Self.fileSize(destination)
        if existing > 0 {
            request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range")
        }
        let loader = ChunkedDownload(destination: destination) { [weak self] received, total in
            Task { @MainActor in
                let detail: String
                if let total {
                    detail = "\(Self.format(received)) of \(Self.format(total))"
                } else {
                    detail = "\(Self.format(received)) · \(about)"
                }
                let fraction = total.map { total in total > 0 ? Double(received) / Double(total) : nil } ?? nil
                self?.phase = .downloading(title: title, fraction: fraction, detail: detail)
            }
        }
        downloader = loader
        defer { downloader = nil }
        do {
            try await loader.start(request)
        } catch {
            if error is CancellationError { throw error }
            throw Failure(error.localizedDescription)
        }
        try Task.checkCancellation()
    }

    // MARK: - File selection

    func useFile(_ url: URL) {
        clearNotice()
        stopPlayback()
        endAccess()
        _ = url.startAccessingSecurityScopedResource()
        scopedURL = url
        fileURL = url
        fileDuration = nil
        voices = []
        turns = []
        speakerSpans = []
        if installed { phase = .choose }
        Task { await probe(url) }
    }

    private func probe(_ url: URL) async {
        let info = await WavExtract.inspect(url)
        guard url == fileURL else { return }
        if !info.hasAudio {
            banner = info.unreadable
                ? (WavExtract.canDecodeForeign
                    ? "Couldn't open that file."
                    : "This Mac can't open that recording. Install ffmpeg, or export the audio as WAV or M4A.")
                : "That file has no audio track Murmur can read."
            fileDuration = nil
            return
        }
        fileDuration = info.duration
    }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "Transcribe a file"
        panel.message = "Choose an audio or video file."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        var types: [UTType] = [.audio, .movie, .video, .mpeg4Movie, .quickTimeMovie]
        for ext in ["mkv", "webm", "avi", "flac", "ogg", "opus"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        panel.allowedContentTypes = types
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        useFile(url)
    }

    // MARK: - Transcription

    func transcribeQuick() {
        names = [:]
        startJob(title: "Transcribing") { model in
            let wav = try await model.prepareWav()
            try await model.ensureServer()
            try await model.transcribeAligned(wav: wav, names: nil)
            model.phase = .result
        }
    }

    func findVoices() {
        startJob(title: "Finding the voices") { model in
            let wav = try await model.prepareWav()
            try await model.ensureServer()
            model.phase = .working(title: "Finding the voices", detail: "Listening for who is speaking. The transcript comes after you name them.")
            let segments = try await model.diarizeAll(wav)
            model.speakerSpans = segments
            let drafts = try model.makeDrafts(from: segments, wav: wav)
            if drafts.isEmpty { throw Failure("No voices stood out in that recording.") }
            model.voices = drafts
            model.phase = .naming
        }
    }

    func writeNamedTranscript() {
        var given: [Int: String] = [:]
        for voice in voices {
            let trimmed = voice.name.trimmingCharacters(in: .whitespacesAndNewlines)
            given[voice.id] = trimmed.isEmpty ? voice.placeholder : trimmed
        }
        names = given
        startJob(title: "Writing the transcript") { model in
            guard let wav = model.wavURL else { throw Failure("The audio file is no longer available.") }
            try await model.ensureServer()
            try await model.transcribeAligned(wav: wav, names: model.names)
            model.phase = .result
        }
    }

    func backToFile() {
        work?.cancel()
        stopPlayback()
        voices = []
        turns = []
        speakerSpans = []
        clearNotice()
        phase = installed ? .choose : .needsDownload
    }

    func toggleSample(_ id: Int) {
        guard let voice = voices.first(where: { $0.id == id }) else { return }
        if playingVoiceID == id {
            stopPlayback()
            return
        }
        stopPlayback()
        do {
            let player = try AVAudioPlayer(contentsOf: voice.sampleURL)
            player.delegate = playback
            player.prepareToPlay()
            self.player = player
            playingVoiceID = id
            player.play()
        } catch {
            banner = "Couldn't play that voice sample."
        }
    }

    func copyTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(FileTranscriptFormat.plainText(turns), forType: .string)
    }

    func saveTranscript() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = (fileURL?.deletingPathExtension().lastPathComponent ?? "Transcript") + ".txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try FileTranscriptFormat.plainText(turns).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            banner = error.localizedDescription
        }
    }

    func shutdown() {
        serverStopping = true
        server?.terminate()
        server = nil
        serverReady = false
        downloader?.cancel()
        work?.cancel()
        work = nil
        stopPlayback()
        endAccess()
        fileURL = nil
        fileDuration = nil
        voices = []
        turns = []
        if !canRun { phase = .unavailable }
        else if installed { phase = .choose }
        else { phase = .needsDownload }
    }

    // MARK: - Jobs

    private func startJob(title: String, _ body: @escaping (FileTranscriptModel) async throws -> Void) {
        guard work == nil else { return }
        clearNotice()
        stopPlayback()
        phase = .working(title: title, detail: serverReady ? "Starting." : "Loading the model into memory. The first file takes a while.")
        work = Task { [weak self] in
            guard let self else { return }
            do {
                try await body(self)
            } catch is CancellationError {
                if self.installed { self.phase = self.voices.isEmpty ? .choose : .naming }
            } catch {
                if Task.isCancelled {
                    if self.installed { self.phase = self.voices.isEmpty ? .choose : .naming }
                } else {
                    self.banner = error.localizedDescription
                    if self.installed { self.phase = self.voices.isEmpty ? .choose : .naming }
                }
            }
            self.work = nil
        }
    }

    private func prepareWav() async throws -> URL {
        guard let fileURL else { throw Failure("Choose an audio or video file first.") }
        if let wavURL, FileManager.default.fileExists(atPath: wavURL.path) { return wavURL }
        phase = .working(title: "Reading the audio", detail: "Turning the file into audio the model can read.")
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-\(UUID().uuidString).wav")
        let seconds = try await WavExtract.extract(from: fileURL, to: destination) { [weak self] detail in
            Task { @MainActor in
                self?.phase = .working(title: "Reading the audio", detail: detail)
            }
        }
        if fileDuration == nil { fileDuration = seconds }
        if seconds < 0.2 { throw Failure("That file is too short to transcribe.") }
        wavURL = destination
        return destination
    }

    private func ensureServer() async throws {
        if serverReady, server?.isRunning == true { return }
        guard let binary = Self.runtimeBinary() else {
            throw Failure("The transcription runtime isn't installed.")
        }
        if await Self.serverIsOurs() {
            modelID = await Self.discoverModelID() ?? modelID
            if !modelID.isEmpty {
                serverReady = true
                return
            }
        }
        serverStopping = false
        serverLog = ""
        let process = Process()
        process.executableURL = binary
        process.arguments = [
            "serve",
            "--asr-model", Self.asrURL.path,
            "--diar-model", Self.diarURL.path,
            "--diar-preset", "v3-streaming",
            "--host", "127.0.0.1",
            "--port", String(Self.port),
            "--device", "metal",
            "--max-upload-mb", "2048",
        ]
        var environment = ProcessInfo.processInfo.environment
        let lib = binary.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("lib")
        if FileManager.default.fileExists(atPath: lib.path) {
            let current = environment["DYLD_LIBRARY_PATH"] ?? ""
            environment["DYLD_LIBRARY_PATH"] = current.isEmpty ? lib.path : lib.path + ":" + current
        }
        environment["NEMO_SPEECH_MODEL_DIR"] = Self.modelDirectory.path
        process.environment = environment
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let absorb: (FileHandle) -> Void = { handle in
            handle.readabilityHandler = { pipe in
                let data = pipe.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                Task { @MainActor in FileTranscriptModel.shared.appendServerLog(text) }
            }
        }
        absorb(out.fileHandleForReading)
        absorb(err.fileHandleForReading)
        process.terminationHandler = { [weak self] ended in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in
                guard let self else { return }
                self.serverReady = false
                if self.serverStopping { return }
                let code = ended.terminationStatus
                let tail = Self.usefulLog(self.serverLog)
                self.banner = tail.isEmpty ? "The transcription engine stopped (code \(code))." : String(tail)
            }
        }
        server = process
        do { try process.run() } catch {
            throw Failure("Couldn't start the transcription engine. \(error.localizedDescription)")
        }
        let deadline = Date().addingTimeInterval(6 * 60)
        while Date() < deadline {
            try Task.checkCancellation()
            if process.isRunning == false {
                let tail = Self.usefulLog(serverLog)
                throw Failure(tail.isEmpty ? "The transcription engine stopped while loading the model." : String(tail))
            }
            if let id = await Self.discoverModelID() {
                modelID = id
                serverReady = true
                return
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw Failure("The model was still loading after several minutes. \(Self.usefulLog(serverLog))")
    }

    private func appendServerLog(_ text: String) {
        serverLog += text
        if serverLog.count > 16_000 { serverLog.removeFirst(serverLog.count - 12_000) }
        guard case .working(let title, _) = phase else { return }
        let line = text.split(whereSeparator: \.isNewline).last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard line.count > 8, line.count < 180, !line.lowercased().contains("unused tensor") else { return }
        phase = .working(title: title, detail: line)
    }

    /// Drop tensor-dump lines so a crash shows the sentence that explains it.
    private static func usefulLog(_ log: String) -> String {
        let lines = log.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { line in
            guard !line.isEmpty, line.count < 240 else { return false }
            let lower = line.lowercased()
            if lower.hasPrefix("llama_model_loader") || lower.contains("unused tensor") { return false }
            if line.hasPrefix(".") || (line.hasPrefix("[") && line.contains("blk.")) { return false }
            return true
        }
        return lines.suffix(4).joined(separator: "\n")
    }

    private struct TimedWord {
        var text: String
        var start: Double
        var end: Double
    }

    /// Sortformer hears the whole file once. Parakeet then writes each piece, and the words take their voice from that one pass.
    private func transcribeAligned(wav: URL, names: [Int: String]?) async throws {
        let duration = fileDuration ?? Self.wavSeconds(wav)
        if speakerSpans.isEmpty {
            speakerSpans = try await diarizeAll(wav)
        }
        let bounds = Self.asrBounds(duration: duration)
        var words: [TimedWord] = []
        for (index, bound) in bounds.enumerated() {
            try Task.checkCancellation()
            phase = .working(
                title: "Transcribing",
                detail: bounds.count == 1 ? "Writing the transcript." : "Part \(index + 1) of \(bounds.count)."
            )
            let piece = try await transcribePiece(wav, from: bound.0, to: bound.1, full: duration)
            let skip = index == 0 ? 0.0 : Self.asrOverlap
            for word in piece where word.start >= skip - 0.05 {
                words.append(TimedWord(text: word.text, start: word.start + bound.0, end: word.end + bound.0))
            }
            turns = FileTranscriptFormat.turns(transcript: "", words: labeled(words), names: names)
        }
        if turns.isEmpty { throw Failure("The recording didn't produce a transcript.") }
    }

    private static func asrBounds(duration: Double) -> [(Double, Double)] {
        guard duration > asrPiece + 1 else { return [(0, max(duration, 0))] }
        var bounds: [(Double, Double)] = []
        var start = 0.0
        while start < duration - 0.2 {
            let end = min(duration, start + asrPiece)
            bounds.append((start, end))
            if end >= duration - 0.05 { break }
            start = end - asrOverlap
        }
        return bounds
    }

    private func transcribePiece(_ wav: URL, from start: Double, to end: Double, full: Double) async throws -> [TimedWord] {
        let partWav = try materialize(wav, from: start, to: end, full: full)
        defer { if partWav != wav { try? FileManager.default.removeItem(at: partWav) } }
        let boundary = "Murmur\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        var body = Data()
        func add(_ string: String) { body.append(contentsOf: string.utf8) }
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"response_format\"\r\n\r\nverbose_json\r\n")
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"timestamp_granularities[]\"\r\n\r\nword\r\n")
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n")
        let audio = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: partWav) }.value
        body.append(audio)
        add("\r\n--\(boundary)--\r\n")
        var request = URLRequest(url: Self.endpoint("v1/audio/transcriptions"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 60 * 45
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.checkHTTP(response, body: data)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure("The transcript didn't come back.")
        }
        let rows = json["words"] as? [[String: Any]] ?? []
        let timed: [TimedWord] = rows.compactMap { row in
            let text = (row["word"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty, let start = Self.jsonDouble(row["start"]), let end = Self.jsonDouble(row["end"]) else { return nil }
            return TimedWord(text: text, start: start, end: end)
        }
        if !timed.isEmpty { return timed }
        let text = (json["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { return [] }
        return [TimedWord(text: text, start: 0, end: max(0, end - start))]
    }

    private func labeled(_ words: [TimedWord]) -> [[String: Any]] {
        let spans = speakerSpans
        return words.map { word in
            var row: [String: Any] = ["word": word.text, "start": word.start, "end": word.end]
            if let speaker = Self.speaker(for: word, in: spans) { row["speaker"] = speaker }
            return row
        }
    }

    private static func speaker(for word: TimedWord, in spans: [SpeechSpan]) -> Int? {
        let mid = (word.start + word.end) / 2
        if let hit = spans.first(where: { mid >= $0.start && mid < $0.end }) { return hit.speaker }
        return spans.min { abs(($0.start + $0.end) / 2 - mid) < abs(($1.start + $1.end) / 2 - mid) }?.speaker
    }

    private static func wavSeconds(_ url: URL) -> Double {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        return Double(max(0, size - 44)) / (16_000 * 2)
    }

    private func diarizeAll(_ wav: URL) async throws -> [SpeechSpan] {
        let duration = fileDuration ?? Self.wavSeconds(wav)
        phase = .working(title: "Finding the voices", detail: "Listening through the whole recording.")
        do {
            return try await diarize(wav)
        } catch {
            guard Self.shouldSplit(error, span: duration) else { throw error }
            banner = "This recording had to be split, so a voice may show up more than once."
            let bounds = WavExtract.partBounds(in: wav, duration: duration, limit: 50 * 60)
            var spans: [SpeechSpan] = []
            var speakerShift = 0
            for (index, bound) in bounds.enumerated() {
                try Task.checkCancellation()
                let label = "Part \(index + 1) of \(bounds.count)."
                let (part, next) = try await diarizeSpan(
                    wav, from: bound.0, to: bound.1, full: duration, shift: speakerShift, label: label
                )
                spans.append(contentsOf: part)
                speakerShift = next
            }
            return spans
        }
    }

    private func diarizeSpan(
        _ wav: URL, from start: Double, to end: Double, full: Double, shift: Int, label: String
    ) async throws -> (spans: [SpeechSpan], nextShift: Int) {
        phase = .working(title: "Finding the voices", detail: label)
        let partWav = try materialize(wav, from: start, to: end, full: full)
        do {
            let part = try await diarize(partWav)
            if partWav != wav { try? FileManager.default.removeItem(at: partWav) }
            let peak = part.map(\.speaker).max() ?? -1
            let spans = part.map {
                SpeechSpan(start: $0.start + start, end: $0.end + start, speaker: $0.speaker + shift)
            }
            return (spans, shift + peak + 1)
        } catch {
            if partWav != wav { try? FileManager.default.removeItem(at: partWav) }
            guard Self.shouldSplit(error, span: end - start) else { throw error }
            let mid = WavExtract.quietCut(in: wav, near: (start + end) / 2, radius: 8) ?? ((start + end) / 2)
            phase = .working(title: "Finding the voices", detail: "That part was too long, so it's being split.")
            let left = try await diarizeSpan(wav, from: start, to: mid, full: full, shift: shift, label: label)
            let right = try await diarizeSpan(wav, from: mid, to: end, full: full, shift: left.nextShift, label: label)
            return (left.spans + right.spans, right.nextShift)
        }
    }

    private func materialize(_ wav: URL, from start: Double, to end: Double, full: Double) throws -> URL {
        if start <= 0.05, end >= full - 0.05 { return wav }
        let partWav = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-part-\(UUID().uuidString).wav")
        try WavExtract.slice(wav, from: start, to: end, destination: partWav)
        return partWav
    }

    private static func shouldSplit(_ error: Error, span: Double) -> Bool {
        guard span > 180, !(error is CancellationError) else { return false }
        let text = error.localizedDescription.lowercased()
        return text.contains("exceed") || text.contains("too long") || text.contains("too large")
            || text.contains("context")
    }

    private func diarize(_ wav: URL) async throws -> [SpeechSpan] {
        let boundary = "Murmur\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        var body = Data()
        func add(_ string: String) { body.append(contentsOf: string.utf8) }
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"mode\"\r\n\r\nstreaming\r\n")
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n")
        let audio = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: wav) }.value
        body.append(audio)
        add("\r\n--\(boundary)--\r\n")
        var request = URLRequest(url: Self.endpoint("v1/audio/diarizations"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 60 * 60 * 2
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.checkHTTP(response, body: data)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure("The voice scan didn't return a result.")
        }
        let rows = (json["segments"] as? [[String: Any]]) ?? (json["diarization_timestamps"] as? [[String: Any]]) ?? []
        let rawIDs = rows.compactMap { FileTranscriptFormat.speakerIndex($0["speaker"]) }
        let sawZero = rawIDs.contains(0)
        return rows.compactMap { row in
            guard let speaker = FileTranscriptFormat.speakerIndex(row["speaker"]) else { return nil }
            let start = Self.jsonDouble(row["start"] ?? row["start_time"])
            let end = Self.jsonDouble(row["end"] ?? row["end_time"])
            guard let start, let end, end > start else { return nil }
            return SpeechSpan(start: start, end: end, speaker: FileTranscriptFormat.zeroBasedSpeaker(speaker, sawZero: sawZero))
        }
    }

    private func makeDrafts(from segments: [SpeechSpan], wav: URL) throws -> [VoiceDraft] {
        let merged = Self.merge(segments)
        var order: [Int] = []
        for span in merged where !order.contains(span.speaker) { order.append(span.speaker) }
        order = Array(order.prefix(8))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-voices-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let previous = sampleDirectory { try? FileManager.default.removeItem(at: previous) }
        sampleDirectory = directory
        var drafts: [VoiceDraft] = []
        for (index, speaker) in order.enumerated() {
            let mine = merged.filter { $0.speaker == speaker }
            guard let window = Self.sampleWindow(in: mine) else { continue }
            let url = directory.appendingPathComponent("voice-\(speaker).wav")
            try WavExtract.slice(wav, from: window.0, to: window.1, destination: url)
            drafts.append(VoiceDraft(
                id: speaker,
                name: "",
                sampleURL: url,
                seconds: window.1 - window.0,
                placeholder: "Voice \(index + 1)",
                peaks: WavExtract.peaks(in: url)
            ))
        }
        return drafts
    }

    private func stopPlayback() {
        player?.stop()
        player = nil
        playingVoiceID = nil
    }

    private func endAccess() {
        if let scopedURL { scopedURL.stopAccessingSecurityScopedResource() }
        scopedURL = nil
        if let wavURL { try? FileManager.default.removeItem(at: wavURL) }
        wavURL = nil
    }

    // MARK: - Paths and memory

    static func physicalMemory() -> UInt64 {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &value, &size, nil, 0)
        return value
    }

    private static var supportRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Murmur", isDirectory: true)
    }

    private static var modelDirectory: URL {
        supportRoot.appendingPathComponent("models/parakeet-sortformer", isDirectory: true)
    }

    private static var runtimeRoot: URL {
        supportRoot.appendingPathComponent("nemo-speech", isDirectory: true)
    }

    static var asrURL: URL { modelDirectory.appendingPathComponent(asrName) }
    static var diarURL: URL { modelDirectory.appendingPathComponent(diarName) }

    private struct Artifact {
        let name: String
        let title: String
        let about: String
        let url: String
        let sha256: String
    }

    private static let artifacts = [
        Artifact(
            name: asrName,
            title: "Parakeet",
            about: "about 680 MB",
            url: "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3/resolve/541d1f99c6b0c3cd0b11a95167540bb8edefd82b/parakeet-tdt-0.6b-v3.q8_0.gguf",
            sha256: "e3880d0aaaaf2c308ea2c35016b2b895c423eb3fda924c1b463d1c19b7f4d32e"
        ),
        Artifact(
            name: diarName,
            title: "Sortformer",
            about: "about 100 MB",
            url: "https://huggingface.co/nvidia/Nemotron-3-Diarization/resolve/f667ed73aee57d40cc39428eb768b4fd87a0a29e/Nemotron-3-Diarization.q8_0.gguf",
            sha256: "08456d9e22cd9a323c0364d98375f3746d6e68507ebb705cd46438c534c7a3a1"
        ),
    ]

    private static func runtimeBinary() -> URL? {
        let url = runtimeRoot.appendingPathComponent("bin/nemo-speech")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    private static func endpoint(_ path: String) -> URL {
        URL(string: "http://127.0.0.1:\(port)/\(path)")!
    }

    private static func discoverModelID() async -> String? {
        var request = URLRequest(url: endpoint("v1/models"))
        request.timeoutInterval = 2
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let rows = (json["data"] as? [[String: Any]]) ?? (json["models"] as? [[String: Any]]) ?? []
        let ids = rows.compactMap { ($0["id"] as? String) ?? ($0["name"] as? String) }
        let blob = String(decoding: data, as: UTF8.self).lowercased()
        guard blob.contains("parakeet"), blob.contains("diar") else { return nil }
        return ids.first { $0.lowercased().contains("parakeet") } ?? ids.first
    }

    private static func serverIsOurs() async -> Bool {
        await discoverModelID() != nil
    }

    private static func checkHTTP(_ response: URLResponse, body: Data? = nil) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let message = body.flatMap { data -> String? in
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
                return (json["error"] as? [String: Any])?["message"] as? String
            }
            throw Failure(message ?? "The transcription engine returned an error (\(http.statusCode)).")
        }
    }

    private static func installRuntime(archive: URL) throws {
        let extract = supportRoot.appendingPathComponent("nemo-speech-extract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: extract, withIntermediateDirectories: true)
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xzf", archive.path, "-C", extract.path]
        try tar.run()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0 else { throw Failure("Couldn't unpack the transcription runtime.") }
        guard let binary = findBinary(in: extract) else { throw Failure("The runtime archive had no nemo-speech tool.") }
        let prefix = binary.deletingLastPathComponent().deletingLastPathComponent()
        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-dr", "com.apple.quarantine", prefix.path]
        try? xattr.run()
        xattr.waitUntilExit()
        if FileManager.default.fileExists(atPath: runtimeRoot.path) {
            try FileManager.default.removeItem(at: runtimeRoot)
        }
        try FileManager.default.createDirectory(at: runtimeRoot.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: prefix, to: runtimeRoot)
        try? FileManager.default.removeItem(at: extract)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runtimeRoot.appendingPathComponent("bin/nemo-speech").path)
    }

    private static func findBinary(in root: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in enumerator where url.lastPathComponent == "nemo-speech" && url.path.contains("/bin/") {
            return url
        }
        return nil
    }

    private static func ggufIsComplete(_ url: URL) -> Bool {
        let minimum: Int64 = url.lastPathComponent == diarName ? 50_000_000 : 400_000_000
        return fileSize(url) >= minimum && hasGGUFMagic(url)
    }

    private static func hasGGUFMagic(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let data = try? handle.read(upToCount: 4) else { return false }
        try? handle.close()
        return data == Data("GGUF".utf8)
    }

    private static func fileSize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    private static func freeBytes(at url: URL) throws -> Int64 {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values.volumeAvailableCapacityForImportantUsage ?? 0
    }

    static func format(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_000_000_000
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", Double(bytes) / 1_000_000)
    }

    private static func sha256File(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func jsonDouble(_ value: Any?) -> Double? {
        switch value {
        case let number as Double: return number
        case let number as NSNumber: return number.doubleValue
        case let text as String: return Double(text)
        default: return nil
        }
    }

    private static func merge(_ segments: [SpeechSpan]) -> [SpeechSpan] {
        var merged: [SpeechSpan] = []
        for span in segments.sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, last.speaker == span.speaker, span.start - last.end < 0.4 {
                merged[merged.count - 1].end = max(last.end, span.end)
            } else {
                merged.append(span)
            }
        }
        return merged
    }

    /// A few seconds from the longest stretch of this voice, taken from the middle so the sample isn't a breath.
    private static func sampleWindow(in spans: [SpeechSpan]) -> (Double, Double)? {
        guard let best = spans.max(by: { ($0.end - $0.start) < ($1.end - $1.start) }) else { return nil }
        let length = best.end - best.start
        let take = min(6, max(0.8, length))
        let mid = (best.start + best.end) / 2
        var start = max(best.start, mid - take / 2)
        let end = min(best.end, start + take)
        start = max(best.start, end - take)
        guard end - start >= 0.35 else { return nil }
        return (start, end)
    }
}

private struct SpeechSpan {
    var start: Double
    var end: Double
    var speaker: Int
}

struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private final class Playback: NSObject, AVAudioPlayerDelegate {
    var onFinish: () -> Void = {}
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { onFinish() }
}

/// Writes a download to disk in chunks, continuing a partial file when the server allows it.
private final class ChunkedDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @Sendable (Int64, Int64?) -> Void
    private var handle: FileHandle?
    private var received: Int64 = 0
    private var total: Int64?
    private var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var satisfied = false

    init(destination: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    func start(_ request: URLRequest) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 180
            config.timeoutIntervalForResource = 60 * 60 * 24
            config.waitsForConnectivity = true
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            self.session = session
            let task = session.dataTask(with: request)
            self.task = task
            task.resume()
        }
    }

    func cancel() { task?.cancel() }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        do {
            if code == 416 {
                satisfied = true
                completionHandler(.cancel)
                return
            }
            if code == 200 {
                FileManager.default.createFile(atPath: destination.path, contents: nil)
                let handle = try FileHandle(forWritingTo: destination)
                try handle.truncate(atOffset: 0)
                self.handle = handle
                received = 0
                total = response.expectedContentLength > 0 ? response.expectedContentLength : nil
            } else if code == 206 {
                let handle = try FileHandle(forWritingTo: destination)
                try handle.seekToEnd()
                self.handle = handle
                received = Int64(try handle.offset())
                if let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range"),
                   let totalPart = header.split(separator: "/").last, let parsed = Int64(totalPart), parsed > 0 {
                    total = parsed
                }
            } else {
                throw Failure("Download failed (HTTP \(code)).")
            }
            completionHandler(.allow)
        } catch {
            failure = error
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !satisfied else { return }
        do {
            try handle?.write(contentsOf: data)
            received += Int64(data.count)
            progress(received, total)
        } catch {
            failure = error
            task?.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        session.finishTasksAndInvalidate()
        let finish = failure ?? (satisfied ? nil : error)
        if let urlError = finish as? URLError, urlError.code == .cancelled {
            continuation?.resume(throwing: CancellationError())
        } else if let finish {
            continuation?.resume(throwing: finish)
        } else {
            continuation?.resume()
        }
        continuation = nil
        self.session = nil
    }
}

private final class ErrorCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = Data()
    func store(_ data: Data) { lock.lock(); stored = data; lock.unlock() }
    var data: Data { lock.lock(); defer { lock.unlock() }; return stored }
}

private enum WavExtract {
    struct Inspection {
        var hasAudio: Bool
        var duration: Double?
        /// AVFoundation could not open the container, and ffmpeg could not either.
        var unreadable: Bool
    }

    static var canDecodeForeign: Bool { tool("ffmpeg") != nil }

    /// AVFoundation rejects Matroska (and some other containers) with "Cannot Open"
    /// even when the audio inside is AAC. ffmpeg reads those.
    static func inspect(_ url: URL) async -> Inspection {
        do {
            let av = try await inspectAV(url)
            if av.hasAudio {
                return Inspection(hasAudio: true, duration: av.duration, unreadable: false)
            }
            if let foreign = inspectFFprobe(url), foreign.hasAudio {
                return Inspection(hasAudio: true, duration: foreign.duration, unreadable: false)
            }
            return Inspection(hasAudio: false, duration: nil, unreadable: false)
        } catch {
            // Matroska and some other containers throw "Cannot Open" before any track is visible.
            if let foreign = inspectFFprobe(url) {
                return Inspection(hasAudio: foreign.hasAudio, duration: foreign.duration, unreadable: false)
            }
            return Inspection(hasAudio: false, duration: nil, unreadable: true)
        }
    }

    static func extract(from source: URL, to destination: URL, progress: @escaping @Sendable (String) -> Void) async throws -> Double {
        try await Task.detached(priority: .userInitiated) {
            do {
                return try await extractAV(from: source, to: destination, progress: progress)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                NSLog("Murmur could not read \(source.lastPathComponent) with AVFoundation: \(error.localizedDescription)")
                return try extractFFmpeg(from: source, to: destination, progress: progress)
            }
        }.value
    }

    private static func inspectAV(_ url: URL) async throws -> (hasAudio: Bool, duration: Double?) {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { return (false, nil) }
        let seconds = CMTimeGetSeconds(try await asset.load(.duration))
        return (true, seconds.isFinite && seconds > 0 ? seconds : nil)
    }

    private static func extractAV(from source: URL, to destination: URL, progress: @escaping @Sendable (String) -> Void) async throws -> Double {
        let asset = AVURLAsset(url: source)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard let track = tracks.first else { throw Failure("That file has no audio track.") }
            let duration = CMTimeGetSeconds(try await asset.load(.duration))
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            guard reader.canAdd(output) else { throw Failure("Couldn't read the audio in that file.") }
            reader.add(output)
            guard reader.startReading() else { throw Failure(reader.error?.localizedDescription ?? "Couldn't read the audio in that file.") }
            FileManager.default.createFile(atPath: destination.path, contents: nil)
            let handle = try FileHandle(forWritingTo: destination)
            try handle.write(contentsOf: header(dataBytes: 0))
            var bytes = 0
            var lastReport = 0
            while let sample = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
                var length = 0
                var pointer: UnsafeMutablePointer<Int8>?
                guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
                      let pointer, length > 0 else { continue }
                try handle.write(contentsOf: Data(bytes: pointer, count: length))
                bytes += length
                if bytes - lastReport > 16_000 * 2 * 5 {
                    lastReport = bytes
                    let seconds = Double(bytes) / (16_000 * 2)
                    if duration.isFinite, duration > 0 {
                        progress("Reading the audio, \(Int(min(100, seconds / duration * 100)))%.")
                    }
                }
            }
            if reader.status == .failed {
                throw Failure(reader.error?.localizedDescription ?? "Couldn't read the audio in that file.")
            }
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: header(dataBytes: bytes))
            try handle.close()
            return Double(bytes) / (16_000 * 2)
    }

    private static func inspectFFprobe(_ url: URL) -> (hasAudio: Bool, duration: Double?)? {
        guard let ffprobe = tool("ffprobe") else { return nil }
        let process = Process()
        process.executableURL = ffprobe
        process.arguments = ["-v", "error", "-show_entries", "format=duration:stream=codec_type", "-of", "json", url.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let streams = json["streams"] as? [[String: Any]] ?? []
        let hasAudio = streams.contains { ($0["codec_type"] as? String) == "audio" }
        let seconds = ((json["format"] as? [String: Any])?["duration"] as? String).flatMap(Double.init)
        let duration = seconds.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        return (hasAudio, duration)
    }

    private static func extractFFmpeg(from source: URL, to destination: URL, progress: @escaping @Sendable (String) -> Void) throws -> Double {
        guard let ffmpeg = tool("ffmpeg") else {
            throw Failure("This Mac can't open that recording. Install ffmpeg, or export the audio as WAV or M4A.")
        }
        let duration = inspectFFprobe(source)?.duration
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = [
            "-hide_banner", "-loglevel", "error",
            "-progress", "pipe:1", "-nostats",
            "-i", source.path,
            "-vn", "-ac", "1", "-ar", "16000",
            "-c:a", "pcm_s16le",
            "-y", destination.path,
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        let errors = stderr.fileHandleForReading
        let errorBox = ErrorCapture()
        let drained = DispatchGroup()
        drained.enter()
        DispatchQueue.global(qos: .utility).async {
            errorBox.store(errors.readDataToEndOfFile())
            drained.leave()
        }

        let reader = stdout.fileHandleForReading
        while true {
            let chunk = reader.availableData
            if chunk.isEmpty { break }
            if Task.isCancelled {
                process.terminate()
                throw CancellationError()
            }
            guard let text = String(data: chunk, encoding: .utf8), let duration, duration > 0 else { continue }
            for line in text.split(separator: "\n") where line.hasPrefix("out_time_us=") {
                guard let microseconds = Double(line.dropFirst("out_time_us=".count)) else { continue }
                let fraction = microseconds / 1_000_000 / duration
                progress("Reading the audio, \(Int(min(99, fraction * 100)))%.")
            }
        }
        process.waitUntilExit()
        drained.wait()
        if Task.isCancelled {
            process.terminate()
            throw CancellationError()
        }
        guard process.terminationStatus == 0 else {
            let message = String(data: errorBox.data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(message?.isEmpty == false ? message! : "Couldn't read the audio in that file.")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.intValue ?? 0
        return Double(max(0, size - 44)) / (16_000 * 2)
    }

    /// Homebrew is not on the PATH when Murmur is launched from Finder.
    private static func tool(_ name: String) -> URL? {
        for path in ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/opt/local/bin/\(name)"]
        where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    static func peaks(in wav: URL, count: Int = 48) -> [Float] {
        guard let data = try? Data(contentsOf: wav), data.count > 44 else { return [] }
        let pcm = data.subdata(in: 44..<data.count)
        let samples = pcm.count / 2
        guard samples > 0 else { return [] }
        let per = max(1, samples / count)
        var result = [Float]()
        result.reserveCapacity(count)
        pcm.withUnsafeBytes { raw in
            let values = raw.bindMemory(to: Int16.self)
            var index = 0
            while index < samples && result.count < count {
                let end = min(samples, index + per)
                var peak = 0
                for sample in index..<end { peak = max(peak, abs(Int(values[sample]))) }
                result.append(Float(peak) / Float(Int16.max))
                index = end
            }
        }
        return result
    }

    /// One span when `duration` fits in `limit`. Otherwise, cuts near silence so each part fits.
    static func partBounds(in wav: URL, duration: Double, limit: Double) -> [(Double, Double)] {
        guard duration > limit + 1, limit > 1 else { return [(0, max(duration, 0))] }
        var bounds: [(Double, Double)] = []
        var start = 0.0
        while duration - start > limit + 1 {
            let ceiling = start + limit
            let cut = quietCut(in: wav, near: ceiling - 6, radius: 6) ?? (ceiling - 1)
            let end = min(duration - 0.3, ceiling - 0.5, max(start + min(30, limit * 0.5), cut))
            guard end > start + 0.2 else { break }
            bounds.append((start, end))
            start = end
        }
        if duration - start > 0.2 { bounds.append((start, duration)) }
        return bounds.isEmpty ? [(0, duration)] : bounds
    }

    static func quietCut(in wav: URL, near: Double, radius: Double) -> Double? {
        let lower = max(0, near - radius)
        let count = Int((near + radius - lower) * 16_000)
        guard count > 320, let handle = try? FileHandle(forReadingFrom: wav) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(44 + Int(lower * 16_000) * 2))) != nil,
              let data = try? handle.read(upToCount: count * 2), data.count > 640 else { return nil }
        let samples = data.count / 2
        let window = 320
        var bestIndex = samples / 2
        var bestEnergy = Int64.max
        data.withUnsafeBytes { raw in
            let values = raw.bindMemory(to: Int16.self)
            var index = 0
            while index + window < samples {
                var energy: Int64 = 0
                for sample in index..<(index + window) {
                    let value = Int64(values[sample])
                    energy += value * value
                }
                if energy < bestEnergy {
                    bestEnergy = energy
                    bestIndex = index + window / 2
                }
                index += window
            }
        }
        return lower + Double(bestIndex) / 16_000
    }

    static func slice(_ source: URL, from start: Double, to end: Double, destination: URL) throws {
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        let startByte = max(0, Int(start * 16_000) * 2)
        let endByte = max(startByte, Int(end * 16_000) * 2)
        try handle.seek(toOffset: UInt64(44 + startByte))
        let pcm = try handle.read(upToCount: endByte - startByte) ?? Data()
        guard pcm.count >= 16_000 / 2 else { throw Failure("That voice sample was too short.") }
        var data = header(dataBytes: pcm.count)
        data.append(pcm)
        try data.write(to: destination)
    }

    private static func header(dataBytes: Int) -> Data {
        let rate: UInt32 = 16_000
        let channels: UInt16 = 1
        let bits: UInt16 = 16
        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        data.appendLE(UInt32(36 + dataBytes))
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        data.appendLE(UInt32(16))
        data.appendLE(UInt16(1))
        data.appendLE(channels)
        data.appendLE(rate)
        data.appendLE(rate * UInt32(channels) * UInt32(bits / 8))
        data.appendLE(channels * bits / 8)
        data.appendLE(bits)
        data.append(contentsOf: "data".utf8)
        data.appendLE(UInt32(dataBytes))
        return data
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
