/*
Copyright The k3sm Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

import Darwin
import Foundation
@testable import K3smSDK
import Testing

private let pageFixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Fixtures/page/darwin.v1.page").path

/// A doorbell file the process may not open is refused, not ignored: the
/// notifier throws `notFound` carrying the open's `EACCES`.
@Test func unreadableDoorbellThrowsNotFoundWithEACCES() throws {
    // Root opens a mode 000 file regardless, so there is nothing to refuse.
    guard geteuid() != 0 else { return }
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("k3sm-sdk-bell-access-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer {
        _ = chmod(dir + "/budget.bell", 0o600)
        try? FileManager.default.removeItem(atPath: dir)
    }
    let bell = dir + "/budget.bell"
    #expect(FileManager.default.createFile(atPath: bell, contents: Data([0])))
    #expect(chmod(bell, 0o000) == 0)
    let page = try BudgetPage.open(path: pageFixture)
    #expect(throws: BudgetError.notFound(errno: EACCES)) {
        try BudgetNotifier(page, doorbellPath: bell)
    }
}
