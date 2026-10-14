import Foundation
import XCTest

final class LocalizationTests: XCTestCase {
    private var resourceBundle: Bundle {
        Bundle(for: LocalizationTests.self)
    }

    func testCatalogBuildsBothSupportedLanguageResources() {
        XCTAssertNotNil(
            resourceBundle.path(forResource: "en", ofType: "lproj"),
            "The English localization must be shipped in the test and app bundles."
        )
        XCTAssertNotNil(
            resourceBundle.path(forResource: "zh-Hans", ofType: "lproj"),
            "The Simplified Chinese localization must be shipped in the test and app bundles."
        )
    }

    func testStaticCatalogStringsResolveForBothLanguages() {
        XCTAssertEqual(
            localized("General", defaultValue: "General", language: .english),
            "General"
        )
        XCTAssertEqual(
            localized(
                "General",
                defaultValue: "General",
                language: .simplifiedChinese
            ),
            "通用"
        )
        XCTAssertEqual(
            localized(
                "window.settings.title",
                defaultValue: "CodeWake Settings",
                language: .english
            ),
            "CodeWake Settings"
        )
        XCTAssertEqual(
            localized(
                "window.settings.title",
                defaultValue: "CodeWake Settings",
                language: .simplifiedChinese
            ),
            "CodeWake · 醒码 设置"
        )
    }

    func testProductBrandUsesLocalizedNamesAndPreservesUpstreamAttribution() {
        let pairs: [(String, String)] = [
            ("CodeWake", "CodeWake · 醒码"),
            ("Quit CodeWake", "退出 CodeWake · 醒码"),
            ("Welcome to CodeWake", "欢迎使用 CodeWake · 醒码"),
            ("Launch CodeWake at login", "登录时启动 CodeWake · 醒码"),
            (
                "Based on Lidless by Nghia Luong (MIT)",
                "基于 Nghia Luong 的 Lidless（MIT）"
            ),
            ("View the original Lidless project", "查看原始 Lidless 项目")
        ]

        for (english, chinese) in pairs {
            XCTAssertEqual(localized(english, defaultValue: english, language: .english), english)
            XCTAssertEqual(
                localized(english, defaultValue: english, language: .simplifiedChinese),
                chinese
            )
        }
    }

    func testBrandInCanonicalErrorsLocalizesWithoutSplittingTheChineseName() {
        let canonical = "The helper has a wake lease that CodeWake cannot safely release."
        XCTAssertEqual(
            PresentationLocalizer.string(canonical, language: .english, bundle: resourceBundle),
            canonical
        )
        XCTAssertEqual(
            PresentationLocalizer.string(
                canonical,
                language: .simplifiedChinese,
                bundle: resourceBundle
            ),
            "辅助程序存在 CodeWake · 醒码 无法安全释放的唤醒租约。"
        )

        let conflict = HookIntegrationError.conflictingBridgeCommand("Stop").errorDescription!
        XCTAssertEqual(
            PresentationLocalizer.string(conflict, language: .english, bundle: resourceBundle),
            "A different CodeWake bridge command already exists for Stop. No changes were made."
        )
        XCTAssertEqual(
            PresentationLocalizer.string(
                conflict,
                language: .simplifiedChinese,
                bundle: resourceBundle
            ),
            "已存在其他 CodeWake · 醒码 桥接命令，未进行任何更改。"
        )
    }

    func testMenuHeightStringsResolveForBothLanguages() {
        let pairs: [(String, String, String)] = [
            ("Menu height", "Menu height", "菜单高度"),
            ("30% Taller", "30% Taller", "加长 30%"),
            ("Show All", "Show All", "显示全部"),
            (
                "Menus still scroll on smaller screens.",
                "Menus still scroll on smaller screens.",
                "小屏幕上的菜单仍可滚动。"
            )
        ]

        for (key, english, chinese) in pairs {
            XCTAssertEqual(localized(key, defaultValue: english, language: .english), english)
            XCTAssertEqual(
                localized(key, defaultValue: english, language: .simplifiedChinese),
                chinese
            )
        }
    }

    func testAudioInputStaticStringsResolveForBothLanguages() {
        let pairs: [(String, String, String)] = [
            (
                "Changes the macOS default input. Apps pinned to another microphone may not follow it.",
                "Changes the macOS default input. Apps pinned to another microphone may not follow it.",
                "更改 macOS 默认输入。已固定使用其他麦克风的应用可能不会跟随切换。"
            ),
            (
                "Choose a different device for each slot. Unavailable inputs stay saved until they reconnect.",
                "Choose a different device for each slot. Unavailable inputs stay saved until they reconnect.",
                "请为每个位置选择不同的设备。不可用的输入会保留，重新连接后即可使用。"
            ),
            ("Choose an input…", "Choose an input…", "选择输入设备…"),
            (
                "Choose two different input devices. Offline selections stay saved and become available again when reconnected.",
                "Choose two different input devices. Offline selections stay saved and become available again when reconnected.",
                "请选择两个不同的输入设备。离线选择会保留，并在重新连接后恢复可用。"
            ),
            ("Configure Input Switching…", "Configure Input Switching…", "配置输入切换…"),
            (
                "Couldn’t monitor system input changes. CodeWake will refresh before switching.",
                "Couldn’t monitor system input changes. CodeWake will refresh before switching.",
                "无法实时监控系统输入变化。CodeWake · 醒码 会在切换前刷新。"
            ),
            (
                "Couldn’t read the available system input devices.",
                "Couldn’t read the available system input devices.",
                "无法读取可用的系统输入设备。"
            ),
            (
                "Couldn’t switch the system input device.",
                "Couldn’t switch the system input device.",
                "无法切换系统输入设备。"
            ),
            ("Current system input", "Current system input", "当前系统输入"),
            ("Input A", "Input A", "输入 A"),
            ("Input B", "Input B", "输入 B"),
            ("Input switching", "Input switching", "输入切换"),
            (
                "CodeWake changes only the macOS default input. Apps that use a fixed microphone may not follow it.",
                "CodeWake changes only the macOS default input. Apps that use a fixed microphone may not follow it.",
                "CodeWake · 醒码 只更改 macOS 默认输入。使用固定麦克风的应用可能不会跟随切换。"
            ),
            ("Microphone input", "Microphone input", "麦克风输入"),
            ("No system input", "No system input", "无系统输入设备"),
            ("Switching input…", "Switching input…", "正在切换输入…"),
            (
                "The selected input device is no longer available.",
                "The selected input device is no longer available.",
                "所选输入设备已不可用。"
            ),
            (
                "macOS didn’t confirm the system input change.",
                "macOS didn’t confirm the system input change.",
                "macOS 未能确认系统输入更改。"
            )
        ]

        for (key, english, chinese) in pairs {
            XCTAssertEqual(localized(key, defaultValue: key, language: .english), english)
            XCTAssertEqual(
                localized(key, defaultValue: key, language: .simplifiedChinese),
                chinese
            )
        }
    }

    func testAudioInputDynamicStringsPreserveDeviceNameInBothLanguages() {
        let deviceName = "Kenny的「Studio Display」 • 麦克风 %@"
        let cases: [(String, String, String, String)] = [
            (
                "audio.input.choice.unavailable",
                "%@ (Unavailable)",
                "\(deviceName) (Unavailable)",
                "\(deviceName)（不可用）"
            ),
            (
                "audio.input.current.accessibility",
                "Current system input: %@",
                "Current system input: \(deviceName)",
                "当前系统输入：\(deviceName)"
            ),
            (
                "audio.input.switch.accessibility",
                "Switch system input to %@",
                "Switch system input to \(deviceName)",
                "将系统输入切换到 \(deviceName)"
            ),
            (
                "audio.input.switch.button",
                "Switch to %@",
                "Switch to \(deviceName)",
                "切换到 \(deviceName)"
            )
        ]

        for (key, defaultValue, english, chinese) in cases {
            let englishResult = L10n.format(
                key,
                defaultValue: defaultValue,
                language: .english,
                bundle: resourceBundle,
                deviceName
            )
            let chineseResult = L10n.format(
                key,
                defaultValue: defaultValue,
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

    func testAudioInputVoiceOverLabelsAndHintsResolveForBothLanguages() {
        let deviceName = "Studio Display Microphone"

        XCTAssertEqual(
            L10n.format(
                "audio.input.current.accessibility",
                defaultValue: "Current system input: %@",
                language: .english,
                bundle: resourceBundle,
                deviceName
            ),
            "Current system input: Studio Display Microphone"
        )
        XCTAssertEqual(
            L10n.format(
                "audio.input.current.accessibility",
                defaultValue: "Current system input: %@",
                language: .simplifiedChinese,
                bundle: resourceBundle,
                deviceName
            ),
            "当前系统输入：Studio Display Microphone"
        )
        XCTAssertEqual(
            L10n.format(
                "audio.input.switch.accessibility",
                defaultValue: "Switch system input to %@",
                language: .english,
                bundle: resourceBundle,
                deviceName
            ),
            "Switch system input to Studio Display Microphone"
        )
        XCTAssertEqual(
            L10n.format(
                "audio.input.switch.accessibility",
                defaultValue: "Switch system input to %@",
                language: .simplifiedChinese,
                bundle: resourceBundle,
                deviceName
            ),
            "将系统输入切换到 Studio Display Microphone"
        )

        let hints: [(String, String)] = [
            (
                "Changes the macOS default input. Apps pinned to another microphone may not follow it.",
                "更改 macOS 默认输入。已固定使用其他麦克风的应用可能不会跟随切换。"
            ),
            (
                "Choose a different device for each slot. Unavailable inputs stay saved until they reconnect.",
                "请为每个位置选择不同的设备。不可用的输入会保留，重新连接后即可使用。"
            )
        ]

        for (english, chinese) in hints {
            XCTAssertEqual(
                localized(english, defaultValue: english, language: .english),
                english
            )
            XCTAssertEqual(
                localized(english, defaultValue: english, language: .simplifiedChinese),
                chinese
            )
        }
    }

    func testDisplayAwakeControlAndWarningsResolveForBothLanguages() {
        let pairs: [(String, String, String)] = [
            ("Keep display awake", "Keep display awake", "保持屏幕常亮"),
            (
                "Keep display awake during activity",
                "Keep display awake during activity",
                "活动期间保持屏幕常亮"
            ),
            (
                "Prevents idle display sleep only during active AI work or a manual or timed hold—not while waiting, confirming completion, or charging alone. It doesn’t light a sleeping display or override lid-closed behavior.",
                "Prevents idle display sleep only during active AI work or a manual or timed hold—not while waiting, confirming completion, or charging alone. It doesn’t light a sleeping display or override lid-closed behavior.",
                "仅在 AI 正在工作、手动保持或计时保持期间防止显示器因闲置熄灭；等待输入、确认完成或仅充电保持时不会常亮。它不会点亮已熄灭的屏幕，也不会覆盖合盖行为。"
            ),
            (
                "Only prevents idle display sleep during active AI work or a manual or timed hold. Waiting, completion confirmation, and charging-only holds do not keep it on. It does not light a sleeping display or override lid-closed behavior.",
                "Only prevents idle display sleep during active AI work or a manual or timed hold. Waiting, completion confirmation, and charging-only holds do not keep it on. It does not light a sleeping display or override lid-closed behavior.",
                "仅在 AI 正在工作、手动保持或计时保持期间防止显示器因闲置熄灭。等待输入、确认完成或仅充电保持时不会常亮。它不会点亮已熄灭的屏幕，也不会覆盖合盖行为。"
            ),
            (
                "Couldn’t keep the screen on. Mac keep-awake remains active.",
                "Couldn’t keep the screen on. Mac keep-awake remains active.",
                "无法保持屏幕常亮。Mac 保持唤醒仍然有效。"
            ),
            (
                "Couldn’t release the screen-on hold immediately. It will expire automatically.",
                "Couldn’t release the screen-on hold immediately. It will expire automatically.",
                "无法立即释放屏幕常亮，断言将在超时后自动失效。"
            ),
            (
                "Install and approve the background helper before using keep-awake. It owns persistent system-sleep changes and restores the prior state after a crash or timeout.",
                "Install and approve the background helper before using keep-awake. It owns persistent system-sleep changes and restores the prior state after a crash or timeout.",
                "使用保持唤醒前，请安装并批准后台辅助程序。它负责持久的系统睡眠变更，并会在崩溃或超时后恢复之前的状态。"
            )
        ]

        for (key, english, chinese) in pairs {
            XCTAssertEqual(localized(key, defaultValue: key, language: .english), english)
            XCTAssertEqual(
                localized(key, defaultValue: key, language: .simplifiedChinese),
                chinese
            )
        }

    }

    func testBuiltInDisplayBlackoutStringsResolveForBothLanguages() {
        let pairs: [(String, String, String)] = [
            ("Built-in display", "Built-in display", "内置屏幕"),
            (
                "Turn Off Built-in Display",
                "Turn Off Built-in Display",
                "内屏熄灭"
            ),
            (
                "Restore Built-in Display",
                "Restore Built-in Display",
                "恢复内屏"
            ),
            (
                "Sets only the built-in display brightness to zero. For 1.5 seconds after turn-off, pointer movement, dragging, and scrolling do not restore brightness. Click again or press a regular key to restore immediately; after that, any input restores brightness.",
                "Sets only the built-in display brightness to zero. For 1.5 seconds after turn-off, pointer movement, dragging, and scrolling do not restore brightness. Click again or press a regular key to restore immediately; after that, any input restores brightness.",
                "仅将内置屏幕亮度设为零。熄屏后 1.5 秒内，移动、拖动和滚动不会恢复亮度。再次点击或按下普通按键会立即恢复；之后任意输入都会恢复亮度。"
            ),
            (
                "Unavailable while an external display is connected.",
                "Unavailable while an external display is connected.",
                "连接外接显示器时不可用"
            ),
            (
                "Turn on keep-awake before turning off the built-in display.",
                "Turn on keep-awake before turning off the built-in display.",
                "请先开启防睡眠，再熄灭内屏。"
            ),
            (
                "Display status could not be confirmed.",
                "Display status could not be confirmed.",
                "无法确认显示器状态。"
            ),
            (
                "Built-in display brightness control is unavailable.",
                "Built-in display brightness control is unavailable.",
                "内置屏幕亮度控制不可用。"
            ),
            (
                "For 1.5 seconds after turn-off, pointer movement, dragging, and scrolling do not restore brightness. Click again or press a regular key to restore immediately; after that, any input restores brightness.",
                "For 1.5 seconds after turn-off, pointer movement, dragging, and scrolling do not restore brightness. Click again or press a regular key to restore immediately; after that, any input restores brightness.",
                "熄屏后 1.5 秒内，移动、拖动和滚动不会恢复亮度。再次点击或按下普通按键会立即恢复；之后任意输入都会恢复亮度。"
            ),
            (
                "The built-in display is offline. Brightness will be restored when it reconnects.",
                "The built-in display is offline. Brightness will be restored when it reconnects.",
                "内置屏幕已离线，重新上线后将恢复亮度。"
            )
        ]

        for (key, english, chinese) in pairs {
            XCTAssertEqual(localized(key, defaultValue: key, language: .english), english)
            XCTAssertEqual(
                localized(key, defaultValue: key, language: .simplifiedChinese),
                chinese
            )
        }
    }

    func testDisplaySleepRecoveryStringsResolveForBothLanguages() {
        let pairs: [(String, String)] = [
            (
                "The built-in display is not ready. Open the lid and wait for brightness to recover, then try again.",
                "内置屏幕尚未就绪。请打开上盖，等待亮度恢复后重试。"
            ),
            (
                "Built-in brightness recovery failed. Raise the built-in display brightness and try again.",
                "内屏亮度恢复失败。请调高内置屏幕亮度后重试。"
            ),
            (
                "Couldn’t confirm the lid or display state. Wait for the displays to reconnect and try again.",
                "无法确认上盖或显示器状态。请等待显示器重新连接后重试。"
            ),
            (
                "The saved brightness recovery record could not be verified. It has been preserved; display sleep was not requested.",
                "无法验证保存的亮度恢复记录。记录已保留，未发起熄屏请求。"
            ),
            (
                "The brightness recovery process is unavailable. Open the lid to restore brightness before trying again.",
                "亮度恢复程序暂不可用。请打开上盖恢复亮度后重试。"
            ),
            (
                "Built-in display recovery encountered an error. The recovery record has been preserved.",
                "内置屏幕恢复出错，恢复记录已保留。"
            ),
            (
                "Built-in display recovery is taking too long. Wait for brightness to recover and try again.",
                "内屏亮度恢复用时过长。请等待亮度恢复后重试。"
            ),
            (
                "The lid is closed. Built-in brightness will recover when opened; external displays can still be turned off.",
                "内屏已合盖，开盖后自动恢复亮度；仍可熄灭外接屏幕。"
            ),
            (
                "Built-in display brightness recovery is pending.",
                "内屏亮度等待恢复。"
            )
        ]

        for (english, chinese) in pairs {
            XCTAssertEqual(
                localized(english, defaultValue: english, language: .english),
                english
            )
            XCTAssertEqual(
                localized(english, defaultValue: english, language: .simplifiedChinese),
                chinese
            )
        }
    }

    func testAllDisplaysSleepStringsResolveForBothLanguages() {
        let pairs: [(String, String)] = [
            ("All displays", "全部屏幕"),
            ("Turn Off All Displays", "全部熄屏"),
            ("Turning Off Displays…", "正在熄屏…"),
            (
                "Turns off the built-in and all external displays after 1.5 seconds. Move the mouse or press a key to restore the displays. The Mac keeps its current keep-awake rules.",
                "1.5 秒后熄灭内置和所有外接屏幕。移动鼠标或按键恢复显示，电脑沿用现有防睡眠规则。"
            ),
            (
                "Couldn’t restore the built-in display before turning off all displays.",
                "无法先恢复内置屏幕，因此未能熄灭全部屏幕。"
            ),
            (
                "Couldn’t start the display sleep request.",
                "无法发起屏幕熄灭请求。"
            ),
            (
                "macOS couldn’t turn off all displays.",
                "macOS 无法熄灭全部屏幕。"
            ),
            (
                "The display sleep request timed out.",
                "屏幕熄灭请求超时。"
            ),
            (
                "macOS didn’t confirm that all displays turned off.",
                "macOS 未能确认全部屏幕已熄灭。"
            )
        ]

        for (english, chinese) in pairs {
            XCTAssertEqual(
                localized(english, defaultValue: english, language: .english),
                english
            )
            XCTAssertEqual(
                localized(english, defaultValue: english, language: .simplifiedChinese),
                chinese
            )
        }
    }

    func testCodexRefreshAndRestoreStringsResolveInBothLanguages() {
        let pairs: [(String, String, String)] = [
            ("Codex status & recovery", "Codex status & recovery", "Codex 状态与恢复"),
            ("Codex status", "Codex status", "Codex 状态"),
            ("Codex task cancelled", "Codex task cancelled", "已检测到 Codex 任务取消"),
            (
                "Codex cancellation detected. The cancelled task is no longer counted as active. CodeWake does not request immediate sleep.",
                "Codex cancellation detected. The cancelled task is no longer counted as active. CodeWake does not request immediate sleep.",
                "已检测到 Codex 任务取消。该任务将不再计为活动任务，CodeWake · 醒码 不会请求立即睡眠。"
            ),
            ("Emergency recovery", "Emergency recovery", "紧急恢复"),
            ("Refresh Codex Status", "Refresh Codex Status", "刷新 Codex 状态"),
            ("Restore Normal Sleep", "Restore Normal Sleep", "恢复正常休眠"),
            ("codex.software.desktop_open", "Desktop app open", "桌面版已开启"),
            ("codex.task.idle", "No active task", "无活动任务"),
            (
                "CodeWake, Mac awake, Codex working",
                "CodeWake, Mac awake, Codex working",
                "CodeWake · 醒码，Mac 保持唤醒，Codex 正在工作"
            ),
            (
                "CodeWake, Mac awake, manual hold active",
                "CodeWake, Mac awake, manual hold active",
                "CodeWake · 醒码，Mac 保持唤醒，手动保持已开启"
            ),
            (
                "CodeWake, Mac awake, Codex waiting for input or confirming completion",
                "CodeWake, Mac awake, Codex waiting for input or confirming completion",
                "CodeWake · 醒码，Mac 保持唤醒，Codex 正在等待输入或确认完成"
            ),
            (
                "codex.restore.result.restored",
                "Normal sleep restored. All CodeWake holds were cleared.",
                "已恢复正常休眠，当前 CodeWake · 醒码 保持已全部清除。"
            )
        ]

        for (key, english, chinese) in pairs {
            XCTAssertEqual(localized(key, defaultValue: english, language: .english), english)
            XCTAssertEqual(
                localized(key, defaultValue: english, language: .simplifiedChinese),
                chinese
            )
        }

        XCTAssertEqual(
            L10n.format(
                "codex.task.waiting.permission",
                defaultValue: "Waiting for permission (%d)",
                language: .simplifiedChinese,
                bundle: resourceBundle,
                2
            ),
            "等待授权（2）"
        )
        XCTAssertEqual(
            L10n.format(
                "codex.task.unknown_count",
                defaultValue: "Unknown (%d)",
                language: .simplifiedChinese,
                bundle: resourceBundle,
                3
            ),
            "未知（3）"
        )
    }

    func testCancelledCodexNoticeLocalizesAsACompleteStatus() {
        let canonical = "Codex task cancelled · system sleep restored"
        XCTAssertEqual(
            PresentationLocalizer.string(
                canonical,
                language: .english,
                bundle: resourceBundle
            ),
            canonical
        )
        XCTAssertEqual(
            PresentationLocalizer.string(
                canonical,
                language: .simplifiedChinese,
                bundle: resourceBundle
            ),
            "已检测到 Codex 任务取消 · 已恢复系统睡眠"
        )
    }

    func testSelectedLanguageControlsPluralAndDynamicFormatting() {
        XCTAssertEqual(taskCount(1, language: .english), "1 task")
        XCTAssertEqual(taskCount(3, language: .english), "3 tasks")
        XCTAssertEqual(taskCount(1, language: .simplifiedChinese), "1 个任务")
        XCTAssertEqual(taskCount(3, language: .simplifiedChinese), "3 个任务")

        XCTAssertEqual(hourCount(1, language: .english), "1 hour")
        XCTAssertEqual(hourCount(4, language: .english), "4 hours")
        XCTAssertEqual(hourCount(1, language: .simplifiedChinese), "1 小时")
        XCTAssertEqual(hourCount(4, language: .simplifiedChinese), "4 小时")

        XCTAssertEqual(waitMinutes(1, language: .english), "1 minute")
        XCTAssertEqual(waitMinutes(5, language: .english), "5 minutes")
        XCTAssertEqual(waitMinutes(1, language: .simplifiedChinese), "1 分钟")
        XCTAssertEqual(waitMinutes(5, language: .simplifiedChinese), "5 分钟")

        XCTAssertEqual(
            L10n.format(
                "onboarding.step_progress",
                defaultValue: "Step %d of %d",
                language: .english,
                bundle: resourceBundle,
                2,
                5
            ),
            "Step 2 of 5"
        )
        XCTAssertEqual(
            L10n.format(
                "onboarding.step_progress",
                defaultValue: "Step %d of %d",
                language: .simplifiedChinese,
                bundle: resourceBundle,
                2,
                5
            ),
            "第 2 步，共 5 步"
        )

        XCTAssertEqual(
            L10n.format(
                "display.status.named",
                defaultValue: "External display: %@",
                language: .simplifiedChinese,
                bundle: resourceBundle,
                "LG UltraFine"
            ),
            "外接显示器：LG UltraFine"
        )
        XCTAssertEqual(
            L10n.format(
                "display.status.multiple",
                defaultValue: "%d external displays connected",
                language: .simplifiedChinese,
                bundle: resourceBundle,
                2
            ),
            "外接显示器：已连接（2 台）"
        )
        XCTAssertEqual(
            L10n.format(
                "display.accessibility.multiple_named",
                defaultValue: "%d external displays connected: %@",
                language: .english,
                bundle: resourceBundle,
                2,
                "LG UltraFine, Studio Display"
            ),
            "2 external displays connected: LG UltraFine, Studio Display"
        )
    }

    func testPresentationLocalizerRendersSameCanonicalStateInEitherLanguage() {
        let canonical = "2 working · 1 waiting"

        XCTAssertEqual(
            PresentationLocalizer.string(
                canonical,
                language: .english,
                bundle: resourceBundle
            ),
            canonical
        )
        XCTAssertEqual(
            PresentationLocalizer.string(
                canonical,
                language: .simplifiedChinese,
                bundle: resourceBundle
            ),
            "2 个进行中 · 1 个等待中"
        )

        XCTAssertEqual(
            PresentationLocalizer.string(
                "Auto-off: 1 hour elapsed.",
                language: .english,
                bundle: resourceBundle
            ),
            "Auto-off: 1 hour elapsed."
        )
        XCTAssertEqual(
            PresentationLocalizer.string(
                "Auto-off: 1 hour elapsed.",
                language: .simplifiedChinese,
                bundle: resourceBundle
            ),
            "自动关闭：已过 1 小时。"
        )
    }

    func testCompletionSnapshotsStateFactsAtCompletionInEitherLanguage() {
        let snapshots = [
            (
                "system sleep restored; lid was open at completion",
                "已恢复系统睡眠；完成时上盖打开"
            ),
            (
                "system sleep restored; external display was connected at completion",
                "已恢复系统睡眠；完成时已连接外接显示器"
            ),
            (
                "system sleep restored; display state was unknown at completion",
                "已恢复系统睡眠；完成时显示器状态未知"
            ),
            (
                "system sleep restored; lid state was unknown at completion",
                "已恢复系统睡眠；完成时上盖状态未知"
            )
        ]

        for (canonical, chinese) in snapshots {
            let labeled = "FINISHED · \(canonical)"
            XCTAssertEqual(
                PresentationLocalizer.string(
                    labeled,
                    language: .english,
                    bundle: resourceBundle
                ),
                labeled
            )
            XCTAssertEqual(
                PresentationLocalizer.string(
                    labeled,
                    language: .simplifiedChinese,
                    bundle: resourceBundle
                ),
                "已完成 · \(chinese)"
            )
        }
    }

    func testPresentationLocalizerPreservesKnownBrandNamesThatMatchTheirKeys() {
        for brand in ["Codex", "Claude Code", "Cursor"] {
            XCTAssertEqual(
                PresentationLocalizer.string(
                    brand,
                    language: .english,
                    bundle: resourceBundle
                ),
                brand
            )
            XCTAssertEqual(
                PresentationLocalizer.string(
                    brand,
                    language: .simplifiedChinese,
                    bundle: resourceBundle
                ),
                brand
            )
        }

        XCTAssertEqual(
            PresentationLocalizer.string(
                "Manual hold",
                language: .simplifiedChinese,
                bundle: resourceBundle
            ),
            "手动保持"
        )
        XCTAssertEqual(
            PresentationLocalizer.string(
                "External/system",
                language: .simplifiedChinese,
                bundle: resourceBundle
            ),
            "外部/系统"
        )
        XCTAssertEqual(
            PresentationLocalizer.string(
                "Manual hold, Codex",
                language: .simplifiedChinese,
                bundle: resourceBundle
            ),
            "手动保持、Codex"
        )
        XCTAssertEqual(
            PresentationLocalizer.string(
                "Codex, Claude Code",
                language: .simplifiedChinese,
                bundle: resourceBundle
            ),
            "Codex、Claude Code"
        )
        XCTAssertEqual(
            PresentationLocalizer.string(
                "Codex, Claude Code",
                language: .english,
                bundle: resourceBundle
            ),
            "Codex, Claude Code"
        )
    }

    func testPresenceLookupDistinguishesIdenticalTranslationFromMissingKey() {
        XCTAssertEqual(
            L10n.stringIfPresent(
                "Codex",
                language: .simplifiedChinese,
                bundle: resourceBundle
            ),
            "Codex"
        )
        XCTAssertNil(
            L10n.stringIfPresent(
                "test.missing.\(UUID().uuidString)",
                language: .simplifiedChinese,
                bundle: resourceBundle
            )
        )
    }

    func testPresentationLocalizerFormatsCountdownAndHidesRawErrorsInChinese() {
        XCTAssertEqual(
            PresentationLocalizer.string(
                "Input-wait release in: 04:59",
                language: .english,
                bundle: resourceBundle
            ),
            "Input-wait release in: 04:59"
        )
        XCTAssertEqual(
            PresentationLocalizer.string(
                "Input-wait release in: 04:59",
                language: .simplifiedChinese,
                bundle: resourceBundle
            ),
            "等待输入释放倒计时：04:59"
        )

        let rawError = "NSXPCConnection interrupted with internal code 4097"
        XCTAssertEqual(
            PresentationLocalizer.string(
                rawError,
                language: .english,
                bundle: resourceBundle
            ),
            rawError
        )
        XCTAssertEqual(
            PresentationLocalizer.string(
                rawError,
                language: .simplifiedChinese,
                bundle: resourceBundle
            ),
            "发生了意外错误。"
        )
    }

    func testDynamicIntegrationErrorsUseStableChineseMessages() {
        let hookConflict = "The hook configuration has an incompatible value at hooks.Stop. No changes were made."
        XCTAssertEqual(
            PresentationLocalizer.string(
                hookConflict,
                language: .english,
                bundle: resourceBundle
            ),
            hookConflict
        )
        XCTAssertEqual(
            PresentationLocalizer.string(
                hookConflict,
                language: .simplifiedChinese,
                bundle: resourceBundle
            ),
            "Hook 配置包含不兼容的值，未进行任何更改。"
        )

        XCTAssertEqual(
            PresentationLocalizer.string(
                "bind failed: Address already in use",
                language: .simplifiedChinese,
                bundle: resourceBundle
            ),
            "AI 事件桥接无法启动。"
        )

        let stableErrors: [(AppPresentationError, String)] = [
            (.eventBridgeStartFailed, "AI 事件桥接无法启动。"),
            (.helperVersionCheckFailed, "无法验证后台辅助程序版本。"),
            (.systemSleepRequestFailed, "无法请求系统睡眠；已恢复正常睡眠策略。")
        ]
        for (error, expected) in stableErrors {
            XCTAssertEqual(
                PresentationLocalizer.string(
                    error.canonicalMessage,
                    language: .simplifiedChinese,
                    bundle: resourceBundle
                ),
                expected
            )
        }
    }

    func testProtocolDiagnosticValuesRemainVerbatimInEitherLanguage() {
        for diagnostic in ["toolFinished", "none", "leaseOwnerMismatch"] {
            XCTAssertEqual(
                localized(
                    diagnostic,
                    defaultValue: diagnostic,
                    language: .english
                ),
                diagnostic
            )
            XCTAssertEqual(
                localized(
                    diagnostic,
                    defaultValue: diagnostic,
                    language: .simplifiedChinese
                ),
                diagnostic
            )
        }
    }

    func testMissingCatalogKeyUsesCallerFallbackInEitherLanguage() {
        let missingKey = "test.missing.\(UUID().uuidString)"

        for language in AppLanguage.allCases {
            XCTAssertEqual(
                localized(
                    missingKey,
                    defaultValue: "Safe fallback",
                    language: language
                ),
                "Safe fallback"
            )
        }
    }

    private func localized(
        _ key: String,
        defaultValue: String,
        language: AppLanguage
    ) -> String {
        L10n.string(
            key,
            defaultValue: defaultValue,
            language: language,
            bundle: resourceBundle
        )
    }

    private func taskCount(_ count: Int, language: AppLanguage) -> String {
        L10n.format(
            "agent.task_count",
            defaultValue: "%d tasks",
            language: language,
            bundle: resourceBundle,
            count
        )
    }

    private func hourCount(_ count: Int, language: AppLanguage) -> String {
        L10n.format(
            "duration.hours",
            defaultValue: "%d hours",
            language: language,
            bundle: resourceBundle,
            count
        )
    }

    private func waitMinutes(_ count: Int, language: AppLanguage) -> String {
        L10n.format(
            "ai.wait.minutes",
            defaultValue: "%d minutes",
            language: language,
            bundle: resourceBundle,
            count
        )
    }
}
