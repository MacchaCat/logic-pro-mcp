import Foundation
import Testing
@testable import LogicBridge
import MIDICore

/// Logic 13.0's sync output while recording from bar 9 at 120 BPM (note-recording spike capture,
/// 2026-11-21): SPP 112 at the Record press (18.645 s) and again at 18.691 s, Continue and the
/// first clock at 18.697 s, 247 clocks, then Stop and SPP 152 at 23.813 / 23.815 s. Times are
/// ms after 18 s of the capture (1 ms resolution); every clock is listed.
enum Logic13RecordCapture {
    static let clockMs: [Int] = [
        697, 710, 731, 752, 773, 793, 814, 835, 856, 877, 898, 918, 939, 960, 981, 1002, 1023, 1043, 1064, 1085,
        1106, 1127, 1148, 1168, 1189, 1210, 1231, 1252, 1273, 1293, 1314, 1335, 1356, 1377, 1398, 1418, 1439, 1460,
        1481, 1502, 1523, 1543, 1564, 1585, 1606, 1627, 1648, 1668, 1689, 1710, 1731, 1752, 1773, 1794, 1814, 1835,
        1856, 1877, 1898, 1919, 1939, 1960, 1981, 2002, 2023, 2043, 2064, 2085, 2106, 2127, 2148, 2168, 2189, 2210,
        2231, 2252, 2273, 2293, 2314, 2335, 2356, 2377, 2398, 2418, 2439, 2460, 2481, 2502, 2523, 2543, 2564, 2585,
        2606, 2626, 2647, 2667, 2688, 2709, 2730, 2751, 2772, 2792, 2813, 2834, 2855, 2876, 2897, 2917, 2938, 2959,
        2980, 3001, 3022, 3042, 3063, 3084, 3105, 3126, 3147, 3167, 3188, 3209, 3230, 3251, 3272, 3292, 3313, 3334,
        3355, 3376, 3397, 3417, 3438, 3459, 3480, 3501, 3522, 3542, 3563, 3584, 3605, 3626, 3647, 3667, 3688, 3709,
        3730, 3751, 3772, 3792, 3813, 3834, 3855, 3876, 3897, 3917, 3938, 3959, 3980, 4001, 4022, 4042, 4063, 4084,
        4105, 4126, 4147, 4167, 4188, 4209, 4230, 4251, 4272, 4292, 4313, 4334, 4355, 4376, 4397, 4417, 4438, 4459,
        4480, 4501, 4522, 4542, 4563, 4584, 4605, 4626, 4647, 4667, 4688, 4709, 4730, 4751, 4772, 4792, 4813, 4834,
        4855, 4876, 4897, 4917, 4938, 4959, 4980, 5001, 5022, 5042, 5063, 5084, 5105, 5126, 5147, 5167, 5188, 5209,
        5230, 5251, 5272, 5292, 5313, 5334, 5355, 5376, 5397, 5417, 5438, 5459, 5480, 5501, 5522, 5542, 5563, 5584,
        5605, 5626, 5647, 5667, 5688, 5709, 5730, 5751, 5772, 5792, 5813,
    ]

    /// Feeds the capture into `timeline` (Stop and the stop SPP included when `throughStop`).
    static func feed(_ timeline: SyncTimeline, origin: ContinuousClock.Instant, throughStop: Bool = true) {
        func at(_ ms: Int) -> ContinuousClock.Instant { origin.advanced(by: .milliseconds(ms)) }
        timeline.record(.songPosition(112), at: at(645))
        timeline.record(.songPosition(112), at: at(691))
        timeline.record(.continue, at: at(697))
        for ms in clockMs { timeline.record(.timingClock, at: at(ms)) }
        guard throughStop else { return }
        timeline.record(.stop, at: at(5813))
        timeline.record(.songPosition(152), at: at(5815))
    }
}

@Suite("Sync timeline")
struct SyncTimelineTests {
    let origin = ContinuousClock.now
    func at(_ ms: Double) -> ContinuousClock.Instant { origin.advanced(by: .microseconds(Int(ms * 1000))) }

    @Test func logic13CaptureFirstClockIsAtTheSongPosition() {
        let timeline = SyncTimeline()
        timeline.beginCapture()
        Logic13RecordCapture.feed(timeline, origin: origin, throughStop: false)
        let fix = timeline.fix()
        #expect(fix.running == true)
        #expect(fix.songPositionCount == 2)
        #expect(Logic13RecordCapture.clockMs.count == 247)
        // First clock = SPP 112 × 6 = tick 672, so the last of the 247 clocks is tick 918.
        #expect(fix.lastClock?.tick == 918)
        #expect(fix.clocksSinceStart == 247)
        #expect(abs((fix.tempoBPM ?? 0) - 120) < 1)

        let track = ClockTrack(events: timeline.endCapture(), after: 0)
        #expect(track.samples.first?.tick == 672)
        #expect(abs((track.tempoBPM ?? 0) - 120) < 0.2)
        // The time display Logic sent at the same moments (240 display ticks per sixteenth):
        // 18.715 s "8 1 1 29" = clock tick 672.7; 23.776 s "10 3 1 157" = tick 915.9.
        #expect(abs((track.tick(at: at(715)) ?? 0) - 672.7) < 1)
        #expect(abs((track.tick(at: at(5776)) ?? 0) - 915.9) < 1)
        // Stop was pressed at 23.807 s and Logic then reported SPP 152: floor(tick / 6) of the
        // clock position at the press is 152 (153 if the first clock were 673). Only about ±1 tick
        // is settled by this: the last clock, tick 918 = SPP 153.0, came with Stop 6 ms later.
        let atStop = track.tick(at: at(5807)) ?? 0
        #expect(Int((atStop / 6).rounded(.down)) == 152)
    }

    @Test func logic13CaptureStopAndSongPosition() {
        let timeline = SyncTimeline()
        Logic13RecordCapture.feed(timeline, origin: origin)
        let fix = timeline.fix()
        #expect(fix.running == false)
        #expect(fix.lastTransport?.kind == .stop)
        #expect(fix.lastSongPosition?.kind == .songPosition(152))
        #expect(timeline.songPositions(after: 0).count == 3)
        #expect(timeline.songPositions(after: fix.lastTransport!.sequence).count == 1)
    }

    @Test func predictionsFollowTheCaptureWithinTwoMilliseconds() {
        // Predict each clock from the ones before it, as the note sender does.
        let timeline = SyncTimeline()
        timeline.record(.songPosition(112), at: at(645))
        timeline.record(.continue, at: at(697))
        var worst = 0.0
        for (index, ms) in Logic13RecordCapture.clockMs.enumerated() {
            if index >= 12, let predicted = timeline.fix().time(ofTick: Double(672 + index)) {
                worst = max(worst, abs(at(Double(ms)).duration(to: predicted).seconds) * 1000)
            }
            timeline.record(.timingClock, at: at(Double(ms)))
        }
        #expect(worst < 2.0)
    }

    @Test func continueResumesAndStoppedClocksDoNotMove() {
        let timeline = SyncTimeline()
        timeline.record(.songPosition(10), at: at(0))
        timeline.record(.timingClock, at: at(1))  // while stopped: not counted
        #expect(timeline.fix().lastClock == nil)
        timeline.record(.continue, at: at(2))
        for i in 0..<5 { timeline.record(.timingClock, at: at(10 + Double(i) * 20)) }
        #expect(timeline.fix().lastClock?.tick == 64)
        timeline.record(.stop, at: at(200))
        timeline.record(.timingClock, at: at(205))
        timeline.record(.continue, at: at(300))
        timeline.record(.timingClock, at: at(310))
        // Continue without a new SPP resumes after the last counted clock.
        #expect(timeline.fix().lastClock?.tick == 65)
        timeline.record(.songPosition(0), at: at(400))
        timeline.record(.start, at: at(401))
        timeline.record(.timingClock, at: at(402))
        #expect(timeline.fix().lastClock?.tick == 0)
    }

    @Test func oneLateClockDoesNotShiftThePrediction() {
        let timeline = SyncTimeline()
        timeline.record(.songPosition(0), at: at(0))
        timeline.record(.continue, at: at(0))
        for i in 0..<24 {
            // Clock 22 arrives 6 ms late.
            let late = i == 22 ? 6.0 : 0
            timeline.record(.timingClock, at: at(Double(i) * 10 + late))
        }
        let fix = timeline.fix()
        #expect(abs((fix.secondsPerTick ?? 0) - 0.010) < 0.0001)
        let predicted = fix.time(ofTick: 24)!
        #expect(abs(at(240).duration(to: predicted).seconds) < 0.0015)
    }

    @Test func clockTrackInterpolatesAndMeasuresJitter() {
        let samples = (0..<48).map { SyncTimeline.ClockSample(tick: 100 + $0, time: at(Double($0) * 20 + ($0 % 2 == 0 ? 0 : 1))) }
        let track = ClockTrack(samples: samples)
        #expect(abs(at(10.5).duration(to: track.time(ofTick: 100.5)!).seconds) < 0.0001)
        #expect(abs((track.tick(at: at(41)) ?? 0) - 102.05) < 0.01)
        let jitter = track.jitterRMS ?? 0
        #expect(jitter > 0.0003 && jitter < 0.0007)
    }

    @Test func timestampLeadsAreKeptAndRecentClocksCanBeLookedUp() {
        let timeline = SyncTimeline()
        timeline.beginCapture()
        timeline.record(.songPosition(10), at: at(0))
        timeline.record(.continue, at: at(1), timestampLead: .milliseconds(30))
        for i in 0..<5 { timeline.record(.timingClock, at: at(10 + Double(i) * 20), timestampLead: .milliseconds(30 + i)) }
        let capture = timeline.endCapture()
        #expect(capture.first?.timestampLead == nil)
        #expect(capture.last?.timestampLead == .milliseconds(34))
        #expect(timeline.clockSample(atOrAfter: 62)?.tick == 62)
        #expect(timeline.clockSample(atOrAfter: 62)?.time == at(50))
        #expect(timeline.clockSample(atOrAfter: 0)?.tick == 60)
        #expect(timeline.clockSample(atOrAfter: 65) == nil)
    }

    @Test func monitorTimesTimedMessagesByTheirTimestamps() async {
        let monitor = SyncMonitor()
        let t0 = ContinuousClock.now
        await monitor.handle(TimedMIDIMessage(message: .songPosition(32), receivedAt: t0))
        await monitor.handle(TimedMIDIMessage(message: .continue, receivedAt: t0))
        // Clocks delivered 25 ms before the times they stand for.
        for i in 0..<30 {
            let stands = t0.advanced(by: .milliseconds(25) + .microseconds(20_833) * i)
            await monitor.handle(TimedMIDIMessage(message: .timingClock, receivedAt: stands.advanced(by: .milliseconds(-25)), timestamp: stands))
        }
        let fix = monitor.timeline.fix()
        #expect(fix.lastClock?.tick == 32 * 6 + 29)
        #expect(fix.lastClock?.time == t0.advanced(by: .milliseconds(25) + .microseconds(20_833) * 29))
        #expect(abs((fix.tempoBPM ?? 0) - 120) < 0.5)
        #expect(await monitor.snapshot().tempoBPM.map { abs($0 - 120) < 0.5 } == true)
    }

    @Test func monitorFeedsTheTimelineWithoutChangingTheSnapshot() async {
        let monitor = SyncMonitor()
        let t0 = ContinuousClock.now
        await monitor.handle(.songPosition(32), at: t0)
        await monitor.handle(.continue, at: t0)
        for i in 0..<48 { await monitor.handle(.timingClock, at: t0.advanced(by: .microseconds(20_833) * i)) }
        #expect(await monitor.snapshot().positionSixteenths == 32 + 48 / 6)
        #expect(monitor.timeline.fix().lastClock?.tick == 32 * 6 + 47)
    }
}
