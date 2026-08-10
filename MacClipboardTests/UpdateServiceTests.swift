import XCTest
@testable import MacClipboard

final class UpdateServiceTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testDetectsAvailableUpdateFromGitHubReleasePayload() {
        let service = makeService(
            statusCode: 200,
            body: #"{"tag_name":"v1.2.0","html_url":"https://example.com/release"}"#.data(using: .utf8)!
        )
        let expectation = expectation(description: "update check completes")

        service.checkForUpdates(currentVersion: "1.1.0") { result in
            switch result {
            case .success(.updateAvailable(let currentVersion, let latestVersion, let downloadURL)):
                XCTAssertEqual(currentVersion, "1.1.0")
                XCTAssertEqual(latestVersion, "1.2.0")
                XCTAssertEqual(downloadURL.absoluteString, "https://example.com/release")
            default:
                XCTFail("Expected available update, got \(result)")
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1)
    }

    func testReportsUpToDateWhenLatestVersionIsNotNewer() {
        let service = makeService(
            statusCode: 200,
            body: #"{"tag_name":"v1.2.0","html_url":"https://example.com/release"}"#.data(using: .utf8)!
        )
        let expectation = expectation(description: "update check completes")

        service.checkForUpdates(currentVersion: "1.2.0") { result in
            XCTAssertEqual(result, .success(.upToDate(currentVersion: "1.2.0")))
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1)
    }

    func testReportsRateLimitResponse() {
        let resetDate = Date(timeIntervalSince1970: 1_893_456_000)
        let service = makeService(
            statusCode: 429,
            headers: ["X-RateLimit-Reset": "1893456000"],
            body: Data()
        )
        let expectation = expectation(description: "update check completes")

        service.checkForUpdates(currentVersion: "1.2.0") { result in
            XCTAssertEqual(result, .failure(.rateLimited(resetDate: resetDate)))
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1)
    }

    // MARK: - Version Ordering

    func testOrdersOrdinaryReleases() {
        XCTAssertTrue(UpdateService.isVersion("0.1.25", newerThan: "0.1.24"))
        XCTAssertTrue(UpdateService.isVersion("0.2.0", newerThan: "0.1.99"))
        XCTAssertTrue(UpdateService.isVersion("1.0.0", newerThan: "0.9.9"))
        XCTAssertFalse(UpdateService.isVersion("0.1.24", newerThan: "0.1.24"))
        XCTAssertFalse(UpdateService.isVersion("0.1.23", newerThan: "0.1.24"))
    }

    func testTolerantOfTagPrefixAndUnevenComponentCounts() {
        XCTAssertTrue(UpdateService.isVersion("v0.1.25", newerThan: "0.1.24"))
        XCTAssertTrue(UpdateService.isVersion("0.2", newerThan: "0.1.24"))
        XCTAssertFalse(UpdateService.isVersion("0.1", newerThan: "0.1.0"))
        XCTAssertFalse(UpdateService.isVersion("0.1.0", newerThan: "0.1"))
    }

    /// The bug the `ReleaseVersion` parse exists to prevent: `Int("25-beta")` is nil, so the naive
    /// parse read `0.1.25-beta.1` as `[0, 1]` and called it *older* than `0.1.24`.
    func testPrereleaseOfANewerVersionStillCountsAsNewer() {
        XCTAssertTrue(UpdateService.isVersion("0.1.25-beta.1", newerThan: "0.1.24"))
        XCTAssertTrue(UpdateService.isVersion("1.0.0-rc.1", newerThan: "0.9.0"))
    }

    func testPrereleasePrecedesItsOwnRelease() {
        XCTAssertTrue(UpdateService.isVersion("0.1.25", newerThan: "0.1.25-beta.1"))
        XCTAssertFalse(UpdateService.isVersion("0.1.25-beta.1", newerThan: "0.1.25"))
    }

    func testBuildMetadataDoesNotAffectPrecedence() {
        XCTAssertFalse(UpdateService.isVersion("0.1.24+build.99", newerThan: "0.1.24"))
        XCTAssertFalse(UpdateService.isVersion("0.1.24", newerThan: "0.1.24+build.99"))
    }

    // MARK: - Scheduling

    func testFirstCheckIsAlwaysDue() {
        XCTAssertTrue(UpdateCheckSchedule.isDue(lastCheck: nil, now: Date()))
    }

    func testCheckIsNotDueBeforeTheIntervalHasElapsed() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let lastCheck = now.addingTimeInterval(-UpdateCheckSchedule.interval + 60)
        XCTAssertFalse(UpdateCheckSchedule.isDue(lastCheck: lastCheck, now: now))
    }

    func testCheckIsDueOnceTheIntervalHasElapsed() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let lastCheck = now.addingTimeInterval(-UpdateCheckSchedule.interval)
        XCTAssertTrue(UpdateCheckSchedule.isDue(lastCheck: lastCheck, now: now))
    }

    /// A clock moved backwards would otherwise leave a stored date in the future and wedge checks
    /// until it came round again.
    func testCheckIsDueWhenTheStoredDateIsInTheFuture() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(UpdateCheckSchedule.isDue(lastCheck: now.addingTimeInterval(60 * 60 * 24 * 30), now: now))
    }

    // MARK: - What Gets Surfaced

    func testSurfacesANewerVersion() {
        XCTAssertEqual(
            UpdateAvailabilityPolicy.versionToSurface(latest: "0.1.25", current: "0.1.24", skipped: nil),
            "0.1.25"
        )
    }

    func testSurfacesNothingWhenCurrent() {
        XCTAssertNil(UpdateAvailabilityPolicy.versionToSurface(latest: "0.1.24", current: "0.1.24", skipped: nil))
        XCTAssertNil(UpdateAvailabilityPolicy.versionToSurface(latest: "0.1.23", current: "0.1.24", skipped: nil))
        XCTAssertNil(UpdateAvailabilityPolicy.versionToSurface(latest: nil, current: "0.1.24", skipped: nil))
        XCTAssertNil(UpdateAvailabilityPolicy.versionToSurface(latest: "", current: "0.1.24", skipped: nil))
    }

    func testSurfacesNothingForASkippedVersion() {
        XCTAssertNil(
            UpdateAvailabilityPolicy.versionToSurface(latest: "0.1.25", current: "0.1.24", skipped: "0.1.25")
        )
    }

    /// Skip means "not this one", not "stop telling me": that is what the preference is for.
    func testSurfacesAVersionNewerThanTheSkippedOne() {
        XCTAssertEqual(
            UpdateAvailabilityPolicy.versionToSurface(latest: "0.1.26", current: "0.1.24", skipped: "0.1.25"),
            "0.1.26"
        )
    }

    func testSurfacesNothingForAVersionOlderThanTheSkippedOne() {
        XCTAssertNil(
            UpdateAvailabilityPolicy.versionToSurface(latest: "0.1.25", current: "0.1.24", skipped: "0.1.26")
        )
    }

    private func makeService(statusCode: Int, headers: [String: String] = [:], body: Data) -> UpdateService {
        let endpoint = URL(string: "https://example.com/latest")!
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url, endpoint)
            let response = HTTPURLResponse(
                url: endpoint,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: headers
            )!
            return (response, body)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return UpdateService(
            session: URLSession(configuration: configuration),
            latestReleaseEndpoint: endpoint,
            fallbackReleaseURL: URL(string: "https://example.com/fallback")!
        )
    }
}


private final class MockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let requestHandler = Self.requestHandler else {
            XCTFail("Missing request handler")
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try requestHandler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}