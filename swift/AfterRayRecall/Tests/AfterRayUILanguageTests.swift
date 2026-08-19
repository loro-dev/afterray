import XCTest
@testable import AfterRayRecall

final class AfterRayUILanguageTests: XCTestCase {
    func testAutoFollowsPreferredChinese() {
        XCTAssertEqual(
            AfterRayUILanguage.resolve(stored: "auto", preferred: ["zh-Hans-CN", "en-US"]),
            .simplifiedChinese
        )
        XCTAssertEqual(
            AfterRayUILanguage.resolve(stored: "auto", preferred: ["zh-TW"]),
            .simplifiedChinese
        )
        XCTAssertEqual(
            AfterRayUILanguage.resolve(stored: "", preferred: ["zh-HK", "en"]),
            .simplifiedChinese
        )
    }

    func testAutoFollowsEnglishAndUnknownFallsBack() {
        XCTAssertEqual(
            AfterRayUILanguage.resolve(stored: "auto", preferred: ["en-US"]),
            .english
        )
        XCTAssertEqual(
            AfterRayUILanguage.resolve(stored: "auto", preferred: ["ja-JP"]),
            .english
        )
        XCTAssertEqual(
            AfterRayUILanguage.resolve(stored: "auto", preferred: []),
            .english
        )
    }

    func testExplicitCodeWins() {
        XCTAssertEqual(
            AfterRayUILanguage.resolve(stored: "en", preferred: ["zh-Hans-CN"]),
            .english
        )
        XCTAssertEqual(
            AfterRayUILanguage.resolve(stored: "zh-Hans", preferred: ["en-US"]),
            .simplifiedChinese
        )
        XCTAssertEqual(
            AfterRayUILanguage.resolve(stored: "ja", preferred: ["zh-Hans-CN"]),
            .english
        )
    }

    func testEnglishFormattersStayPinned() {
        XCTAssertEqual(
            RelativeStamp.short(fromMs: 0, nowMs: 0, copy: .english),
            "NOW"
        )
        XCTAssertEqual(
            DaySummaryLayout.dateHeading(dayStartMs: 0, nowMs: 0, copy: .english).kicker,
            "TODAY"
        )
        XCTAssertEqual(
            ChatTimeLabel.dayHeading(ms: 1_000, now: Date(timeIntervalSince1970: 1), copy: .english),
            "Today"
        )
    }

    func testChineseCatalogIsRead() {
        let copy = AfterRayCopy.simplifiedChinese
        XCTAssertEqual(copy.format.now, "现在")
        XCTAssertEqual(copy.format.today, "今天")
        XCTAssertEqual(copy.onboarding.headlineHotKey, "打开 AfterRay。")
        XCTAssertEqual(copy.settings.interface, "界面")
        XCTAssertEqual(copy.common.followSystem, "跟随系统")
        XCTAssertEqual(
            RelativeStamp.short(fromMs: 0, nowMs: 0, copy: copy),
            "现在"
        )
    }

    func testUiLanguagePickerOffersOnlyShippedLanguages() {
        let settings = AppSettings(
            dataDir: "/tmp/data",
            modelDir: "/tmp/models",
            recordAudio: true,
            captureIntervalSeconds: 10,
            languageOptions: [
                LanguageOption(code: "auto", nativeName: "跟随系统 / System", englishName: "Follow system"),
                LanguageOption(code: "en", nativeName: "English", englishName: "English"),
                LanguageOption(code: "ja", nativeName: "日本語", englishName: "Japanese"),
            ]
        )
        XCTAssertEqual(
            settings.uiLanguagePickerOptions(selected: "auto").map(\.code),
            ["auto", "en", "zh-Hans"]
        )
        XCTAssertEqual(
            settings.uiLanguagePickerOptions(selected: "ja").map(\.code),
            ["auto", "en", "zh-Hans", "ja"]
        )
        XCTAssertEqual(
            settings.languagePickerOptions(selected: "ja").map(\.code),
            ["auto", "en", "ja"]
        )
    }

    func testMenuTitleFollowsCopy() {
        XCTAssertEqual(LanguageOption.followSystem.menuTitle(.english), "Follow system")
        XCTAssertEqual(LanguageOption.followSystem.menuTitle(.simplifiedChinese), "跟随系统")
        XCTAssertEqual(
            LanguageOption(code: "ja", nativeName: "日本語", englishName: "Japanese")
                .menuTitle(.english),
            "日本語"
        )
    }
}
