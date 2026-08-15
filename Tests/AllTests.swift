#if canImport(LocalDictationCore)
import LocalDictationCore
#endif

public func allTests() -> [RegisteredTest] {
    [
        RegisteredTest(name: "cleanup.fillers", body: CleanupSuite.fillers),
        RegisteredTest(name: "cleanup.repeats", body: CleanupSuite.repeats),
        RegisteredTest(name: "cleanup.polishedPunctuation", body: CleanupSuite.polishedPunctuation),
        RegisteredTest(name: "cleanup.emailStyle", body: CleanupSuite.emailStyle),
        RegisteredTest(name: "cleanup.vocabulary", body: CleanupSuite.vocabulary),
        RegisteredTest(name: "cleanup.rawKeepsFillers", body: CleanupSuite.rawKeepsFillers),
        RegisteredTest(name: "vocab.persist", body: VocabularySuite.persist),
        RegisteredTest(name: "vocab.shortWordsRejected", body: VocabularySuite.shortWordsRejected),
        RegisteredTest(name: "vocab.remove", body: VocabularySuite.remove),
        RegisteredTest(name: "session.readyHoldCycle", body: KeyboardSessionSuite.readyHoldCycle),
        RegisteredTest(name: "session.setupBlocksRecording", body: KeyboardSessionSuite.setupBlocksRecording),
        RegisteredTest(name: "session.emptyAudioFails", body: KeyboardSessionSuite.emptyAudioFails),
        RegisteredTest(name: "session.cancelReturnsIdle", body: KeyboardSessionSuite.cancelReturnsIdle),
        RegisteredTest(name: "session.toggleStartsAndStops", body: KeyboardSessionSuite.toggleStartsAndStops),
        RegisteredTest(name: "session.readinessRecovery", body: KeyboardSessionSuite.readinessRecovery),
        RegisteredTest(name: "session.missingFullAccessStillRecords", body: KeyboardSessionSuite.missingFullAccessStillRecords),
        RegisteredTest(name: "store.roundTrip", body: SharedStoreSuite.roundTrip),
        RegisteredTest(name: "store.missingFileIsIdle", body: SharedStoreSuite.missingFileIsIdle),
        RegisteredTest(name: "pipeline.insertsCleanedText", body: PipelineSuite.insertsCleanedText),
        RegisteredTest(name: "pipeline.rejectsBlank", body: PipelineSuite.rejectsBlank),
        RegisteredTest(name: "pipeline.prependsSpaceWhenNeeded", body: PipelineSuite.prependsSpaceWhenNeeded),
        RegisteredTest(name: "pipeline.noSpaceAfterPunctuation", body: PipelineSuite.noSpaceAfterPunctuation),
        RegisteredTest(name: "readiness.blockingOrder", body: ReadinessSuite.blockingOrder),
        RegisteredTest(name: "capture.errorCopy", body: CaptureSuite.errorCopy),
    ]
}
