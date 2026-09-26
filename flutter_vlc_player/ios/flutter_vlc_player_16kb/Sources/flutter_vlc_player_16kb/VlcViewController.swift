import Flutter
import Foundation
import MobileVLCKit
import UIKit

public class VLCViewController: NSObject, FlutterPlatformView {
    var hostedView: UIView
    var vlcMediaPlayer: VLCMediaPlayer
    var mediaEventChannel: FlutterEventChannel
    let mediaEventChannelHandler: VLCPlayerEventStreamHandler
    var rendererEventChannel: FlutterEventChannel
    let rendererEventChannelHandler: VLCRendererEventStreamHandler
    var rendererdiscoverers: [VLCRendererDiscoverer] = .init()
    private var vlcView: UIView!
    private var seekWorkItem: DispatchWorkItem?
    
    // Dedicated serial queue for reading libvlc properties OFF the timer/main thread.
    // This queue must NEVER be used for set_position or any mutating libvlc call.
    private let vlcReadQueue = DispatchQueue(label: "com.gridstreamr.vlc_read", qos: .userInitiated)
    
    // Subtitle font size as freetype-rel-fontsize (% of video height; VLC default = 5).
    // Stored so it can be re-injected each time a new media or subtitle track opens.
    private var subtitleRelSize: Int = 5
    
    // Tracks the SPU track ID last explicitly set via setSpuTrack.
    // nil  = user has never made an explicit selection this session →
    //        spuTrack falls back to VLC's real currentVideoSubTitleIndex so the
    //        modal correctly reflects what is already playing.
    // non-nil = use this optimistic value so Flutter's _waitForSubtitleActivation
    //        receives the intended index without waiting for VLC's (lagging) commit.
    // Reset to nil on every new media load so the real VLC state is re-read.
    private var lastSetSpuTrackId: Int32? = nil
    
    // Guards to prevent seek flooding (main-thread only)
    private var isSeekInFlight: Bool = false
    private var coalescedSeekTarget: Int64? = nil

    // Pending subtitle-size restore work item – cancelled when a newer resize
    // arrives so only the final tap in a rapid sequence fires the decoder restart.
    private var pendingSubtitleSizeRestore: DispatchWorkItem? = nil

    // Last external subtitle URL added via addSubtitleTrack.
    // For network URLs this will be a LOCAL temp file path after the async
    // download completes.  Used by setSubtitleHeightScale to re-add the slave.
    // Reset on every new media load.
    private var lastExternalSubtitleUrl: URL? = nil

    // Raw bytes of the last external subtitle that was downloaded.
    // Cached so setSubtitleHeightScale can write a NEW temp file without
    // making a second network request — only a fast local write is needed
    // to give VLC a unique URL that forces a fresh FreeType decoder.
    // Reset on every new media load.
    private var lastExternalSubtitleData: Data? = nil

    // Xtream / Smart Collections: sidecar probe runs asynchronously after
    // setSpuTrack. While in flight, defer embedded font-size reloads.
    private var sidecarPromotionInProgress = false
    private var sidecarCandidateQueue: [URL] = []
    private var sidecarCandidateTrackIndex: Int32 = -1
    private var sidecarPromotionAttemptedForTrack: Int32? = nil
    private var pendingSubtitleScaleAfterPromotion: Float? = nil
    
    // Caches — updated only from safe contexts, read from main thread
    private var lastKnownPosition: Int = 0
    private var lastKnownDuration: Int = 0
    private var lastKnownIsPlaying: Bool = false

    // Last media load parameters — stored so setSubtitleHeightScale can reload
    // the same media with an updated freetype-rel-fontsize when the embedded-
    // subtitle fallback is needed (toggle does not restart the FreeType renderer).
    private var lastMediaUri: String = ""
    private var lastMediaIsAsset: Bool = false
    private var lastMediaHwAcc: Int = 0
    private var lastMediaOptions: [String] = []

    public func view() -> UIView {
        return self.hostedView
    }
    
    init(frame: CGRect, viewId: Int64, messenger: FlutterBinaryMessenger) {
        let mediaEventChannel = FlutterEventChannel(
            name: "flutter_video_plugin/getVideoEvents_\(viewId)",
            binaryMessenger: messenger
        )
        let rendererEventChannel = FlutterEventChannel(
            name: "flutter_video_plugin/getRendererEvents_\(viewId)",
            binaryMessenger: messenger
        )
        
        self.hostedView = UIView(frame: frame)
        self.hostedView.backgroundColor = .black
        self.hostedView.isOpaque = true
        
        self.vlcView = UIView(frame: self.hostedView.bounds)
        self.vlcView.backgroundColor = .black
        self.vlcView.isOpaque = true
        self.vlcView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        self.hostedView.addSubview(self.vlcView)
        
        let library = VLCLibrary.shared()
        self.vlcMediaPlayer = VLCMediaPlayer(library: library)
        self.mediaEventChannel = mediaEventChannel
        self.mediaEventChannelHandler = VLCPlayerEventStreamHandler()
        self.mediaEventChannelHandler.player = self.vlcMediaPlayer
        self.rendererEventChannel = rendererEventChannel
        self.rendererEventChannelHandler = VLCRendererEventStreamHandler()
        
        // All stored properties are initialised — call super before using
        // `self` as a value (required by Swift's two-phase initialisation).
        super.init()
        
        self.mediaEventChannel.setStreamHandler(self.mediaEventChannelHandler)
        self.rendererEventChannel.setStreamHandler(self.rendererEventChannelHandler)
        self.vlcMediaPlayer.drawable = self.vlcView
        self.vlcMediaPlayer.delegate = self.mediaEventChannelHandler
        // Give the event handler a back-reference so it can read the optimistic
        // spuTrack (lastSetSpuTrackId) instead of VLC's raw currentVideoSubTitleIndex.
        self.mediaEventChannelHandler.vlcController = self
        
        // Note: minimalTimePeriod is not available in MobileVLCKit 3.x.
        // Time change notifications are received via the standard delegate/notification mechanism.
    }
    
    public func play() {
        self.vlcMediaPlayer.play()
    }
    
    public func pause() {
        self.vlcMediaPlayer.pause()
    }
    
    public func stop() {
        self.vlcMediaPlayer.stop()
    }
    
    public var isPlaying: Bool {
        return self.vlcMediaPlayer.isPlaying
    }
    
    public var isSeekable: Bool {
        // This is a fast check in VLCKit usually
        return self.vlcMediaPlayer.isSeekable
    }
    
    public func setLooping(isLooping: Bool) {
        self.vlcMediaPlayer.media?.addOption(isLooping ? "--loop" : "--no-loop")
    }
    
    public func seek(position: Int64) {
        // Cancel any pending debounce timer
        self.seekWorkItem?.cancel()
        
        // If a seek is already executing in libvlc, coalesce to the latest target
        if self.isSeekInFlight {
            self.coalescedSeekTarget = position
            return
        }
        
        // Short 50ms coalesce window to batch rapid slider moves
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.executeSeek(position: position)
        }
        
        self.seekWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)
    }
    
    private func executeSeek(position: Int64) {
        self.isSeekInFlight = true
        
        // CRITICAL: setPosition ultimately calls libvlc_media_player_set_position
        // which acquires vlc_player_Lock. This MUST NOT run on the vlcReadQueue
        // because the timer callbacks that update time also dispatch there.
        // Use a GCD global concurrent queue — completely isolated from everything.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            let rawDuration = self.vlcMediaPlayer.media?.length.value?.int64Value ?? 0
            let isMicro = rawDuration > 20_000_000
            let duration = isMicro ? (rawDuration / 1000) : rawDuration
            
            // ALWAYS use setPosition (fraction 0..1) rather than setTime.
            // setTime triggers synchronous timeChangeUpdate callbacks that
            // dispatch_sync on _timeChangeLockQueue → deadlock chain.
            if duration > 0 {
                let percent = Double(position) / Double(duration)
                let clampedPercent = max(0.0, min(1.0, percent))
                self.vlcMediaPlayer.position = Float(clampedPercent)
            } else {
                // Fallback: no duration known yet — use setTime best-effort
                let targetTime = isMicro ? (position * 1000) : position
                self.vlcMediaPlayer.time = VLCTime(number: NSNumber(value: targetTime))
            }
            
            // Let VLCKit's watch_time callbacks naturally propagate the new position.
            // Do NOT call refreshCaches or read any player properties here.
            
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.isSeekInFlight = false
                
                // If another seek came in while we were executing, fire it now
                if let next = self.coalescedSeekTarget {
                    self.coalescedSeekTarget = nil
                    self.executeSeek(position: next)
                }
            }
        }
    }
    
    public var position: Int {
        return self.lastKnownPosition
    }
    
    public var duration: Int {
        return self.lastKnownDuration
    }
    
    public func setVolume(volume: Int64) {
        self.vlcMediaPlayer.audio?.volume = Int32(volume)
    }
    
    public var volume: Int32 {
        self.vlcMediaPlayer.audio?.volume ?? 100
    }
    
    public func setPlaybackSpeed(speed: Float) {
        self.vlcMediaPlayer.rate = speed
    }
    
    public var playbackSpeed: Float {
        self.vlcMediaPlayer.rate
    }
    
    public func takeSnapshot() -> String? {
        guard let videoView = self.vlcMediaPlayer.drawable as? UIView else { return nil }
        let size = videoView.frame.size
        UIGraphicsBeginImageContextWithOptions(size, false, 0.0)
        let rec = videoView.frame
        videoView.drawHierarchy(in: rec, afterScreenUpdates: false)
        let image = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        let byteArray = (image ?? UIImage()).pngData()
        
        return byteArray?.base64EncodedString()
    }
    
    public var spuTracksCount: Int32 {
        Int32(self.vlcMediaPlayer.subtitleTrackDictionary().count)
    }
    
    public var spuTracks: [Int: String] {
        self.vlcMediaPlayer.subtitleTrackDictionary()
    }
    
    public func setSpuTrack(spuTrackNumber: Int32) {
        let before = self.vlcMediaPlayer.currentVideoSubTitleIndex
        // Mirror the requested index immediately so spuTrack returns it without
        // waiting for VLC's internal state to commit (avoids Flutter timeout).
        lastSetSpuTrackId = spuTrackNumber
        if spuTrackNumber < 0 {
            // Disable subtitles: use -1 (VLCKit 3 sentinel)
            self.vlcMediaPlayer.currentVideoSubTitleIndex = -1
        } else {
            // Inject the stored font size before enabling so the subtitle ES
            // decoder initialises with the correct freetype option.
            self.vlcMediaPlayer.media?.addOption(":freetype-rel-fontsize=\(subtitleRelSize)")
            self.vlcMediaPlayer.selectSubtitleTrack(at: Int(spuTrackNumber))
        }
        let after = self.vlcMediaPlayer.currentVideoSubTitleIndex
        // Keep this single log per selection (not in the hot polling path).
        print("[VLC-SPU] setSpuTrack: requested=\(spuTrackNumber) vlcBefore=\(before) vlcAfter=\(after)")

        // Xtream / Smart Collections: embedded subtitle font-size resizing is not
        // currently supported. Media reload is intentionally suppressed here to
        // avoid HEVC decoder flicker on iOS with VLCKit 3.5.
    }

    private func isXtreamStyleMediaUri() -> Bool {
        lastMediaUri.contains("/movie/") || lastMediaUri.contains("/series/")
    }
    
    public var spuTrack: Int32 {
        // NOTE: this getter is polled every 60 ms by Flutter — do NOT log here.
        //
        // When the user has made an explicit selection (lastSetSpuTrackId != nil)
        // return the optimistic value so Flutter's _waitForSubtitleActivation
        // receives a stable index immediately after setSpuTrack without waiting
        // for VLC's (sometimes lagging) currentVideoSubTitleIndex to commit.
        //
        // When no explicit selection has been made this session (nil) fall back
        // to VLC's real index so the modal shows the track that is *actually*
        // playing (e.g. a default track chosen by VLC on media open).
        if let lastSet = lastSetSpuTrackId {
            return lastSet
        }
        return self.vlcMediaPlayer.currentVideoSubTitleIndex
    }
    
    public func setSpuDelay(delay: Int) {
        self.vlcMediaPlayer.currentVideoSubTitleDelay = delay
    }
    
    public var spuDelay: Int {
        self.vlcMediaPlayer.currentVideoSubTitleDelay
    }
    
    public func addSubtitleTrack(uri: String, isSelected: Bool) {
        guard let url = URL(string: uri) else { return }
        // Apply the current font size before the external subtitle track opens.
        self.vlcMediaPlayer.media?.addOption(":freetype-rel-fontsize=\(subtitleRelSize)")

        if url.scheme == "http" || url.scheme == "https" {
            // Network subtitles: VLC's addPlaybackSlave silently fails for HTTP
            // URLs in some MobileVLCKit 3 configurations.  Download the SRT to a
            // local temp file first — local-file addPlaybackSlave is reliable and
            // enables fast resize (just write cached bytes to a new temp path).
            print("[VLC-SPU] addSubtitleTrack: network URL — downloading \(url.lastPathComponent)")
            // Signal that a download is in flight so setSubtitleHeightScale defers
            // any scale change via pendingSubtitleScaleAfterPromotion instead of
            // immediately triggering an embedded-subtitle media reload.
            sidecarPromotionInProgress = true
            downloadSubtitleThenAdd(networkUrl: url, isSelected: isSelected) { [weak self] success in
                if !success {
                    // Download failed (e.g. bitmap PGSSUB whose SRT URL returns 404,
                    // or a transient network error).  Clear the in-progress flag and
                    // record this track as "attempted but failed" so subsequent size
                    // changes skip the pointless media-reload path.
                    guard let self else { return }
                    self.sidecarPromotionInProgress = false
                    self.pendingSubtitleScaleAfterPromotion = nil
                    let trackIndex = self.vlcMediaPlayer.currentVideoSubTitleIndex
                    if trackIndex >= 0 {
                        self.sidecarPromotionAttemptedForTrack = trackIndex
                    }
                    print("[VLC-SPU] addSubtitleTrack: sidecar download failed for \(url.lastPathComponent)")
                }
            }
        } else {
            // Local file — read bytes, convert SRT→ASS with font size baked in (same
            // pipeline as network subtitles) so resize works for OpenSubtitles files
            // and any other locally-cached subtitle source (XTREAM, Smart Collections).
            guard let data = try? Data(contentsOf: url), !data.isEmpty else {
                print("[VLC-SPU] addSubtitleTrack: could not read local file \(url.lastPathComponent)")
                return
            }
            self.lastExternalSubtitleData = data
            let srtString = String(data: data, encoding: .utf8)
                          ?? String(data: data, encoding: .isoLatin1)
                          ?? ""
            let assData = srtString.isEmpty
                ? data
                : (srtToAssData(srtContent: srtString, relFontSize: subtitleRelSize) ?? data)
            let ext = srtString.isEmpty ? url.pathExtension.lowercased().isEmpty ? "srt" : url.pathExtension.lowercased() : "ass"
            guard let tmpUrl = writeTempSubtitleFile(data: assData, ext: ext) else {
                print("[VLC-SPU] addSubtitleTrack: writeTempSubtitleFile failed for \(url.lastPathComponent)")
                return
            }
            lastExternalSubtitleUrl = tmpUrl
            _doAddSubtitleSlave(localUrl: tmpUrl, isSelected: isSelected)
        }
    }

    /// Downloads a subtitle from [networkUrl] to a unique temp ASS file (converted
    /// from SRT), then adds it via addPlaybackSlave on the main thread.
    private func downloadSubtitleThenAdd(
        networkUrl: URL,
        isSelected: Bool,
        completion: ((Bool) -> Void)? = nil
    ) {
        URLSession.shared.dataTask(with: networkUrl) { [weak self] data, _, error in
            guard let self else {
                DispatchQueue.main.async { completion?(false) }
                return
            }
            if let error = error {
                print("[VLC-SPU] downloadSubtitleThenAdd: download failed: \(error.localizedDescription)")
                DispatchQueue.main.async { completion?(false) }
                return
            }
            guard let data = data, !data.isEmpty else {
                print("[VLC-SPU] downloadSubtitleThenAdd: empty response for \(networkUrl.lastPathComponent)")
                DispatchQueue.main.async { completion?(false) }
                return
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    completion?(false)
                    return
                }
                self.finishExternalSubtitleFromData(data, isSelected: isSelected)
                completion?(true)
            }
        }.resume()
    }

    /// Converts cached SRT bytes to ASS, stores them for resize, and adds the slave.
    private func finishExternalSubtitleFromData(_ data: Data, isSelected: Bool) {
        sidecarPromotionInProgress = false
        if sidecarCandidateTrackIndex >= 0 {
            sidecarPromotionAttemptedForTrack = sidecarCandidateTrackIndex
        }
        lastExternalSubtitleData = data
        let srtString = String(data: data, encoding: .utf8)
                      ?? String(data: data, encoding: .isoLatin1)
                      ?? ""
        let assData = srtString.isEmpty
            ? data
            : (srtToAssData(srtContent: srtString, relFontSize: subtitleRelSize) ?? data)
        let ext = srtString.isEmpty ? "srt" : "ass"
        guard let tmpUrl = writeTempSubtitleFile(data: assData, ext: ext) else {
            completeSubtitlePromotionFailure()
            return
        }
        lastExternalSubtitleUrl = tmpUrl
        _doAddSubtitleSlave(localUrl: tmpUrl, isSelected: isSelected)
        reapplyPendingSubtitleScaleAfterPromotion()
    }

    private func reapplyPendingSubtitleScaleAfterPromotion() {
        guard let pendingScale = pendingSubtitleScaleAfterPromotion else { return }
        pendingSubtitleScaleAfterPromotion = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.setSubtitleHeightScale(scale: pendingScale)
        }
    }

    private func completeSubtitlePromotionFailure() {
        sidecarPromotionInProgress = false
        if sidecarCandidateTrackIndex >= 0 {
            sidecarPromotionAttemptedForTrack = sidecarCandidateTrackIndex
        }
        // Do NOT fall back to embedded media reload — it stops/restarts playback and
        // causes visible flicker without reliably restoring subtitle tracks.
        pendingSubtitleScaleAfterPromotion = nil
        print("[VLC-SPU] completeSubtitlePromotionFailure: no external subs available")
    }

    private func cancelSubtitlePromotionWork() {
        sidecarCandidateQueue.removeAll()
        sidecarCandidateTrackIndex = -1
        sidecarPromotionInProgress = false
    }

    /// Converts SRT-formatted string to ASS subtitle data with an explicit font size.
    ///
    /// ASS subtitles embed `Fontsize` in the style header which VLC reads from
    /// the file at parse time — independent of the `freetype-rel-fontsize` media
    /// option (which is only a fallback for formats that don't declare a size).
    ///
    /// Coordinate space: PlayResY=1000.  Font sizes map as:
    ///   `freetype-rel-fontsize N` (= N% of video height) → Fontsize = N * 5
    ///   e.g. relSize 10 → ASS Fontsize 50  (5% of 1000-unit vertical space = VLC default)
    private func srtToAssData(srtContent: String, relFontSize: Int) -> Data? {
        let assFontSize = max(5, relFontSize * 5)

        let header = """
[Script Info]
ScriptType: v4.00+
WrapStyle: 0
PlayResX: 1777
PlayResY: 1000

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Arial,\(assFontSize),&H00FFFFFF,&H00FFFFFF,&H00000000,&H80000000,-1,0,0,0,100,100,0,0,1,2,0,2,20,20,20,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
"""
        var dialogues: [String] = []

        // SRT blocks are separated by blank lines.
        let blocks = srtContent.components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.trimmingCharacters(in: .whitespacesAndNewlines)
                             .components(separatedBy: "\n")
            guard lines.count >= 3 else { continue }

            // Line 1: timestamps "HH:MM:SS,mmm --> HH:MM:SS,mmm"
            let timeParts = lines[1].components(separatedBy: " --> ")
            guard timeParts.count == 2,
                  let start = srtTimeToAss(timeParts[0].trimmingCharacters(in: .whitespaces)),
                  let end   = srtTimeToAss(timeParts[1].trimmingCharacters(in: .whitespaces))
            else { continue }

            // Lines 2+: subtitle text — convert basic HTML tags to ASS overrides.
            var text = lines[2...].joined(separator: "\\N")
            text = text.replacingOccurrences(of: "<i>",  with: "{\\i1}")
            text = text.replacingOccurrences(of: "</i>", with: "{\\i0}")
            text = text.replacingOccurrences(of: "<b>",  with: "{\\b1}")
            text = text.replacingOccurrences(of: "</b>", with: "{\\b0}")
            // Strip any remaining HTML-like tags.
            text = text.replacingOccurrences(of: "<[^>]+>",
                                              with: "",
                                              options: .regularExpression)

            dialogues.append("Dialogue: 0,\(start),\(end),Default,,0,0,0,,\(text)")
        }

        guard !dialogues.isEmpty else {
            // Not a valid SRT file — return nil so the caller falls back to the
            // original bytes (e.g. a natively-formatted ASS file).
            print("[VLC-SPU] srtToAssData: no SRT blocks parsed — falling back to original data")
            return nil
        }
        let ass = header + "\n" + dialogues.joined(separator: "\n")
        return ass.data(using: .utf8)
    }

    /// Converts an SRT timestamp "HH:MM:SS,mmm" to ASS format "H:MM:SS.cc".
    private func srtTimeToAss(_ srt: String) -> String? {
        let parts = srt.components(separatedBy: ",")
        guard parts.count == 2 else { return nil }
        let hms = parts[0]          // "01:23:45"
        let ms  = parts[1]          // "678"
        let cs  = String(ms.prefix(2).padding(toLength: 2, withPad: "0", startingAt: 0))
        // ASS hours have no leading zero.
        let hmsParts = hms.components(separatedBy: ":")
        guard hmsParts.count == 3 else { return nil }
        let h = Int(hmsParts[0]) ?? 0
        return "\(h):\(hmsParts[1]):\(hmsParts[2]).\(cs)"
    }

    /// Attempts to download a sibling `.srt` for Xtream movie/series URLs so
    /// font-size changes use the external-subtitle path (no media reload).
    private func tryPromoteHeuristicXtreamSidecar(trackIndex: Int32) {
        guard !lastMediaUri.isEmpty else {
            completeSubtitlePromotionFailure()
            return
        }
        guard lastMediaUri.contains("/movie/") || lastMediaUri.contains("/series/") else {
            completeSubtitlePromotionFailure()
            return
        }
        guard let sourceUrl = URL(string: lastMediaUri) else {
            completeSubtitlePromotionFailure()
            return
        }

        let base = sourceUrl.deletingPathExtension()
        sidecarCandidateQueue = [
            base.appendingPathExtension("srt"),
            URL(string: base.absoluteString + "_\(trackIndex).srt") ?? base.appendingPathExtension("srt"),
            URL(string: base.absoluteString + ".\(trackIndex).srt") ?? base.appendingPathExtension("srt"),
        ]
        tryNextSidecarCandidate()
    }

    private func tryNextSidecarCandidate() {
        guard lastExternalSubtitleData == nil else {
            sidecarPromotionInProgress = false
            return
        }
        guard !sidecarCandidateQueue.isEmpty else {
            print("[VLC-SPU] tryPromoteHeuristicXtreamSidecar: all sidecar probes failed")
            completeSubtitlePromotionFailure()
            return
        }
        let candidate = sidecarCandidateQueue.removeFirst()
        print("[VLC-SPU] tryPromoteHeuristicXtreamSidecar: probing \(candidate.lastPathComponent)")
        downloadSubtitleThenAdd(networkUrl: candidate, isSelected: true) { [weak self] success in
            guard let self else { return }
            if success {
                print("[VLC-SPU] tryPromoteHeuristicXtreamSidecar: loaded \(candidate.lastPathComponent)")
                self.sidecarPromotionAttemptedForTrack = self.sidecarCandidateTrackIndex
            } else {
                self.tryNextSidecarCandidate()
            }
        }
    }

    /// Writes [data] to a unique temp file with the given extension and returns its URL.
    private func writeTempSubtitleFile(data: Data, ext: String = "ass") -> URL? {
        let ts  = Int(Date().timeIntervalSince1970 * 1000)
        let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent("gs_sub_\(ts).\(ext)")
        let url = URL(fileURLWithPath: tmp)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            print("[VLC-SPU] writeTempSubtitleFile: write failed: \(error)")
            return nil
        }
    }

    /// Core addPlaybackSlave call with before/after logging.
    private func _doAddSubtitleSlave(localUrl: URL, isSelected: Bool) {
        let tracksBefore = self.vlcMediaPlayer.videoSubTitlesNames ?? []
        print("[VLC-SPU] addSubtitleSlave: file=\(localUrl.lastPathComponent) enforce=\(isSelected) tracksBefore.count=\(tracksBefore.count)")
        self.vlcMediaPlayer.addPlaybackSlave(localUrl, type: .subtitle, enforce: isSelected)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            let tracksAfter = self.vlcMediaPlayer.videoSubTitlesNames ?? []
            print("[VLC-SPU] addSubtitleSlave: tracksAfter(0.5s).count=\(tracksAfter.count) currentIndex=\(self.vlcMediaPlayer.currentVideoSubTitleIndex)")
        }
    }
    
    /// Restores a subtitle (and audio) track after a media reload.
    /// Prefers matching by `trackLabel` (survives index shifts on reload); falls back
    /// to `trackIndex` if no label was captured or no match is found.
    /// Retries every 500 ms until VLC accepts the selection or attempts run out.
    private func retryRestoreSubtitleTrack(trackIndex: Int32, trackLabel: String?, audioTrack: Int32, remainingAttempts: Int) {
        if audioTrack >= 0 {
            vlcMediaPlayer.selectAudioTrack(at: Int(audioTrack))
        }

        // Resolve the best track index to use: prefer by label to survive index shifts.
        var resolvedIndex = trackIndex
        if let label = trackLabel,
           let tracks = vlcMediaPlayer.videoSubTitlesNames as? [Int: String],
           let match = tracks.first(where: { $0.value == label }) {
            resolvedIndex = Int32(match.key)
        }

        if resolvedIndex >= 0 {
            vlcMediaPlayer.currentVideoSubTitleIndex = resolvedIndex
            lastSetSpuTrackId = resolvedIndex
        }
        let actual = vlcMediaPlayer.currentVideoSubTitleIndex
        print("[VLC-SPU] retryRestoreSubtitleTrack: attempt resolved=\(resolvedIndex) vlcReal=\(actual) remaining=\(remainingAttempts)")
        if actual == resolvedIndex || remainingAttempts <= 1 {
            print("[VLC-SPU] retryRestoreSubtitleTrack: \(actual == resolvedIndex ? "success" : "gave up") track=\(resolvedIndex)")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.retryRestoreSubtitleTrack(trackIndex: trackIndex, trackLabel: trackLabel, audioTrack: audioTrack, remainingAttempts: remainingAttempts - 1)
        }
    }

    public func setSubtitleHeightScale(scale: Float) {
        // MobileVLCKit 3 has no currentSubTitleFontScale (a VLC 4+ API).
        //
        // `freetype-rel-fontsize` is "font size as a percentage of video height".
        // VLC's built-in default is 5 (= 5 % of video height, which looks normal).
        // `scale` arrives from Dart as (userFontSize / 16.0), so scale = 1.0 maps
        // to the user's default size, 2.0 to double, etc.
        //
        // Dart sends `scale = userFontSize / 16.0`.  The initial VLC flag
        // (--freetype-rel-fontsize=N) is set directly to `userFontSize`, so
        // we must invert the same ratio here:  relSize = round(scale * 16).
        //   scale 0.5 ( 8 pt UI) → relSize  8   (small)
        //   scale 0.625(10 pt UI) → relSize 10   (matches the app default)
        //   scale 0.75 (12 pt UI) → relSize 12
        //   scale 1.0  (16 pt UI) → relSize 16   (large)
        //   scale 1.5  (24 pt UI) → relSize 24   (very large)
        //   scale 2.0  (32 pt UI) → relSize 32   (enormous)
        let relSize = max(1, Int((scale * 16.0).rounded()))
        // No-op guard: if the size hasn't changed and there is no external
        // sidecar that needs its ASS file regenerated, skip everything.
        // This prevents the embedded-subtitle media reload that would otherwise
        // be triggered by color/direction-only changes (which also call
        // setSubtitleHeightScale because _applySubtitleSettings always fires).
        if relSize == subtitleRelSize && lastExternalSubtitleData == nil {
            return
        }
        subtitleRelSize = relSize

        // Persist as a per-item media option so every future subtitle decoder
        // open (on track selection or media re-open) picks up the correct size.
        self.vlcMediaPlayer.media?.addOption(":freetype-rel-fontsize=\(relSize)")

        // Cancel any previous pending restore so rapid slider taps only fire once.
        pendingSubtitleSizeRestore?.cancel()

        // ── Strategy ─────────────────────────────────────────────────────────
        // In MobileVLCKit 3, the FreeType text renderer is a vout-level module
        // initialized ONCE per playback session — `freetype-rel-fontsize` is
        // read in `freetype_Create()` and never re-read for the same vout.
        //
        // • External subtitle (added via addPlaybackSlave / addSubtitleTrack):
        //   Re-write the SRT bytes as a new ASS temp file with Fontsize baked into
        //   the style header, then re-add the slave.  VLC parses Fontsize from the
        //   file itself, bypassing the FreeType renderer option entirely.
        //
        // • Embedded subtitle (XTREAM IPTV / Smart Collections container tracks):
        //   The FreeType renderer cannot be resized without reinitializing the vout.
        //   Solution: reload the media with the new freetype-rel-fontsize, then seek
        //   back to the saved position and restore track selections.  The reload is
        //   debounced 1.5 s so rapid +/- taps only fire once.
        // ─────────────────────────────────────────────────────────────────────

        if sidecarPromotionInProgress && lastExternalSubtitleData == nil {
            pendingSubtitleScaleAfterPromotion = scale
            print("[VLC-SPU] setSubtitleHeightScale: deferred (subtitle promotion in progress) relSize=\(relSize)")
            return
        }

        if let subData = lastExternalSubtitleData {
            let capturedRelSize = relSize
            print("[VLC-SPU] setSubtitleHeightScale (external): relSize=\(relSize)")

            // Briefly hide the current subtitle so there's no flash of old-size text.
            self.vlcMediaPlayer.currentVideoSubTitleIndex = -1

            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                // Regenerate ASS from cached SRT bytes with the NEW font size.
                // ASS Fontsize is baked into the file content so VLC reads it
                // fresh — bypassing the freetype-rel-fontsize option which is
                // only read once at decoder initialization and cannot be changed.
                let srtString = String(data: subData, encoding: .utf8)
                              ?? String(data: subData, encoding: .isoLatin1)
                              ?? ""
                guard let assData = srtString.isEmpty ? nil : self.srtToAssData(srtContent: srtString, relFontSize: capturedRelSize) else {
                    // Not a recognised SRT file (e.g. native ASS); font-size cannot be
                    // dynamically changed for this format.  Re-add the original bytes so
                    // the subtitle at least continues to show.
                    print("[VLC-SPU] setSubtitleHeightScale (external): non-SRT data, skipping resize")
                    if let fallbackUrl = self.writeTempSubtitleFile(data: subData, ext: self.lastExternalSubtitleUrl?.pathExtension ?? "srt") {
                        self.vlcMediaPlayer.addPlaybackSlave(fallbackUrl, type: .subtitle, enforce: true)
                    }
                    return
                }
                guard let newTmpUrl = self.writeTempSubtitleFile(data: assData, ext: "ass") else { return }
                self.lastExternalSubtitleUrl = newTmpUrl
                print("[VLC-SPU] setSubtitleHeightScale (external): re-adding relSize=\(capturedRelSize) file=\(newTmpUrl.lastPathComponent)")
                self.vlcMediaPlayer.addPlaybackSlave(newTmpUrl, type: .subtitle, enforce: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self else { return }
                    print("[VLC-SPU] setSubtitleHeightScale (external): vlcAfter(0.5s)=\(self.vlcMediaPlayer.currentVideoSubTitleIndex)")
                }
            }
            pendingSubtitleSizeRestore = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
            return
        }

        // Embedded subtitle fallback: the VLC FreeType text renderer is a vout-level
        // module that is initialized ONCE per playback session — track toggling only
        // closes/reopens the ES decoder but reuses the same renderer.  The only
        // reliable way to change the font size for embedded tracks is to reload the
        // media from the current position with the updated freetype-rel-fontsize.
        //
        // The work item is debounced (1.5 s) so rapid +/- taps only fire once.
        let trackToRestore: Int32
        let vlcRealIndex = self.vlcMediaPlayer.currentVideoSubTitleIndex
        if let last = lastSetSpuTrackId, last >= 0 {
            trackToRestore = last
        } else {
            guard vlcRealIndex >= 0 else {
                // No subtitle track active yet – the stored relSize will be applied
                // the next time a track is enabled via setSpuTrack or addSubtitleTrack.
                return
            }
            trackToRestore = vlcRealIndex
        }
        guard !lastMediaUri.isEmpty else { return }

        // Xtream / Smart Collections with container-only subs: never reload media for
        // font-size changes — the reload disrupts HEVC decoding and causes flicker.
        if isXtreamStyleMediaUri() {
            pendingSubtitleScaleAfterPromotion = nil
            print("[VLC-SPU] setSubtitleHeightScale (embedded): skipped for xtream — no external subs")
            return
        }

        // If a sidecar load was already attempted for this track and failed
        // (e.g. a PGSSUB/bitmap track whose SRT URL returns 404, or any transient
        // download error), skip the media reload.  FreeType font-size changes have
        // no effect on bitmap subtitles, and reloading just restarts playback.
        if let attempted = sidecarPromotionAttemptedForTrack,
           attempted == Int32(trackToRestore) {
            pendingSubtitleScaleAfterPromotion = nil
            print("[VLC-SPU] setSubtitleHeightScale (embedded): skipped — sidecar previously failed for track \(trackToRestore)")
            return
        }

        print("[VLC-SPU] setSubtitleHeightScale (embedded): relSize=\(relSize) vlcReal=\(vlcRealIndex) → scheduling reload for track \(trackToRestore)")

        let capturedRelSize = relSize
        let capturedTrack   = trackToRestore
        let capturedAudio   = Int32(self.vlcMediaPlayer.selectedAudioTrackIndex)
        let capturedPos     = Int64(self.lastKnownPosition)
        let capturedDuration = Int64(self.lastKnownDuration)
        let capturedUri     = lastMediaUri
        let capturedIsAsset = lastMediaIsAsset
        let capturedHwAcc   = lastMediaHwAcc
        let capturedOptions = lastMediaOptions
        // Capture the track LABEL so we can re-match by name after reload even if
        // VLC assigns a different index to the same track in the restarted session.
        let capturedLabel: String? = (vlcMediaPlayer.videoSubTitlesNames as? [Int: String])?[Int(trackToRestore)]

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            print("[VLC-SPU] setSubtitleHeightScale (embedded): reloading media relSize=\(capturedRelSize) pos=\(capturedPos)ms label=\(capturedLabel ?? "?")")

            // Build a fresh VLCMedia with the updated freetype option.
            var media: VLCMedia?
            if capturedIsAsset {
                if let path = Bundle.main.path(forResource: capturedUri, ofType: nil) {
                    media = VLCMedia(path: path)
                }
            } else if let url = URL(string: capturedUri) {
                media = VLCMedia(url: url)
            }
            guard let media else { return }
            for opt in capturedOptions { media.addOption(opt) }
            media.addOption(":freetype-rel-fontsize=\(capturedRelSize)")
            // Note: --start-time= is NOT used here. It is only honoured by VLC
            // for local files; for HTTP/network streams (e.g. Jellyfin direct
            // stream) VLC always starts buffering from byte 0 and the option is
            // silently ignored, resulting in playback starting at 00:00. Position
            // is restored by an explicit seek below after VLC begins playing.
            self.subtitleRelSize = capturedRelSize

            self.mediaEventChannelHandler.beginPlaybackMutation()
            self.vlcMediaPlayer.stop()
            self.vlcMediaPlayer.media = media
            self.vlcMediaPlayer.play()
            self.mediaEventChannelHandler.endPlaybackMutation()

            // Restore playback position via an explicit seek once VLC has
            // started buffering the container. Use the float position (0…1)
            // which works reliably for both local files and HTTP streams.
            // 1.5 s gives VLC enough time to parse the container header and
            // establish the HTTP connection before accepting a position seek.
            // The subtitle/audio restore fires at 2.5 s, after the seek.
            let duration = capturedDuration > 0 ? capturedDuration : Int64(self.lastKnownDuration)
            if duration > 0 && capturedPos > 2000 {
                let seekFraction = Float(capturedPos - 2000) / Float(duration)
                if seekFraction > 0 && seekFraction < 1 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                        guard let self else { return }
                        self.vlcMediaPlayer.position = seekFraction
                        print("[VLC-SPU] setSubtitleHeightScale (embedded): sought to \(seekFraction) after reload")
                    }
                }
            }

            // Restore audio and subtitle track selections after VLC begins parsing
            // the container.  Prefer matching by label (survives index shifts);
            // fall back to the original index if no label was captured.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self else { return }
                self.retryRestoreSubtitleTrack(
                    trackIndex: capturedTrack,
                    trackLabel: capturedLabel,
                    audioTrack: capturedAudio,
                    remainingAttempts: 20
                )
            }
        }
        pendingSubtitleSizeRestore = workItem
        // 1.5 s debounce: absorbs rapid +/− taps so only the final size fires the reload.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: workItem)
    }
    
    public var audioTracksCount: Int32 {
        Int32(self.vlcMediaPlayer.audioTrackDictionary().count)
    }
    
    public var audioTracks: [Int: String] {
        self.vlcMediaPlayer.audioTrackDictionary()
    }
    
    public func setAudioTrack(audioTrackNumber: Int32) {
        self.vlcMediaPlayer.selectAudioTrack(at: Int(audioTrackNumber))
    }
    
    public var audioTrack: Int32 {
        Int32(self.vlcMediaPlayer.selectedAudioTrackIndex)
    }
    
    public func setAudioDelay(delay: Int) {
        self.vlcMediaPlayer.currentAudioPlaybackDelay = delay
    }
    
    public var audioDelay: Int {
        self.vlcMediaPlayer.currentAudioPlaybackDelay
    }
    
    public func addAudioTrack(uri: String, isSelected: Bool) {
        guard let url = URL(string: uri) else { return }
        self.vlcMediaPlayer.addPlaybackSlave(url, type: .audio, enforce: isSelected)
    }
    
    public var videoTracksCount: Int32 {
        Int32(self.vlcMediaPlayer.videoTrackDictionary().count)
    }
    
    public var videoTracks: [Int: String] {
        self.vlcMediaPlayer.videoTrackDictionary()
    }
    
    public func setVideoTrack(videoTrackNumber: Int32) {
        self.vlcMediaPlayer.selectVideoTrack(at: Int(videoTrackNumber))
    }
    
    public var videoTrack: Int32 {
        Int32(self.vlcMediaPlayer.selectedVideoTrackIndex)
    }
    
    public func setVideoScale(scale: Float) {
        self.vlcMediaPlayer.scaleFactor = scale
    }
    
    public var videoScale: Float {
        self.vlcMediaPlayer.scaleFactor
    }
    
    public func setVideoAspectRatio(aspectRatio: String) {
        // MobileVLCKit 3: videoAspectRatio is UnsafeMutablePointer<CChar>?
        // strdup() allocates a C string that VLCKit will own/free.
        self.vlcMediaPlayer.videoAspectRatio = strdup(aspectRatio)
    }
    
    public var videoAspectRatio: String {
        guard let ptr = self.vlcMediaPlayer.videoAspectRatio else { return "" }
        return String(cString: ptr)
    }
    
    public var availableRendererServices: [String] {
        self.vlcMediaPlayer.rendererServices()
    }
    
    public func startRendererScanning() {
        self.rendererdiscoverers.removeAll()
        self.rendererEventChannelHandler.renderItems.removeAll()
        let rendererServices = self.vlcMediaPlayer.rendererServices()
        for rendererService in rendererServices {
            guard let rendererDiscoverer
                = VLCRendererDiscoverer(name: rendererService)
            else {
                continue
            }
            rendererDiscoverer.delegate = self.rendererEventChannelHandler
            rendererDiscoverer.start()
            self.rendererdiscoverers.append(rendererDiscoverer)
        }
    }
    
    public func stopRendererScanning() {
        for rendererDiscoverer in self.rendererdiscoverers {
            rendererDiscoverer.stop()
            rendererDiscoverer.delegate = nil
        }
        self.rendererdiscoverers.removeAll()
        self.rendererEventChannelHandler.renderItems.removeAll()
        if self.vlcMediaPlayer.isPlaying {
            self.vlcMediaPlayer.pause()
        }
        self.vlcMediaPlayer.setRendererItem(nil)
    }
    
    public var rendererDevices: [String: String] {
        var rendererDevices: [String: String] = [:]
        let rendererItems = self.rendererEventChannelHandler.renderItems
        for (_, item) in rendererItems.enumerated() {
            rendererDevices[item.name] = item.name
        }
        return rendererDevices
    }
    
    public func cast(rendererDevice: String) {
        if self.vlcMediaPlayer.isPlaying {
            self.vlcMediaPlayer.pause()
        }
        let rendererItems = self.rendererEventChannelHandler.renderItems
        let rendererItem = rendererItems.first {
            $0.name.contains(rendererDevice)
        }
        self.vlcMediaPlayer.setRendererItem(rendererItem)
        self.vlcMediaPlayer.play()
    }
    
    public func startRecording(saveDirectory: String) -> Bool {
        self.vlcMediaPlayer.startRecording(atPath: saveDirectory)
        return true
    }
    
    public func stopRecording() -> Bool {
        self.vlcMediaPlayer.stopRecording()
        return true
    }
    
    func updatePlaybackCaches(position: Int, duration: Int, isPlaying: Bool) {
        self.lastKnownPosition = position
        if duration > 0 {
            self.lastKnownDuration = duration
        }
        self.lastKnownIsPlaying = isPlaying
    }

    public func dispose() {
        cancelSubtitlePromotionWork()
        pendingSubtitleScaleAfterPromotion = nil
        // Stop VLC delegate callbacks immediately so timer threads can't enqueue
        // new `vlc_event_read` work while we're tearing down.
        self.vlcMediaPlayer.delegate = nil
        self.mediaEventChannelHandler.prepareForDisposeDrainingReads()

        self.mediaEventChannel.setStreamHandler(nil)
        self.rendererEventChannel.setStreamHandler(nil)
        self.rendererdiscoverers.removeAll()
        self.rendererEventChannelHandler.renderItems.removeAll()
        self.vlcMediaPlayer.stop()
        self.mediaEventChannelHandler.player = nil
    }
    
    func setMediaPlayerUrl(uri: String, isAssetUrl: Bool, autoPlay: Bool, hwAcc: Int, options: [String]) {
        // Reset per-media state so values from a previous media item don't bleed
        // into the new one.
        lastSetSpuTrackId = nil
        lastExternalSubtitleUrl = nil
        lastExternalSubtitleData = nil
        sidecarPromotionAttemptedForTrack = nil
        cancelSubtitlePromotionWork()
        pendingSubtitleScaleAfterPromotion = nil
        pendingSubtitleSizeRestore?.cancel()
        pendingSubtitleSizeRestore = nil
        // Remember the load parameters so we can reload for embedded subtitle resize.
        lastMediaUri = uri
        lastMediaIsAsset = isAssetUrl
        lastMediaHwAcc = hwAcc
        lastMediaOptions = options
        // Block and drain time/state read work while stop/media swap runs so
        // vlcReadQueue never touches VLCMediaPlayer after libvlc teardown starts.
        self.mediaEventChannelHandler.beginPlaybackMutation()
        defer { self.mediaEventChannelHandler.endPlaybackMutation() }
        self.vlcMediaPlayer.stop()
        
        var media: VLCMedia?
        if isAssetUrl {
            guard let path = Bundle.main.path(forResource: uri, ofType: nil)
            else {
                return
            }
            media = VLCMedia(path: path)
        }
        else {
            guard let url = URL(string: uri)
            else {
                return
            }
            media = VLCMedia(url: url)
        }
        
        guard let media = media else { return }
        
        if !options.isEmpty {
            for option in options {
                media.addOption(option)
            }
        }
        
        // Bake the current subtitle font size into every new media item so the
        // freetype renderer reads the correct value when it first initialises
        // (before any setSubtitleHeightScale call can arrive from Dart).
        media.addOption(":freetype-rel-fontsize=\(subtitleRelSize)")
        
        switch HWAccellerationType(rawValue: hwAcc) {
        case .HW_ACCELERATION_DISABLED:
            media.addOption("--codec=avcodec")
        case .HW_ACCELERATION_DECODING:
            media.addOption("--codec=all")
            media.addOption(":no-mediacodec-dr")
            media.addOption(":no-omxil-dr")
        case .HW_ACCELERATION_FULL:
            media.addOption("--codec=all")
        case .HW_ACCELERATION_AUTOMATIC:
            break
        case .none:
            break
        }
        
        self.vlcMediaPlayer.media = media
        self.vlcMediaPlayer.play()
        if !autoPlay {
            self.vlcMediaPlayer.stop()
        }
    }
}

class VLCRendererEventStreamHandler: NSObject, FlutterStreamHandler, VLCRendererDiscovererDelegate {
    private var rendererEventSink: FlutterEventSink?
    var renderItems: [VLCRendererItem] = .init()
    
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.rendererEventSink = events
        return nil
    }
    
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.rendererEventSink = nil
        return nil
    }
    
    @objc func rendererDiscovererItemAdded(_ rendererDiscoverer: VLCRendererDiscoverer, item: VLCRendererItem) {
        self.renderItems.append(item)
        
        guard let rendererEventSink = self.rendererEventSink else { return }
        rendererEventSink([
            "event": "attached",
            "id": item.name,
            "name": item.name,
        ])
    }
    
    @objc func rendererDiscovererItemDeleted(_ rendererDiscoverer: VLCRendererDiscoverer, item: VLCRendererItem) {
        if let index = renderItems.firstIndex(of: item) {
            self.renderItems.remove(at: index)
        }
        
        guard let rendererEventSink = self.rendererEventSink else { return }
        rendererEventSink([
            "event": "detached",
            "id": item.name,
            "name": item.name,
        ])
    }
}

class VLCPlayerEventStreamHandler: NSObject, FlutterStreamHandler, VLCMediaPlayerDelegate {
    private var mediaEventSink: FlutterEventSink?
    weak var player: VLCMediaPlayer?
    /// Back-reference to the owning controller so we can read the OPTIMISTIC
    /// spuTrack (lastSetSpuTrackId) rather than VLC's raw currentVideoSubTitleIndex,
    /// which keeps the event stream consistent with the Pigeon getter.
    weak var vlcController: VLCViewController?
    
    // Dedicated read queue — reads happen OFF the timer thread to avoid
    // calling libvlc_media_player_* while timer.lock is held.
    private let vlcReadQueue = DispatchQueue(label: "com.gridstreamr.vlc_event_read", qos: .userInitiated)
    
    // CRITICAL: isPlaying must NEVER be read from a timer callback.
    // libvlc_media_player_is_playing needs vlc_player_Lock, but timer
    // callbacks run inline on the timer thread which holds timer.lock.
    // Calling vlc_player_Lock while timer.lock is held triggers:
    //   Assertion failed: (!vlc_mutex_held(&player->timer.lock))
    // We cache isPlaying from state-change events (which fire on a safe thread).
    private var cachedIsPlaying: Bool = false
    /// Duration in milliseconds, refreshed from media.length on state changes.
    private var cachedDurationMs: Int = 0
    /// True while stop/media swap/dispose is in progress; suppresses new reads.
    private var isPlaybackMutationInProgress: Bool = false
    
    override init() {
        super.init()
    }

    /// Refresh duration cache from `media.length` only — never touch `player.time`
    /// here because VLCTime can be torn down while libvlc updates the clock.
    private func refreshDurationCache(from player: VLCMediaPlayer) {
        let rawLength = player.media?.length.value?.int64Value ?? 0
        guard rawLength > 0 else { return }
        let isMicro = rawLength > 20_000_000
        cachedDurationMs = Int(isMicro ? (rawLength / 1000) : rawLength)
    }

    /// Derive position ms from the float slider (0…1) and cached duration.
    /// Avoids reading `player.time`, which races with libvlc on background queues.
    private func positionMs(from player: VLCMediaPlayer) -> Int {
        guard cachedDurationMs > 0 else { return 0 }
        let fraction = max(0, min(1, player.position))
        return Int((Float(cachedDurationMs) * fraction).rounded())
    }

    private func deliverMediaEvent(_ event: [String: Any]) {
        guard let mediaEventSink = self.mediaEventSink else { return }
        if Thread.isMainThread {
            mediaEventSink(event)
        } else {
            DispatchQueue.main.async {
                mediaEventSink(event)
            }
        }
    }
    
    func onListen(withArguments _: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.mediaEventSink = events
        return nil
    }
    
    func onCancel(withArguments _: Any?) -> FlutterError? {
        self.mediaEventSink = nil
        return nil
    }

    /// Blocks until queued read work on vlc_event_read completes. Safe to call
    /// before `stop`/media teardown so VLCMediaPlayer accessors are never hit
    /// while libvlc is tearing down another thread still posting time-change events.
    func drainPlaybackPropertyReadQueueForSafeMutation() {
        vlcReadQueue.sync { /* drain */ }
    }

    /// Call before `stop`/media swap: suppresses new reads and drains in-flight work.
    func beginPlaybackMutation() {
        isPlaybackMutationInProgress = true
        cachedDurationMs = 0
        vlcReadQueue.sync { /* drain legacy state-change reads */ }
    }

    /// Call after `stop`/media swap: drains stop-triggered reads, then re-enables events.
    func endPlaybackMutation() {
        vlcReadQueue.sync { /* drain legacy state-change reads */ }
        isPlaybackMutationInProgress = false
    }

    /// Call while disposing or before VLCMediaPlayer teardown: clears the Flutter
    /// sink first (so `sendTimeEvent` stops scheduling reads), then drains the
    /// read queue before native `stop`/deallocation proceeds.
    func prepareForDisposeDrainingReads() {
        isPlaybackMutationInProgress = true
        cachedDurationMs = 0
        self.mediaEventSink = nil
        vlcReadQueue.sync { /* drain legacy state-change reads */ }
    }
    
    // mediaPlayerLengthChanged(:Int64) was a VLCKit 4 delegate method.
    // In MobileVLCKit 3, duration changes come through mediaPlayerTimeChanged notification
    // and are read from player.media?.length inside sendTimeEvent.
    
    @objc func mediaPlayerStateChanged(_ newState: VLCMediaPlayerState) {
        guard self.mediaEventSink != nil,
              self.player != nil,
              !isPlaybackMutationInProgress else { return }
        
        // State-change callbacks (HandleMediaInstanceStateChanged) dispatch through
        // VLCEventsHandler. With VLCEventsDefaultConfiguration (dispatchQueue=nil),
        // they run inline on the libvlc event thread. This thread does NOT hold
        // timer.lock, so calling player.isPlaying here is safe.
        //
        // However, to be extra safe, dispatch all reads to vlcReadQueue (async)
        // so they execute off whatever thread VLCKit called us on.
        self.vlcReadQueue.async { [weak self] in
            guard let self = self,
                  self.mediaEventSink != nil,
                  !self.isPlaybackMutationInProgress,
                  let player = self.player else { return }
            
            let height = player.videoSize.height
            let width = player.videoSize.width
            let audioTracksCount = player.audioTrackDictionary().count
            let activeAudioTrack = player.selectedAudioTrackIndex
            let spuTracksCount = player.subtitleTrackDictionary().count
            // Use the optimistic lastSetSpuTrackId (via vlcController.spuTrack) so that
            // state-change events are consistent with the Pigeon getSpuTrack() getter.
            // Without this, a playing/buffering event immediately after setSpuTrack would
            // send the wrong raw VLC index, resetting Flutter's selected-track indicator.
            let activeSpuTrack = self.vlcController.map { Int($0.spuTrack) }
                ?? player.selectedSubtitleTrackIndex
            self.refreshDurationCache(from: player)
            let duration = self.cachedDurationMs
            let speed = player.rate
            let position = self.positionMs(from: player)
            // SAFE here: state-change callback thread does not hold timer.lock
            let isPlaying = player.isPlaying
            let isSeekable = player.isSeekable
            
            // Cache isPlaying for use by time-event callbacks
            self.cachedIsPlaying = isPlaying
            
            var event: [String: Any] = ["event": "unknown"]
            switch newState {
            case .opening: event = ["event": "opening"]
            case .paused:
                self.cachedIsPlaying = false
                event = ["event": "paused"]
            case .stopped:
                self.cachedIsPlaying = false
                event = ["event": "stopped"]
            case .error: event = ["event": "error"]
            case .playing, .buffering:
                if newState == .playing { self.cachedIsPlaying = true }
                event = [
                    "event": newState == .playing ? "playing" : "buffering",
                    "height": height, "width": width, "speed": speed,
                    "duration": duration, "position": position,
                    "audioTracksCount": audioTracksCount, "activeAudioTrack": activeAudioTrack,
                    "spuTracksCount": spuTracksCount, "activeSpuTrack": activeSpuTrack,
                    "isPlaying": isPlaying, "isSeekable": isSeekable,
                ]
                if newState == .buffering { event["buffer"] = 100.0 }
            default: break
            }
            
            self.vlcController?.updatePlaybackCaches(
                position: position,
                duration: duration,
                isPlaying: isPlaying
            )
            self.deliverMediaEvent(event)
        }
    }
    
    // mediaPlayer(_:watchTime:) is a VLCKit 4 delegate method — not available in MobileVLCKit 3.
    // Time updates in MobileVLCKit 3 come via the mediaPlayerTimeChanged NSNotification delegate.
    
    @objc func mediaPlayerTimeChanged(_ aNotification: Notification) {
        guard let notificationPlayer = aNotification.object as? VLCMediaPlayer,
              notificationPlayer === self.player else { return }
        self.sendTimeEvent()
    }

    /// Called directly from `mediaPlayerTimeChanged` while VLCKit's time snapshot
    /// is still valid. Never defer to vlcReadQueue — deferred reads of
    /// `player.time` / `VLCTime.value` race with the next tick and can SIGSEGV.
    /// Use `player.position` (float 0…1) × cached duration instead of `player.time`.
    private func sendTimeEvent() {
        guard self.mediaEventSink != nil,
              !isPlaybackMutationInProgress,
              let player = self.player else { return }
        
        let isPlaying = self.cachedIsPlaying
        if cachedDurationMs <= 0 {
            refreshDurationCache(from: player)
        }
        let duration = cachedDurationMs
        let position = positionMs(from: player)
        
        vlcController?.updatePlaybackCaches(
            position: position,
            duration: duration,
            isPlaying: isPlaying
        )
        deliverMediaEvent([
            "event": "timeChanged",
            "duration": duration,
            "position": position,
            "isPlaying": isPlaying,
        ])
    }
}

enum DataSourceType: Int { case ASSET = 0; case NETWORK = 1; case FILE = 2 }
enum HWAccellerationType: Int { case HW_ACCELERATION_AUTOMATIC = 0; case HW_ACCELERATION_DISABLED = 1; case HW_ACCELERATION_DECODING = 2; case HW_ACCELERATION_FULL = 3 }

// MARK: - MobileVLCKit 3.x compatibility extensions
// MobileVLCKit 3 exposes tracks via typed arrays (audioTrackNames, videoSubTitlesNames, etc.)
// rather than the KVO-based generic trackDictionary used in VLCKit 4.
extension VLCMediaPlayer {
    /// True when `media.length` is expressed in microseconds (VLC live/TS streams).
    var lengthUsesMicroseconds: Bool {
        let rawDuration = self.media?.length.value?.int64Value ?? 0
        return rawDuration > 20_000_000
    }
    var normalizedDuration: Int {
        let raw = self.media?.length.value?.int64Value ?? 0
        guard raw > 0 else { return 0 }
        return Int(lengthUsesMicroseconds ? (raw / 1000) : raw)
    }
    var normalizedTime: Int {
        let raw = self.time.value?.int64Value ?? 0
        guard raw > 0 else { return 0 }
        let isMicro = lengthUsesMicroseconds || raw > 20_000_000
        return Int(isMicro ? (raw / 1000) : raw)
    }

    // MARK: Track dictionaries (MobileVLCKit 3 API)

    /// Returns { index: name } for audio tracks. Index is the sequential position
    /// used by currentAudioTrackIndex to select a track.
    func audioTrackDictionary() -> [Int: String] {
        var dict: [Int: String] = [:]
        let names = self.audioTrackNames ?? []
        for (i, name) in names.enumerated() {
            dict[i] = (name as? String) ?? "Audio \(i)"
        }
        return dict
    }

    /// Returns { internalId: name } for subtitle tracks.
    ///
    /// Keys are the **VLC internal track IDs** from `videoSubTitlesIndexes`.
    /// `currentVideoSubTitleIndex` / `libvlc_video_set_spu` uses these IDs directly —
    /// NOT the positional indices in `videoSubTitlesNames`.  Using positional indices
    /// caused an off-by-one where selecting "pt-PT" (positional 4) would activate
    /// the track whose internal ID is 4, which is actually "Persian" (positional 3).
    /// -1 is the disable sentinel and is always excluded.
    func subtitleTrackDictionary() -> [Int: String] {
        var dict: [Int: String] = [:]
        let names   = self.videoSubTitlesNames   ?? []
        let indices = self.videoSubTitlesIndexes ?? []
        for (i, name) in names.enumerated() {
            let label = (name as? String) ?? ""
            if label.lowercased() == "disable" || label.isEmpty { continue }
            // Use the actual VLC internal ID if available, otherwise fall back to
            // the positional index (shouldn't happen in practice).
            let internalId: Int
            if i < indices.count, let n = indices[i] as? NSNumber {
                internalId = n.intValue
            } else {
                internalId = i
            }
            if internalId < 0 { continue } // skip the "Disabled" sentinel (-1)
            dict[internalId] = label
        }
        return dict
    }

    /// Returns { index: name } for video tracks.
    func videoTrackDictionary() -> [Int: String] {
        var dict: [Int: String] = [:]
        let names = self.videoTrackNames ?? []
        for (i, name) in names.enumerated() {
            dict[i] = (name as? String) ?? "Video \(i)"
        }
        return dict
    }

    // MARK: Selected track indices (MobileVLCKit 3 API)

    var selectedAudioTrackIndex: Int {
        return Int(self.currentAudioTrackIndex)
    }

    var selectedSubtitleTrackIndex: Int {
        let idx = Int(self.currentVideoSubTitleIndex)
        // VLCKit 3 returns -1 when subtitles are disabled
        return idx
    }

    var selectedVideoTrackIndex: Int {
        return Int(self.currentVideoTrackIndex)
    }

    // MARK: Track selection (MobileVLCKit 3 API)

    func selectAudioTrack(at index: Int) {
        self.currentAudioTrackIndex = Int32(index)
    }

    func selectSubtitleTrack(at index: Int) {
        self.currentVideoSubTitleIndex = Int32(index)
    }

    func selectVideoTrack(at index: Int) {
        self.currentVideoTrackIndex = Int32(index)
    }

    func rendererServices() -> [String] {
        let renderers = VLCRendererDiscoverer.list()
        var services: [String] = []
        renderers?.forEach { description in services.append(description.name) }
        return services
    }
}
