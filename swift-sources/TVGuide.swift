import Foundation

struct GuideProgram: Identifiable, Sendable {
    let title: String
    let description: String
    let start: Date
    let end: Date
    let categories: String
    init(title: String, description: String, start: Date, end: Date, categories: String = "") {
        self.title = title; self.description = description; self.start = start; self.end = end
        self.categories = categories
    }
    var id: String { "\(start.timeIntervalSince1970)|\(end.timeIntervalSince1970)|\(title)" }
    var timeRange: String { "\(start.formatted(date: .abbreviated, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))" }
    var durationMin: Int { Int(end.timeIntervalSince(start) / 60) }
    func isCurrent(at now: Date) -> Bool { start <= now && now < end }
    func progress(at now: Date) -> Double { min(1, max(0, now.timeIntervalSince(start) / end.timeIntervalSince(start))) }
}

enum GuideError: LocalizedError {
    case invalidFeed, tooLarge, download, missingSource, missingChannelID, noMatchingChannel, noUpcomingPrograms, invalidListings
    var errorDescription: String? {
        switch self {
        case .invalidFeed: return "The provider returned an invalid TV guide."
        case .tooLarge: return "The provider's single-channel guide response is unexpectedly large."
        case .download: return "Could not download the TV guide. Please try again."
        case .missingSource: return "This channel has no supported TV guide URL. Refresh your playlist or check its guide configuration."
        case .missingChannelID: return "This channel has no XMLTV channel ID. Its provider did not return a usable channel schedule."
        case .noMatchingChannel: return "The XMLTV guide has no programmes matching the channel IDs in your playlist."
        case .noUpcomingPrograms: return "The provider has no usable current or upcoming programmes for the rest of today."
        case .invalidListings: return "The provider returned listings, but their titles or programme times could not be read."
        }
    }
}

struct ChannelGuideResult: Sendable {
    let programs: [GuideProgram]
    let updatedAt: Date?
    let nextRefresh: Date
    let message: String?
}

actor TVGuide {
    typealias Download = @Sendable (URL) async throws -> URL
    private let download: Download

    init(download: @escaping Download = { try await TVGuide.downloadRequest($0) }) { self.download = download }
    static func feedURL(for item: M3UItem) -> URL? {
        if let url = item.guideURL {
            return ["http", "https"].contains(url.scheme?.lowercased() ?? "") ? url : nil
        }
        let path = item.streamURL.pathComponents
        let index = path.count - 4
        guard item.contentType == .live, index >= 1, path[index] == "live",
              var parts = URLComponents(url: item.streamURL, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? "") else { return nil }
        parts.path = "/" + path.dropFirst().prefix(index - 1).joined(separator: "/")
            + (index > 1 ? "/" : "") + "xmltv.php"
        parts.queryItems = [URLQueryItem(name: "username", value: path[index + 1]),
                            URLQueryItem(name: "password", value: path[index + 2])]
        parts.fragment = nil
        return parts.url
    }

    static func channelRequest(for item: M3UItem) -> URL? {
        guard item.guideURL == nil,
              let streamID = Int(item.streamURL.deletingPathExtension().lastPathComponent), streamID > 0,
              let feed = feedURL(for: item),
              var parts = URLComponents(url: feed, resolvingAgainstBaseURL: false) else { return nil }
        parts.path = feed.deletingLastPathComponent().appendingPathComponent("player_api.php").path
        parts.queryItems = (parts.queryItems ?? []) + [URLQueryItem(name: "action", value: "get_simple_data_table"),
                                                     URLQueryItem(name: "stream_id", value: String(streamID))]
        return parts.url
    }

    static func remainingToday(_ programs: [GuideProgram], now: Date, calendar: Calendar = .current) -> [GuideProgram] {
        let midnight = calendar.dateInterval(of: .day, for: now)?.end ?? now
        return programs.filter { $0.end > now && $0.start < midnight }.sorted { $0.start < $1.start }
    }

    func load(for item: M3UItem) async throws -> [GuideProgram] {
        var channelError: Error?
        if let url = Self.channelRequest(for: item) {
            do {
                let programs = try await loadChannel(url)
                if !programs.isEmpty { return programs }
            } catch {
                try Task.checkCancellation()
                channelError = error
            }
        }
        guard let url = Self.feedURL(for: item), let id = item.tvgID, !id.isEmpty else {
            if let channelError { throw channelError }
            return []
        }
        let file = try await download(url)
        defer { try? FileManager.default.removeItem(at: file) }
        guard let stream = InputStream(url: file) else { throw GuideError.invalidFeed }
        return try Self.parse(XMLParser(stream: stream), channelID: id, now: Date())
    }

    func load(for item: M3UItem, index: GuideSearchIndex, channels: [M3UItem], force: Bool) async throws -> ChannelGuideResult {
        var summary: GuideRefreshSummary?
        var feedError: Error?
        var channelError: Error?
        if Self.feedURL(for: item) != nil, !(item.tvgID ?? "").isEmpty {
            do {
                summary = try await index.refresh(channels: channels, force: force)
                let programs = try await index.programs(for: item)
                if !programs.isEmpty {
                    let status = try await index.downloadStatus(for: item)
                    return ChannelGuideResult(programs: programs, updatedAt: status.updatedAt,
                                              nextRefresh: summary?.nextRefresh ?? Date().addingTimeInterval(60),
                                              message: status.failed ? "Refresh failed for this channel's guide. Showing cached listings." : nil)
                }
            } catch {
                try Task.checkCancellation()
                feedError = error
            }
        }
        if let url = Self.channelRequest(for: item) {
            do {
                let programs = try await loadChannel(url)
                if !programs.isEmpty {
                    let nextRefresh = summary?.nextRefresh ?? Date().addingTimeInterval(feedError == nil ? 10_800 : 60)
                    return ChannelGuideResult(programs: programs, updatedAt: Date(),
                                              nextRefresh: min(nextRefresh, Calendar.current.dateInterval(of: .day, for: Date())?.end ?? Date()),
                                              message: "Using the provider's channel schedule; XMLTV listings for this channel are unavailable.")
                }
            } catch {
                try Task.checkCancellation()
                channelError = error
            }
        }
        if Self.feedURL(for: item) == nil { throw GuideError.missingSource }
        if (item.tvgID ?? "").isEmpty { throw GuideError.missingChannelID }
        if let feedError { throw feedError }
        if let message = summary?.failureMessage {
            let channelMessage = channelError.map { " Channel schedule: \($0.localizedDescription)" } ?? ""
            throw NSError(domain: "TVGuide", code: 1, userInfo: [NSLocalizedDescriptionKey: message + channelMessage])
        }
        if let channelError { throw channelError }
        throw GuideError.noUpcomingPrograms
    }

    private func loadChannel(_ url: URL) async throws -> [GuideProgram] {
        let file = try await download(url)
        defer { try? FileManager.default.removeItem(at: file) }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 8 * 1024 * 1024 else { throw GuideError.tooLarge }
        return Self.remainingToday(try Self.parseChannel(Data(contentsOf: file, options: .mappedIfSafe)), now: Date())
    }

    private static func downloadRequest(_ url: URL) async throws -> URL {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 45
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 90
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let file: URL
        do {
            let response: URLResponse
            (file, response) = try await session.download(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                try? FileManager.default.removeItem(at: file)
                throw GuideError.download
            }
        } catch let error as GuideError { throw error }
        catch {
            try Task.checkCancellation()
            throw GuideError.download
        }
        if Task.isCancelled {
            try? FileManager.default.removeItem(at: file)
            throw CancellationError()
        }
        return file
    }

    static func parse(_ data: Data, channelID: String) throws -> [GuideProgram] {
        try parse(XMLParser(data: data), channelID: channelID, now: nil)
    }

    static func parse(_ parser: XMLParser, channelID: String, now: Date?, calendar: Calendar = .current) throws -> [GuideProgram] {
        let delegate = XMLTVPrograms(channelID: channelID, now: now, calendar: calendar)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        let parsed = parser.parse()
        try Task.checkCancellation()
        if let error = delegate.failure { throw error }
        guard parsed, delegate.isTV else { throw GuideError.invalidFeed }
        return delegate.programs.sorted { $0.start < $1.start }
    }

    static func parseChannel(_ data: Data) throws -> [GuideProgram] {
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let listings = response["epg_listings"] as? [[String: Any]] else { throw GuideError.invalidFeed }
        func timestamp(_ value: Any?) -> Double? {
            let result = (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
            return result.flatMap { $0.isFinite ? $0 : nil }
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let server = response["server_info"] as? [String: Any]
        // shortcut: dates without an advertised zone use UTC; add provider-specific offsets if a provider omits its zone.
        formatter.timeZone = (server?["timezone"] as? String).flatMap(TimeZone.init(identifier:)) ?? TimeZone(secondsFromGMT: 0)
        func date(_ values: [Any?]) -> Date? {
            for value in values {
                if let seconds = timestamp(value) { return Date(timeIntervalSince1970: seconds) }
                if let text = value as? String,
                   let date = ISO8601DateFormatter().date(from: text) ?? formatter.date(from: text) { return date }
            }
            return nil
        }
        func text(_ value: Any?) -> String {
            guard let value = value as? String else { return "" }
            return (Data(base64Encoded: value).flatMap { String(data: $0, encoding: .utf8) } ?? value)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let programs: [GuideProgram] = listings.compactMap { listing in
            guard let start = date([listing["start_timestamp"], listing["start"]]),
                  let end = date([listing["stop_timestamp"], listing["end_timestamp"], listing["end"], listing["stop"]]), end > start else { return nil }
            let title = text(listing["title"])
            guard !title.isEmpty else { return nil }
            return GuideProgram(title: title, description: text(listing["description"]),
                                start: start, end: end)
        }
        if !listings.isEmpty, programs.isEmpty { throw GuideError.invalidListings }
        return programs
    }
}

final class XMLTVPrograms: NSObject, XMLParserDelegate {
    let channelID: String
    private let now: Date?
    private let midnight: Date?
    var isTV = false
    private var sawRoot = false
    var programs: [GuideProgram] = []
    var failure: Error?
    var matchedChannels = Set<String>()
    private let channelIDs: Set<String>?
    private let receive: ((String, GuideProgram) throws -> Void)?
    private var currentChannel = ""
    private var categories = ""
    private var depth = 0
    private let formatter = DateFormatter()
    private var selected = false
    private var start: Date?
    private var end: Date?
    private var title = ""
    private var details = ""
    private var field: String?
    private var text = ""

    init(channelID: String = "", channelIDs: Set<String>? = nil, now: Date?, calendar: Calendar,
         receive: ((String, GuideProgram) throws -> Void)? = nil) {
        self.channelID = channelID
        self.channelIDs = channelIDs
        self.receive = receive
        self.now = now
        self.midnight = now.flatMap { calendar.dateInterval(of: .day, for: $0)?.end }
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.isLenient = false
    }

    private func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let parts = value.split(whereSeparator: { $0.isWhitespace })
        guard let stamp = parts.first, [12, 14].contains(stamp.count), stamp.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        let zone = parts.count > 1 ? String(parts[1]) : "+0000"
        guard zone.count == 5, ["+", "-"].contains(String(zone.prefix(1))), zone.dropFirst().allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        let format = stamp.count == 14 ? "yyyyMMddHHmmss Z" : "yyyyMMddHHmm Z"
        if formatter.dateFormat != format { formatter.dateFormat = format }
        return formatter.date(from: "\(stamp) \(zone)")
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if Task.isCancelled { parser.abortParsing(); return }
        depth += 1
        guard depth <= 64, attributes.values.allSatisfy({ $0.utf8.count <= 16_384 }) else {
            failure = GuideError.invalidFeed; parser.abortParsing(); return
        }
        if !sawRoot { isTV = name == "tv"; sawRoot = true }
        if name == "programme" {
            currentChannel = attributes["channel"] ?? ""
            selected = channelIDs?.contains(currentChannel) ?? (currentChannel == channelID)
            if selected { matchedChannels.insert(currentChannel) }
            start = selected ? date(attributes["start"]) : nil
            end = selected ? date(attributes["stop"]) : nil
            if let now, let midnight, let start, let end {
                selected = selected && end > now && start < midnight
            }
            title = ""; details = ""; categories = ""; field = nil
        } else if selected && ["title", "desc", "category"].contains(name) {
            field = name; text = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if Task.isCancelled { parser.abortParsing(); return }
        if field != nil { text += string.prefix(max(0, 8_192 - text.count)) }
    }
    func parser(_ parser: XMLParser, foundCDATA data: Data) {
        self.parser(parser, foundCharacters: String(decoding: data.prefix(32_768), as: UTF8.self))
    }
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        failure = GuideError.invalidFeed; parser.abortParsing()
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        depth -= 1
        if name == field {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if name == "title", title.isEmpty { title = String(value.prefix(1_024)) }
            if name == "desc", details.isEmpty { details = value }
            if name == "category" { categories = String((categories + " " + value).prefix(1_024)) }
            field = nil
        }
        if name == "programme" {
            if selected, let start, let end, end > start, !title.isEmpty {
                let program = GuideProgram(title: title, description: details, start: start, end: end, categories: categories)
                if let receive {
                    do { try receive(currentChannel, program) }
                    catch { failure = error; parser.abortParsing() }
                } else { programs.append(program) }
            }
            selected = false; field = nil
        }
    }
}
