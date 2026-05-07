import XCTest
@testable import Berth

final class ZshrcImporterTests: XCTestCase {
    func test_parsesDoubleQuotedAlias() {
        let line = #"alias pf-goldgard-staging="kubectl port-forward services/goldgard-api 3100:3000 -n 271-goldgard-staging""#
        let result = ZshrcImporter.parseLine(line, defaultContext: "oidc@sparteo")
        XCTAssertNotNil(result?.parsed)
        XCTAssertEqual(result?.parsed?.serviceName, "goldgard-api")
        XCTAssertEqual(result?.parsed?.localPort, 3100)
        XCTAssertEqual(result?.parsed?.remotePort, 3000)
        XCTAssertEqual(result?.parsed?.namespace, "271-goldgard-staging")
        XCTAssertEqual(result?.parsed?.context, "oidc@sparteo")
    }

    func test_parsesSingleQuotedAliasWithSubshellRejected() {
        let line = #"alias pf-adsleuth-staging='kubectl port-forward -n 224-adsleuth-staging $(kubectl get pods ...) 3001:3000'"#
        let result = ZshrcImporter.parseLine(line, defaultContext: "oidc@sparteo")
        XCTAssertNotNil(result)
        XCTAssertNil(result?.parsed)
        XCTAssertNotNil(result?.note)
    }

    func test_ignoresUnrelatedAliases() {
        XCTAssertNil(ZshrcImporter.parseLine(#"alias ll="ls -la""#, defaultContext: "x"))
        XCTAssertNil(ZshrcImporter.parseLine(#"alias g="git""#, defaultContext: "x"))
    }

    func test_fuzzyScoreMatches() {
        XCTAssertNotNil(ServiceCatalog.fuzzyScore(needle: "gold", haystack: "goldgard-api"))
        XCTAssertNotNil(ServiceCatalog.fuzzyScore(needle: "gdapi", haystack: "goldgard-api"))
        XCTAssertNil(ServiceCatalog.fuzzyScore(needle: "xyz", haystack: "goldgard"))
    }
}
