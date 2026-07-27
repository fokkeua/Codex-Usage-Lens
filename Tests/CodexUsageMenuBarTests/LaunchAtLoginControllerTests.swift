import Foundation
import ServiceManagement
import Testing
@testable import CodexUsageMenuBar

@Test(
    "Системные статусы автозапуска преобразуются в состояние интерфейса",
    arguments: [
        (SMAppService.Status.notRegistered, LaunchAtLoginState.disabled),
        (SMAppService.Status.enabled, LaunchAtLoginState.enabled),
        (
            SMAppService.Status.requiresApproval,
            LaunchAtLoginState.requiresApproval
        ),
        (SMAppService.Status.notFound, LaunchAtLoginState.unavailable),
    ]
)
func launchAtLoginStateMapping(
    status: SMAppService.Status,
    expected: LaunchAtLoginState
) {
    #expect(LaunchAtLoginState(status: status) == expected)
}

@MainActor
@Test("Переключатель регистрирует и удаляет main-app login item")
func launchAtLoginControllerChangesRegistration() {
    final class ServiceState {
        var status = SMAppService.Status.notRegistered
        var registerCalls = 0
        var unregisterCalls = 0
    }

    let serviceState = ServiceState()
    let service = LoginItemServiceClient(
        status: { serviceState.status },
        register: {
            serviceState.registerCalls += 1
            serviceState.status = .enabled
        },
        unregister: {
            serviceState.unregisterCalls += 1
            serviceState.status = .notRegistered
        },
        openSystemSettings: {}
    )
    let controller = LaunchAtLoginController(service: service)

    #expect(controller.state == .disabled)

    controller.setEnabled(true)
    #expect(controller.state == .enabled)
    #expect(serviceState.registerCalls == 1)
    #expect(serviceState.unregisterCalls == 0)

    controller.setEnabled(false)
    #expect(controller.state == .disabled)
    #expect(serviceState.registerCalls == 1)
    #expect(serviceState.unregisterCalls == 1)
}

@MainActor
@Test("Ошибка регистрации показывается и не включает переключатель")
func launchAtLoginControllerReportsRegistrationError() {
    let service = LoginItemServiceClient(
        status: { .notRegistered },
        register: {
            throw NSError(
                domain: "LaunchAtLoginControllerTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Registration denied"]
            )
        },
        unregister: {},
        openSystemSettings: {}
    )
    let controller = LaunchAtLoginController(service: service)

    controller.setEnabled(true)

    #expect(controller.state == .disabled)
    #expect(controller.errorDescription == "Registration denied")
    #expect(!controller.isChanging)
}
