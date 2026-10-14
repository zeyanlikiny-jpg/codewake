import Foundation
import XCTest

final class AudioInputSwitchPresentationLocalizationTests: XCTestCase {
    private var resourceBundle: Bundle {
        Bundle(for: AudioInputSwitchPresentationLocalizationTests.self)
    }

    func testStaticButtonStatusErrorAndVoiceOverTextInBothLanguages() {
        let pairs: [(String, String)] = [
            ("Connection unstable — switching paused", "连接不稳定，已暂停切换"),
            ("Couldn’t confirm microphone status", "无法确认麦克风状态"),
            (
                "Couldn’t confirm whether the current microphone is in use. Switching is paused for safety.",
                "无法确认当前麦克风是否正在使用，已为安全起见暂停切换。"
            ),
            ("Input devices changed. Please try again.", "输入设备已变化，请重试。"),
            ("Microphone in use", "麦克风正在使用"),
            ("Please wait…", "请稍候…"),
            (
                "The input device is reconnecting. Switching will be available when it is stable.",
                "输入设备正在重新连接，稳定后才能切换。"
            ),
            (
                "The microphone is being used by another app. Stop recording before switching.",
                "麦克风正在被其他应用使用，请停止录音后再切换。"
            ),
            (
                "The target input became unavailable before switching.",
                "目标输入设备在切换前变为不可用。"
            ),
            (
                "The target input is unstable. Try again when it is ready.",
                "目标输入设备状态不稳定，请在就绪后重试。"
            ),
            (
                "This input device has disconnected repeatedly. Switching will resume automatically when the connection is stable.",
                "该输入设备近期反复断开，连接稳定后会自动恢复。"
            )
        ]

        for (english, chinese) in pairs {
            XCTAssertEqual(localized(english, language: .english), english)
            XCTAssertEqual(localized(english, language: .simplifiedChinese), chinese)
        }
    }

    func testDynamicReconnectAndUnavailableLabelsPreserveDeviceName() {
        let deviceName = "Kenny的「Studio Display」 • %@"
        let cases: [(String, String, String, String)] = [
            (
                "audio.input.switch.reconnecting",
                "Waiting for %@ to reconnect…",
                "Waiting for \(deviceName) to reconnect…",
                "等待 \(deviceName) 重新连接…"
            ),
            (
                "audio.input.switch.unavailable",
                "%@ unavailable",
                "\(deviceName) unavailable",
                "\(deviceName) 不可用"
            )
        ]

        for (key, fallback, english, chinese) in cases {
            let englishResult = L10n.format(
                key,
                defaultValue: fallback,
                language: .english,
                bundle: resourceBundle,
                deviceName
            )
            let chineseResult = L10n.format(
                key,
                defaultValue: fallback,
                language: .simplifiedChinese,
                bundle: resourceBundle,
                deviceName
            )

            XCTAssertEqual(englishResult, english)
            XCTAssertEqual(chineseResult, chinese)
            XCTAssertTrue(englishResult.contains(deviceName))
            XCTAssertTrue(chineseResult.contains(deviceName))
        }
    }

    private func localized(_ key: String, language: AppLanguage) -> String {
        L10n.string(
            key,
            defaultValue: key,
            language: language,
            bundle: resourceBundle
        )
    }
}
