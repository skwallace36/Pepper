import UIKit
import Vision

// MARK: - OCR Text Recognition

/// Runs Vision text recognition on a CGImage and returns observations in screen coordinates.
enum PepperOCR {

    /// A single recognized text region.
    struct Observation {
        let text: String
        /// Bounding box in screen coordinates (UIKit top-left origin).
        let boundingBox: CGRect
        let confidence: Float
    }

    /// Minimum confidence to include a result. Below 0.7, misreadings are common.
    static let confidenceThreshold: Float = 0.7

    /// Recognize text in `image` and return observations with bounding boxes
    /// converted to screen coordinates.
    ///
    /// - Parameters:
    ///   - image: Source image (typically a full-screen or region capture).
    ///   - screenSize: The screen size used to convert Vision's normalized rects
    ///     (0-1, bottom-left origin) into UIKit points (top-left origin).
    /// - Returns: Recognized text observations sorted top-to-bottom, left-to-right.
    ///   Empty array if recognition finds nothing; `nil` on framework error.
    static func recognizeText(in image: CGImage, screenSize: CGSize) -> [Observation]? {
        var result: [Observation]?

        let request = VNRecognizeTextRequest { request, error in
            if let error = error {
                PepperLogger.shared.error("OCR error: \(error.localizedDescription)", category: .bridge)
                result = nil
                return
            }
            guard let observations = request.results as? [VNRecognizedTextObservation] else {
                result = []
                return
            }
            result = observations.compactMap { observation in
                convert(observation, screenSize: screenSize)
            }
        }

        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if #available(iOS 16.0, *) {
            request.revision = VNRecognizeTextRequestRevision3
        }

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            PepperLogger.shared.error("OCR perform failed: \(error.localizedDescription)", category: .bridge)
            return nil
        }

        // Sort top-to-bottom, then left-to-right
        result?.sort { a, b in
            if abs(a.boundingBox.minY - b.boundingBox.minY) > 4 {
                return a.boundingBox.minY < b.boundingBox.minY
            }
            return a.boundingBox.minX < b.boundingBox.minX
        }

        return result
    }

    // MARK: - Private

    /// Convert a Vision observation to screen coordinates, filtering by confidence.
    private static func convert(
        _ observation: VNRecognizedTextObservation,
        screenSize: CGSize
    ) -> Observation? {
        guard let candidate = observation.topCandidates(1).first else { return nil }
        guard candidate.confidence >= confidenceThreshold else { return nil }

        // Vision rect: normalized (0-1), bottom-left origin.
        // UIKit rect: points, top-left origin.
        let vr = observation.boundingBox
        let screenRect = CGRect(
            x: vr.origin.x * screenSize.width,
            y: (1 - vr.origin.y - vr.height) * screenSize.height,
            width: vr.width * screenSize.width,
            height: vr.height * screenSize.height
        )

        return Observation(
            text: candidate.string,
            boundingBox: screenRect,
            confidence: candidate.confidence
        )
    }
}
