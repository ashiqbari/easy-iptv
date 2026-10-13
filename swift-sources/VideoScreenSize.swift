import AVFoundation

public enum VideoScreenSize: String, CaseIterable, Sendable {
    case auto, widescreen, standard, ultrawide, square, stretch, zoom

    static let storageKey = "com.iptvplayer.videoScreenSize"

    public var title: String {
        switch self {
        case .auto: "Auto / Original"
        case .widescreen: "16:9"
        case .standard: "4:3"
        case .ultrawide: "21:9"
        case .square: "1:1"
        case .stretch: "Fill / Stretch"
        case .zoom: "Zoom / Crop"
        }
    }

    var shortTitle: String {
        switch self {
        case .auto: "Auto"
        case .stretch: "Stretch"
        case .zoom: "Zoom"
        default: title
        }
    }

    var ratio: CGFloat? {
        switch self {
        case .widescreen: 16.0 / 9
        case .standard: 4.0 / 3
        case .ultrawide: 21.0 / 9
        case .square: 1
        default: nil
        }
    }

    var gravity: AVLayerVideoGravity {
        switch self {
        case .auto: .resizeAspect
        case .zoom: .resizeAspectFill
        default: .resize
        }
    }

    func videoRect(in bounds: CGRect) -> CGRect {
        guard let ratio, bounds.width > 0, bounds.height > 0 else { return bounds }
        let width = min(bounds.width, bounds.height * ratio)
        let height = width / ratio
        return CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
    }
}
