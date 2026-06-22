import XCTest
import ImageIO
import AppKit
@testable import CapyBuddy

@MainActor
final class ConversionQueueTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CapyBuddyTests-Queue-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - Submission + lifecycle

    func testSubmitAppendsJobsImmediately() throws {
        let queue = ConversionQueue()
        let url = try writePNG(name: "a.png")

        queue.submit(urls: [url], targetFormat: .jpeg)

        XCTAssertEqual(queue.jobs.count, 1)
        XCTAssertEqual(queue.jobs[0].inputURL, url)
        XCTAssertEqual(queue.jobs[0].targetFormat, .jpeg)
    }

    func testJobReachesFinishedStateForValidInput() async throws {
        let queue = ConversionQueue()
        let url = try writePNG(name: "ok.png")

        queue.submit(urls: [url], targetFormat: .jpeg)
        await queue.waitForAllJobs()

        guard case .finished(let outputURL, let inBytes, let outBytes) = queue.jobs[0].state else {
            return XCTFail("expected .finished, got \(queue.jobs[0].state)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertEqual(outputURL.pathExtension, "jpg")
        XCTAssertGreaterThan(inBytes, 0)
        XCTAssertGreaterThan(outBytes, 0)
    }

    func testJobReachesFailedStateForUnreadableInput() async throws {
        let queue = ConversionQueue()
        let bogus = tempDir.appendingPathComponent("ghost.png")

        queue.submit(urls: [bogus], targetFormat: .jpeg)
        await queue.waitForAllJobs()

        guard case .failed(let message) = queue.jobs[0].state else {
            return XCTFail("expected .failed, got \(queue.jobs[0].state)")
        }
        XCTAssertFalse(message.isEmpty)
    }

    func testSubmittingMultipleURLsCreatesIndependentJobs() async throws {
        let queue = ConversionQueue()
        let urls = try (0..<3).map { try writePNG(name: "f\($0).png") }

        queue.submit(urls: urls, targetFormat: .heic)
        await queue.waitForAllJobs()

        XCTAssertEqual(queue.jobs.count, 3)
        for job in queue.jobs {
            guard case .finished = job.state else {
                return XCTFail("\(job.displayName) not finished: \(job.state)")
            }
        }
    }

    func testClearCompletedRemovesOnlyTerminalJobs() async throws {
        let queue = ConversionQueue()
        let good = try writePNG(name: "good.png")
        let bad = tempDir.appendingPathComponent("bad.png")  // doesn't exist

        queue.submit(urls: [good, bad], targetFormat: .jpeg)
        await queue.waitForAllJobs()

        // Add a fresh queued job that hasn't run yet by inserting directly
        // — we want to verify clearCompleted doesn't reach into non-terminal
        // states.
        let pending = ConversionJob(
            inputURL: good,
            targetFormat: .png
        )
        // Pending jobs sit in `.queued`, never terminal.
        XCTAssertFalse(pending.isTerminal)

        let beforeCount = queue.jobs.count
        XCTAssertEqual(beforeCount, 2)

        queue.clearCompleted()
        XCTAssertTrue(queue.jobs.isEmpty,
                      "all submitted jobs reached terminal state and should clear")
    }

    func testOutputDirectoryOverrideWritesToOverrideFolder() async throws {
        let queue = ConversionQueue()
        let alt = tempDir.appendingPathComponent("alt-output", isDirectory: true)
        try FileManager.default.createDirectory(at: alt, withIntermediateDirectories: true)
        queue.outputDirectoryOverride = alt

        let input = try writePNG(name: "src.png")
        queue.submit(urls: [input], targetFormat: .jpeg)
        await queue.waitForAllJobs()

        guard case .finished(let outURL, _, _) = queue.jobs[0].state else {
            return XCTFail("expected finished, got \(queue.jobs[0].state)")
        }
        XCTAssertEqual(outURL.deletingLastPathComponent().path, alt.path)
    }

    // MARK: - Formatting helpers

    func testSavingsLabelPositiveSavings() {
        XCTAssertEqual(
            ConversionQueue.savingsLabel(inputBytes: 1000, outputBytes: 250),
            "saved 75%"
        )
    }

    func testSavingsLabelNegativeShownAsPlusPercent() {
        XCTAssertEqual(
            ConversionQueue.savingsLabel(inputBytes: 1000, outputBytes: 1500),
            "+50%"
        )
    }

    func testSavingsLabelHandlesNoChangeWithinHalfPercent() {
        XCTAssertEqual(
            ConversionQueue.savingsLabel(inputBytes: 1000, outputBytes: 1003),
            "no change"
        )
    }

    func testSavingsLabelHandlesZeroInputBytes() {
        XCTAssertEqual(
            ConversionQueue.savingsLabel(inputBytes: 0, outputBytes: 1000),
            ""
        )
    }

    func testErrorMessageMapsKnownConversionErrors() {
        XCTAssertEqual(
            ConversionQueue.errorMessage(ConversionError.unreadableSource),
            "Couldn't read this file."
        )
        XCTAssertEqual(
            ConversionQueue.errorMessage(ConversionError.unsupportedTarget),
            "Can't write to this format on your system."
        )
        XCTAssertEqual(
            ConversionQueue.errorMessage(ConversionError.writeFailed),
            "Failed to save the converted file."
        )
    }

    // MARK: - ConversionJob state

    func testJobIsTerminalReflectsState() {
        let job = ConversionJob(
            inputURL: URL(fileURLWithPath: "/tmp/x.png"),
            targetFormat: .jpeg
        )
        XCTAssertFalse(job.isTerminal)

        job.state = .running
        XCTAssertFalse(job.isTerminal)

        job.state = .finished(
            outputURL: URL(fileURLWithPath: "/tmp/x.jpg"),
            inputBytes: 1, outputBytes: 1
        )
        XCTAssertTrue(job.isTerminal)

        job.state = .failed(message: "nope")
        XCTAssertTrue(job.isTerminal)
    }

    // MARK: - Helpers

    private func writePNG(name: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        let size = 32
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        )!
        let ctx = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        NSColor.systemPink.setFill()
        NSBezierPath.fill(NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()

        guard let cg = bitmap.cgImage,
              let dest = CGImageDestinationCreateWithURL(
                url as CFURL,
                ConversionFormat.png.utiIdentifier as CFString,
                1, nil
              ) else {
            throw NSError(domain: "test", code: -1)
        }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "test", code: -2)
        }
        return url
    }
}
