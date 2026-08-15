// AudioMixer.swift
// Sums ScreenCaptureKit's microphone and system-audio streams into ONE
// uniformly-formatted PCM stream, so `AudioTrackMode.mixed` can write a single
// audio track that plays everywhere (many players and upload pipelines — YouTube
// among them — read only the FIRST audio track of an MP4).
//
// ── WHY THIS FILE EXISTS AT ALL (project trap #4) ─────────────────────────────
// Apple DTS confirmed that appending SCK's `.audio` and `.microphone` sample
// buffers to a SINGLE AVAssetWriterInput produces a corrupt, unplayable MP4:
// the two carry different CMFormatDescriptions, potentially different sample
// rates and channel counts, and independent clocks, so the muxer's sample tables
// end up nonsense. `.mixed` is therefore NOT "point both append paths at one
// input". Everything below exists so that by the time a buffer reaches the
// writer there is exactly ONE format, ONE clock, and ONE monotonically
// increasing sample position on that input — the writer never sees the seam.
//
// Nothing here touches AVAudioEngine. AVAudioEngine's default graph is wired to
// the output device, which system-audio capture would immediately re-record:
// a feedback loop that grows louder every pass. AVAudioConverter alone does the
// format work with no audio graph and no output device involved.

import AVFoundation
import CoreMedia
import Foundation
import os

/// Mixes the two capture sources into one canonical-format PCM stream.
///
/// THREAD SAFETY: all mutable state is guarded by `lock`. The two audio pumps
/// (system audio and microphone) run on separate detached tasks and call
/// `push` concurrently, so this cannot rely on the caller's serialization.
public final class AudioMixer: @unchecked Sendable {

    // MARK: - Canonical format

    /// CANONICAL FORMAT: 48 kHz, stereo, **Float32, interleaved**.
    ///
    /// - 48 kHz stereo because that is what ScreenCaptureKit delivers natively
    ///   for both sources on this hardware, so the common case costs a memcpy
    ///   rather than a resample, and it is already what the AAC writer input is
    ///   configured for (see `Recorder.makeAudioInput`) — one conversion for the
    ///   whole pipeline instead of two.
    /// - Float32 rather than Int16 because mixing is a SUM: two sources at full
    ///   scale reach ±2.0. In Int16 that intermediate has to be clamped (or it
    ///   wraps into a loud click) *before* any shaping can be applied, so the
    ///   information needed to limit gracefully is already gone. Float32 carries
    ///   the sum exactly and lets `softClip` shape it afterwards. AVAudioConverter
    ///   and the AAC encoder both take Float32 LPCM directly, so the extra
    ///   precision costs nothing downstream.
    /// - Interleaved because a CMSampleBuffer then needs exactly one contiguous
    ///   CMBlockBuffer; non-interleaved would mean a multi-buffer AudioBufferList
    ///   and a materially more delicate construction path for zero benefit.
    public static let sampleRate: Double = 48_000
    public static let channelCount: AVAudioChannelCount = 2

    static let canonicalFormat: AVAudioFormat = {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioMixer.sampleRate,
            channels: AudioMixer.channelCount,
            interleaved: true
        ) else {
            // Cannot fail for a valid constant description; a nil here means the
            // constants above were edited into something invalid.
            preconditionFailure("AudioMixer canonical format is not constructible")
        }
        return format
    }()

    private static let log = Logger(subsystem: "com.halo.recorder", category: "AudioMixer")

    // MARK: - Stats

    public struct Stats: Sendable, Equatable {
        /// Input sample buffers accepted, per source.
        public var microphoneBuffersIn: Int = 0
        public var systemAudioBuffersIn: Int = 0
        /// Input buffers that could not be decoded/converted and were skipped.
        public var buffersRejected: Int = 0
        /// Mixed blocks handed back to the caller.
        public var blocksOut: Int = 0
        /// Canonical frames written as silence: either padding inside one
        /// source's gap, or a span no source covered at all. A block where one
        /// of two sources was missing is counted by
        /// `blocksEmittedWithoutAllSources` instead.
        public var silenceFramesSynthesized: Int = 0
        /// Canonical frames discarded because they arrived for a span that had
        /// already been mixed and emitted.
        public var lateFramesDropped: Int = 0
        /// Blocks emitted before every source had delivered its share, because
        /// one source ran `lateTolerance` ahead of the other.
        public var blocksEmittedWithoutAllSources: Int = 0
        /// Canonical frames of a no-source-had-anything span that were skipped
        /// over rather than materialized as silence blocks. The track gains a
        /// hole of exactly this length; the next block's PTS is absolute, so
        /// nothing after it shifts. See `skipEmptySpan`.
        public var silenceFramesSkipped: Int = 0
    }

    // MARK: - Per-source lane

    /// One capture source's staging area on the canonical timeline.
    ///
    /// `pending` holds canonical interleaved samples starting at absolute frame
    /// `pendingStart`; `head` is how many *frames* at the front have already been
    /// consumed by an emitted block (consuming by index avoids an O(n) shift per
    /// block; the array is compacted when the dead prefix grows past half).
    private final class Lane {
        let kind: AudioSourceKind
        var converter: AVAudioConverter?
        var converterInputFormat: AVAudioFormat?

        var pending: [Float] = []
        var head: Int = 0                     // frames already consumed from the front
        var pendingStart: Int64 = 0           // absolute canonical frame of pending[head]

        /// Absolute canonical frame one past the last sample ever ingested.
        /// `Int64.min` means "this source has produced nothing yet", which is
        /// what makes a late-starting source distinguishable from a stalled one.
        var endFrame: Int64 = .min

        /// Set by `endLane` when this source's AsyncStream has finished, i.e.
        /// nothing more can EVER arrive on it. An ended lane no longer holds
        /// the output back — the exact, immediate answer to "is this source
        /// over?", which the staleness timeout below can only approximate.
        var ended: Bool = false

        /// `systemUptime` of this lane's most recent arrival (or of the
        /// mixer's construction, before the first one). Drives the staleness
        /// test in `drain`: a source that is still delivering is waited for
        /// however far behind its timeline runs, so ordinary arrival skew
        /// between the two pumps never costs a sample.
        var lastArrival: TimeInterval

        /// Rate limiting for the "samples arrived too late to use" warning:
        /// how many frames have been lost since the last log line, and when
        /// that line was emitted. Losing audio must never be silent, but one
        /// log line per 21 ms block would be its own problem.
        var droppedSinceLog: Int = 0
        var lastDropLogTime: TimeInterval = 0

        init(kind: AudioSourceKind, now: TimeInterval) {
            self.kind = kind
            self.lastArrival = now
        }

        var pendingFrames: Int { (pending.count / 2) - head }
        var pendingEnd: Int64 { pendingStart + Int64(pendingFrames) }
        var hasData: Bool { endFrame != .min }
    }

    // MARK: - Configuration

    /// Frames per emitted block. 1024 @ 48 kHz ≈ 21.3 ms — small enough that the
    /// mixed track lags the inputs imperceptibly, large enough that the
    /// per-buffer overhead (a CMBlockBuffer allocation) stays negligible.
    private let blockFrames: Int

    /// WALL-CLOCK time a live source may deliver NOTHING before it stops
    /// holding the output back (its span then becoming silence).
    ///
    /// This measures the right thing, and that matters more than its value.
    /// The question the readiness rule has to answer is "has this source
    /// stopped producing?", which is a statement about the passage of real
    /// time. The obvious cheap proxy — "the OTHER source's timeline has run N
    /// ahead of this one" — answers a different question, because two sources
    /// can both be delivering perfectly while one's buffers simply arrive
    /// behind the other's. The two pumps are independent detached tasks that
    /// contend for Recorder's lock against a video pump appending 4K frames, so
    /// arrival skew of several hundred milliseconds is an ordinary scheduling
    /// outcome. Under the position-based proxy any skew past the bound made
    /// `ingest` discard the laggard's samples permanently — and a SUSTAINED
    /// skew discarded that source for the whole recording, silently, which is
    /// precisely the narration loss mixed mode exists to prevent (measured:
    /// a 1.0 s sustained delivery lag cost 5.4 s of a 6.4 s microphone track).
    ///
    /// Measured against arrivals instead, skew costs nothing at all: a source
    /// that is merely behind is still delivering, so the mixer waits for it and
    /// every sample lands. Only a source that has genuinely gone quiet for a
    /// full second — and has not reported end-of-stream, which `endLane`
    /// handles instantly and exactly — spends this timeout, once.
    private let staleTimeoutSeconds: TimeInterval

    /// Absolute bound on how far the leading source's timeline may run past the
    /// block being emitted, regardless of the staleness rule above.
    ///
    /// Purely a memory guard, not a correctness knob. Waiting on a live-but-far
    /// behind source means staging the leader's samples until the laggard
    /// catches up, and that backlog is unbounded if a source falls permanently
    /// behind (roughly 384 KB per second of skew per lane). 10 s is far beyond
    /// any scheduling hiccup, so reaching it means something is genuinely
    /// broken and dropping the laggard is the lesser failure.
    private let maxSkewFrames: Int64

    /// A span this long that NO lane has any data for is skipped over rather
    /// than materialized as silence blocks. Both audio paths pausing together
    /// (display sleep, SCStream suspension) and then resuming would otherwise
    /// make a single `push` synthesize the whole gap: a 10-minute pause is
    /// ~28,000 blocks and ~225 MB, allocated in one synchronous call while
    /// Recorder's lock is held — which also blocks the video pump. Skipping
    /// leaves a hole in the audio track instead, and a hole is harmless because
    /// every block's PTS is absolute, so nothing after it shifts against video.
    private let gapSkipFrames: Int64

    /// Upper bound on blocks emitted by one non-flushing `drain`, so a burst is
    /// spread over subsequent pushes instead of being allocated (and appended
    /// under Recorder's lock) all at once. 64 blocks ≈ 1.4 s of audio.
    private static let maxBlocksPerDrain = 64

    /// Sub-`slack` disagreement between a chunk's PTS-derived position and where
    /// the lane's data actually ended is absorbed by appending contiguously
    /// rather than by inserting silence or dropping samples.
    ///
    /// This exists because AVAudioConverter's resampler holds a few frames of
    /// internal latency, so with a non-48 kHz input the emitted frame count per
    /// buffer does not exactly match the nominal duration. Inserting a 10-sample
    /// silence every buffer to "correct" that would be a periodic zero-notch —
    /// audible as a buzz — while the error itself is inaudible. Anything LARGER
    /// than the slack is a genuine discontinuity and is resynchronized against
    /// the PTS, so real drift can never accumulate past 5 ms.
    private let slackFrames: Int64

    // MARK: - Guarded state

    private let lock = NSLock()
    private var lanes: [AudioSourceKind: Lane] = [:]
    /// Absolute canonical frame of the next block to emit. Also the low-water
    /// mark of the timeline: anything arriving before this has already been
    /// written and cannot be retro-fitted.
    private var nextOutputFrame: Int64 = 0
    private var _stats = Stats()
    private var formatDescription: CMAudioFormatDescription?
    /// Scratch accumulator, reused across blocks to keep the steady state
    /// allocation-free apart from the block buffer itself.
    private var accumulator: [Float] = []

    // MARK: - Init

    /// - Parameters:
    ///   - mixesMicrophone: microphone capture is enabled in the config. A lane
    ///     is pre-created so the mixer WAITS (up to `lateTolerance`) for a source
    ///     that is merely slow to warm up, instead of racing ahead and writing
    ///     its first second as silence.
    ///   - mixesSystemAudio: as above, for system audio.
    public init(
        mixesMicrophone: Bool,
        mixesSystemAudio: Bool,
        blockFrames: Int = 1024,
        staleTimeoutSeconds: Double = 1.0,
        resyncSlackSeconds: Double = 0.005,
        gapSkipSeconds: Double = 2.0,
        maxSkewSeconds: Double = 10.0
    ) {
        self.blockFrames = max(64, blockFrames)
        self.staleTimeoutSeconds = max(0, staleTimeoutSeconds)
        self.slackFrames = Int64((resyncSlackSeconds * AudioMixer.sampleRate).rounded())
        self.gapSkipFrames = max(Int64(blockFrames), Int64((gapSkipSeconds * AudioMixer.sampleRate).rounded()))
        self.maxSkewFrames = Int64((maxSkewSeconds * AudioMixer.sampleRate).rounded())
        // A lane's staleness clock starts at construction, so a source that
        // never delivers a single buffer is waited for exactly once (for
        // `staleTimeoutSeconds`) and then stops gating — rather than being
        // waited for forever or not at all.
        let now = ProcessInfo.processInfo.systemUptime
        if mixesMicrophone { lanes[.microphone] = Lane(kind: .microphone, now: now) }
        if mixesSystemAudio { lanes[.systemAudio] = Lane(kind: .systemAudio, now: now) }
        self.formatDescription = AudioMixer.makeFormatDescription()
    }

    public var stats: Stats {
        lock.lock(); defer { lock.unlock() }
        return _stats
    }

    /// The canonical output format description, for callers that want to assert
    /// what they are about to hand the writer.
    public var outputFormatDescription: CMAudioFormatDescription? {
        lock.lock(); defer { lock.unlock() }
        return formatDescription
    }

    // MARK: - Ingest

    /// Accepts one capture buffer and returns however many mixed blocks became
    /// deliverable as a result — usually zero or one, more when a source has
    /// just jumped forward. Returned buffers are already in the canonical format
    /// with strictly increasing, gap-free presentation timestamps, so the caller
    /// appends them to its single AVAssetWriterInput in order and does nothing
    /// else.
    public func push(_ frame: AudioFrame) -> [CMSampleBuffer] {
        lock.lock()
        defer { lock.unlock() }

        // A lane can also appear here without having been declared at init (a
        // source the config said was off but that delivered anyway). Creating it
        // lazily is safe: it arrives WITH data, so its `endFrame` is set in the
        // same call and the readiness test below never stalls on it.
        let now = ProcessInfo.processInfo.systemUptime
        let lane: Lane
        if let existing = lanes[frame.source] {
            lane = existing
        } else {
            lane = Lane(kind: frame.source, now: now)
            lanes[frame.source] = lane
            AudioMixer.log.info("AudioMixer: lane \(String(describing: frame.source), privacy: .public) activated on first buffer")
        }
        // Stamped on ARRIVAL, before any decode/convert work, and stamped even
        // for a buffer that turns out to be unusable: what this records is that
        // the source is alive, which is true either way.
        lane.lastArrival = now
        // A source that delivers again after `endLane` (a stream that finished
        // and was somehow restarted) is live again; refusing to un-end it would
        // silently drop everything it sends from here on.
        lane.ended = false

        switch frame.source {
        case .microphone: _stats.microphoneBuffersIn += 1
        case .systemAudio: _stats.systemAudioBuffersIn += 1
        }

        guard let converted = convertToCanonical(frame.sampleBuffer, lane: lane), converted.frameLength > 0 else {
            _stats.buffersRejected += 1
            return []
        }

        // PTS ALIGNMENT: `frame.presentationTime` is already normalized to
        // start-of-recording = 0 by ScreenSource, and CRUCIALLY both sources are
        // normalized against the SAME origin (ScreenSource.firstHostTime), so
        // converting each to an absolute frame index on one 48 kHz timeline is
        // all the alignment the two streams need. No cross-correlation, no
        // "whichever arrived first wins" — position is derived from the clock.
        let startFrame = AudioMixer.frameIndex(for: frame.presentationTime)
        ingest(converted, into: lane, startFrame: startFrame)

        return drain(flushing: false)
    }

    /// Declares that `kind`'s capture stream has FINISHED — nothing more can
    /// ever arrive on it. Call this from each audio pump when its `for await`
    /// loop exits.
    ///
    /// The mixer's own staleness rule can only INFER that a source is finished,
    /// and only after `staleTimeoutSeconds` of silence — during which the mixed
    /// track stalls. This says so precisely and immediately instead, so the
    /// timeout is a fallback for sources that die without notice rather than
    /// the normal path.
    ///
    /// - Returns: blocks that became deliverable because this lane stopped
    ///   holding them back. Append them like `push`'s output.
    @discardableResult
    public func endLane(_ kind: AudioSourceKind) -> [CMSampleBuffer] {
        lock.lock()
        defer { lock.unlock() }

        let lane: Lane
        if let existing = lanes[kind] {
            lane = existing
        } else {
            // A source that was expected but never delivered a single buffer:
            // record it as an ended lane so it cannot gate anything later.
            lane = Lane(kind: kind, now: ProcessInfo.processInfo.systemUptime)
            lanes[kind] = lane
        }
        guard !lane.ended else { return [] }
        lane.ended = true
        AudioMixer.log.info("AudioMixer: lane \(String(describing: kind), privacy: .public) ended")
        return drain(flushing: false)
    }

    /// Emits everything still staged, padding the shorter source with silence so
    /// the final block ends on the last sample either source produced. Call once
    /// after both input streams have finished and before `markAsFinished`.
    public func flush() -> [CMSampleBuffer] {
        lock.lock()
        defer { lock.unlock() }
        return drain(flushing: true)
    }

    // MARK: - Format conversion

    /// Converts one capture buffer to the canonical format, building (and
    /// rebuilding) this lane's AVAudioConverter as the input format demands.
    ///
    /// The converter is cached per lane and only recreated when the incoming
    /// format actually changes: constructing one per buffer would both cost real
    /// CPU and reset the resampler's state every 20 ms, which is audible.
    private func convertToCanonical(_ sampleBuffer: CMSampleBuffer, lane: Lane) -> AVAudioPCMBuffer? {
        guard let sourceDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(sourceDescription)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM
        else {
            // Compressed capture audio is not a thing ScreenCaptureKit produces;
            // if it ever were, mixing it would need a decode step this file
            // deliberately does not carry.
            return nil
        }

        let sourceFormat = AVAudioFormat(cmAudioFormatDescription: sourceDescription)
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return nil }

        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }
        // frameLength must be set BEFORE the copy: it is what sizes the
        // mDataByteSize fields of the AudioBufferList that CoreMedia fills in.
        inputBuffer.frameLength = AVAudioFrameCount(frameCount)
        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: inputBuffer.mutableAudioBufferList
        )
        guard copyStatus == noErr else { return nil }

        // Already canonical (the normal case on this hardware): skip the
        // converter entirely.
        if sourceFormat.isCanonicalMix {
            return inputBuffer
        }

        if lane.converter == nil || lane.converterInputFormat?.isEqual(sourceFormat) != true {
            guard let converter = AVAudioConverter(from: sourceFormat, to: AudioMixer.canonicalFormat) else {
                return nil
            }
            // Mono -> stereo needs an explicit map: without one AVAudioConverter
            // fills only the first output channel and the mix ends up
            // hard-panned left. [0, 0] copies the single input channel to both.
            if sourceFormat.channelCount == 1 {
                converter.channelMap = [0, 0]
            }
            lane.converter = converter
            lane.converterInputFormat = sourceFormat
            AudioMixer.log.info(
                """
                AudioMixer: \(String(describing: lane.kind), privacy: .public) converter \
                \(sourceFormat.sampleRate, privacy: .public)Hz/\(sourceFormat.channelCount, privacy: .public)ch \
                -> 48000Hz/2ch float32
                """
            )
        }
        guard let converter = lane.converter else { return nil }

        // Ratio plus a pad: a resampler can emit one frame more than the exact
        // ratio implies on any given call, and an undersized output buffer would
        // silently truncate.
        let ratio = AudioMixer.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(frameCount) * ratio).rounded(.up)) + 64
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: AudioMixer.canonicalFormat, frameCapacity: capacity) else {
            return nil
        }

        // The input block hands over this one buffer and then reports the input
        // as dry, so `convert` returns as soon as it has drained what it can.
        let pull = ConverterInput(inputBuffer)
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if pull.supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            pull.supplied = true
            outStatus.pointee = .haveData
            return pull.buffer
        }
        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            return outputBuffer.frameLength > 0 ? outputBuffer : nil
        case .error:
            AudioMixer.log.error("AudioMixer: conversion failed: \(conversionError?.localizedDescription ?? "unknown", privacy: .public)")
            return nil
        @unknown default:
            return nil
        }
    }

    /// One-shot supply state for `AVAudioConverter`'s pull block.
    ///
    /// `AVAudioConverterInputBlock` is declared `@Sendable` by the SDK, but
    /// `convert(to:error:withInputFrom:)` invokes it synchronously on the
    /// calling thread and never retains it past the call, so nothing here can
    /// be touched concurrently. `@unchecked Sendable` states that rather than
    /// leaving a warning about a non-Sendable AVAudioPCMBuffer capture.
    private final class ConverterInput: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        var supplied = false
        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    }

    // MARK: - Timeline staging

    /// Places one converted chunk on the lane's timeline at `startFrame`,
    /// synthesizing silence for gaps and trimming overlaps.
    ///
    /// SILENCE, NOT SHIFTING: when a source skips a span, the missing frames
    /// become zeros of exactly the missing duration. Appending the late chunk
    /// straight after the previous one instead would pull everything after it
    /// EARLIER by the gap, and that error is permanent — the mixed track would
    /// drift against the video by the total of every gap in the recording.
    private func ingest(_ buffer: AVAudioPCMBuffer, into lane: Lane, startFrame: Int64) {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let source = buffer.floatChannelData?[0] else { return }

        var start = startFrame
        var skipFrames = 0

        if lane.pendingFrames > 0 {
            let gap = start - lane.pendingEnd
            if abs(gap) <= slackFrames {
                // Sub-slack disagreement: converter latency / rounding, not a
                // real discontinuity. Append contiguously.
                start = lane.pendingEnd
            } else if gap > 0 {
                if gap > Int64(blockFrames) * 128 {
                    // Absurd jump (a source that vanished for seconds). Drop the
                    // stale remainder rather than allocating the whole gap as
                    // zeros; the emitted blocks cover that span as silence
                    // anyway, since this lane simply has nothing there.
                    lane.pending.removeAll(keepingCapacity: true)
                    lane.head = 0
                    lane.pendingStart = start
                } else {
                    lane.pending.append(contentsOf: repeatElement(0, count: Int(gap) * 2))
                    _stats.silenceFramesSynthesized += Int(gap)
                    start = lane.pendingEnd
                }
            } else {
                // Real overlap: the tail of this chunk covers ground already
                // staged. Keep what is staged, drop the duplicated head.
                skipFrames = Int(-gap)
                if skipFrames >= frames {
                    // Wholly duplicated (a stale buffer arriving out of order).
                    _stats.lateFramesDropped += frames
                    return
                }
                start = lane.pendingEnd
            }
        } else {
            // Empty lane: no padding is needed at all. A block region that no
            // lane covers is already zeros in the accumulator, so the gap
            // between the last emitted frame and `start` becomes silence for
            // free — and at exactly the right duration, because `start` came
            // from the PTS.
            lane.pending.removeAll(keepingCapacity: true)
            lane.head = 0
            lane.pendingStart = start
        }

        // Anything wholly before the timeline's low-water mark has already been
        // written to the file; it cannot be retro-fitted.
        //
        // THIS IS REAL AUDIO BEING LOST — it is the "narration silently
        // disappears" failure that mixed mode exists to prevent, so it is
        // logged rather than only counted in a Stats struct nothing reads.
        // Reaching here means this source went quiet for `staleTimeout`, or ran
        // `maxSkew` behind, or reported end-of-stream and then delivered more:
        // ordinary arrival skew no longer lands here at all (see `drain`).
        if start < nextOutputFrame {
            let dead = min(Int64(frames - skipFrames), nextOutputFrame - start)
            if dead > 0 {
                skipFrames += Int(dead)
                start += dead
                _stats.lateFramesDropped += Int(dead)
                noteLateDrop(lane: lane, frames: Int(dead))
                if skipFrames >= frames { return }
                if lane.pendingFrames == 0 { lane.pendingStart = start }
            }
        }

        let usable = frames - skipFrames
        guard usable > 0 else { return }
        lane.pending.reserveCapacity(lane.pending.count + usable * 2)
        for index in (skipFrames * 2)..<((skipFrames + usable) * 2) {
            lane.pending.append(source[index])
        }
        // `.min` is the "nothing yet" sentinel, so max() promotes it correctly.
        lane.endFrame = max(lane.endFrame, start + Int64(usable))
    }

    /// Reports dropped-because-late frames: immediately on the first loss for a
    /// lane, then at most once every 5 seconds with the running total. Caller
    /// must hold `lock`.
    private func noteLateDrop(lane: Lane, frames: Int) {
        lane.droppedSinceLog += frames
        let now = ProcessInfo.processInfo.systemUptime
        guard lane.lastDropLogTime == 0 || now - lane.lastDropLogTime >= 5 else { return }
        let milliseconds = Int((Double(lane.droppedSinceLog) / AudioMixer.sampleRate) * 1000)
        AudioMixer.log.warning(
            """
            AudioMixer: dropped \(milliseconds, privacy: .public)ms of \
            \(String(describing: lane.kind), privacy: .public) audio — buffers arrived after \
            their span had already been mixed and written. That audio is not in the file.
            """
        )
        lane.droppedSinceLog = 0
        lane.lastDropLogTime = now
    }

    // MARK: - Mixing

    /// Fast-forwards `nextOutputFrame` over a long span that NO lane has any
    /// data for, instead of emitting it as thousands of silence blocks. Caller
    /// must hold `lock`.
    ///
    /// Only a span nobody covers is skipped: if any lane still has staged
    /// samples, `earliest` is that lane's start and nothing moves. So this can
    /// never skip past audio — it only declines to write silence that carries
    /// no information. The resulting hole in the track is safe precisely
    /// because every emitted block's PTS is absolute: the audio after the hole
    /// still lands at its true time against the video.
    private func skipEmptySpan(upTo maxEnd: Int64, lanes laneList: [Lane]) {
        guard maxEnd - nextOutputFrame > gapSkipFrames else { return }

        var earliest = Int64.max
        for lane in laneList where lane.pendingFrames > 0 {
            earliest = min(earliest, lane.pendingStart)
        }
        let target = (earliest == .max) ? maxEnd : earliest
        guard target - nextOutputFrame > gapSkipFrames else { return }

        // Land on a block boundary so block geometry stays uniform.
        let aligned = (target / Int64(blockFrames)) * Int64(blockFrames)
        guard aligned > nextOutputFrame else { return }

        let skipped = aligned - nextOutputFrame
        _stats.silenceFramesSkipped += Int(skipped)
        AudioMixer.log.info(
            """
            AudioMixer: skipped \(Int(Double(skipped) / AudioMixer.sampleRate * 1000), privacy: .public)ms \
            with no audio from any source rather than writing it as silence blocks
            """
        )
        nextOutputFrame = aligned
    }

    /// Emits every block that is currently deliverable.
    ///
    /// READINESS RULE — the whole "the two sources do not arrive in lockstep"
    /// problem lives here. A block is emitted once every source that could
    /// still contribute to it has; a source counts as unable to contribute
    /// when, and only when, one of these holds:
    ///   • its stream has ENDED (`endLane`) — exact and immediate;
    ///   • it has delivered NOTHING for `staleTimeoutSeconds` of wall clock —
    ///     the inference for a source that dies without notice;
    ///   • the leader is `maxSkew` ahead of it — the memory guard.
    /// Anything else waits, however far behind the laggard's timeline runs,
    /// because a source that is still delivering will still deliver this span
    /// and emitting the block now would discard it (`ingest` cannot retro-fit
    /// samples into a span already written).
    ///
    /// Note that the first two conditions are about the SOURCE's liveness, not
    /// about how the two timelines compare. That distinction is the fix for the
    /// failure where ordinary arrival skew between the two detached pumps
    /// silently deleted one source from the recording.
    ///
    /// WORK BOUND: a non-flushing drain emits at most `maxBlocksPerDrain`
    /// blocks, and `skipEmptySpan` collapses long nobody-had-anything spans, so
    /// one `push` can never allocate an unbounded burst while the caller holds
    /// its writer lock.
    private func drain(flushing: Bool) -> [CMSampleBuffer] {
        var output: [CMSampleBuffer] = []
        let laneList = Array(lanes.values)
        guard !laneList.isEmpty else { return output }

        let now = ProcessInfo.processInfo.systemUptime

        while true {
            // `minEndLive` gates readiness and counts only lanes that could
            // still deliver this span; `minEndAll` is just for the partial-mix
            // stat.
            var minEndLive = Int64.max
            var minEndAll = Int64.max
            var maxEnd = Int64.min
            var liveLanes = 0
            var allEnded = true
            for lane in laneList {
                minEndAll = min(minEndAll, lane.endFrame)
                maxEnd = max(maxEnd, lane.endFrame)
                if lane.ended { continue }
                allEnded = false
                // Still delivering? Then it will cover this span too — wait.
                guard now - lane.lastArrival < staleTimeoutSeconds else { continue }
                liveLanes += 1
                minEndLive = min(minEndLive, lane.endFrame)
            }
            guard maxEnd > Int64.min else { break }   // nothing has arrived at all

            // Nobody can contribute anything further right now, so waiting is
            // pointless: drain the remainder exactly as a flush would.
            let finalizing = flushing || liveLanes == 0

            skipEmptySpan(upTo: maxEnd, lanes: laneList)

            let blockStart = nextOutputFrame
            var blockEnd = blockStart + Int64(blockFrames)

            var partialMix = false
            if finalizing {
                guard maxEnd > blockStart else { break }
                // Final block: end exactly on the last sample produced, so the
                // track does not gain a tail of padding.
                blockEnd = min(blockEnd, maxEnd)
                partialMix = minEndAll < blockEnd
            } else {
                if minEndLive >= blockEnd {
                    // Every live source has the data: a complete mix.
                    partialMix = minEndAll < blockEnd
                } else if maxEnd >= blockEnd + maxSkewFrames {
                    // Memory guard only — a live source this far behind is a
                    // malfunction, and the alternative is staging the leader's
                    // samples without limit.
                    partialMix = true
                    AudioMixer.log.warning(
                        """
                        AudioMixer: a source is more than \
                        \(Int(Double(self.maxSkewFrames) / AudioMixer.sampleRate), privacy: .public)s behind and \
                        is being written as silence from \(blockStart, privacy: .public) frames
                        """
                    )
                } else {
                    break
                }
            }
            guard blockEnd > blockStart else { break }

            guard let buffer = emitBlock(from: blockStart, to: blockEnd, lanes: laneList) else { break }
            output.append(buffer)
            _stats.blocksOut += 1
            if partialMix { _stats.blocksEmittedWithoutAllSources += 1 }
            nextOutputFrame = blockEnd

            // Hand back what we have and let the next push continue. Only
            // `flush()` and the all-lanes-ENDED case may run uncapped, because
            // those are the two cases with no next push to continue from; a
            // merely stale lane can still wake up and drive one.
            if !flushing, !allEnded, output.count >= AudioMixer.maxBlocksPerDrain { break }
        }
        return output
    }

    /// Sums every lane's contribution over `[start, end)` and packages it as one
    /// canonical CMSampleBuffer.
    private func emitBlock(from start: Int64, to end: Int64, lanes laneList: [Lane]) -> CMSampleBuffer? {
        let frames = Int(end - start)
        let sampleCount = frames * 2

        // Zero-filled: every frame no lane covers is silence by construction,
        // which is precisely the "missing input becomes silence of the correct
        // duration" requirement — the duration comes from the block geometry,
        // never from what a source happened to deliver.
        if accumulator.count < sampleCount {
            accumulator = [Float](repeating: 0, count: sampleCount)
        } else {
            for index in 0..<sampleCount { accumulator[index] = 0 }
        }
        var silentFrames = frames

        for lane in laneList {
            let laneStart = lane.pendingStart
            let laneEnd = lane.pendingEnd
            guard lane.pendingFrames > 0, laneEnd > start, laneStart < end else {
                // Entirely in the future (or empty): leave it staged.
                if laneEnd <= start && lane.pendingFrames > 0 {
                    // Entirely in the past — already-mixed leftovers. Discard.
                    lane.pending.removeAll(keepingCapacity: true)
                    lane.head = 0
                    lane.pendingStart = end
                }
                continue
            }

            let from = max(laneStart, start)
            let to = min(laneEnd, end)
            let copyFrames = Int(to - from)
            if copyFrames > 0 {
                let sourceOffset = (lane.head + Int(from - laneStart)) * 2
                let destinationOffset = Int(from - start) * 2
                lane.pending.withUnsafeBufferPointer { source in
                    for index in 0..<(copyFrames * 2) {
                        accumulator[destinationOffset + index] += source[sourceOffset + index]
                    }
                }
                silentFrames -= copyFrames
            }

            // Consume everything up to `end`; what remains belongs to a later
            // block. `head` advances instead of shifting the array; compact only
            // once the dead prefix outweighs the live data.
            let consumed = Int(min(laneEnd, end) - laneStart)
            if consumed > 0 {
                lane.head += consumed
                lane.pendingStart = laneStart + Int64(consumed)
                if lane.head * 2 >= lane.pending.count {
                    lane.pending.removeAll(keepingCapacity: true)
                    lane.head = 0
                } else if lane.head * 2 > lane.pending.count / 2 {
                    lane.pending.removeFirst(lane.head * 2)
                    lane.head = 0
                }
            }
        }
        if silentFrames > 0 { _stats.silenceFramesSynthesized += silentFrames }

        // CLIPPING: see `softClip`.
        for index in 0..<sampleCount {
            accumulator[index] = AudioMixer.softClip(accumulator[index])
        }

        let pts = CMTime(value: start, timescale: CMTimeScale(AudioMixer.sampleRate))
        return makeSampleBuffer(frameCount: frames, presentationTime: pts)
    }

    /// HEADROOM / CLIPPING POLICY.
    ///
    /// Two independent sources summed at unity can reach ±2.0, and anything past
    /// ±1.0 is a hard clip — the loudest, ugliest artifact this pipeline could
    /// produce. The obvious fix, attenuating both sources by 6 dB, is worse in
    /// the common case: most of a screencast has narration over near-silent
    /// system audio, and pre-attenuation would make that narration quiet in
    /// every recording to insure against a peak that usually never comes.
    ///
    /// So: unity gain up to the knee, then a smooth compressive curve that is
    /// asymptotically bounded by 1.0 and can never clip.
    ///   |x| <= knee            -> x, bit-exact, no coloration at all
    ///   |x| >  knee            -> knee + (1-knee)·tanh((|x|-knee)/(1-knee))
    /// The curve is continuous AND C1 at the knee (tanh'(0) = 1 cancels the
    /// 1/(1-knee) scaling), so there is no discontinuity to hear as the signal
    /// crosses it.
    ///
    /// Deliberately STATELESS — a waveshaper, not a compressor with attack and
    /// release. A stateful limiter would carry gain-reduction state across the
    /// gaps and silence spans this mixer synthesizes, and would then apply the
    /// wrong gain on the far side of a dropout. A memoryless curve cannot
    /// desynchronize from a timeline that has holes in it.
    @inline(__always)
    static func softClip(_ x: Float) -> Float {
        let knee: Float = 0.7
        let magnitude = abs(x)
        if magnitude <= knee { return x }
        let excess = (magnitude - knee) / (1 - knee)
        let shaped = knee + (1 - knee) * tanhf(excess)
        return x < 0 ? -shaped : shaped
    }

    // MARK: - CMSampleBuffer construction

    private func makeSampleBuffer(frameCount: Int, presentationTime: CMTime) -> CMSampleBuffer? {
        guard let formatDescription else { return nil }
        let byteCount = frameCount * 2 * MemoryLayout<Float>.size

        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,          // let CoreMedia allocate; we fill it below
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let blockBuffer else { return nil }

        status = accumulator.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }
        guard status == noErr else { return nil }

        var sampleBuffer: CMSampleBuffer?
        // packetDescriptions is nil because canonical LPCM is constant
        // bytes-per-packet; CoreMedia derives the layout from the ASBD.
        status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: CMItemCount(frameCount),
            presentationTimeStamp: presentationTime,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr else { return nil }
        return sampleBuffer
    }

    private static func makeFormatDescription() -> CMAudioFormatDescription? {
        var asbd = canonicalFormat.streamDescription.pointee
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        var description: CMAudioFormatDescription?
        let status = withUnsafePointer(to: &layout) { layoutPointer in
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &asbd,
                layoutSize: MemoryLayout<AudioChannelLayout>.size,
                layout: layoutPointer,
                magicCookieSize: 0,
                magicCookie: nil,
                extensions: nil,
                formatDescriptionOut: &description
            )
        }
        return status == noErr ? description : nil
    }

    /// Absolute canonical frame index for a normalized presentation time.
    /// Rounds rather than truncates so a PTS that lands a hair below an exact
    /// frame boundary does not systematically bias every buffer one frame early.
    static func frameIndex(for time: CMTime) -> Int64 {
        guard time.isValid, time.isNumeric else { return 0 }
        let converted = CMTimeConvertScale(
            time,
            timescale: CMTimeScale(AudioMixer.sampleRate),
            method: .roundHalfAwayFromZero
        )
        return max(0, converted.value)
    }
}

private extension AVAudioFormat {
    /// True when this format is already the mixer's canonical layout, so the
    /// converter can be skipped entirely.
    var isCanonicalMix: Bool {
        commonFormat == .pcmFormatFloat32
            && isInterleaved
            && channelCount == AudioMixer.channelCount
            && sampleRate == AudioMixer.sampleRate
    }
}
