// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot

import XCTest
@testable import RailwayMapCore

final class PackDirsTests: XCTestCase {
    private struct Copy: Hashable {
        let id: String
        let version: Int
        let folder: String
    }

    private func choose(_ copies: Copy...) -> (chosen: [Copy], superseded: [Copy]) {
        PackDirs.choose(copies, id: { $0.id }, version: { $0.version }, folderName: { $0.folder })
    }

    func testStagingFoldersBecomeInstalledFolders() {
        let staging = PackDirs.stagingName(id: "netherlands", timestamp: 1_789_400_000_000)
        XCTAssertEqual("netherlands@1789400000000.download", staging)
        XCTAssertTrue(PackDirs.isStaging(staging))
        XCTAssertEqual("netherlands@1789400000000", PackDirs.installedName(stagingName: staging))
        XCTAssertFalse(PackDirs.isStaging(PackDirs.installedName(stagingName: staging)))
    }

    func testFoldersBelongToTheirPackOnly() {
        XCTAssertTrue(PackDirs.belongsTo("netherlands", id: "netherlands"))
        XCTAssertTrue(PackDirs.belongsTo("netherlands@12", id: "netherlands"))
        XCTAssertTrue(PackDirs.belongsTo("netherlands@12.download", id: "netherlands"))
        XCTAssertFalse(PackDirs.belongsTo("netherlands-antilles@12", id: "netherlands"))
        XCTAssertFalse(PackDirs.belongsTo("ireland-and-northern-ireland", id: "ireland"))
    }

    func testHighestVersionWins() {
        let old = Copy(id: "belgium", version: 1, folder: "belgium")
        let new = Copy(id: "belgium", version: 3, folder: "belgium@200")
        let (chosen, superseded) = choose(old, new)
        XCTAssertEqual([new], chosen)
        XCTAssertEqual([old], superseded)
    }

    func testNewestFolderWinsForTheSameVersion() {
        let first = Copy(id: "spain", version: 3, folder: "spain@100")
        let second = Copy(id: "spain", version: 3, folder: "spain@200")
        let legacy = Copy(id: "spain", version: 3, folder: "spain")
        let (chosen, superseded) = choose(first, legacy, second)
        XCTAssertEqual([second], chosen)
        XCTAssertEqual(Set([first, legacy]), Set(superseded))
    }

    func testPacksAreChosenIndependently() {
        let nl = Copy(id: "netherlands", version: 1, folder: "netherlands")
        let be = Copy(id: "belgium", version: 2, folder: "belgium@5")
        let (chosen, superseded) = choose(nl, be)
        XCTAssertEqual(Set([nl, be]), Set(chosen))
        XCTAssertTrue(superseded.isEmpty)
    }
}
