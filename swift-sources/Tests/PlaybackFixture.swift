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

/// Two silent PCM tracks in one alternate group exercise real engine selection.
func alternateAudioMedia() async throws -> URL {
    let wav = FileManager.default.temporaryDirectory.appendingPathComponent("audio-source-\(UUID()).wav")
    let mov = FileManager.default.temporaryDirectory.appendingPathComponent("audio-tracks-\(UUID()).mov")
    var data = Data()
    func text(_ value: String) { data.append(contentsOf: value.utf8) }
    func number<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
    let samples: UInt32 = 80_000
    text("RIFF"); number(UInt32(36) + samples * 2); text("WAVEfmt "); number(UInt32(16))
    number(UInt16(1)); number(UInt16(1)); number(UInt32(8_000)); number(UInt32(16_000))
    number(UInt16(2)); number(UInt16(16)); text("data"); number(samples * 2)
    data.append(Data(count: Int(samples * 2)))
    try data.write(to: wav)
    defer { try? FileManager.default.removeItem(at: wav) }
    let asset = AVURLAsset(url: wav)
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    let track = try XCTUnwrap(tracks.first)
    let formats = try await track.load(.formatDescriptions)
    let format = try XCTUnwrap(formats.first)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    reader.add(output)
    let writer = try AVAssetWriter(outputURL: mov, fileType: .mov)
    let english = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: format)
    let french = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: format)
    english.extendedLanguageTag = "en"; french.extendedLanguageTag = "fr"
    writer.add(english); writer.add(french)
    writer.add(AVAssetWriterInputGroup(inputs: [english, french], defaultInput: english))
    XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
    XCTAssertTrue(reader.startReading())
    while let sample = output.copyNextSampleBuffer() {
        while (!english.isReadyForMoreMediaData || !french.isReadyForMoreMediaData) && writer.status == .writing {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        guard english.append(sample), french.append(sample) else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }
    english.markAsFinished(); french.markAsFinished()
    await writer.finishWriting()
    if let error = reader.error ?? writer.error { throw error }
    return mov
}
