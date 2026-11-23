import Foundation
import MyRemoteAgentKit
import MyRemoteCore
import Network
import XCTest

/// Opt-in: `MYREMOTE_TEST_BONJOUR=1 swift test --filter BonjourTests`.
///
/// Registering and browsing Bonjour services is subject to macOS Local Network
/// privacy. Tools started from Terminal are exempt, but the same test started from
/// an IDE can make the system show a permission prompt, and it briefly advertises
/// a service on the LAN. So it never runs by default.
final class BonjourTests: XCTestCase {
    private final class Found: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: (name: String, txt: [String: String])?
        var value: (name: String, txt: [String: String])? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    func testServiceIsAdvertisedWithContractTXTRecords() async throws {
        guard ProcessInfo.processInfo.environment["MYREMOTE_TEST_BONJOUR"] == "1" else {
            throw XCTSkip("set MYREMOTE_TEST_BONJOUR=1 to run the Bonjour advertising test")
        }
        let directory = try TestDirectories.make("bonjour")
        defer { TestDirectories.remove(directory) }
        let agent = try TestAgent.start(in: directory, advertise: true)
        defer { agent.server.stop() }
        let expectedName = "MyRemote Test \(agent.agent.id)"

        let found = Found()
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: "_myremote._tcp", domain: "local."), using: .tcp)
        browser.browseResultsChangedHandler = { results, _ in
            for result in results {
                guard case let .service(name, type, _, _) = result.endpoint,
                      type.hasPrefix("_myremote._tcp"),
                      case let .bonjour(record) = result.metadata,
                      record["id"] == agent.agent.id
                else { continue }
                found.value = (name, record.dictionary)
            }
        }
        browser.start(queue: DispatchQueue(label: "myremote.tests.browser"))
        defer { browser.cancel() }

        await waitUntil(timeout: 10, "the service to show up in a Bonjour browse") { found.value != nil }
        let service = try XCTUnwrap(found.value)
        XCTAssertEqual(service.name, expectedName)
        XCTAssertEqual(service.txt, ["v": "1", "id": agent.agent.id])
    }
}
