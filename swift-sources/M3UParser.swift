//
//  M3UParser.swift
//  IPTVPlayer
//
//  Created for iOS 16+ and macOS 13+
//

import Foundation

/// Errors that can occur during M3U/M3U8 playlist downloading and parsing.
public enum M3UParserError: LocalizedError, Sendable {
    case invalidURL
    case downloadFailed(String)
    case invalidEncoding
    case emptyPlaylist
    case corruptedData
    
    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The playlist URL provided is invalid or malformed."
        case .downloadFailed(let reason):
            return "Failed to download the M3U playlist: \(reason)"
        case .invalidEncoding:
            return "Unable to decode playlist content. Expected UTF-8 or Latin-1 text encoding."
        case .emptyPlaylist:
            return "The playlist was parsed successfully but contained 0 valid channels."
        case .corruptedData:
            return "The playlist does not follow the standard Extended M3U format."
        }
    }
}

/// An asynchronous, high-performance parser designed for `#EXTINF` directives in M3U/M3U8 playlists.
public actor M3UParser {
    
    public init() {}
    
    // MARK: - Public API
    
    /// Downloads and parses an M3U playlist from a remote HTTP/HTTPS URL asynchronously.
    /// - Parameter url: The remote playlist URL.
    /// - Returns: An array of structured `M3UItem` instances.
    public func parse(from url: URL) async throws -> [M3UItem] {
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw M3UParserError.downloadFailed(error.localizedDescription)
        }
        
        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            throw M3UParserError.downloadFailed("HTTP Status \(httpResponse.statusCode)")
        }
        
        guard let contentString = String(data: data, encoding: .utf8) ??
                                 String(data: data, encoding: .isoLatin1) ??
                                 String(data: data, encoding: .ascii) else {
            throw M3UParserError.invalidEncoding
        }
        
        return try parse(string: contentString)
    }
    
    /// Parses an M3U playlist from an in-memory string representation using high-speed line enumeration.
    /// - Parameter content: Raw string containing `#EXTM3U` and `#EXTINF` lines.
    /// - Returns: An array of `M3UItem` instances.
    public func parse(string content: String) throws -> [M3UItem] {
        var items: [M3UItem] = []
        items.reserveCapacity(4000)
        var pendingExtInf: String? = nil
        
        content.enumerateLines { rawLine, _ in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                return
            }
            
            if line.hasPrefix("#EXTINF:") {
                pendingExtInf = line
                return
            }
            
            // Skip other comment tags like #EXTM3U, #EXTVLCOPT, etc.
            if line.hasPrefix("#") {
                return
            }
            
            // Non-comment line following an EXTINF directive is the stream URL
            if let extInf = pendingExtInf {
                let cleanURLString = line.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? line
                if let streamURL = URL(string: cleanURLString) ?? URL(string: line) {
                    let parsedItem = Self.parseExtInf(extInf: extInf, streamURL: streamURL)
                    items.append(parsedItem)
                }
                pendingExtInf = nil
            }
        }
        
        guard !items.isEmpty else {
            throw M3UParserError.emptyPlaylist
        }
        
        return items
    }
    
    // MARK: - Private Parser Core
    
    /// Extracts metadata fields (`tvg-name`, `group-title`, `tvg-logo`, channel title) from a single `#EXTINF` line.
    private static func parseExtInf(extInf: String, streamURL: URL) -> M3UItem {
        let tvgName = extractAttribute(named: "tvg-name", from: extInf)
        let tvgID = extractAttribute(named: "tvg-id", from: extInf)
        let groupTitle = extractAttribute(named: "group-title", from: extInf) ?? "General"
        let logoURLString = extractAttribute(named: "tvg-logo", from: extInf)
        let logoURL = logoURLString.flatMap { URL(string: $0) }
        
        // Extract channel name:
        // In standard M3U, the display name comes after the last comma:
        // #EXTINF:-1 tvg-name="Foo" group-title="Bar",Display Name Here
        var displayName: String = ""
        if let commaIndex = extInf.lastIndex(of: ",") {
            let substring = extInf[extInf.index(after: commaIndex)...]
            displayName = substring.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        // If display name is empty, fallback to tvg-name or the URL filename
        if displayName.isEmpty {
            displayName = tvgName ?? streamURL.lastPathComponent
        }
        
        return M3UItem(
            name: displayName,
            groupTitle: groupTitle,
            logoURL: logoURL,
            streamURL: streamURL,
            tvgID: tvgID,
            tvgName: tvgName,
            isFavorite: false
        )
    }
    
    /// Ultra-fast attribute extraction matching `attributeName="value"` or `attributeName='value'`
    /// without NSRegularExpression compilation overhead.
    private static func extractAttribute(named attributeName: String, from text: String) -> String? {
        let nameLower = attributeName.lowercased()
        let textLower = text.lowercased()
        
        for quote in ["\"", "'"] {
            let prefix = nameLower + "=" + quote
            if let range = textLower.range(of: prefix) {
                let valStart = range.upperBound
                if let endIdx = text[valStart...].firstIndex(of: Character(quote)) {
                    let value = String(text[valStart..<endIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
                    return value.isEmpty ? nil : value
                }
            }
        }
        return nil
    }
}
