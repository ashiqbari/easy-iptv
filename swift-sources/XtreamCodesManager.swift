//
//  XtreamCodesManager.swift
//  IPTVPlayer
//
//  Created for iOS 16+ and macOS 13+
//

import Foundation

// MARK: - Xtream Codes Data Models

/// Account and subscription information returned by `player_api.php`.
public struct XtreamUserInfo: Codable, Sendable {
    public let username: String?
    public let password: String?
    public let status: String?
    public let expDate: String?
    public let isTrial: String?
    public let activeCons: String?
    public let maxConnections: String?
    public let auth: Int?
    
    enum CodingKeys: String, CodingKey {
        case username
        case password
        case status
        case expDate = "exp_date"
        case isTrial = "is_trial"
        case activeCons = "active_cons"
        case maxConnections = "max_connections"
        case auth
    }
}

/// Server capabilities and environment details returned by `player_api.php`.
public struct XtreamServerInfo: Codable, Sendable {
    public let url: String?
    public let port: String?
    public let httpsPort: String?
    public let serverProtocol: String?
    public let rtmpPort: String?
    public let timezone: String?
    public let timestampNow: Int?
    public let timeNow: String?
    
    enum CodingKeys: String, CodingKey {
        case url
        case port
        case httpsPort = "https_port"
        case serverProtocol = "server_protocol"
        case rtmpPort = "rtmp_port"
        case timezone
        case timestampNow = "timestamp_now"
        case timeNow = "time_now"
    }
}

/// The top-level response returned when authenticating with `player_api.php`.
public struct XtreamAuthResponse: Codable, Sendable {
    public let userInfo: XtreamUserInfo?
    public let serverInfo: XtreamServerInfo?
    
    enum CodingKeys: String, CodingKey {
        case userInfo = "user_info"
        case serverInfo = "server_info"
    }
}

/// Category metadata returned by `action=get_live_categories` or `get_vod_categories`.
public struct XtreamCategory: Codable, Sendable {
    public let categoryId: String
    public let categoryName: String
    public let parentId: Int?
    
    enum CodingKeys: String, CodingKey {
        case categoryId = "category_id"
        case categoryName = "category_name"
        case parentId = "parent_id"
    }
}

/// Live channel stream metadata returned by `action=get_live_streams`.
public struct XtreamLiveStream: Codable, Sendable {
    public let num: Int?
    public let name: String
    public let streamType: String?
    public let streamId: Int
    public let streamIcon: String?
    public let epgChannelId: String?
    public let added: String?
    public let categoryId: String?
    public let customSid: String?
    public let tvArchive: Int?
    public let directSource: String?
    
    enum CodingKeys: String, CodingKey {
        case num
        case name
        case streamType = "stream_type"
        case streamId = "stream_id"
        case streamIcon = "stream_icon"
        case epgChannelId = "epg_channel_id"
        case added
        case categoryId = "category_id"
        case customSid = "custom_sid"
        case tvArchive = "tv_archive"
        case directSource = "direct_source"
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.num = try? container.decodeIfPresent(Int.self, forKey: .num)
        self.name = (try? container.decode(String.self, forKey: .name)) ?? "Live Channel"
        self.streamType = try? container.decodeIfPresent(String.self, forKey: .streamType)
        self.streamIcon = try? container.decodeIfPresent(String.self, forKey: .streamIcon)
        self.epgChannelId = try? container.decodeIfPresent(String.self, forKey: .epgChannelId)
        self.added = try? container.decodeIfPresent(String.self, forKey: .added)
        self.categoryId = try? container.decodeIfPresent(String.self, forKey: .categoryId)
        self.customSid = try? container.decodeIfPresent(String.self, forKey: .customSid)
        self.tvArchive = try? container.decodeIfPresent(Int.self, forKey: .tvArchive)
        self.directSource = try? container.decodeIfPresent(String.self, forKey: .directSource)
        
        if let idInt = try? container.decode(Int.self, forKey: .streamId) {
            self.streamId = idInt
        } else if let idStr = try? container.decode(String.self, forKey: .streamId), let parsedInt = Int(idStr) {
            self.streamId = parsedInt
        } else {
            self.streamId = 0
        }
    }
}

/// VOD Movie metadata returned by `action=get_vod_streams`.
public struct XtreamVodStream: Codable, Sendable {
    public let streamId: Int
    public let name: String
    public let streamIcon: String?
    public let categoryId: String?
    public let containerExtension: String?
    
    enum CodingKeys: String, CodingKey {
        case streamId = "stream_id"
        case name
        case streamIcon = "stream_icon"
        case categoryId = "category_id"
        case containerExtension = "container_extension"
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = (try? container.decode(String.self, forKey: .name)) ?? "Movie"
        self.streamIcon = try? container.decodeIfPresent(String.self, forKey: .streamIcon)
        self.categoryId = try? container.decodeIfPresent(String.self, forKey: .categoryId)
        self.containerExtension = try? container.decodeIfPresent(String.self, forKey: .containerExtension)
        
        if let idInt = try? container.decode(Int.self, forKey: .streamId) {
            self.streamId = idInt
        } else if let idStr = try? container.decode(String.self, forKey: .streamId), let parsedInt = Int(idStr) {
            self.streamId = parsedInt
        } else {
            self.streamId = 0
        }
    }
}

/// Series metadata returned by `action=get_series`.
public struct XtreamSeriesItem: Codable, Sendable {
    public let seriesId: Int
    public let name: String
    public let cover: String?
    public let categoryId: String?
    
    enum CodingKeys: String, CodingKey {
        case seriesId = "series_id"
        case name
        case cover
        case categoryId = "category_id"
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = (try? container.decode(String.self, forKey: .name)) ?? "TV Series"
        self.cover = try? container.decodeIfPresent(String.self, forKey: .cover)
        self.categoryId = try? container.decodeIfPresent(String.self, forKey: .categoryId)
        
        if let idInt = try? container.decode(Int.self, forKey: .seriesId) {
            self.seriesId = idInt
        } else if let idStr = try? container.decode(String.self, forKey: .seriesId), let parsedInt = Int(idStr) {
            self.seriesId = parsedInt
        } else {
            self.seriesId = 0
        }
    }
}

/// Errors specific to Xtream Codes API communication and parsing.
public enum XtreamCodesError: LocalizedError, Sendable {
    case invalidServerURL
    case authenticationFailed(String)
    case invalidResponse
    case networkError(String)
    case decodingError(String)
    case noStreamsFound
    
    public var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            return "The Xtream server URL is invalid or malformed."
        case .authenticationFailed(let reason):
            return "Xtream authentication failed: \(reason)"
        case .invalidResponse:
            return "The server did not respond with valid Xtream JSON data."
        case .networkError(let msg):
            return "Network connection to Xtream server failed: \(msg)"
        case .decodingError(let msg):
            return "Failed to decode Xtream response: \(msg)"
        case .noStreamsFound:
            return "Authentication succeeded, but 0 channels were found on this account."
        }
    }
}

/// Actor-isolated asynchronous client for interacting with Xtream Codes IPTV servers.
public actor XtreamCodesManager {
    
    public init() {}
    
    // MARK: - Public API
    
    /// Authenticates with the Xtream server and returns account/server information.
    public func authenticate(serverURL: String, username: String, password: String) async throws -> XtreamAuthResponse {
        let cleanBase = sanitizeBaseURL(serverURL)
        guard let url = URL(string: "\(cleanBase)/player_api.php?username=\(urlEncoded(username))&password=\(urlEncoded(password))") else {
            throw XtreamCodesError.invalidServerURL
        }
        
        let data = try await performRequest(url: url)
        let decoder = JSONDecoder()
        
        do {
            let authResponse = try decoder.decode(XtreamAuthResponse.self, from: data)
            guard let userInfo = authResponse.userInfo else {
                throw XtreamCodesError.authenticationFailed("Server returned an empty user profile.")
            }
            
            if userInfo.auth == 0 && userInfo.status != "Active" {
                throw XtreamCodesError.authenticationFailed("Account status is \(userInfo.status ?? "Inactive"). Please verify subscription.")
            }
            
            return authResponse
        } catch let err as XtreamCodesError {
            throw err
        } catch {
            throw XtreamCodesError.decodingError(error.localizedDescription)
        }
    }
    
    /// Fetches all 3 categories: Live TV, Movies (VOD), and TV Shows (Series).
    public func fetchAllContent(serverURL: String, username: String, password: String) async throws -> [M3UItem] {
        async let liveItems = (try? fetchLiveChannels(serverURL: serverURL, username: username, password: password)) ?? []
        async let movieItems = (try? fetchVodStreams(serverURL: serverURL, username: username, password: password)) ?? []
        async let seriesItems = (try? fetchSeries(serverURL: serverURL, username: username, password: password)) ?? []
        
        let all = await (liveItems + movieItems + seriesItems)
        guard !all.isEmpty else {
            throw XtreamCodesError.noStreamsFound
        }
        return all
    }
    
    /// Fetches live categories and live streams, returning them as `[M3UItem]` tagged with `.live`.
    public func fetchLiveChannels(serverURL: String, username: String, password: String) async throws -> [M3UItem] {
        let cleanBase = sanitizeBaseURL(serverURL)
        let userEnc = urlEncoded(username)
        let passEnc = urlEncoded(password)
        
        // 1. Fetch categories
        let catURLString = "\(cleanBase)/player_api.php?username=\(userEnc)&password=\(passEnc)&action=get_live_categories"
        var categoryMap: [String: String] = [:]
        
        if let catURL = URL(string: catURLString),
           let catData = try? await performRequest(url: catURL) {
            let decoder = JSONDecoder()
            if let categories = try? decoder.decode([XtreamCategory].self, from: catData) {
                for c in categories {
                    categoryMap[c.categoryId] = c.categoryName
                }
            }
        }
        
        // 2. Fetch live streams
        guard let streamURL = URL(string: "\(cleanBase)/player_api.php?username=\(userEnc)&password=\(passEnc)&action=get_live_streams") else {
            throw XtreamCodesError.invalidServerURL
        }
        
        let streamData = try await performRequest(url: streamURL)
        let decoder = JSONDecoder()
        let rawStreams = try decoder.decode([XtreamLiveStream].self, from: streamData)
        
        // 3. Transform to M3UItem
        return rawStreams.compactMap { stream in
            let categoryName = stream.categoryId.flatMap { categoryMap[$0] } ?? "Live Channels"
            let streamEndpoint = "\(cleanBase)/live/\(userEnc)/\(passEnc)/\(stream.streamId).m3u8"
            guard let finalStreamURL = URL(string: streamEndpoint) else { return nil }
            
            return M3UItem(
                name: stream.name,
                groupTitle: categoryName,
                logoURL: stream.streamIcon.flatMap { URL(string: $0) },
                streamURL: finalStreamURL,
                tvgID: stream.epgChannelId,
                tvgName: stream.name,
                isFavorite: false,
                contentType: .live
            )
        }
    }
    
    /// Fetches VOD categories and movie streams, returning them as `[M3UItem]` tagged with `.movie`.
    public func fetchVodStreams(serverURL: String, username: String, password: String) async throws -> [M3UItem] {
        let cleanBase = sanitizeBaseURL(serverURL)
        let userEnc = urlEncoded(username)
        let passEnc = urlEncoded(password)
        
        // 1. Fetch VOD categories
        let catURLString = "\(cleanBase)/player_api.php?username=\(userEnc)&password=\(passEnc)&action=get_vod_categories"
        var categoryMap: [String: String] = [:]
        if let catURL = URL(string: catURLString),
           let catData = try? await performRequest(url: catURL) {
            let decoder = JSONDecoder()
            if let categories = try? decoder.decode([XtreamCategory].self, from: catData) {
                for c in categories { categoryMap[c.categoryId] = c.categoryName }
            }
        }
        
        // 2. Fetch VOD streams
        guard let vodURL = URL(string: "\(cleanBase)/player_api.php?username=\(userEnc)&password=\(passEnc)&action=get_vod_streams") else {
            return []
        }
        
        let streamData = try await performRequest(url: vodURL)
        let decoder = JSONDecoder()
        let rawVod = (try? decoder.decode([XtreamVodStream].self, from: streamData)) ?? []
        
        return rawVod.compactMap { vod in
            let categoryName = vod.categoryId.flatMap { categoryMap[$0] } ?? "Movies"
            let ext = vod.containerExtension ?? "mp4"
            let streamEndpoint = "\(cleanBase)/movie/\(userEnc)/\(passEnc)/\(vod.streamId).\(ext)"
            guard let finalURL = URL(string: streamEndpoint) else { return nil }
            
            return M3UItem(
                name: vod.name,
                groupTitle: categoryName,
                logoURL: vod.streamIcon.flatMap { URL(string: $0) },
                streamURL: finalURL,
                isFavorite: false,
                contentType: .movie
            )
        }
    }
    
    /// Fetches Series categories and TV Shows, returning them as `[M3UItem]` tagged with `.series`.
    public func fetchSeries(serverURL: String, username: String, password: String) async throws -> [M3UItem] {
        let cleanBase = sanitizeBaseURL(serverURL)
        let userEnc = urlEncoded(username)
        let passEnc = urlEncoded(password)
        
        // 1. Fetch Series categories
        let catURLString = "\(cleanBase)/player_api.php?username=\(userEnc)&password=\(passEnc)&action=get_series_categories"
        var categoryMap: [String: String] = [:]
        if let catURL = URL(string: catURLString),
           let catData = try? await performRequest(url: catURL) {
            let decoder = JSONDecoder()
            if let categories = try? decoder.decode([XtreamCategory].self, from: catData) {
                for c in categories { categoryMap[c.categoryId] = c.categoryName }
            }
        }
        
        // 2. Fetch Series list
        guard let seriesURL = URL(string: "\(cleanBase)/player_api.php?username=\(userEnc)&password=\(passEnc)&action=get_series") else {
            return []
        }
        
        let streamData = try await performRequest(url: seriesURL)
        let decoder = JSONDecoder()
        let rawSeries = (try? decoder.decode([XtreamSeriesItem].self, from: streamData)) ?? []
        
        return rawSeries.compactMap { show in
            let categoryName = show.categoryId.flatMap { categoryMap[$0] } ?? "TV Series"
            let streamEndpoint = "\(cleanBase)/series/\(userEnc)/\(passEnc)/\(show.seriesId).mp4"
            guard let finalURL = URL(string: streamEndpoint) else { return nil }
            
            return M3UItem(
                name: show.name,
                groupTitle: categoryName,
                logoURL: show.cover.flatMap { URL(string: $0) },
                streamURL: finalURL,
                isFavorite: false,
                contentType: .series
            )
        }
    }
    
    /// Fetches all playable episodes for a specific series ID from Xtream Codes server.
    public func fetchSeriesEpisodes(serverURL: String, username: String, password: String, seriesId: Int) async throws -> [M3UItem] {
        let cleanBase = sanitizeBaseURL(serverURL)
        let userEnc = urlEncoded(username)
        let passEnc = urlEncoded(password)
        
        guard let url = URL(string: "\(cleanBase)/player_api.php?username=\(userEnc)&password=\(passEnc)&action=get_series_info&series_id=\(seriesId)") else {
            return []
        }
        
        let data = try await performRequest(url: url)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let episodesDict = json["episodes"] as? [String: [[String: Any]]] else {
            return []
        }
        
        var episodeItems: [M3UItem] = []
        let sortedSeasons = episodesDict.keys.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }
        
        for seasonKey in sortedSeasons {
            guard let seasonEps = episodesDict[seasonKey] else { continue }
            for ep in seasonEps {
                guard let epId = ep["id"] else { continue }
                let epIdStr = "\(epId)"
                let title = (ep["title"] as? String) ?? "Episode \(ep["episode_num"] ?? "")"
                let ext = (ep["container_extension"] as? String) ?? "mp4"
                let streamEndpoint = "\(cleanBase)/series/\(userEnc)/\(passEnc)/\(epIdStr).\(ext)"
                guard let finalURL = URL(string: streamEndpoint) else { continue }
                
                episodeItems.append(
                    M3UItem(
                        name: "S\(seasonKey) • \(title)",
                        groupTitle: "Season \(seasonKey)",
                        streamURL: finalURL,
                        contentType: .series
                    )
                )
            }
        }
        return episodeItems
    }
    
    /// Generates the direct M3U Plus playlist download URL for this Xtream account.
    public func directM3UPlusURL(serverURL: String, username: String, password: String) -> URL? {
        let cleanBase = sanitizeBaseURL(serverURL)
        let path = "\(cleanBase)/get.php?username=\(urlEncoded(username))&password=\(urlEncoded(password))&type=m3u_plus&output=m3u8"
        return URL(string: path)
    }
    
    // MARK: - Private Helpers
    
    private func sanitizeBaseURL(_ url: String) -> String {
        var clean = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.lowercased().hasPrefix("http://") && !clean.lowercased().hasPrefix("https://") {
            clean = "http://" + clean
        }
        while clean.hasSuffix("/") {
            clean.removeLast()
        }
        return clean
    }
    
    private func urlEncoded(_ string: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }
    
    private func performRequest(url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 25.0
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 / VLC / AppleCoreMedia", forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        
        let config = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: config)
        
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw XtreamCodesError.invalidResponse
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                throw XtreamCodesError.networkError("Server responded with HTTP \(httpResponse.statusCode)")
            }
            return data
        } catch let err as XtreamCodesError {
            throw err
        } catch {
            throw XtreamCodesError.networkError(error.localizedDescription)
        }
    }
}
