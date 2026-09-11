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

## Incomplete fork checkout

Before installing dependencies, the workflow fetches the pinned VideoLAN
GitLab upstream revision used as the base for these changes. It restores files that
are absent from the fork and never overwrites files already present in the
fork. This prevents partial folder uploads from repeatedly failing on missing
original VLC headers or implementation files.

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
