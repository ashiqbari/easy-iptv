//
//  M3UItem.swift
//  IPTVPlayer
//
//  Created for iOS 16+ and macOS 13+
//

import Foundation

/// Represents a single channel or stream item parsed from an M3U / M3U8 playlist or Xtream Codes server.
public struct M3UItem: Identifiable, Hashable, Codable, Sendable {
    
    // MARK: - Content Categorization Enum
    
    /// The fundamental 3-category taxonomy for IPTV content: Live TV, Movies (VOD), and TV Shows (Series).
    public enum ContentType: String, Codable, Sendable, CaseIterable {
        case live = "Live TV"
        case movie = "Movies"
        case series = "TV Shows"
        
        public var iconName: String {
            switch self {
            case .live: return "tv"
            case .movie: return "film"
            case .series: return "play.tv"
            }
        }
    }
    
    // MARK: - Properties
    
    /// Unique identifier for SwiftUI list rendering and identity tracking.
    public let id: UUID
    
    /// Display name of the channel or media title.
    public let name: String
    
    /// Categorization or genre (e.g. "News", "Action Movies", "Sci-Fi Series").
    public let groupTitle: String
    
    /// Optional HTTP/HTTPS URL pointing to the channel's icon/logo.
    public let logoURL: URL?
    
    /// The media stream endpoint (HLS `.m3u8`, `.mp4`, or direct transport stream).
    public let streamURL: URL
    
    /// Optional unique identifier string from `tvg-id` tag.
    public let tvgID: String?
    
    /// Optional EPG identifier string from `tvg-name` tag.
    public let tvgName: String?
    
    /// Flag indicating if the user has marked this channel as a favorite.
    public var isFavorite: Bool
    
    /// The primary content type (Live TV, Movie, or TV Show).
    public let contentType: ContentType
    
    // MARK: - Initializer
    
    public init(
        id: UUID = UUID(),
        name: String,
        groupTitle: String = "General",
        logoURL: URL? = nil,
        streamURL: URL,
        tvgID: String? = nil,
        tvgName: String? = nil,
        isFavorite: Bool = false,
        contentType: ContentType? = nil
    ) {
        self.id = id
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = cleanName.isEmpty ? "Unnamed Stream" : cleanName
        
        let cleanGroup = groupTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        self.groupTitle = cleanGroup.isEmpty ? "General" : cleanGroup
        self.logoURL = logoURL
        self.streamURL = streamURL
        self.tvgID = tvgID
        self.tvgName = tvgName
        self.isFavorite = isFavorite
        
        // Auto-detect content classification if not explicitly provided
        if let explicit = contentType {
            self.contentType = explicit
        } else {
            self.contentType = Self.detectType(group: cleanGroup, name: cleanName, url: streamURL)
        }
    }
    
    // MARK: - Smart Auto-Classification
    
    /// Classifies an IPTV stream into Live TV, Movies, or TV Shows based on metadata patterns.
    public static func detectType(group: String, name: String, url: URL) -> ContentType {
        let g = group.lowercased()
        let n = name.lowercased()
        let u = url.absoluteString.lowercased()
        
        // TV Shows / Series
        if g.contains("series") || g.contains("tv show") || g.contains("season") || g.contains("temporada") ||
           u.contains("/series/") ||
           n.contains(" s0") || n.contains(" s1") || n.contains(" s2") || n.contains(" e0") || n.contains(" e1") ||
           n.contains("season ") || n.contains("episode ") || n.contains("[series]") {
            return .series
        }
        
        // Movies / VOD
        if g.contains("movie") || g.contains("vod") || g.contains("cinema") || g.contains("film") ||
           g.contains("pelicula") || u.contains("/movie/") ||
           u.hasSuffix(".mp4") || u.hasSuffix(".mkv") || u.hasSuffix(".avi") {
            return .movie
        }
        
        // Default: Live TV
        return .live
    }
    
    // MARK: - Computed Helpers
    
    /// Formatted category name suitable for display in UI headers.
    public var displayGroup: String {
        return groupTitle.isEmpty ? "General" : groupTitle
    }
    
    /// Determines whether the item points to an Apple HTTP Live Streaming (HLS) playlist.
    public var isHLS: Bool {
        let pathExtension = streamURL.pathExtension.lowercased()
        let absoluteString = streamURL.absoluteString.lowercased()
        return pathExtension == "m3u8" || absoluteString.contains(".m3u8")
    }
    
    /// Determines whether the item points to an MP4 video container.
    public var isMP4: Bool {
        let pathExtension = streamURL.pathExtension.lowercased()
        let absoluteString = streamURL.absoluteString.lowercased()
        return pathExtension == "mp4" || absoluteString.contains(".mp4")
    }
    
    /// Indicates whether the media item is Video-on-Demand (Movie or TV Show).
    public var isVOD: Bool {
        return contentType == .movie || contentType == .series || isMP4
    }
}

// MARK: - Sample Data for Previews and Testing
extension M3UItem {
    public static let sampleItems: [M3UItem] = []
}
