//
//  FakeLoginItem.swift
//  RelayBackTests
//
//  A `LoginItemControlling` fake so the launch-at-login toggle glue in `SettingsModel` is testable
//  without touching the real `SMAppService` (which would register the app as a real login item).
//  It records the last requested state and can be told to fail, to exercise the error path.
//

import Foundation
@testable import RelayBack

final class FakeLoginItem: LoginItemControlling {
    private(set) var isEnabled: Bool
    /// When non-nil, `setEnabled` throws it — to drive the model's failure handling.
    var errorToThrow: Error?

    init(isEnabled: Bool = false) { self.isEnabled = isEnabled }

    func setEnabled(_ enabled: Bool) throws {
        if let errorToThrow { throw errorToThrow }
        isEnabled = enabled
    }
}
