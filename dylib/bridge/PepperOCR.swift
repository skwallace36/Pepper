import Vision
import CoreGraphics
import os

/// Runs Vision OCR on a CGImage and returns recognized text observations.
enum PepperOCR {

    /// A single recognized text region from OCR.
    struct TextObservation {
        let text: String
        let confidence: Float
        /// Bounding rect in screen coordinates (origin top-left).
        let boundingRect: CGRect
        /// Center point in screen coordinates.
        var center: CGPoint { CGPoint(x: boundingRect.midX, y: boundingRect.midY) }
    }

    private static let logger = PepperLogger.logger(category: "ocr")

    /// Runs VNRecognizeTextRequest synchronously on the given image.
    /// Vision returns normalized coordinates (origin bottom-left, 0..1).
    /// Results are converted to screen coordinates using `imageSize`.
    /// Returns observations sorted top-to-bottom by center Y.
    static func recognizeText(in image: CGImage, imageSize: CGSize) -> [TextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            logger.error("OCR failed: \(error.localizedDescription, privacy: .public)")
            return []
        }

        guard let results = request.results else { return [] }

        var observations: [TextObservation] = []
        for result in results {
            guard let candidate = result.topCandidates(1).first else { continue }
            // Skip very low confidence results
            guard candidate.confidence > 0.3 else { continue }

            // Convert Vision normalized rect (bottom-left origin) to screen coords (top-left origin)
            let box = result.boundingBox
            let rect = CGRect(
                x: box.origin.x * imageSize.width,
                y: (1.0 - box.origin.y - box.height) * imageSize.height,
                width: box.width * imageSize.width,
                height: box.height * imageSize.height
            )

            observations.append(TextObservation(
                text: candidate.string,
                confidence: candidate.confidence,
                boundingRect: rect
            ))
        }

        observations.sort { $0.center.y < $1.center.y }
        return observations
    }
}
