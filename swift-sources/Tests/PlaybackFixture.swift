import XCTest
import AVFoundation

/// A native-written silent movie exercises real metadata/clock without a provider account.
func silentMedia() async throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("resume-test-\(UUID()).mov")
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.jpeg, AVVideoWidthKey: 32, AVVideoHeightKey: 32
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
        kCVPixelBufferWidthKey as String: 32, kCVPixelBufferHeightKey as String: 32
    ])
    writer.add(input)
    XCTAssertTrue(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, 32, 32, kCVPixelFormatType_32ARGB, nil, &buffer)
    let frame = try XCTUnwrap(buffer)
    CVPixelBufferLockBaseAddress(frame, [])
    memset(CVPixelBufferGetBaseAddress(frame), 0, CVPixelBufferGetDataSize(frame))
    CVPixelBufferUnlockBaseAddress(frame, [])
    for time in 0..<300 {
        while !input.isReadyForMoreMediaData && writer.status == .writing {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        guard adaptor.append(frame, withPresentationTime: CMTime(seconds: Double(time), preferredTimescale: 600)) else {
            throw writer.error ?? NSError(domain: "Fixture", code: 1)
        }
    }
    writer.endSession(atSourceTime: CMTime(seconds: 300, preferredTimescale: 600))
    input.markAsFinished()
    await writer.finishWriting()
    if let error = writer.error { throw error }
    return url
}
