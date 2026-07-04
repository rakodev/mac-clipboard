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