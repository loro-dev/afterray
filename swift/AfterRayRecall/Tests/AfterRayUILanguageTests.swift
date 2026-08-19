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
            .traditionalChinese
        )
        XCTAssertEqual(
            AfterRayUILanguage.resolve(stored: "", preferred: ["zh-HK", "en"]),
            .traditionalChinese
        )
    }

    func testAutoFollowsShippedLanguagesAndUnknownFallsBack() {
        XCTAssertEqual(
            AfterRayUILanguage.resolve(stored: "auto", preferred: ["en-US"]),
            .english
        )
        XCTAssertEqual(
            AfterRayUILanguage.resolve(stored: "auto", preferred: ["ja-JP"]),
            .japanese
        )
        XCTAssertEqual(
            AfterRayUILanguage.resolve(stored: "auto", preferred: ["ko-KR"]),
            .korean
        )
        XCTAssertEqual(
            AfterRayUILanguage.resolve(stored: "auto", preferred: ["es-MX", "en"]),
            .spanish
        )
        XCTAssertEqual(
            AfterRayUILanguage.resolve(stored: "auto", preferred: ["de-DE"]),
            .german
        )
        XCTAssertEqual(
            AfterRayUILanguage.resolve(stored: "auto", preferred: ["fr-FR"]),
            .french
        )
        XCTAssertEqual(
            AfterRayUILanguage.resolve(stored: "auto", preferred: ["it-IT"]),
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
            AfterRayUILanguage.resolve(stored: "zh-Hant", preferred: ["en-US"]),
            .traditionalChinese
        )
        XCTAssertEqual(
            AfterRayUILanguage.resolve(stored: "ja", preferred: ["zh-Hans-CN"]),
            .japanese
        )
        XCTAssertEqual(
            AfterRayUILanguage.resolve(stored: "xx", preferred: ["ja-JP"]),
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
        XCTAssertEqual(AfterRayCopy.traditionalChinese.settings.interface, "介面")
        XCTAssertEqual(AfterRayCopy.japanese.common.followSystem.isEmpty, false)
        XCTAssertEqual(AfterRayCopy.korean.format.now.isEmpty, false)
        XCTAssertEqual(AfterRayCopy.spanish.format.today.isEmpty, false)
        XCTAssertEqual(AfterRayCopy.german.menu.settings.isEmpty, false)
        XCTAssertEqual(AfterRayCopy.french.recall.tryAgain.isEmpty, false)
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
            AfterRayUILanguage.pickerCodes
        )
        XCTAssertEqual(
            settings.uiLanguagePickerOptions(selected: "ja").map(\.code),
            AfterRayUILanguage.pickerCodes
        )
        XCTAssertEqual(
            settings.uiLanguagePickerOptions(selected: "xx").map(\.code),
            AfterRayUILanguage.pickerCodes + ["xx"]
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
