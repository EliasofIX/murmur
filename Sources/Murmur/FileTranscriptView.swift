import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FileTranscriptView: View {
    @Bindable var model = FileTranscriptModel.shared
    @State private var confirmRemoval = false

    var body: some View {
        GlassPage {
            if let notice = model.notice {
                Text(notice)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            PillMark(title: markTitle)
                .frame(maxWidth: .infinity)
            switch model.phase {
            case .unavailable:
                Text("This Mac has \(model.memoryGigabytes) GB of memory. File transcription needs about 8 GB, so it stays off. Live dictation is unchanged.")
                    .fixedSize(horizontal: false, vertical: true)
            case .needsDownload:
                offer
            case .downloading(let title, let fraction, let detail):
                download(title: title, fraction: fraction, detail: detail)
            case .choose:
                choose
            case .working(let title, let detail):
                working(title: title, detail: detail)
            case .naming:
                naming
            case .result:
                result
            }
            Spacer(minLength: 8)
            footer
        }
        .frame(minWidth: 480, minHeight: 520)
        .onDrop(of: [.fileURL], isTargeted: nil, perform: dropFiles)
        .alert("Remove the transcription model?", isPresented: $confirmRemoval) {
            Button("Remove", role: .destructive) { model.removeDownload() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes Parakeet and Sortformer, about 800 MB. You can download them again later.")
        }
    }

    private var markTitle: String {
        if let duration = model.fileDuration, model.phase != .needsDownload, model.phase != .unavailable {
            return clock(duration)
        }
        return "Murmur"
    }

    private var offer: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Parakeet and Sortformer")
                    .font(.body.weight(.medium))
                Text("About 800 MB, kept on this Mac. A long recording keeps the same voices from start to finish.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("This Mac has \(model.memoryGigabytes) GB of memory, which is enough.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            pathCards(enabled: false, reason: "Available after the download.")
        }
    }

    private func download(title: String, fraction: Double?, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            status(title: title, detail: detail, fraction: fraction)
            pathCards(enabled: false, reason: "Available when the download finishes.")
        }
    }

    private var choose: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let file = model.fileURL {
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.lastPathComponent)
                        .font(.body.weight(.medium))
                        .lineLimit(2)
                    if let duration = model.fileDuration {
                        Text(clock(duration))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                pathCards(enabled: true, reason: nil)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Drop an audio or video file")
                        .font(.body.weight(.medium))
                    Text("Or choose one. Live dictation stays separate.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                pathCards(enabled: false, reason: "Choose a file first.")
            }
        }
    }

    private var naming: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let file = model.fileURL {
                Text(file.lastPathComponent)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
            }
            Text(model.voices.count == 1 ? "One voice. Name it, then write the transcript." : "\(model.voices.count) voices. Name them, then write the transcript.")
                .font(.callout)
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach($model.voices) { $voice in
                        voiceRow($voice)
                    }
                }
            }
        }
    }

    private func voiceRow(_ voice: Binding<FileTranscriptModel.VoiceDraft>) -> some View {
        HStack(alignment: .center, spacing: 12) {
            sampleButton(
                playing: model.playingVoiceID == voice.wrappedValue.id,
                name: voice.wrappedValue.placeholder
            ) { model.toggleSample(voice.wrappedValue.id) }

            VStack(alignment: .leading, spacing: 6) {
                SampleWave(peaks: voice.wrappedValue.peaks)
                    .frame(height: 28)
                Text(voice.wrappedValue.placeholder)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(voice.wrappedValue.placeholder, text: voice.name)
                    .textFieldStyle(.roundedBorder)
                Text("\(Int(voice.wrappedValue.seconds.rounded())) seconds")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 12)
        .overlay(alignment: .top) {
            if voice.wrappedValue.id != model.voices.first?.id {
                Divider()
            }
        }
    }

    private var result: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let file = model.fileURL {
                Text(file.lastPathComponent)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.turns) { turn in
                        VStack(alignment: .leading, spacing: 4) {
                            if !turn.speaker.isEmpty {
                                Text(turn.speaker).font(.body.weight(.medium))
                            }
                            Text(turn.text)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12)
                        .overlay(alignment: .top) {
                            if turn.id != model.turns.first?.id { Divider() }
                        }
                    }
                }
            }
        }
    }

    private func working(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            status(title: title, detail: detail, fraction: nil)
            if !model.turns.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(model.turns) { turn in
                            VStack(alignment: .leading, spacing: 3) {
                                if !turn.speaker.isEmpty {
                                    Text(turn.speaker).font(.body.weight(.medium))
                                }
                                Text(turn.text)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var footer: some View {
        switch model.phase {
        case .needsDownload:
            Button("Download") { model.download() }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .keyboardShortcut(.defaultAction)
        case .downloading, .working:
            Button("Cancel", action: model.cancel)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        case .choose:
            HStack(spacing: 16) {
                Button(model.fileURL == nil ? "Choose a file" : "Choose another file") { model.chooseFile() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                if model.installed {
                    Button("Remove download") { confirmRemoval = true }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
            }
        case .naming:
            HStack(spacing: 12) {
                Button("Write the transcript") { model.writeNamedTranscript() }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                Button("Back") { model.backToFile() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
        case .result:
            HStack(spacing: 16) {
                Button("Copy") { model.copyTranscript() }
                Button("Save…") { model.saveTranscript() }
                Button("Another file") { model.backToFile() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
        case .unavailable:
            EmptyView()
        }
    }

    private func status(title: String, detail: String, fraction: Double?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.body.weight(.medium))
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            if let fraction {
                ProgressView(value: min(1, max(0, fraction)))
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func pathCards(enabled: Bool, reason: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            pathCard(
                title: "Quick transcript",
                copy: "Speakers are labeled Voice 1, Voice 2, Voice 3.",
                enabled: enabled,
                prominent: true
            ) { model.transcribeQuick() }
            pathCard(
                title: "Name the voices",
                copy: "Hear a short sample of each voice and name it. The transcript uses those names.",
                enabled: enabled,
                prominent: false
            ) { model.findVoices() }
            if let reason, !enabled {
                Text(reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func pathCard(title: String, copy: String, enabled: Bool, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(copy)
                    .font(.subheadline)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .disabled(!enabled)
        .modifier(ProminentIf(prominent: prominent))
    }

    private func sampleButton(playing: Bool, name: String, action: @escaping () -> Void) -> some View {
        let symbol = playing ? "stop.fill" : "play.fill"
        return Group {
            if playing {
                Button(action: action) { Image(systemName: symbol) }
                    .buttonStyle(.borderedProminent)
            } else {
                Button(action: action) { Image(systemName: symbol) }
                    .buttonStyle(.bordered)
            }
        }
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .help(playing ? "Stop" : "Play a short sample")
        .accessibilityLabel(playing ? "Stop \(name)" : "Play \(name)")
    }

    private func dropFiles(_ providers: [NSItemProvider]) -> Bool {
        switch model.phase {
        case .choose, .needsDownload, .result, .unavailable: break
        default: return false
        }
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL?
            if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else {
                url = item as? URL
            }
            guard let url else { return }
            Task { @MainActor in model.useFile(url) }
        }
        return true
    }

    private func clock(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded())
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

private struct ProminentIf: ViewModifier {
    var prominent: Bool
    func body(content: Content) -> some View {
        if prominent {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

private struct SampleWave: View {
    let peaks: [Float]

    var body: some View {
        Canvas { context, size in
            let bars = peaks.isEmpty ? [Float](repeating: 0.15, count: 40) : peaks
            let gap: CGFloat = 2
            let width = max(1, (size.width - gap * CGFloat(bars.count - 1)) / CGFloat(bars.count))
            for (index, peak) in bars.enumerated() {
                let height = max(2, CGFloat(min(1, peak)) * size.height)
                let rect = CGRect(
                    x: CGFloat(index) * (width + gap),
                    y: (size.height - height) / 2,
                    width: width,
                    height: height
                )
                context.fill(Path(roundedRect: rect, cornerRadius: width / 2), with: .color(.secondary))
            }
        }
        .accessibilityHidden(true)
    }
}
