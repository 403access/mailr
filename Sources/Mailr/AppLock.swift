import Foundation
import LocalAuthentication
import Observation

/// Owns the App Lock preference and the locked state shared by the root view
/// and the privacy settings screen. Biometric prompts go through
/// `LocalAuthentication`, with the device passcode as the system fallback.
@MainActor
@Observable
final class AppLock {
    enum Biometry: Equatable {
        case faceID
        case touchID
        case opticID
        case none

        var displayName: String {
            switch self {
            case .faceID: "Face ID"
            case .touchID: "Touch ID"
            case .opticID: "Optic ID"
            case .none: "Biometrics"
            }
        }

        var symbolName: String {
            switch self {
            case .faceID: "faceid"
            case .touchID: "touchid"
            case .opticID: "opticid"
            case .none: "lock.shield"
            }
        }
    }

    private enum Key {
        static let isEnabled = "appLock.isEnabled"
    }

    private(set) var biometry: Biometry = .none
    private(set) var canUseBiometrics = false
    private(set) var isEnabled: Bool
    private(set) var isLocked: Bool
    private(set) var isAuthenticating = false
    private(set) var availabilityError: String?
    private(set) var lastErrorMessage: String?

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let enabled = defaults.bool(forKey: Key.isEnabled)
        self.isEnabled = enabled
        self.isLocked = enabled
        refreshBiometry()
    }

    var biometryName: String { biometry.displayName }

    var biometrySymbol: String {
        canUseBiometrics ? biometry.symbolName : "lock.shield"
    }

    /// Re-checks whether biometrics are enrolled and available. The check has
    /// to run before `LAContext.biometryType` is meaningful.
    func refreshBiometry() {
        let context = LAContext()
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            canUseBiometrics = true
            availabilityError = nil
            switch context.biometryType {
            case .faceID:
                biometry = .faceID
            case .touchID:
                biometry = .touchID
            case .opticID:
                biometry = .opticID
            default:
                biometry = .none
            }
        } else {
            canUseBiometrics = false
            biometry = .none
            availabilityError = error?.localizedDescription
        }
    }

    /// Asks for biometrics before turning the lock on, then records the
    /// preference. Returns `true` when App Lock is now enabled.
    @discardableResult
    func enable() async -> Bool {
        refreshBiometry()
        guard canUseBiometrics else {
            lastErrorMessage = availabilityError ?? "\(biometryName) isn’t available on this device."
            return false
        }

        let authenticated = await authenticate(reason: "Confirm it’s you to turn on App Lock.")
        guard authenticated else { return false }

        defaults.set(true, forKey: Key.isEnabled)
        isEnabled = true
        isLocked = false
        lastErrorMessage = nil
        return true
    }

    func disable() {
        defaults.set(false, forKey: Key.isEnabled)
        isEnabled = false
        isLocked = false
        lastErrorMessage = nil
    }

    /// Locks the app when App Lock is on. Called when Mailr is backgrounded.
    func lock() {
        guard isEnabled else { return }
        isLocked = true
    }

    /// Prompts for biometrics (or the device passcode) and clears the lock on
    /// success. Returns `true` when the app is unlocked.
    @discardableResult
    func unlock() async -> Bool {
        guard isLocked else { return true }
        guard !isAuthenticating else { return false }

        let authenticated = await authenticate(reason: "Unlock Mailr to view your mail.")
        if authenticated {
            isLocked = false
            lastErrorMessage = nil
        }
        return authenticated
    }

    private func authenticate(reason: String) async -> Bool {
        isAuthenticating = true
        defer { isAuthenticating = false }

        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        #if os(macOS)
        context.localizedFallbackTitle = "Use Password"
        #else
        context.localizedFallbackTitle = "Use Passcode"
        #endif

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            lastErrorMessage = message(for: error)
            return false
        }

        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: reason
            )
            if !success {
                lastErrorMessage = "Authentication failed. Try again."
            }
            return success
        } catch {
            lastErrorMessage = message(for: error)
            return false
        }
    }

    private func message(for error: (any Error)?) -> String? {
        guard let error else { return "Authentication isn’t available right now." }
        guard let laError = error as? LAError else { return error.localizedDescription }

        switch laError.code {
        case .userCancel, .appCancel, .systemCancel:
            return nil
        case .authenticationFailed:
            return "Authentication failed. Try again."
        case .biometryNotAvailable:
            return "Biometrics aren’t available right now."
        case .biometryNotEnrolled:
            return "No biometrics are set up on this device."
        case .biometryLockout:
            return "Biometrics are locked. Use your device passcode."
        case .passcodeNotSet:
            return "Set a device passcode or password to use App Lock."
        default:
            return laError.localizedDescription
        }
    }
}
