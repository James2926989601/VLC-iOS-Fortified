/*****************************************************************************
 * MediaModel.swift
 *
 * Copyright © 2018-2026 VLC authors and VideoLAN
 * Copyright © 2018-2026 Videolabs
 *
 * Authors: Soomin Lee <bubu@mikan.io>
 *
 * Refer to the COPYING file of the official project for license.
 *****************************************************************************/

import Foundation

#if !os(watchOS)
import AppIntents
import CoreSpotlight
#endif

protocol MediaModel: NSObject, MLBaseModel where MLType == VLCMLMedia { }

extension Notification.Name {
    static let VLCAudioArtworkDidBecomeAvailable = Notification.Name("VLCAudioArtworkDidBecomeAvailable")
}

/// Reads embedded audio artwork independently from the media-library thumbnail.
/// This recovers stale databases whose artwork file was removed and preserves
/// source pixels for every consumer.
final class AudioArtworkProvider: NSObject, VLCMediaParserDelegate {
    static let shared = AudioArtworkProvider()

    private struct PendingRequest {
        let media: VLCMedia
        let sourceURL: URL
        let cacheURL: URL
        let libraryIdentifier: VLCMLIdentifier
    }

    private let stateLock = NSLock()
    private var pendingRequests = [URL: PendingRequest]()
    private var pendingSourceURLs = Set<URL>()
    private var failureCounts = [URL: Int]()
    private var libraryReloadNotificationScheduled = false

    private lazy var parser: VLCMediaParser = {
        let parser = VLCMediaParser(library: VLCLibrary.shared(), timeout: -1)
        parser.delegate = self
        return parser
    }()

    private lazy var cacheDirectoryURL: URL? = {
        guard let cachesURL = FileManager.default.urls(for: .cachesDirectory,
                                                       in: .userDomainMask).first else {
            return nil
        }
        let directoryURL = cachesURL.appendingPathComponent("OriginalAudioArtwork",
                                                            isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directoryURL,
                                                    withIntermediateDirectories: true)
            return directoryURL
        } catch {
            APLog("AudioArtworkProvider: failed to create cache directory: \(error.localizedDescription)")
            return nil
        }
    }()

    private override init() {
        super.init()
    }

    func artwork(for media: VLCMLMedia) -> UIImage? {
        guard let requestInfo = requestInfo(for: media) else {
            return nil
        }

        if FileManager.default.fileExists(atPath: requestInfo.cacheURL.path),
           let image = VLCThumbnailsCache.thumbnail(for: requestInfo.cacheURL) {
            return image
        }

        requestArtwork(for: media, requestInfo: requestInfo)
        return nil
    }

    func requestArtwork(for media: VLCMLMedia) {
        guard let requestInfo = requestInfo(for: media),
              !FileManager.default.fileExists(atPath: requestInfo.cacheURL.path) else {
            return
        }
        requestArtwork(for: media, requestInfo: requestInfo)
    }

    private func requestInfo(for media: VLCMLMedia) -> (sourceURL: URL, cacheURL: URL)? {
        guard media.type() == .audio,
              let file = media.mainFile(),
              let cacheDirectoryURL = cacheDirectoryURL else {
            return nil
        }

        let sourceURL = file.mrl
        guard sourceURL.isFileURL else {
            return nil
        }
        let fingerprint = "\(sourceURL.absoluteString)|\(file.size())|\(String(describing: file.lastModificationDate))"
        let fileName = stableCacheFileName(for: fingerprint)
        return (sourceURL, cacheDirectoryURL.appendingPathComponent(fileName))
    }

    private func stableCacheFileName(for fingerprint: String) -> String {
        var firstHash: UInt64 = 14_695_981_039_346_656_037
        var secondHash: UInt64 = 5_381
        for byte in fingerprint.utf8 {
            firstHash ^= UInt64(byte)
            firstHash &*= 1_099_511_628_211
            secondHash = ((secondHash << 5) &+ secondHash) ^ UInt64(byte)
        }

        let first = String(firstHash, radix: 16)
        let second = String(secondHash, radix: 16)
        return String(repeating: "0", count: 16 - first.count) + first
            + String(repeating: "0", count: 16 - second.count) + second
    }

    private func requestArtwork(for media: VLCMLMedia,
                                requestInfo: (sourceURL: URL, cacheURL: URL)) {
        stateLock.lock()
        let shouldRequest = !pendingSourceURLs.contains(requestInfo.sourceURL)
            && failureCounts[requestInfo.sourceURL, default: 0] < 3
        if shouldRequest {
            pendingSourceURLs.insert(requestInfo.sourceURL)
        }
        stateLock.unlock()

        guard shouldRequest else {
            return
        }
        guard let parserMedia = VLCMedia(url: requestInfo.sourceURL) else {
            stateLock.lock()
            pendingSourceURLs.remove(requestInfo.sourceURL)
            failureCounts[requestInfo.sourceURL, default: 0] += 1
            stateLock.unlock()
            return
        }

        let request = PendingRequest(media: parserMedia,
                                     sourceURL: requestInfo.sourceURL,
                                     cacheURL: requestInfo.cacheURL,
                                     libraryIdentifier: media.identifier())
        stateLock.lock()
        pendingRequests[requestInfo.sourceURL] = request
        stateLock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let result = self.parser.queue(parserMedia, options: [.parse, .fetchLocal])
            if result == -1 {
                self.finishFailedRequest(for: parserMedia)
            }
        }
    }

    func mediaFinishedParsing(_ media: VLCMedia, with status: VLCMediaParsedStatus) {
        guard let request = takePendingRequest(for: media) else {
            return
        }

        guard status == .done,
              let artworkData = originalArtworkData(from: media) else {
            APLog("AudioArtworkProvider: local artwork parsing failed for \(request.sourceURL.lastPathComponent), status: \(status.rawValue)")
            markFailed(request.sourceURL)
            return
        }

        do {
            try artworkData.write(to: request.cacheURL, options: .atomic)
        } catch {
            APLog("AudioArtworkProvider: failed to cache artwork for \(request.sourceURL.lastPathComponent): \(error.localizedDescription)")
            markFailed(request.sourceURL)
            return
        }

        stateLock.lock()
        failureCounts.removeValue(forKey: request.sourceURL)
        stateLock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.scheduleLibraryReloadNotification()

            let playbackService = PlaybackService.sharedInstance()
            let matchesLibraryMedia = playbackService.currentlyPlayingLibraryMedia?.identifier()
                == request.libraryIdentifier
            let matchesPlaybackURL = playbackService.currentlyPlayingMedia?.url == request.sourceURL
            if matchesLibraryMedia || matchesPlaybackURL {
                playbackService.setNeedsMetadataUpdate()
            }
        }
    }

    private func takePendingRequest(for media: VLCMedia) -> PendingRequest? {
        stateLock.lock()
        defer { stateLock.unlock() }

        let matchedKey: URL?
        if let sourceURL = media.url, pendingRequests[sourceURL] != nil {
            matchedKey = sourceURL
        } else {
            matchedKey = pendingRequests.first(where: { $0.value.media === media })?.key
        }
        guard let matchedKey = matchedKey,
              let request = pendingRequests.removeValue(forKey: matchedKey) else {
            return nil
        }
        pendingSourceURLs.remove(request.sourceURL)
        return request
    }

    private func finishFailedRequest(for media: VLCMedia) {
        guard let request = takePendingRequest(for: media) else {
            return
        }
        APLog("AudioArtworkProvider: failed to queue local artwork parsing for \(request.sourceURL.lastPathComponent)")
        markFailed(request.sourceURL)
    }

    private func originalArtworkData(from media: VLCMedia) -> Data? {
        let metadata = media.metaData
        var candidates = [(image: UIImage, data: Data?)]()

        if let artworkURL = metadata.artworkURL,
           artworkURL.isFileURL,
           let data = try? Data(contentsOf: artworkURL),
           let image = UIImage(data: data) {
            candidates.append((image, data))
        }

        if let image = metadata.artwork {
            candidates.append((image, nil))
        }

        guard let largest = candidates.max(by: { pixelCount(for: $0.image) < pixelCount(for: $1.image) }) else {
            return nil
        }
        return largest.data ?? largest.image.pngData()
    }

    private func pixelCount(for image: UIImage) -> UInt64 {
        guard let cgImage = image.cgImage else {
            return 0
        }
        return UInt64(cgImage.width) * UInt64(cgImage.height)
    }

    private func markFailed(_ sourceURL: URL) {
        stateLock.lock()
        failureCounts[sourceURL, default: 0] += 1
        stateLock.unlock()
    }

    private func scheduleLibraryReloadNotification() {
        guard !libraryReloadNotificationScheduled else {
            return
        }
        libraryReloadNotificationScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.libraryReloadNotificationScheduled = false
            NotificationCenter.default.post(name: .VLCAudioArtworkDidBecomeAvailable,
                                            object: nil)
        }
    }
}

extension MediaModel {
    func append(_ item: VLCMLMedia) {
        fileArrayLock.lock()
        defer { fileArrayLock.unlock() }
        if !files.contains(where: { $0 == item }) {
            files.append(item)
        }
    }

    func delete(_ items: [VLCMLMedia]) {
        for case let media in items {
            media.deleteMainFile()
        }
        medialibrary.reload()
        fileArrayLock.lock()
        defer { fileArrayLock.unlock() }
        filterFilesFromDeletion(of: items)
    }
}

// MARK: - ViewModel

extension VLCMLMedia {
    @objc func deleteMainFile() {
        if let mainFile = mainFile() {
            mainFile.delete()
        }
    }

    @objc func mediaDuration() -> String {
        return String(format: "%@", VLCTime(number: NSNumber.init(value: duration())))
    }

    @objc func formatSize() -> String {
        return ByteCountFormatter.string(fromByteCount: Int64(mainFile()?.size() ?? 0),
                                         countStyle: .file)
    }

    @objc func videoDimensions() -> String {
        if let firstTrack = videoTracks?.first {
            return String(format: NSLocalizedString("FORMAT_VIDEO_DIMENSIONS", comment: ""),
                          firstTrack.width(), firstTrack.height())
        }
        return ""
    }

    @objc func resolutionClass() -> String? {
        guard let firstTrack = videoTracks?.first else {
            return nil
        }
        let shortSide = min(firstTrack.width(), firstTrack.height())
        let longSide = max(firstTrack.width(), firstTrack.height())

        if shortSide >= 4320 || longSide >= 7680 {
            return NSLocalizedString("RESOLUTION_CLASS_8K", comment: "")
        } else if shortSide >= 2160 || longSide >= 3840 {
            return NSLocalizedString("RESOLUTION_CLASS_4K", comment: "")
        } else if shortSide >= 1080 || longSide >= 1920 {
            return NSLocalizedString("RESOLUTION_CLASS_HD", comment: "")
        } else if shortSide >= 540 || longSide >= 960 {
            return NSLocalizedString("RESOLUTION_CLASS_SD", comment: "")
        }
        return nil
    }

    @objc func artworkImage() -> UIImage? {
        if (!UserDefaults.standard.bool(forKey: kVLCSettingShowThumbnails) && subtype() != .albumTrack)
            || (!UserDefaults.standard.bool(forKey: kVLCSettingShowArtworks) && subtype() == .albumTrack) {
            return nil
        }

        if type() == .audio,
           let embeddedArtwork = AudioArtworkProvider.shared.artwork(for: self) {
            return embeddedArtwork
        }

        return VLCThumbnailsCache.thumbnail(for: thumbnail())
    }

    @objc func placeholderImage() -> UIImage? {
        // Podcast episodes have no generated thumbnail of their own and aren't album tracks,
        // so they'd otherwise fall through to the generic movie placeholder below - use the
        // same colored-initials placeholder the show list shows for the owning show instead.
        #if !os(watchOS) && !os(tvOS)
        if nbSubscriptions() > 0,
           let show = linkedSubscriptions(with: .default, desc: false)?.first {
            return VLCPlaceholderArtwork.placeholderImage(forName: show.name,
                                                           size: CGSize(width: 512, height: 512),
                                                           cornerRadius: 0,
                                                           fontSize: 160)
        }
        #endif
        #if os(watchOS)
        /// watchOS only doesn't have light mode
        let isDarktheme = true
        #else
        let isDarktheme = PresentationTheme.current.isDark
        #endif
        if subtype() == .albumTrack {
            return isDarktheme ? UIImage(named: "song-placeholder-dark") : UIImage(named: "song-placeholder-white")
        }

        return isDarktheme ? UIImage(named: "movie-placeholder-dark") : UIImage(named: "movie-placeholder-white")
    }

    @objc func thumbnailImage() -> UIImage? {
        return artworkImage() ?? placeholderImage()
    }

    func accessibilityText(editing: Bool) -> String? {
        if editing {
            return title + " " + mediaDuration() + " " + formatSize()
        }
        return title + " " + albumTrackArtistName() + " " + (isNew ? NSLocalizedString("NEW", comment: "") : "")
    }

    func title() -> String {
        if UserDefaults.standard.bool(forKey: kVLCOptimizeItemNamesForDisplay) == true
            && title.isSupportedMediaFormat() {
            return (title as NSString).deletingPathExtension
        }
        return title
    }
}

// MARK: - CoreSpotlight
extension VLCMLMedia {
#if !os(tvOS) && !os(watchOS)
    func coreSpotlightAttributeSet() -> CSSearchableItemAttributeSet {
        let contentType = type() == .video ? "public.movie" : "public.audio"
        let attributeSet = CSSearchableItemAttributeSet(itemContentType: contentType)
        attributeSet.title = title
        attributeSet.metadataModificationDate = Date()
        attributeSet.addedDate = insertionDate()
        attributeSet.contentCreationDate = releaseDate()
        attributeSet.lastUsedDate = lastPlayedDate()
        attributeSet.duration = NSNumber(value: duration() / 1000)
        attributeSet.streamable = 0
        attributeSet.deliveryType = 0
        attributeSet.local = 1
        attributeSet.playCount = NSNumber(value: playCount())
        if type() == .audio {
            attributeSet.thumbnailData = artworkImage()?.pngData()
        } else if thumbnailStatus() == .available {
            let image = VLCThumbnailsCache.thumbnail(for: thumbnail(), maxPixelSize: 270)
            attributeSet.thumbnailData = image?.jpegData(compressionQuality: 0.9)
        }
        attributeSet.codecs = codecs()
        attributeSet.languages = languages()
        if let file = mainFile() {
            attributeSet.path = file.mrl.path
            attributeSet.contentModificationDate = file.lastModificationDate
            attributeSet.fileSize = NSNumber(value: Double(file.size()) / (1024 * 1024))
        }
        if type() == .video, let video = videoTracks?.first {
            attributeSet.pixelWidth = NSNumber(value: video.width())
            attributeSet.pixelHeight = NSNumber(value: video.height())
            attributeSet.videoBitRate = NSNumber(value: video.bitrate())
        }
        if let audioTracks = audioTracks {
            for track in audioTracks {
                attributeSet.audioBitRate = NSNumber(value: track.bitrate())
                attributeSet.audioChannelCount = NSNumber(value: track.nbChannels())
                attributeSet.audioSampleRate = NSNumber(value: track.sampleRate())
            }
        }
        if subtype() == .albumTrack {
            if let genre = genre {
                attributeSet.genre = genre.name
                attributeSet.musicalGenre = genre.name
            }
            if let artist = artist {
                attributeSet.artist = artist.name
                attributeSet.performers = [artist.name]
            }
            attributeSet.audioTrackNumber = NSNumber(value:trackNumber)
            if let album = album {
                attributeSet.album = album.title
            }
        }

        if #available(iOS 18.4, visionOS 2.4, *), type() == .video {
            attributeSet.associateAppEntity(VideoEntity(media: self), priority: isFavorite() ? 10 : 1)
        }

        // iOS 27 SDK
#if canImport(MediaIntents)
        if #available(iOS 27, *), type() == .audio {
            attributeSet.associateAppEntity(SongEntity(media: self), priority: isFavorite() ? 10 : 1)
        }
#endif

        return attributeSet
    }

    func updateCoreSpotlightEntry() {
        if !KeychainCoordinator.passcodeService.hasSecret {
            let groupIdentifier = ProcessInfo.processInfo.environment["GROUP_IDENTIFIER"]
            let item = CSSearchableItem(uniqueIdentifier: "\(identifier())", domainIdentifier: groupIdentifier, attributeSet: coreSpotlightAttributeSet())
            CSSearchableIndex.default().indexSearchableItems([item], completionHandler: nil)
        }
    }
#endif

    func codecs() -> [String] {
        var codecs = [String]()
        if let videoTracks = videoTracks {
            for track in videoTracks {
                codecs.append(track.codec)
            }
        }
        if let audioTracks = audioTracks {
            for track in audioTracks {
                codecs.append(track.codec)
            }
        }
        if let subtitleTracks = subtitleTracks {
            for track in subtitleTracks {
                codecs.append(track.codec)
            }
        }
        return codecs
    }

    func languages() -> [String] {
        var languages = [String]()

        if let videoTracks = videoTracks {
            for track in videoTracks where track.language != "" {
                languages.append(track.language)
            }
        }
        if let audioTracks = audioTracks {
            for track in audioTracks where track.language != "" {
                languages.append(track.language)
            }
        }
        if let subtitleTracks = subtitleTracks {
            for track in subtitleTracks where track.language != "" {
                languages.append(track.language)
            }
        }
        return languages
    }
}

// MARK: - Search
extension VLCMLMedia: SearchableMLModel {
    @objc func contains(_ searchString: String) -> Bool {
        var matches = false

        matches = matches || search(searchString, in: title)

        if subtype() == .albumTrack {
            matches = matches || search(searchString, in: artist?.name ?? "")
            matches = matches || search(searchString, in: genre?.name ?? "")
            matches = matches || search(searchString, in: album?.title ?? "")
        }

        matches = matches || search(searchString, in: title)
        return matches
    }
}

extension VLCMLMedia {
    func albumTrackArtistName() -> String {
        guard let artist = artist, artist.identifier() != UnknownArtistID else {
            return NSLocalizedString("UNKNOWN_ARTIST", comment: "")
        }
        return artist.name
    }
}
