import Foundation

/// A provider-supplied sidecar subtitle. The URL identifies the file cache entry.
public struct SubtitleSource: Codable, Hashable, Sendable, Identifiable {
    public let url: URL
    public let label: String
    public var id: String { url.absoluteString }

    public init(url: URL, label: String) {
        self.url = url
        self.label = label
    }

    /// Xtream extensions vary by provider. Only accept entries with actual URLs;
    /// an embedded track's codec/index metadata is not a downloadable subtitle.
    static func fromMetadata(_ metadata: [String: Any], relativeTo base: URL?) -> [SubtitleSource] {
        let raw = metadata["subtitles"] ?? metadata["subtitle"]
        let entries: [[String: Any]]
        if let array = raw as? [[String: Any]] {
            entries = array
        } else if let dictionary = raw as? [String: Any] {
            if dictionary["url"] != nil || dictionary["subtitle_url"] != nil {
                entries = [dictionary]
            } else {
                entries = dictionary.compactMap { language, value in
                    if let path = value as? String { return ["url": path, "language": language] }
                    guard var entry = value as? [String: Any] else { return nil }
                    if entry["language"] == nil { entry["language"] = language }
                    return entry
                }
            }
        } else if let path = raw as? String {
            entries = [["url": path]]
        } else {
            entries = []
        }
        return entries.compactMap { entry in
            guard let path = (entry["url"] ?? entry["subtitle_url"] ?? entry["file"]) as? String,
                  let url = URL(string: path, relativeTo: base)?.absoluteURL,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            let language = entry["language"] as? String
            let label = (entry["label"] ?? entry["name"]) as? String
                ?? language.flatMap { Locale.current.localizedString(forLanguageCode: $0) ?? $0 }
                ?? "Subtitle \(url.lastPathComponent)"
            return SubtitleSource(url: url, label: label)
        }
    }
}

enum SubtitleError: LocalizedError {
    case malformed, tooLarge, http(Int), discovery

    var errorDescription: String? {
        switch self {
        case .malformed: return "This subtitle file is malformed or unsupported. Choose an SRT or WebVTT file."
        case .tooLarge: return "The subtitle file exceeds the 5 MB limit."
        case .http(let status): return "Subtitles could not be downloaded (HTTP \(status)). Try again."
        case .discovery: return "Subtitle tracks are not ready yet. Try again once playback starts."
        }
    }
}

struct SubtitleCue: Equatable, Sendable {
    let start: Double
    let end: Double
    let text: String
}

/// SRT and WebVTT are normalized to timed plain text for both playback engines.
/// This avoids reloading a native track when changing its size.
struct SubtitleDocument: Sendable {
    let cues: [SubtitleCue]
    private let maximumEnds: [Double]

    init(data: Data) throws {
        guard data.count <= 5 * 1024 * 1024 else { throw SubtitleError.tooLarge }
        guard let source = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .utf16) else { throw SubtitleError.malformed }
        let normalized = source.replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var parsed: [SubtitleCue] = []
        var lines: [String] = []
        func consume() throws {
            defer { lines.removeAll(keepingCapacity: true) }
            guard !lines.isEmpty else { return }
            let first = lines[0]
            if first.hasPrefix("WEBVTT") || first == "STYLE" || first == "REGION"
                || first == "NOTE" || first.hasPrefix("NOTE ") { return }
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }), timingIndex <= 1 else {
                throw SubtitleError.malformed
            }
            let timing = lines[timingIndex].components(separatedBy: "-->")
            guard timing.count == 2,
                  let start = Self.timestamp(timing[0].trimmingCharacters(in: .whitespaces)),
                  let endToken = timing[1].split(whereSeparator: { $0.isWhitespace }).first,
                  let end = Self.timestamp(String(endToken)), end > start else { throw SubtitleError.malformed }
            let text = Self.plainText(lines.dropFirst(timingIndex + 1).joined(separator: "\n"))
            guard !text.isEmpty else { throw SubtitleError.malformed }
            parsed.append(SubtitleCue(start: start, end: end, text: text))
        }
        for line in normalized.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { try consume() }
            else { lines.append(line) }
        }
        try consume()
        guard !parsed.isEmpty else { throw SubtitleError.malformed }
        cues = parsed.sorted { $0.start < $1.start }
        var latestEnd = 0.0
        maximumEnds = cues.map { latestEnd = max(latestEnd, $0.end); return latestEnd }
    }

    func text(at time: Double) -> String {
        guard time.isFinite, time >= 0 else { return "" }
        var low = 0
        var high = cues.count
        while low < high {
            let middle = (low + high) / 2
            if cues[middle].start <= time { low = middle + 1 } else { high = middle }
        }
        var active: [String] = []
        var index = low - 1
        while index >= 0 && maximumEnds[index] > time {
            let cue = cues[index]
            if cue.end > time { active.append(cue.text) }
            index -= 1
        }
        return active.reversed().joined(separator: "\n")
    }

    private static func timestamp(_ value: String) -> Double? {
        let pieces = value.replacingOccurrences(of: ",", with: ".").split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 2 || pieces.count == 3,
              let seconds = Double(pieces.last!), seconds.isFinite, (0..<60).contains(seconds),
              let minutes = Int(pieces[pieces.count - 2]), (0..<60).contains(minutes) else { return nil }
        let hours = pieces.count == 3 ? Int(pieces[0]) : 0
        guard let hours, hours >= 0 else { return nil }
        return Double(hours) * 3600 + Double(minutes) * 60 + seconds
    }

    private static func plainText(_ text: String) -> String {
        var result = text.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
        for (entity, replacement) in [("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Each media item owns a cache. Successful files and in-flight tasks are reused;
/// failures are deliberately not cached so selecting the track can retry.
actor SubtitleFileCache {
    typealias Fetch = @Sendable (URL) async throws -> Data
    private let fetch: Fetch
    private var files: [URL: SubtitleDocument] = [:]
    private var requests: [URL: Task<SubtitleDocument, Error>] = [:]

    init(fetch: @escaping Fetch = { try await SubtitleFileCache.download($0) }) { self.fetch = fetch }

    func document(for url: URL) async throws -> SubtitleDocument {
        if let cached = files[url] { return cached }
        if let pending = requests[url] { return try await pending.value }
        let fetch = self.fetch
        let task = Task { try SubtitleDocument(data: await fetch(url)) }
        requests[url] = task
        do {
            let document = try await task.value
            files[url] = document
            requests[url] = nil
            return document
        } catch {
            requests[url] = nil
            throw error
        }
    }

    func cancel() {
        requests.values.forEach { $0.cancel() }
        requests.removeAll()
    }

    private static func download(_ url: URL) async throws -> Data {
        if url.isFileURL {
            return try await Task.detached {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return try Data(contentsOf: url, options: .mappedIfSafe)
            }.value
        }
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw SubtitleError.malformed }
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw SubtitleError.malformed }
        guard (200...299).contains(response.statusCode) else { throw SubtitleError.http(response.statusCode) }
        let limit = 5 * 1024 * 1024
        guard response.expectedContentLength <= limit else { throw SubtitleError.tooLarge }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw SubtitleError.tooLarge }
            data.append(byte)
        }
        return data
    }
}
