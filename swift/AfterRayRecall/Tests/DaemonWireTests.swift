import Foundation
import XCTest
@testable import AfterRayRecall

final class DaemonWireTests: XCTestCase {
    func testTimelineRequestMatchesRustShape() throws {
        let data = try JSONEncoder().encode(WireRequest(type: "timeline_list"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["type"] as? String, "timeline_list")
        XCTAssertNil(json["session_id"])
    }

    func testTimelineSinceRequestMatchesRustShape() throws {
        let data = try JSONEncoder().encode(WireRequest(type: "timeline_since", sinceMs: 42))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["type"] as? String, "timeline_since")
        XCTAssertEqual(json["since_ms"] as? Int, 42)
    }

    func testDaySummaryRequestMatchesRustShape() throws {
        let data = try JSONEncoder().encode(WireRequest(type: "day_summary", dayMs: 1_786_698_000_000))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["type"] as? String, "day_summary")
        XCTAssertEqual((json["day_ms"] as? NSNumber)?.int64Value, 1_786_698_000_000)
    }

    func testSummaryHistoryRequestMatchesRustShape() throws {
        let data = try JSONEncoder().encode(
            WireRequest(type: "summary_history", limit: 7, beforeMs: 1_786_698_000_000)
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["type"] as? String, "summary_history")
        XCTAssertEqual((json["before_ms"] as? NSNumber)?.int64Value, 1_786_698_000_000)
        XCTAssertEqual(json["limit"] as? Int, 7)
    }

    func testRecallWindowRequestMatchesRustShape() throws {
        let request = WireRequest(type: "recall_window", sessionID: "session-1", centerMs: 42, limit: 120)
        let data = try JSONEncoder().encode(request)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["type"] as? String, "recall_window")
        XCTAssertEqual(json["session_id"] as? String, "session-1")
        XCTAssertEqual(json["center_ms"] as? Int, 42)
        XCTAssertEqual(json["limit"] as? Int, 120)
        XCTAssertNil(json["artifact_id"])
    }

    func testMomentDecodesCurrentRustShapeWithoutAudio() throws {
        let json = #"{"id":"m1","session_id":"s1","captured_at_ms":123,"image_artifact_id":"a1","is_favorite":false,"ocr_text":"hello","transcript_text":null}"#
        let moment = try JSONDecoder().decode(RecallMoment.self, from: Data(json.utf8))

        XCTAssertEqual(moment.id, "m1")
        XCTAssertEqual(moment.ocrText, "hello")
        XCTAssertNil(moment.audioArtifactId)
        XCTAssertNil(moment.audioStartedAtMs)
        XCTAssertNil(moment.accessibilityArtifactId)
        XCTAssertFalse(moment.hasVisibleTranscript)
    }

    func testVisibleTranscriptIgnoresBlankAudioOnlyMoments() throws {
        let blank = RecallMoment(
            id: "m1",
            sessionId: "s1",
            capturedAtMs: 1,
            imageArtifactId: "a1",
            transcriptText: "   ",
            audioArtifactId: "audio-1"
        )
        let spoken = RecallMoment(
            id: "m2",
            sessionId: "s1",
            capturedAtMs: 2,
            imageArtifactId: "a1",
            transcriptText: "hello there",
            audioArtifactId: "audio-2"
        )
        XCTAssertFalse(blank.hasVisibleTranscript)
        XCTAssertTrue(spoken.hasVisibleTranscript)
    }

    func testMomentDecodesAccessibilityArtifact() throws {
        let json = #"{"id":"m1","session_id":"s1","captured_at_ms":123,"image_artifact_id":"a1","is_favorite":false,"ocr_text":null,"transcript_text":null,"audio_artifact_id":null,"accessibility_artifact_id":"ax1","application_name":"Xcode","bundle_identifier":"com.apple.dt.Xcode"}"#
        let moment = try JSONDecoder().decode(RecallMoment.self, from: Data(json.utf8))
        XCTAssertEqual(moment.accessibilityArtifactId, "ax1")
        XCTAssertEqual(moment.applicationName, "Xcode")
        XCTAssertEqual(moment.bundleIdentifier, "com.apple.dt.Xcode")
        XCTAssertNil(moment.windowTitle)
        XCTAssertNil(moment.url)
        XCTAssertNil(moment.document)
    }

    func testMomentDecodesActivityContextFields() throws {
        let json = #"{"id":"m1","session_id":"s1","captured_at_ms":123,"image_artifact_id":"a1","is_favorite":false,"application_name":"Safari","bundle_identifier":"com.apple.Safari","window_title":"Example Domain","url":"https://example.com/","document":"file:///tmp/Notes.txt"}"#
        let moment = try JSONDecoder().decode(RecallMoment.self, from: Data(json.utf8))
        XCTAssertEqual(moment.windowTitle, "Example Domain")
        XCTAssertEqual(moment.url, "https://example.com/")
        XCTAssertEqual(moment.document, "file:///tmp/Notes.txt")
    }

    func testMomentDecodesGopAndNullableStill() throws {
        let json = #"{"id":"m1","session_id":"s1","captured_at_ms":123,"image_artifact_id":null,"is_favorite":false,"gop":{"segment_id":"g1","index":3,"keyframe_index":0,"frame_count":12,"codec":"av01"},"still_origin":"capture"}"#
        let moment = try JSONDecoder().decode(RecallMoment.self, from: Data(json.utf8))
        XCTAssertNil(moment.imageArtifactId)
        XCTAssertEqual(moment.gop?.segmentId, "g1")
        XCTAssertEqual(moment.gop?.index, 3)
        XCTAssertEqual(moment.displayCacheKey, "gop:g1#3")
    }

    func testDisplayCacheKeyPrefersGopOverLeftoverStill() throws {
        let json = #"{"id":"m1","session_id":"s1","captured_at_ms":123,"image_artifact_id":"a1","is_favorite":true,"gop":{"segment_id":"g1","index":3,"keyframe_index":0,"frame_count":12,"codec":"av01"}}"#
        let moment = try JSONDecoder().decode(RecallMoment.self, from: Data(json.utf8))
        XCTAssertEqual(moment.imageArtifactId, "a1")
        XCTAssertEqual(moment.displayCacheKey, "gop:g1#3")
    }

    func testArtifactMetaDecodesByteLengthWithoutPayload() throws {
        let json = #"{"id":"a1","content_type":"image/jpeg","byte_length":12}"#
        let meta = try JSONDecoder().decode(ArtifactMeta.self, from: Data(json.utf8))
        XCTAssertEqual(meta.id, "a1")
        XCTAssertEqual(meta.contentType, "image/jpeg")
        XCTAssertEqual(meta.byteLength, 12)
    }

    func testStatusDecodesRustShape() throws {
        let json = #"{"daemon_version":"0.1.0","protocol_version":1,"schema_version":1,"recording_state":"recording","active_session_id":"s1"}"#
        let status = try JSONDecoder().decode(DaemonStatus.self, from: Data(json.utf8))
        XCTAssertEqual(status.recordingState, .recording)
        XCTAssertEqual(status.activeSessionId, "s1")
    }

    func testStatusDecodesWaitingBeforeFirstFrame() throws {
        let json = #"{"daemon_version":"0.1.0","protocol_version":4,"schema_version":8,"recording_state":"waiting","active_session_id":"s1"}"#
        let status = try JSONDecoder().decode(DaemonStatus.self, from: Data(json.utf8))
        XCTAssertEqual(status.recordingState, .waiting)
    }

    func testSettingsRequestMatchesRustShape() throws {
        let data = try JSONEncoder().encode(WireRequest(type: "settings"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "settings")
        XCTAssertNil(json["record_audio"])
    }

    func testUpdateSettingsRequestMatchesRustShape() throws {
        let data = try JSONEncoder().encode(WireRequest(type: "update_settings", recordAudio: false))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "update_settings")
        XCTAssertEqual(json["record_audio"] as? Bool, false)
    }

    func testAppSettingsDecodesRustShape() throws {
        let json = #"{"data_dir":"/tmp/data","model_dir":"/tmp/models","record_audio":false,"capture_interval_seconds":10}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.dataDir, "/tmp/data")
        XCTAssertEqual(settings.modelDir, "/tmp/models")
        XCTAssertFalse(settings.recordAudio)
        XCTAssertEqual(settings.captureIntervalSeconds, 10)
        XCTAssertEqual(settings.storageLimitBytes, AppSettings.defaultStorageLimitBytes)
        XCTAssertTrue(settings.excludedBundleIds.isEmpty)
        XCTAssertEqual(settings.uiLanguage, AppSettings.defaultLanguage)
        XCTAssertEqual(settings.summaryLanguage, AppSettings.defaultLanguage)
        XCTAssertTrue(settings.languageOptions.isEmpty)
    }

    func testAppSettingsDefaultsLanguageWhenOldDaemonOmitsFields() throws {
        let json = #"{"data_dir":"/tmp/data","model_dir":"/tmp/models","record_audio":true,"capture_interval_seconds":10}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.uiLanguage, "auto")
        XCTAssertEqual(settings.summaryLanguage, "auto")
        XCTAssertTrue(settings.languageOptions.isEmpty)

        let picker = settings.languagePickerOptions(selected: settings.uiLanguage)
        XCTAssertEqual(picker.map(\.code), ["auto"])
        XCTAssertEqual(picker.first?.menuTitle, "跟随系统")
        XCTAssertEqual(picker.first?.englishName, "Follow system")
    }

    func testAppSettingsDecodesLanguageCatalogueFromDaemon() throws {
        let json = """
        {"data_dir":"/tmp/data","model_dir":"/tmp/models","record_audio":true,"capture_interval_seconds":10,"ui_language":"en","summary_language":"ja","language_options":[{"code":"auto","native_name":"跟随系统 / System","english_name":"Follow system"},{"code":"en","native_name":"English","english_name":"English"},{"code":"ja","native_name":"日本語","english_name":"Japanese"}]}
        """
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.uiLanguage, "en")
        XCTAssertEqual(settings.summaryLanguage, "ja")
        XCTAssertEqual(settings.languageOptions.count, 3)
        XCTAssertEqual(settings.languageOptions[2].nativeName, "日本語")
        XCTAssertEqual(settings.languageOptions[2].englishName, "Japanese")
        XCTAssertEqual(settings.languageOptions[0].menuTitle, "跟随系统")
        XCTAssertEqual(settings.languageOptions[2].menuTitle, "日本語")
        XCTAssertEqual(
            settings.languagePickerOptions(selected: settings.summaryLanguage).map(\.code),
            ["auto", "en", "ja"]
        )
    }

    func testLanguagePickerOptionsKeepsDaemonCatalogueAndUnknownSelection() throws {
        let settings = AppSettings(
            dataDir: "/tmp/data",
            modelDir: "/tmp/models",
            recordAudio: true,
            captureIntervalSeconds: 10,
            languageOptions: [
                LanguageOption(code: "en", nativeName: "English", englishName: "English"),
            ]
        )
        XCTAssertEqual(settings.languagePickerOptions(selected: "en").map(\.code), ["en"])
        XCTAssertEqual(settings.languagePickerOptions(selected: "xx").map(\.code), ["en", "xx"])
    }

    func testUpdateSettingsRequestIncludesLanguageFields() throws {
        let data = try JSONEncoder().encode(
            WireRequest(
                type: "update_settings",
                uiLanguage: "zh-Hans",
                summaryLanguage: "ja"
            )
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "update_settings")
        XCTAssertEqual(json["ui_language"] as? String, "zh-Hans")
        XCTAssertEqual(json["summary_language"] as? String, "ja")
    }

    func testUpdateSettingsRequestIncludesStorageLimit() throws {
        let data = try JSONEncoder().encode(
            WireRequest(type: "update_settings", storageLimitBytes: 250_000_000_000)
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["storage_limit_bytes"] as? UInt64, 250_000_000_000)
    }

    func testAppSettingsDecodesStorageLimit() throws {
        let json = #"{"data_dir":"/tmp/data","model_dir":"/tmp/models","record_audio":true,"capture_interval_seconds":10,"storage_limit_bytes":250000000000}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.storageLimitBytes, 250_000_000_000)
    }

    func testAppSettingsDecodesExcludedApps() throws {
        let json = #"{"data_dir":"/tmp/data","model_dir":"/tmp/models","record_audio":true,"capture_interval_seconds":10,"excluded_bundle_ids":["com.apple.Safari"]}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.excludedBundleIds, ["com.apple.Safari"])
        XCTAssertEqual(settings.llmProvider, .mlxLocal)
        XCTAssertTrue(settings.llmModel.isEmpty)
    }

    /// Settings written before the built-in GGUF backend was removed still say
    /// `builtin`. That must resolve to the managed MLX packs rather than
    /// failing the whole decode and stranding the Settings window.
    func testAppSettingsMapsRetiredBuiltinProviderToLocalMlx() throws {
        let json = #"{"data_dir":"/tmp/data","model_dir":"/tmp/models","record_audio":true,"capture_interval_seconds":10,"llm_provider":"builtin"}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.llmProvider, .mlxLocal)
    }

    func testAppSettingsDecodesExcludedWebsites() throws {
        let json = #"{"data_dir":"/tmp/data","model_dir":"/tmp/models","record_audio":true,"capture_interval_seconds":10,"excluded_domains":["bank.example","mail.example.com"]}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.excludedDomains, ["bank.example", "mail.example.com"])
    }

    /// A daemon that predates website exclusion omits the key entirely. Decoding
    /// must not fail there, or upgrading the app strands the old daemon.
    func testAppSettingsTreatsMissingExcludedWebsitesAsNone() throws {
        let json = #"{"data_dir":"/tmp/data","model_dir":"/tmp/models","record_audio":true,"capture_interval_seconds":10}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertTrue(settings.excludedDomains.isEmpty)
    }

    /// The daemon distinguishes "leave this list alone" from "make it empty",
    /// so an update that only touches apps must not carry a domains key at all.
    func testUpdateSettingsOmitsWebsitesWhenUntouched() throws {
        let data = try JSONEncoder().encode(
            WireRequest(type: "update_settings", excludedBundleIds: ["com.apple.Safari"])
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["excluded_bundle_ids"] as? [String], ["com.apple.Safari"])
        XCTAssertNil(json["excluded_domains"])
    }

    func testUpdateSettingsRequestCarriesExcludedWebsites() throws {
        let data = try JSONEncoder().encode(
            WireRequest(type: "update_settings", excludedDomains: ["example.com"])
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["excluded_domains"] as? [String], ["example.com"])
    }

    func testAppSettingsDecodesLlmFields() throws {
        let json = #"{"data_dir":"/tmp/data","model_dir":"/tmp/models","record_audio":true,"capture_interval_seconds":10,"llm_provider":"ollama","llm_base_url":"http://127.0.0.1:11434","llm_model":"qwen3.6:latest","llm_api_key_set":false}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.llmProvider, .ollama)
        XCTAssertEqual(settings.llmBaseUrl, "http://127.0.0.1:11434")
        XCTAssertEqual(settings.llmModel, "qwen3.6:latest")
        XCTAssertFalse(settings.llmApiKeySet)
    }

    func testUpdateSettingsRequestIncludesLlmFields() throws {
        let data = try JSONEncoder().encode(
            WireRequest(
                type: "update_settings",
                llmProvider: "ollama",
                llmModel: "qwen3.6:latest"
            )
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "update_settings")
        XCTAssertEqual(json["llm_provider"] as? String, "ollama")
        XCTAssertEqual(json["llm_model"] as? String, "qwen3.6:latest")
    }

    func testLlmProbeRequestMatchesRustShape() throws {
        let data = try JSONEncoder().encode(WireRequest(type: "llm_probe", provider: "ollama"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "llm_probe")
        XCTAssertEqual(json["provider"] as? String, "ollama")
        XCTAssertNil(json["llm_provider"])
    }

    func testLlmEndpointStatusDecodesRustShape() throws {
        let json = #"{"reachable":true,"models":[{"id":"qwen3.6:latest","name":"qwen3.6:latest"}],"recommended_model":"qwen3.6:latest","default_base_url":"http://127.0.0.1:11434"}"#
        let status = try JSONDecoder().decode(LlmEndpointStatus.self, from: Data(json.utf8))
        XCTAssertTrue(status.reachable)
        XCTAssertEqual(status.models.first?.id, "qwen3.6:latest")
        XCTAssertEqual(status.recommendedModel, "qwen3.6:latest")
    }

    func testModelLibraryDecodesInstalledPack() throws {
        let json = #"{"directory":"/tmp/models","packs":[{"id":"asr","name":"Qwen3 ASR","capability":"asr","path":"/tmp/models/Qwen3-ASR-1.7B","present":true,"bytes":1024,"required":true,"note":"qwen3"}]}"#
        let library = try JSONDecoder().decode(ModelLibrary.self, from: Data(json.utf8))
        XCTAssertEqual(library.directory, "/tmp/models")
        XCTAssertEqual(library.packs.first?.id, "asr")
        XCTAssertEqual(library.packs.first?.bytes, 1024)
        XCTAssertNil(library.packs.first?.expectedBytes)
        XCTAssertEqual(library.installedBytes, 1024)
    }

    func testModelLibraryDecodesDownloadProgress() throws {
        let json = #"{"directory":"/tmp/models","packs":[],"download":{"pack_id":"asr","bytes":42,"expected_bytes":100,"completed_files":0,"total_files":1}}"#
        let library = try JSONDecoder().decode(ModelLibrary.self, from: Data(json.utf8))
        XCTAssertEqual(library.download?.packId, "asr")
        XCTAssertEqual(library.download?.percent, 42)
        XCTAssertEqual(library.download?.fraction, 0.42)
    }

    func testModelPackDecodesExpectedBytes() throws {
        let json = #"{"id":"asr","name":"Qwen3 ASR","capability":"asr","path":"/tmp/qwen","present":false,"bytes":0,"required":true,"expected_bytes":2460000000}"#
        let pack = try JSONDecoder().decode(ModelPack.self, from: Data(json.utf8))
        XCTAssertEqual(pack.expectedBytes, 2_460_000_000)
    }

    func testDownloadModelsRequestMatchesRustShape() throws {
        let data = try JSONEncoder().encode(WireRequest(type: "download_models", packID: "asr"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "download_models")
        XCTAssertEqual(json["pack_id"] as? String, "asr")
    }

    func testRemoveModelRequestMatchesRustShape() throws {
        let data = try JSONEncoder().encode(WireRequest(type: "remove_model", packID: "llm_qwen35_4b_mlx4"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "remove_model")
        XCTAssertEqual(json["pack_id"] as? String, "llm_qwen35_4b_mlx4")
    }

    func testShutdownRequestMatchesRustShape() throws {
        let data = try JSONEncoder().encode(WireRequest(type: "shutdown"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "shutdown")
    }

    func testShutdownResultDecodesDaemonPid() throws {
        let json = #"{"stopping":true,"pid":4321}"#
        let result = try JSONDecoder().decode(DaemonShutdownResult.self, from: Data(json.utf8))
        XCTAssertTrue(result.stopping)
        XCTAssertEqual(result.pid, 4321)
    }

    func testAskRequestMatchesRustShape() throws {
        let request = WireRequest(type: "ask", question: "我今天做了什么", fromMs: 10, toMs: 20)
        let data = try JSONEncoder().encode(request)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["type"] as? String, "ask")
        XCTAssertEqual(json["question"] as? String, "我今天做了什么")
        XCTAssertEqual(json["from_ms"] as? Int, 10)
        XCTAssertEqual(json["to_ms"] as? Int, 20)
        XCTAssertNil(json["query"])
    }

    func testAskRequestOmitsRangeWhenDefaultingToToday() throws {
        let request = WireRequest(type: "ask", question: "what did I do")
        let data = try JSONEncoder().encode(request)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "ask")
        XCTAssertEqual(json["question"] as? String, "what did I do")
        XCTAssertNil(json["from_ms"])
        XCTAssertNil(json["to_ms"])
    }

    func testAskAnswerDecodesRustShape() throws {
        let json = #"{"answer":"You used Xcode.","citations":[{"moment_id":"m1","captured_at_ms":42,"label":"Xcode","excerpt":"fn main"}],"model_missing":false}"#
        let answer = try JSONDecoder().decode(AskAnswer.self, from: Data(json.utf8))
        XCTAssertEqual(answer.answer, "You used Xcode.")
        XCTAssertEqual(answer.citations.count, 1)
        XCTAssertEqual(answer.citations[0].momentId, "m1")
        XCTAssertEqual(answer.citations[0].label, "Xcode")
        XCTAssertFalse(answer.modelMissing)
        XCTAssertEqual(answer.citations[0].asSearchHit().momentId, "m1")
    }

    func testAskAnswerDefaultsModelMissing() throws {
        let json = #"{"answer":"ok"}"#
        let answer = try JSONDecoder().decode(AskAnswer.self, from: Data(json.utf8))
        XCTAssertEqual(answer.answer, "ok")
        XCTAssertTrue(answer.citations.isEmpty)
        XCTAssertFalse(answer.modelMissing)
    }

    func testSearchRequestMatchesRustShape() throws {
        let request = WireRequest(type: "search", limit: 30, query: "design review")
        let data = try JSONEncoder().encode(request)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["type"] as? String, "search")
        XCTAssertEqual(json["query"] as? String, "design review")
        XCTAssertEqual(json["limit"] as? Int, 30)
    }

    func testThumbnailRequestMatchesRustShape() throws {
        let request = WireRequest(type: "read_thumbnail", momentID: "m1", maxEdge: 360)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode(request)) as? [String: Any]
        )

        XCTAssertEqual(json["type"] as? String, "read_thumbnail")
        XCTAssertEqual(json["moment_id"] as? String, "m1")
        XCTAssertEqual(json["max_edge"] as? Int, 360)
    }

    func testThumbnailRequestOmitsMaxEdgeWhenUnset() throws {
        // Rust defaults `max_edge` to None; sending null would not deserialize.
        let request = WireRequest(type: "read_thumbnail", momentID: "m1")
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode(request)) as? [String: Any]
        )
        XCTAssertNil(json["max_edge"])
    }

    func testEvidenceOcrRequestMatchesRustShape() throws {
        let request = WireRequest(type: "evidence_ocr", momentID: "m1")
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode(request)) as? [String: Any]
        )

        XCTAssertEqual(json["type"] as? String, "evidence_ocr")
        XCTAssertEqual(json["moment_id"] as? String, "m1")
    }

    func testOcrEvidenceDecodesVisionBoxes() throws {
        let json = """
        {"moment_id":"m1","text":"Roadmap","regions":[
          {"text":"Roadmap","confidence":0.94,"x":0.1,"y":0.8,"width":0.3,"height":0.05}
        ]}
        """
        let evidence = try JSONDecoder().decode(OcrEvidence.self, from: Data(json.utf8))

        XCTAssertEqual(evidence.momentId, "m1")
        XCTAssertEqual(evidence.regions.count, 1)
        XCTAssertEqual(evidence.regions[0].text, "Roadmap")
        XCTAssertEqual(evidence.regions[0].y, 0.8, accuracy: 0.0001)
    }

    func testOcrEvidenceToleratesOmittedRegions() throws {
        // The daemon skips `regions` entirely when a frame produced no boxes.
        let evidence = try JSONDecoder().decode(
            OcrEvidence.self,
            from: Data(#"{"moment_id":"m1","text":"nothing"}"#.utf8)
        )
        XCTAssertTrue(evidence.regions.isEmpty)
    }

    func testClientSpeaksTheCurrentProtocolVersion() throws {
        // Must move in lockstep with PROTOCOL_VERSION in afterray-protocol.
        XCTAssertEqual(UnixSocketDaemonClient.protocolVersion, 7)
    }

    func testRecordResultsDecodeBothDaemonBranches() throws {
        let started = #"{"session":{"id":"s1","started_at_ms":100,"ended_at_ms":null}}"#
        let existing = #"{"session_id":"s1","already_recording":true}"#
        let stopped = #"{"session_id":"s1"}"#

        XCTAssertEqual(
            try JSONDecoder().decode(RecordStartResult.self, from: Data(started.utf8)).effectiveSessionId,
            "s1"
        )
        XCTAssertEqual(
            try JSONDecoder().decode(RecordStartResult.self, from: Data(existing.utf8)).alreadyRecording,
            true
        )
        XCTAssertEqual(
            try JSONDecoder().decode(RecordStopResult.self, from: Data(stopped.utf8)).sessionId,
            "s1"
        )
    }

    func testStatusDecodesHostBuildStampedByTheApp() throws {
        let json = #"""
        {"daemon_version":"0.0.1","protocol_version":7,"schema_version":11,\#
        "recording_state":"recording","active_session_id":"s1","host_build":"142"}
        """#
        let status = try JSONDecoder().decode(DaemonStatus.self, from: Data(json.utf8))

        XCTAssertEqual(status.hostBuild, "142")
        XCTAssertEqual(status.daemonVersion, "0.0.1")
    }

    func testStatusFromADaemonWithoutHostBuildDecodesToNil() throws {
        // A daemon left running by a previous version predates the field. It
        // must still decode, because that is exactly the daemon an updated app
        // needs to recognise and replace.
        let json = #"""
        {"daemon_version":"0.0.1","protocol_version":7,"schema_version":11,\#
        "recording_state":"idle","active_session_id":null}
        """#
        let status = try JSONDecoder().decode(DaemonStatus.self, from: Data(json.utf8))

        XCTAssertNil(status.hostBuild)
    }
}
