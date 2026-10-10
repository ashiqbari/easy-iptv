import SwiftUI

struct SeriesDetails: Sendable {
    let details: MediaDetails?
    let episodes: [M3UItem]
}

struct MediaDetails: Sendable {
    var title: String?
    var poster: URL?
    var backdrop: URL?
    var year: String?
    var runtime: String?
    var rating: String?
    var certification: String?
    var genres: String?
    var plot: String?
    var cast: String?
    var director: String?
    var writer: String?
    var producer: String?
    var trailer: URL?
    var recommendedIDs: [String] = []

    static func parse(_ data: Data) throws -> MediaDetails {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["info"] is [String: Any] || root["movie_data"] is [String: Any] else {
            throw XtreamCodesError.invalidResponse
        }
        let info = root["info"] as? [String: Any] ?? [:]
        let movie = root["movie_data"] as? [String: Any] ?? [:]
        func text(_ value: Any?) -> String? {
            let raw: String?
            if let string = value as? String { raw = string }
            else if let number = value as? NSNumber { raw = number.stringValue }
            else if let values = value as? [String] { raw = values.joined(separator: ", ") }
            else { raw = nil }
            guard let result = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !result.isEmpty, !["null", "n/a"].contains(result.lowercased()) else { return nil }
            return result
        }
        func field(_ keys: String...) -> String? {
            keys.lazy.compactMap { text(info[$0]) ?? text(movie[$0]) }.first
        }
        func image(_ keys: String...) -> URL? {
            for key in keys {
                let values = info[key] as? [String] ?? [text(info[key]) ?? text(movie[key]) ?? ""]
                if let url = values.compactMap({ webURL($0) }).first { return url }
            }
            return nil
        }
        var result = MediaDetails()
        result.title = field("name", "title")
        result.poster = image("movie_image", "cover", "poster")
        result.backdrop = image("backdrop_path", "backdrop", "banner")
        let release = field("releasedate", "releaseDate", "release_date", "year")
        if let release, release.prefix(4).allSatisfy(\.isNumber), release.count >= 4 {
            result.year = String(release.prefix(4))
        }
        if let seconds = field("duration_secs"), let duration = Double(seconds), duration.isFinite,
           duration > 0, duration / 60 < Double(Int.max) {
            result.runtime = "\(max(1, Int(duration / 60))) min"
        } else if let minutes = field("episode_run_time"), let value = Double(minutes), value.isFinite, value > 0 {
            result.runtime = "\(minutes) min/ep"
        } else { result.runtime = field("duration", "runtime") }
        result.rating = field("rating", "rating_5based")
        result.certification = field("certification", "age_rating", "mpaa_rating")
        result.genres = field("genre", "genres")
        result.plot = field("plot", "description", "overview")
        result.cast = field("cast", "actors")
        result.director = field("director")
        result.writer = field("writer", "screenwriter")
        result.producer = field("producer")
        if let trailer = field("trailer", "trailer_url", "youtube_trailer") {
            result.trailer = webURL(trailer)
            if result.trailer == nil, trailer.count == 11,
               trailer.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) {
                result.trailer = URL(string: "https://www.youtube.com/watch?v=\(trailer)")
            }
        }
        let recommendations = root["recommendations"] ?? root["similar"] ?? info["recommendations"] ?? info["similar"]
        if let values = recommendations as? [Any] {
            result.recommendedIDs = values.compactMap { value in
                if let movie = value as? [String: Any] { return text(movie["stream_id"] ?? movie["vod_id"]) }
                return text(value)
            }
        }
        return result
    }

    private static func webURL(_ value: String) -> URL? {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host != nil else { return nil }
        return url
    }
}

struct MovieDetailsView: View {
    let item: M3UItem
    @ObservedObject var manager: IPTVPlayerManager
    @State private var details: MediaDetails?
    @State private var loading = true
    @State private var failed = false
    @State private var retry = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Button { manager.stop() } label: { Label("Back to Movies", systemImage: "chevron.left") }
                    .buttonStyle(.plain)
                if let backdrop = details?.backdrop {
                    AsyncImage(url: backdrop) { image in
                        image.resizable().scaledToFill()
                    } placeholder: { Color.white.opacity(0.08) }
                    .frame(maxWidth: .infinity).frame(height: 180).clipped().cornerRadius(12)
                    .accessibilityHidden(true)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 24) {
                        poster
                        information.frame(minWidth: 240, maxWidth: .infinity, alignment: .leading)
                    }
                    VStack(alignment: .leading, spacing: 20) { poster; information }
                }
                if loading { ProgressView("Loading movie details…") }
                if failed {
                    HStack {
                        Text("Movie details couldn't be loaded. You can still play this movie.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Retry") { retry += 1 }
                    }
                }
                MediaDescriptionView(details: details)
                if !recommendations.isEmpty {
                    Text("Recommended Movies").font(.headline)
                    ForEach(recommendations) { movie in
                        Button { manager.playChannel(movie) } label: { Text(movie.name) }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(.white)
        .background(LinearGradient(colors: [.orange.opacity(0.2), .black], startPoint: .top, endPoint: .bottom))
        .task(id: "\(item.subtitleCacheKey)|\(retry)") {
            details = nil
            loading = true
            failed = false
            do {
                let result = try await XtreamCodesManager().fetchMovieDetails(for: item)
                try Task.checkCancellation()
                details = result
            } catch {
                guard !Task.isCancelled else { return }
                failed = true
            }
            loading = false
        }
    }

    private var poster: some View {
        HeroArtworkView(url: details?.poster ?? item.logoURL, symbol: "film")
    }

    private var information: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(details?.title ?? item.name).font(.largeTitle.bold()).fixedSize(horizontal: false, vertical: true)
            MediaMetadataView(details: details)
            let position = manager.progressStore.progress(for: item)?.resumePosition
            Button { manager.playMovie() } label: {
                Label(position.map { "Resume from \(PlaybackProgress.timestamp($0))" } ?? "Play", systemImage: "play.fill")
                    .font(.headline).padding(.horizontal, 16).padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            if position != nil {
                Button("Start over") { manager.playMovie(startOver: true) }.buttonStyle(.bordered)
            }
            MediaProgressView(store: manager.progressStore, item: item)
        }
    }

    private var recommendations: [M3UItem] {
        let ids = Set(details?.recommendedIDs ?? [])
        return manager.channels.filter { movie in
            guard movie.contentType == .movie, movie.id != item.id,
                  movie.streamURL.deletingLastPathComponent() == item.streamURL.deletingLastPathComponent() else { return false }
            let id = movie.mediaID ?? movie.streamURL.deletingPathExtension().lastPathComponent
            return ids.contains(id)
        }
    }
}

struct MediaMetadataView: View {
    let details: MediaDetails?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let metadata = [details?.year, details?.runtime, details?.certification].compactMap { $0 }
            if !metadata.isEmpty { Text(metadata.joined(separator: " • ")).font(.subheadline).foregroundStyle(.secondary) }
            if let genres = details?.genres { Text(genres).font(.subheadline) }
            if let rating = details?.rating {
                HStack(spacing: 4) {
                    Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                    Text(rating).font(.caption.bold()).foregroundStyle(.white)
                }
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Color.yellow.opacity(0.2)).cornerRadius(6)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Rating \(rating)")
            }
        }
    }
}

struct MediaDescriptionView: View {
    let details: MediaDetails?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let plot = details?.plot { Text(plot).fixedSize(horizontal: false, vertical: true) }
            credit("Cast", details?.cast)
            credit("Director", details?.director)
            credit("Writer", details?.writer)
            credit("Producer", details?.producer)
            if let trailer = details?.trailer {
                Link(destination: trailer) { Label("Watch Trailer", systemImage: "play.rectangle") }
            }
        }
    }
    @ViewBuilder private func credit(_ label: String, _ value: String?) -> some View {
        if let value {
            VStack(alignment: .leading, spacing: 4) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct HeroArtworkView: View {
    let url: URL?
    let symbol: String
    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            RoundedRectangle(cornerRadius: 12).fill(Color.purple.opacity(0.2))
                .overlay(Image(systemName: symbol).font(.largeTitle).foregroundStyle(.purple))
        }
        .frame(width: 150, height: 225).clipped().cornerRadius(12)
        .shadow(color: .black.opacity(0.6), radius: 16, x: 0, y: 8)
        .accessibilityHidden(true)
    }
}
