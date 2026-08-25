/// Every user-facing chrome string AfterRay draws. Adding a field is a
/// compile error until every shipped locale fills it.
public struct AfterRayCopy {
    public var common: Common
    public var format: Format
    public var onboarding: Onboarding
    public var menu: Menu
    public var permissions: Permissions
    public var settings: Settings
    public var recall: Recall
    public var chat: Chat
    public var compute: Compute
    public var hotKey: HotKey
}

extension AfterRayCopy {
    public struct Common {
        public var followSystem: String
        public var back: String
        public var continueLabel: String
        public var cancel: String
        public var close: String
        public var save: String
        public var reset: String
        public var retry: String
        public var refresh: String
        public var show: String
        public var copy: String
        public var copied: String
        public var open: String
        public var include: String
        public var exclude: String
        public var pause: String
        public var resume: String
        public var dismiss: String
        public var skip: String
        public var installed: String
        public var downloading: String
        public var verifying: String
        public var paused: String
        public var waiting: String
        public var failed: String
        public var ready: String
        public var loaded: String
        public var optional: String
        public var on: String
        public var off: String
    }

    public struct Format {
        public var now: String
        public var today: String
        public var todayKicker: String
        public var yesterday: String
        public var noDaySelected: String
        public var quietNothingOnScreen: String
        public var goodMorning: String
        public var goodAfternoon: String
        public var goodEvening: String
        public var stillUp: String
        public var minutes: (UInt32) -> String
        public var oneHour: String
        public var hours: (UInt32) -> String
        public var summaryFailed: String
        public var idle: String
        public var capturePaused: String
        public var asleep: String
        public var notSummarised: String
    }

    public struct Onboarding {
        public var eyebrowHotKey: String
        public var eyebrowPrivacy: String
        public var eyebrowCli: String
        public var eyebrowModels: String
        public var headlineHotKey: String
        public var headlinePrivacy: String
        public var headlineCli: String
        public var headlineModels: String
        public var apps: String
        public var websites: String
        public var none: String
        public var addApp: String
        public var domainPlaceholder: String
        public var passwordManagersSkipped: String
        public var alwaysExcludedHelp: String
        public var stopExcluding: (String) -> String
        public var cliBody: String
        public var notOnPath: String
        public var cliReady: String
        public var cliInstalledNeedPath: String
        public var notInstalledYet: String
        public var modelsBody: String
        public var checkingModels: String
        public var verifyingPack: (String) -> String
        public var downloadingPack: (String) -> String
        public var closeAnytime: String
        public var pausedResume: String
        public var optionalAssistant: String
        public var pausedPercent: (Int) -> String
        public var verifyingFiles: String
        public var downloadingPercent: (Int) -> String
        public var waitingToDownload: String
        public var downloadSize: (String) -> String
        public var modelFallback: String
        public var sizeUnavailable: String
        public var recordHint: String
        public var practiced: String
        public var tryIt: String
        public var neverMind: String
        public var changeShortcut: String
        public var gotIt: String
        public var skipCli: String
        public var installing: String
        public var installCli: String
        public var downloadModels: String
        public var checkAgain: String
        public var startUsing: String
        public var skipForNow: String
        public var starting: String
        public var resumeDownload: String
        public var requiredModelsReady: String
    }

    public struct Menu {
        public var settings: String
        public var settingsWindow: String
        public var quit: String
        public var openAfterRay: String
        public var pauseCapture: String
        public var resumeCapture: String
        public var localComputation: String
        public var deleteLastHour: String
        public var checkForUpdates: String
        public var updateInstallsOnQuit: (String) -> String
        public var historyWindow: String
        public var chatWindow: String
        public var recording: String
        public var paused: String
        public var tooltip: (String, String) -> String
    }

    public struct Permissions {
        public var eyebrow: String
        public var threeRequired: String
        public var twoRequired: String
        public var audioOffSummary: String
        public var noMicSummary: String
        public var micDeclinedSummary: String
        public var allThreeSummary: String
        public var afterChanging: (String) -> String
        public var waitingApproval: String
        public var checkPermissions: String
        public var screenAndSystemAudio: String
        public var microphone: String
        public var accessibility: String
        public var noInputDevice: String
        public var allowed: String
        public var allowAccess: String
        public var openSettings: String
        public var addTo: (String) -> String
        public var dragInstructions: String
        public var dragIntoSettings: String
        public var afterGranting: (String) -> String
    }

    public struct Settings {
        public var brand: String
        public var pageGeneral: String
        public var pageModels: String
        public var pageAdvanced: String
        public var pageDeveloper: String
        public var pageDiagnostics: String
        public var closeSettings: String
        public var openingAfterRay: String
        public var globalShortcut: String
        public var listeningShortcut: String
        public var clickToRecord: String
        public var capture: String
        public var recordAudio: String
        public var recordAudioSubtitle: String
        public var summaries: String
        public var summariesFootnote: String
        public var summaryLength: String
        public var summaryLengthSubtitle: String
        public var language: String
        public var interface: String
        public var interfaceSubtitle: String
        public var interfaceLanguage: String
        public var summaryLanguage: String
        public var excludedApps: String
        public var excludedWebsites: String
        public var nothingExcluded: String
        public var alwaysExcluded: String
        public var chooseApp: String
        public var domainPlaceholder: String
        public var deleteHistory: String
        public var deleteHistoryFootnote: String
        public var removeCapturedMoments: String
        public var lastHour: String
        public var today: String
        public var everything: String
        public var storage: String
        public var afterRayUses: String
        public var freeOnDisk: String
        public var memories: String
        public var models: String
        public var runtime: String
        public var diskUnavailable: String
        public var lessThanTenth: String
        public var diskShare: (String, String) -> String
        public var memoryLimit: String
        public var memoryLimitSubtitle: String
        public var memoryLocation: String
        public var memoryLocationSubtitle: String
        public var changeMemoryLocation: String
        public var moveMemoriesTitle: String
        public var moveMemoriesMessage: (String) -> String
        public var moveExistingMemories: String
        public var useEmptyMemoryFolder: String
        public var memoryLocationChanged: (String) -> String
        public var assistantSource: String
        public var providerMlx: String
        public var providerOllama: String
        public var providerOpenAI: String
        public var ollamaStaysLocal: String
        public var openaiCompatibleNote: String
        public var modelPacks: String
        public var onDeviceOcr: String
        public var appleVision: String
        public var builtIn: String
        public var readingModelFolder: String
        public var recentInference: String
        public var downloadMissing: (Int) -> String
        public var allPacksInstalled: String
        public var downloads: String
        public var downloadsFootnote: String
        public var cancelAll: String
        public var downloadFailed: String
        public var checkingChecksums: String
        public var partialFilesKept: String
        public var startsAfterCurrent: String
        public var startsAfterCurrentEta: (String) -> String
        public var ofSize: (String, String) -> String
        public var aFewSeconds: String
        public var seconds: (Int) -> String
        public var aboutAMinute: String
        public var minutesLeft: (Int) -> String
        public var left: (String) -> String
        public var downloadSource: String
        public var downloadSourceFootnote: String
        public var officialEndpoint: String
        public var mirrorEndpoint: String
        public var customEndpoint: String
        public var customEndpointPlaceholder: String
        public var apply: String
        public var model: String
        public var recommendedQwen4B: String
        public var higherQualityQwen9B: String
        public var mlxLicense: String
        public var mlx4BNote: String
        public var mlx9BNote: String
        public var inQueueTop: String
        public var retryDownload: String
        public var downloadSized: (String) -> String
        public var showFiles: String
        public var removeEllipsis: String
        public var removeFromMac: (String) -> String
        public var removeDownload: String
        public var canRedownload: String
        public var mlxUnavailable: String
        public var notDownloaded: String
        public var incompatible: String
        public var checkAgain: String
        public var serverUrl: String
        public var apiKey: String
        public var savedKeepBlank: String
        public var optionalKey: String
        public var saveConnection: String
        public var endpointReachable: String
        public var notReachable: String
        public var lookingForOllama: String
        public var ollamaNotProbed: String
        public var ollamaOneModel: String
        public var ollamaManyModels: (Int) -> String
        public var ollamaUnreachable: String
        public var inDownloadQueue: String
        public var download: String
        public var incomplete: String
        public var needed: String
        public var jobAsr: String
        public var jobOcr: String
        public var jobEmbedding: String
        public var jobAssistant: String
        public var jobOk: String
        public var jobRunning: String
        public var jobQueued: String
        public var jobCancelled: String
        public var localComputation: String
        public var localComputationFootnote: String
        public var showComputePanel: String
        public var showComputePanelSubtitle: String
        public var developerOptions: String
        public var showDeveloperSettings: String
        public var updates: String
        public var updatesFootnote: String
        public var checkAutomatically: String
        public var checkNow: String
        public var cliForAgents: String
        public var cliForAgentsFootnote: String
        public var cliInstalled: String
        public var cliName: String
        public var cliReady: String
        public var cliMissing: String
        public var originalEvidence: String
        public var evidenceOff: String
        public var evidenceLessThanMinute: String
        public var evidenceMinutes: (Int64) -> String
        public var reinstallCli: String
        public var installCli: String
        public var turnOff: String
        public var allow30Minutes: String
        public var captureCadence: String
        public var oneStillEvery: (UInt64) -> String
        public var fixed: String
        public var locations: String
        public var locationsFootnote: String
        public var vault: String
        public var onboarding: String
        public var onboardingFootnote: String
        public var replayOnboarding: String
        public var replay: String
        public var logs: String
        public var logsFootnote: String
        public var logFile: String
        public var revealLogFolder: String
        public var copyReport: String
        public var audioOn: String
        public var audioOff: String
        public var interfaceSet: (String) -> String
        public var summarySet: (String) -> String
        public var memoryLimitSet: (String) -> String
        public var newSummariesCover: (String) -> String
        public var capabilityAsr: String
        public var capabilityOcr: String
        public var capabilityEmbedding: String
        public var capabilityLlm: String
        public var capabilitySummary: String
        public var cliInstalledOnPath: (String) -> String
        public var cliInstalledNeedPath: (String) -> String
        public var cliNotInstalledAgents: String
        public var cliBinaryMissing: String
        public var hoursShort: (Int) -> String
        public var hoursAndMinutes: (Int, Int) -> String
        public var evidenceOnFor30Minutes: String
        public var evidenceOffToast: String
        public var updateReadyOnQuit: (String) -> String
        public var onVersionChecking: (String) -> String
        public var onVersionChecksOff: (String) -> String
        public var developerUnlocked: String
        public var passwordManagersAlwaysExcluded: String
        public var chooseAppNeverRecord: String
        public var couldNotReadAppIdentifier: String
        public var doesNotRecordOwnWindow: String
        public var deletedOneMoment: String
        public var deletedMoments: (Int) -> String
        public var packReady: (String) -> String
        public var cancelledDownload: (String) -> String
        public var downloadsUseOfficial: String
        public var downloadsUseEndpoint: (String) -> String
        public var removedPack: (String) -> String
        public var assistantConnectionSaved: String
        public var modelDownloadsFinished: String
        public var versionBuild: (String, String) -> String
        public var moveToApplicationsQuestion: String
        public var moveFromDiskImage: String
        public var moveFromElsewhere: String
        public var moveToApplications: String
        public var notNow: String
        public var keepWhereItIs: String
        public var couldNotMove: String
        public var dragToApplicationsManually: String
        public var alreadyRunningInApplications: String
        public var chooseAppToSkip: String
        public var alreadyExcludesOwnWindows: String
        public var appAlreadyExcluded: String
        public var passwordAppsAlwaysSkipped: String
        public var askUsesMlx: String
        public var askUsesOllama: String
        public var askUsesOpenAI: String
    }

    public struct Recall {
        public var understanding: String
        public var hideContext: String
        public var showContext: String
        public var dragHint: String
        public var swipeMatches: String
        public var search: String
        public var ask: String
        public var searchPlaceholder: String
        public var askPlaceholder: String
        public var switchToAsking: String
        public var switchToSearch: String
        public var inputMode: String
        public var clear: String
        public var openChat: String
        public var closeAfterRay: String
        public var olderMatch: String
        public var newerMatch: String
        public var captureStatus: String
        public var localOnly: String
        public var firstMoments: String
        public var dayBegins: String
        public var keepRunning: String
        public var capturingAutomatically: String
        public var serviceUnavailable: String
        public var couldntOpen: String
        public var daemonFailed: String
        public var tryAgain: String
        public var cancelAudio: String
        public var pauseAudio: String
        public var playAudio: String
        public var copy: String
        public var open: String
        public var heard: String
        public var seen: String
        public var onScreen: String
        public var accessibilityTree: String
        public var settingsHelp: String
        public var openAsWindow: String
        public var copyAllLoadedDays: String
        public var copyThisDay: String
        public var copyThisSlot: String
        public var copySummary: String
        public var openSummaryAsMarkdown: String
        public var nothingRecorded: String
        public var pastDaysWillAppear: String
        public var noRecordings: String
        public var openURL: (String) -> String
        public var openAt: (String, String) -> String
        public var appsUsed: (String) -> String
        public var swipeToHistory: String
        public var dragToZoom: String
        public var timeline: String
        public var dayCount: (Int) -> String
        public var openThisSlot: String
        public var loadingOlderSummaries: String
        public var loadOlderSummaries: String
        public var pausing: String
        public var offline: String
        public var recording: String
        public var hideTodaySummary: String
        public var showTodaySummary: String
        public var noMomentsMatched: (String) -> String
        public var gapNotRecorded: (String) -> String
        public var ocrProcessing: String
        public var noScreenTextFound: String
        public var transcriptProcessing: String
        public var noTranscriptNear: String
        public var capturedContext: String
        public var noSnapshot: String
        public var snapshotFailed: String
        public var hideDetails: String
        public var fullDetails: String
        public var copyAllText: String
    }

    public struct Chat {
        public var loading: String
        public var pastChats: String
        public var noChatsMatch: String
        public var hideSidebar: String
        public var showSidebar: String
        public var searchChats: String
        public var clearSearch: String
        public var newConversation: String
        public var more: String
        public var closeChat: String
        public var askAnything: String
        public var stopGenerating: String
        public var chooseModel: String
        public var copyEntire: String
        public var copyThreadHelp: String
        public var contextWindow: String
        public var used: String
        public var total: String
        public var contextUsed: (String) -> String
        public var stopped: String
        public var tokensPerSecondHelp: String
        public var turnWallTimeHelp: String
        public var agentCopied: String
        public var copyAgentOutput: String
        public var thoughtItThrough: String
        public var shortened: String
        public var streaming: String
        public var code: String
        public var thinking: String
        public var working: String
        public var send: String
        public var deleteConversation: String
        public var goToLatest: String
        public var conversationTitle: String
        public var notServingYet: String
        public var couldNotReachDaemon: String
        public var contextUsedA11y: (String, String) -> String
        public var charactersBack: (Int) -> String
        public var charactersBackShortened: (Int, Int) -> String
        public var droppedOneLookup: String
        public var droppedLookups: (Int) -> String
        public var lookedUpSlot: (String) -> String
        public var lookedUpHalfHour: String
        public var browsedMomentsFrom: (String) -> String
        public var browsedTimeline: String
        public var readTranscriptFrom: (String) -> String
        public var readATranscript: String
        public var checkedActivityFrom: (String) -> String
        public var checkedActivity: String
        public var readSavedMemories: String
        public var searchedQuery: (String) -> String
        public var searchedVault: String
        public var openedMoment: String
        public var readOnScreenText: String
        public var readInterfaceTree: String
        public var calledTool: (String) -> String
        public var lookedSomethingUp: String
        public var headlineAndMore: (String, Int) -> String
        public var openCapturedMoment: String
        public var openCapturedMomentAt: (String) -> String
        public var openCapturedTitled: (String) -> String
        public var openCapturedTitledAt: (String, String) -> String
        public var screenshotUnavailable: String
        public var capturedMoment: String
    }

    public struct Compute {
        public var windowTitle: String
        public var full: String
        public var essential: String
        public var off: String
        public var fullDetail: String
        public var essentialDetail: String
        public var offDetail: String
        public var screenText: String
        public var transcription: String
        public var searchIndex: String
        public var summaries: String
        public var archive: String
        public var howItDecides: String
        public var runningNow: String
        public var nothingRunningWaiting: (Int) -> String
        public var nothingRunning: String
        public var summaryTiming: String
        public var usually: String
        public var perSlot: (Int) -> String
        public var finished: String
        public var gaveUp: String
        public var workTypes: String
        public var itemsWaiting: (Int) -> String
        public var waitingCount: (Int) -> String
        public var waitingAudioDuration: (String) -> String
        public var upToDate: String
        public var forced: String
        public var held: String
        public var startNow: String
        public var startAllNow: (Int) -> String
        public var startRemainingNow: (Int) -> String
        public var startsWhen: (String) -> String
        public var noConditions: String
        public var summariesExpensive: String
        public var loadedModels: String
        public var thisMachine: String
        public var power: String
        public var pluggedIn: String
        public var onBattery: String
        public var load: String
        public var unavailable: String
        public var thermal: (String) -> String
        public var onBatteryNote: String
        public var overlayOpenNote: String
        public var nothingToSuspend: String
        public var suspendHelp: String
        public var chatAlwaysRuns: String
        public var resumeNow: (Int) -> String
        public var pauseForHour: String
        public var idleHelp: String
        public var oneTaskRunning: String
        public var tasksRunning: (Int) -> String
        public var suspendedMinutes: (Int) -> String
        public var suspended: String
        public var switchedOff: String
        public var waitingReason: (String) -> String
        public var switchedOn: String
        public var currentlyOff: String
        public var notSuspended: String
        public var youSuspended: (Int) -> String
        public var onPower: String
        public var onBatteryShort: String
        public var fullSpeed: String
        public var batterySlower: String
        public var batteryAbove: (Int) -> String
        public var idleFor: (Int) -> String
        public var lastInput: (Int) -> String
        public var loadBelow: (String) -> String
        public var thermalName: String
        public var runningNowAtRequest: String
        public var heldShort: String
        public var conditionsHelp: String
        public var noBatteryToConserve: String
        public var unreadableBusy: String
    }

    public struct HotKey {
        public var spotlightConflict: String
        public var inputSourceConflict: String
        public var screenshotConflict: String
        public var needsModifier: String
        public var commandAlone: (String) -> String
        public var unsupportedKey: String
        public var recordNew: String
        public var shortcutActivate: (String) -> String
        public var pressKeys: String
    }
}
