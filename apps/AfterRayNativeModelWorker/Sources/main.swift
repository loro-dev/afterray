import CoreGraphics
import Foundation
import ImageIO
import Vision

private let protocolVersion = 2

private struct WorkerRequest: Decodable {
    let protocolVersion: Int
    let capability: String
    let input: Input

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case capability, input
    }
}

private struct Input: Decodable {
    let type: String
    let imagePath: String?

    enum CodingKeys: String, CodingKey {
        case type
        case imagePath = "image_path"
    }
}

private struct WorkerResponse: Encodable {
    let protocolVersion: Int
    let output: Output?
    let error: String?
    let retryable: Bool

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case output, error, retryable
    }
}

/// One recognized line. Geometry is Apple Vision's normalized bounding box:
/// origin at the **bottom-left**, unit square relative to the image.
private struct OcrRegion: Encodable {
    let text: String
    let confidence: Float
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

private struct Output: Encodable {
    let type = "ocr"
    let text: String
    let regions: [OcrRegion]
}

private enum WorkerFailure: LocalizedError {
    case invalidRequest(String)
    case imageLoad(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest(let message): message
        case .imageLoad(let path): "Could not decode OCR image at \(path)"
        }
    }
}

private func recognizeText(at path: String) throws -> (text: String, regions: [OcrRegion]) {
    let url = URL(fileURLWithPath: path) as CFURL
    guard
        let source = CGImageSourceCreateWithURL(url, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { throw WorkerFailure.imageLoad(path) }

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
    try VNImageRequestHandler(cgImage: image).perform([request])

    var regions: [OcrRegion] = []
    regions.reserveCapacity(request.results?.count ?? 0)
    for observation in request.results ?? [] {
        guard let candidate = observation.topCandidates(1).first else { continue }
        let box = observation.boundingBox
        regions.append(
            OcrRegion(
                text: candidate.string,
                confidence: candidate.confidence,
                x: box.origin.x,
                y: box.origin.y,
                width: box.size.width,
                height: box.size.height
            )
        )
    }
    let text = regions.map(\.text).joined(separator: "\n")
    return (text, regions)
}

private func execute(_ request: WorkerRequest) throws -> Output {
    guard request.protocolVersion == protocolVersion else {
        throw WorkerFailure.invalidRequest("Unsupported worker protocol \(request.protocolVersion)")
    }
    guard request.capability == "ocr", request.input.type == "ocr" else {
        throw WorkerFailure.invalidRequest("The native worker only handles OCR")
    }
    guard let path = request.input.imagePath, !path.isEmpty else {
        throw WorkerFailure.invalidRequest("OCR input is missing image_path")
    }
    let result = try recognizeText(at: path)
    return Output(text: result.text, regions: result.regions)
}

do {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    let request = try JSONDecoder().decode(WorkerRequest.self, from: data)
    let response = WorkerResponse(
        protocolVersion: protocolVersion,
        output: try execute(request),
        error: nil,
        retryable: false
    )
    print(String(decoding: try JSONEncoder().encode(response), as: UTF8.self))
} catch {
    let response = WorkerResponse(
        protocolVersion: protocolVersion,
        output: nil,
        error: error.localizedDescription,
        retryable: false
    )
    let data = try? JSONEncoder().encode(response)
    print(data.map { String(decoding: $0, as: UTF8.self) } ?? "{\"protocol_version\":2,\"error\":\"Native worker failed\",\"retryable\":false}")
}
