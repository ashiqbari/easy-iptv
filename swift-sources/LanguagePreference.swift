import SwiftUI

/// Match metadata first; names are only a fallback for tracks without a language tag.
enum LanguagePreference {
    static let audioKey = "com.iptvplayer.audioLanguage"
    static let subtitleKey = "com.iptvplayer.subtitleLanguage"
    static let codes = Locale.LanguageCode.isoLanguageCodes.map(\.identifier).filter { $0.count == 2 }
    static let choices = codes.sorted {
        name($0).localizedStandardCompare(name($1)) == .orderedAscending
    }

    static func name(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    static func canonical(_ value: String) -> String {
        let tag = value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "_", with: "-")
        return Locale.Language(identifier: tag).languageCode?.identifier(.alpha2) ?? tag.lowercased()
    }

    static func matches(_ preference: String, language: String?, label: String) -> Bool {
        guard !preference.isEmpty else { return false }
        let code = canonical(preference)
        if let language, !language.isEmpty, language != "und" {
            return canonical(language) == code
        }
        let names = [code, Locale.Language(identifier: code).languageCode?.identifier(.alpha3) ?? code,
                     name(code), Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code]
        let normalized = label.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
        return names.contains { name in
            let candidate = name.lowercased()
            return (" " + normalized + " ").contains(" " + candidate + " ")
        }
    }
}

struct LanguagePreferencePicker: View {
    let title: String
    let defaultLabel: String
    @Binding var selection: String

    var body: some View {
        Picker(title, selection: $selection) {
            Text(defaultLabel).tag("")
            ForEach(LanguagePreference.choices, id: \.self) { code in
                Text(LanguagePreference.name(code)).tag(code)
            }
        }
        .help("Saved for new movie and episode playback. Choose a track below to override it for this item.")
    }
}
