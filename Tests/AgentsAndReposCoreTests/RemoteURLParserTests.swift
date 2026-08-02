import XCTest

@testable import AgentsAndReposCore

final class RemoteURLParserTests: XCTestCase {
    func testFormats() {
        XCTAssertEqual(
            RemoteURLParser.githubOwnerRepo(from: "git@github.com:millisecond/tree.git"),
            "millisecond/tree")
        XCTAssertEqual(
            RemoteURLParser.githubOwnerRepo(from: "https://github.com/owner/repo"),
            "owner/repo")
        XCTAssertEqual(
            RemoteURLParser.githubOwnerRepo(from: "https://github.com/owner/repo.git"),
            "owner/repo")
        XCTAssertEqual(
            RemoteURLParser.githubOwnerRepo(from: "ssh://git@github.com/owner/repo.git"),
            "owner/repo")
        XCTAssertEqual(
            RemoteURLParser.githubOwnerRepo(from: "git://github.com/owner/repo.git"),
            "owner/repo")
        XCTAssertEqual(
            RemoteURLParser.githubOwnerRepo(from: "https://user@github.com/owner/repo.git"),
            "owner/repo")
    }

    func testNonGitHub() {
        XCTAssertNil(RemoteURLParser.githubOwnerRepo(from: "git@gitlab.com:owner/repo.git"))
        XCTAssertNil(RemoteURLParser.githubOwnerRepo(from: "https://bitbucket.org/o/r"))
        XCTAssertNil(RemoteURLParser.githubOwnerRepo(from: "https://gitlab.com/github.com/repo"))
        XCTAssertNil(RemoteURLParser.githubOwnerRepo(from: ""))
    }
}
