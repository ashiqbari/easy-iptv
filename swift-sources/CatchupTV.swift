import SwiftUI

public struct CatchupInfo: Codable, Hashable, Sendable {
    public let mode: String
    public let days: Int
    public let source: String?
    public let timezone: String?

    func url(for channel: M3UItem, program: GuideProgram, now: Date = Date()) -> URL? {
        guard channel.contentType == .live, days > 0, days <= 365, program.start.timeIntervalSince1970.isFinite,
              program.end.timeIntervalSince1970.isFinite, program.end > program.start,
              program.end <= now, program.start >= now.addingTimeInterval(-Double(days) * 86400) else { return nil }
        let seconds = Int(ceil(program.end.timeIntervalSince(program.start)))
        guard seconds > 0, seconds <= 86400 else { return nil }
        var text: String
        if mode == "xc" {
            guard var parts = URLComponents(url: channel.streamURL, resolvingAgainstBaseURL: false),
                  let live = parts.percentEncodedPath.range(of: "/live/", options: .backwards) else { return nil }
            let suffix = String(parts.percentEncodedPath[live.upperBound...]).split(separator: "/")
            guard suffix.count == 3 else { return nil }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            // shortcut: Xtream providers omitting their server zone use UTC; add a per-source override if such a provider needs local time.
            formatter.timeZone = timezone.flatMap(TimeZone.init(identifier:)) ?? TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd:HH-mm"
            parts.percentEncodedPath = String(parts.percentEncodedPath[..<live.lowerBound]) + "/timeshift/\(suffix[0])/\(suffix[1])/\(Int(ceil(Double(seconds) / 60)))/\(formatter.string(from: program.start))/\(suffix[2])"
            parts.query = nil; parts.fragment = nil
            return Self.validURL(parts.url?.absoluteString)
        } else {
            guard ["default", "append"].contains(mode), let source, !source.isEmpty else { return nil }
            text = mode == "append" ? channel.streamURL.absoluteString + source : source
        }
        let values = ["{utc}": String(Int(program.start.timeIntervalSince1970)),
                      "{utcend}": String(Int(program.end.timeIntervalSince1970)),
                      "{lutc}": String(Int(now.timeIntervalSince1970)), "{duration}": String(seconds),
                      "${start}": String(Int(program.start.timeIntervalSince1970)),
                      "${end}": String(Int(program.end.timeIntervalSince1970)),
                      "${duration}": String(seconds), "${now}": String(Int(now.timeIntervalSince1970)),
                      "{duration:60}": String(Int(ceil(Double(seconds) / 60)))]
        for (token, value) in values { text = text.replacingOccurrences(of: token, with: value) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for (token, format) in [("Y", "yyyy"), ("m", "MM"), ("d", "dd"), ("H", "HH"), ("M", "mm"), ("S", "ss")] {
            formatter.dateFormat = format
            text = text.replacingOccurrences(of: "{\(token)}", with: formatter.string(from: program.start))
        }
        guard !text.contains("{"), !text.contains("}") else { return nil }
        return Self.validURL(text)
    }
    private static func validURL(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else { return nil }
        return url
    }
}

struct CatchupView: View {
    let channel: M3UItem
    @ObservedObject var manager: IPTVPlayerManager
    @Environment(\.appPalette) private var palette
    @Environment(\.dismiss) private var dismiss
    @State private var programs: [GuideProgram] = []
    @State private var loading = false
    @State private var error: String?
    @State private var retry = 0
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text(channel.name).font(.headline)
                Text("Available recordings depend on your provider's archive and guide.").font(.caption).foregroundStyle(.secondary)
                if loading { ProgressView("Loading past programmes…") }
                if let error { Text(error).foregroundStyle(.secondary) }
                if !loading, programs.isEmpty, error == nil { Text("No past programmes are available in this channel's archive window.") }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(programs) { program in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(program.title).font(.headline)
                                    Text(program.timeRange).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Watch") { manager.playCatchup(channel, program: program); dismiss() }
                            }.padding(12).background(palette.surface, in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
            }.padding(20).background(palette.background)
            .navigationTitle("Catch-up TV")
            .toolbar {
                ToolbarItem { Button("Refresh") { retry += 1 }.disabled(loading) }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .frame(minWidth: 420, idealWidth: 600, minHeight: 400)
        .task(id: retry) {
            loading = true; error = nil
            do {
                let result = try await TVGuide().loadCatchup(for: channel)
                try Task.checkCancellation()
                let now = Date()
                programs = result.filter { channel.catchup?.url(for: channel, program: $0, now: now) != nil }.sorted { $0.start > $1.start }
            } catch {
                guard !Task.isCancelled else { return }
                self.error = "Past listings couldn't be loaded. Check the connection and try Refresh."
            }
            loading = false
        }
    }
}
