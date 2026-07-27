import Foundation
import ServiceManagement

enum LaunchAtLoginState: Equatable {
    case disabled
    case enabled
    case requiresApproval
    case unavailable

    init(status: SMAppService.Status) {
        switch status {
        case .notRegistered:
            self = .disabled
        case .enabled:
            self = .enabled
        case .requiresApproval:
            self = .requiresApproval
        case .notFound:
            self = .unavailable
        @unknown default:
            self = .unavailable
        }
    }

    var isRequested: Bool {
        self == .enabled || self == .requiresApproval
    }
}

struct LoginItemServiceClient {
    let status: () -> SMAppService.Status
    let register: () throws -> Void
    let unregister: () throws -> Void
    let openSystemSettings: () -> Void

    static var mainApp: LoginItemServiceClient {
        let service = SMAppService.mainApp
        return LoginItemServiceClient(
            status: { service.status },
            register: { try service.register() },
            unregister: { try service.unregister() },
            openSystemSettings: {
                SMAppService.openSystemSettingsLoginItems()
            }
        )
    }
}

@MainActor
final class LaunchAtLoginController: ObservableObject {
    @Published private(set) var state: LaunchAtLoginState
    @Published private(set) var isChanging = false
    @Published private(set) var errorDescription: String?

    private let service: LoginItemServiceClient

    init(service: LoginItemServiceClient = .mainApp) {
        self.service = service
        state = LaunchAtLoginState(status: service.status())
    }

    func refresh() {
        guard !isChanging else { return }
        state = LaunchAtLoginState(status: service.status())
    }

    func setEnabled(_ shouldEnable: Bool) {
        guard !isChanging else { return }

        let currentState = LaunchAtLoginState(status: service.status())
        if currentState.isRequested == shouldEnable {
            state = currentState
            return
        }

        isChanging = true
        errorDescription = nil
        defer {
            state = LaunchAtLoginState(status: service.status())
            isChanging = false
        }

        do {
            if shouldEnable {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            errorDescription = error.localizedDescription
        }
    }

    func openSystemSettings() {
        service.openSystemSettings()
    }
}
