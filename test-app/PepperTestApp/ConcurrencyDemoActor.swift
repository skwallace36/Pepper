import Foundation

/// A demo actor used to exercise `concurrency actors` discovery.
/// Simulates image processing work with cooperative cancellation support.
actor ImageProcessor {
    private(set) var processedCount: Int = 0

    func reset() {
        processedCount = 0
    }

    func processImage(_ index: Int) async {
        guard !Task.isCancelled else { return }
        try? await Task.sleep(nanoseconds: 700_000_000) // 0.7s per image
        guard !Task.isCancelled else { return }
        processedCount += 1
        print("[PepperTest] ImageProcessor: processed image \(index) (total: \(processedCount))")
    }
}
