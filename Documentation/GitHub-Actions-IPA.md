# GitHub Actions IPA build

The workflow in `.github/workflows/build-ios-ipa.yml` builds the
`VLC-iOS-no-watch` scheme for iPhoneOS and packages the result as an unsigned
IPA.

## Run the workflow

1. Commit and push `.github/workflows/build-ios-ipa.yml` with the source changes.
2. Open the fork on GitHub and enable Actions if GitHub asks for confirmation.
3. Open **Actions** > **Build iOS IPA** > **Run workflow**.
4. Download `VLC-iOS-unsigned-ipa-<run number>` from the run's **Artifacts**
   section.

The artifact contains the IPA and a SHA-256 checksum. GitHub retains it for 14
days.

## Reconstructed upstream base

Before installing dependencies, the workflow fetches the pinned VideoLAN
GitLab upstream revision used as the base for these changes. The fork contains
both missing files and existing files from older VLC revisions, so restoring
only missing files is not sufficient. The workflow reconstructs every original
upstream file from the pinned revision while preserving every source file
intentionally customized by the playback and artwork changes.

The reconstruction is confined to the temporary Actions checkout; it does not
write changes back to the GitHub repository. It then compares every reconstructed
upstream file byte-for-byte with the pinned archive and fails early with the full
list if any mismatch remains. Files that exist only in the mixed-version fork
are removed from the temporary checkout, so recursive header lookup and build
scripts cannot accidentally consume stale source files. Git metadata, the
workflow directory, and this build document are excluded from that cleanup.

The preserved customization list is deliberately explicit:

- `Resources/en.lproj/Localizable.strings`
- `Sources/App/VLCAppCoordinator.m`
- `Sources/App/iOS/VLCAppDelegate.m`
- `Sources/Headers/VLCConstants.h`
- `Sources/Helpers/Thumbnail Cache/VLCThumbnailsCache.h`
- `Sources/Helpers/Thumbnail Cache/VLCThumbnailsCache.m`
- `Sources/Media Library/MediaCategories/MediaCategoryViewController.swift`
- `Sources/Media Library/MediaLibraryModel/MediaModel.swift`
- `Sources/Media Library/MediaLibraryService.swift`
- `Sources/Playback/Control/VLCPlaybackService.m`
- `Sources/Playback/OS Integration/VLCMetadata.m`
- `Sources/Playback/Player/AudioPlayer/AudioPlayerView.swift`
- `Sources/Playback/Player/AudioPlayer/AudioPlayerViewController.swift`
- `Sources/Playback/Player/MiniPlayer-iOS/AudioMiniPlayer.swift`
- `Sources/Playback/Player/VideoPlayer-iOS/MediaMoreOptionsActionSheet.swift`
- `Sources/Playback/Player/VideoPlayer-iOS/Subviews/MediaPlayerActionSheet.swift`
- `Sources/Podcasts/Views/PodcastArtworkView.swift`
- `Sources/WiFi Sharing/VLCHTTPConnection.m`

The reconstruction step also checks for the original-resolution artwork markers.
It fails before dependency installation if rsync ever replaces those files with
the upstream 1024-pixel implementation.

On the first launch after this change, VLC runs one metadata-parser repair pass.
This restores audio artwork removed by an earlier broken migration without
deleting media-library data. Audio never enters the frame-thumbnail generator;
embedded and linked cover art remains owned by metadata parsing. Artwork image
loading preserves source pixel dimensions on library pages, playback, and Now
Playing.

The reconstruction guard also preserves the iOS 26 search fix: media pages use
only the navigation item's integrated `UISearchController`. Album detail pages
never reattach the legacy standalone `UISearchBar`, preventing the clipped
search field from appearing over the top-left navigation area.

The workflow then scans every app bridging header and verifies all quoted local
imports in one pass. Missing and ambiguous imports are reported together before
dependency installation, rather than surfacing one header at a time during the
build. If this check fails, confirm that the runner can reach the public
VideoLAN GitLab repository and that the pinned revision still matches the
project file.

The unsigned build also adds the recursive `Sources/**` header search path while
preserving inherited target settings. This makes headers restored after checkout
visible to Swift bridging-header dependency scanning without changing each
`#import` to a repository-relative special case.

## Signing

This workflow deliberately disables code signing. Its IPA cannot be installed
through normal iOS installation or submitted to App Store Connect until it has
been signed with an Apple Developer certificate and matching provisioning
profiles.

`VLC-iOS-no-watch` embeds both `VLC-ShareExtension` and
`MediaLibraryWidgetExtension`. A signed build therefore needs registered bundle
identifiers and matching profiles for all three targets, including the App
Groups and iCloud capabilities used by the project.
