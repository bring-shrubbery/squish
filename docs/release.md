# Releasing Squish

Releases are automatic. Every push to `main` that passes CI and changes something
other than documentation is built, signed, notarized and published as
`Squish-vX.Y.Z-macos-arm64.dmg` (and a zip of the app) on a GitHub release tagged
`vX.Y.Z`. Installed copies update themselves from the `appcast.xml` each release
publishes (Sparkle), and the website at https://squish.quassum.com is redeployed so
its download button offers the new version.

The pipeline mirrors NeuralSheet's. The differences: Squish is a Swift package, so
`scripts/build-app.sh` assembles and signs the bundle instead of an Xcode archive,
and the website deploys from GitHub Actions with wrangler (`.github/workflows/web.yml`)
instead of Cloudflare Workers Builds.

## Versions

The workflow computes the version: the higher of `CFBundleShortVersionString` in
`Support/Info.plist` and the last release tag with its patch bumped
(`scripts/release-version.sh`).

- A code push after `v0.1.3` releases `v0.1.4`. Nothing to do.
- To ship a minor or major, set `CFBundleShortVersionString` to, say, `1.0.0` and
  push. That push releases `v1.0.0`; the next one `v1.0.1`. CI never edits the plist.
- The build number (`CFBundleVersion`, which Sparkle compares) is the workflow run
  number, written into the built bundle by `build-app.sh`.
- Pushes that change only `docs/`, `web/`, `*.md`, `LICENSE`, `NOTICE` or `.github/`
  (except the workflows) release nothing (`scripts/release-changes.sh`). The run says
  so in its log.

The GitHub release body and the notes the update prompt shows are the commit
subjects since the previous tag (`scripts/release-notes.sh`): the conventional
`type(scope):` prefix is dropped, and `docs`, `ci`, `test` and `chore` commits, and
anything scoped `web`, `docs` or `ci`, are left out. Write every subject as the line a
user will read.

## How a release is built

1. **Decide the version** (Linux): the version, the tag, and whether anything worth
   releasing changed.
2. **Build and sign**: `scripts/build-app.sh` with `SIGN_IDENTITY`, `VERSION` and
   `BUILD_NUMBER` builds `Squish` and `squish-hook` for arm64, embeds
   `Sparkle.framework`, points the executable's rpath at `Contents/Frameworks`, and
   signs inside out with the Developer ID, the hardened runtime and a secure
   timestamp: Sparkle's XPC services, `Autoupdate` and `Updater.app`, the framework,
   `squish-hook`, then the app. The workflow then checks every one of them carries the
   Developer ID and the runtime.
3. **Disk image**: `create-dmg`, retrying without the Finder layout on a flaky runner.
4. **Notarize**: the image is signed, submitted with the App Store Connect key,
   stapled (image and app), and the app is zipped for Sparkle.
5. **Appcast**: the zip is signed with the Sparkle EdDSA key and
   `scripts/release-appcast.sh` writes the feed.
6. **Publish**: tag, GitHub release with the dmg, zip and `appcast.xml`, then
   dispatch the Website workflow.

The same build runs locally on a Mac with the certificate, up to notarization:

```sh
SIGN_IDENTITY="Developer ID Application: Quassum MB (6WCYZER5LX)" VERSION=0.1.0 BUILD_NUMBER=1 \
  ./scripts/build-app.sh
```

## One-time setup: the secrets

The release refuses to run without all eight of these repository secrets; an
unsigned build must never reach a release. They are the same values as NeuralSheet's
(same team, certificate and App Store Connect key), except the Sparkle key, which is
Squish's own.

| Secret | Status |
| --- | --- |
| `APPLE_TEAM_ID` | set (`6WCYZER5LX`) |
| `MACOS_SIGNING_IDENTITY` | set (`Developer ID Application: Quassum MB (6WCYZER5LX)`) |
| `SPARKLE_PRIVATE_KEY` | set (generated 2026-10-04, see below) |
| `MACOS_CERTIFICATE_P12` | to add |
| `MACOS_CERTIFICATE_PASSWORD` | to add |
| `ASC_API_KEY_P8` | to add |
| `ASC_API_KEY_ID` | to add |
| `ASC_API_ISSUER_ID` | to add |

### 1. The Developer ID certificate

Keychain Access → My Certificates → `Developer ID Application: Quassum MB
(6WCYZER5LX)` → Export as `.p12` with a password, then:

```sh
gh secret set MACOS_CERTIFICATE_P12 < <(base64 -i developer-id.p12)
gh secret set MACOS_CERTIFICATE_PASSWORD        # paste the .p12 password
rm developer-id.p12
```

### 2. The App Store Connect API key (for notarization)

Reuse the `NeuralSheet CI` key (Developer access) or generate a new one at
https://appstoreconnect.apple.com → Users and Access → Integrations → App Store
Connect API → Team Keys. The Key ID is on the key's row, the Issuer ID above the
table:

```sh
gh secret set ASC_API_KEY_P8 < AuthKey_XXXXXXXXXX.p8
gh secret set ASC_API_KEY_ID --body XXXXXXXXXX
gh secret set ASC_API_ISSUER_ID --body 00000000-0000-0000-0000-000000000000
```

`gh secret list` should then show all eight names (plus the website's two).

### 3. Sparkle (in-app updates)

Installed copies read `https://squish.quassum.com/appcast.xml`, a redirect
(`web/public/_redirects`) to the latest release's asset. The zip is signed with an
EdDSA key so the app accepts only our builds.

The key pair was generated on 2026-10-04 with Sparkle's
`generate_keys --account Squish`. The private key lives in the login keychain of
the Mac that ran it (Keychain Access → search "sparkle-project.org", account
`Squish`) and in the repository secret `SPARKLE_PRIVATE_KEY`. **Losing both means no
installed copy can ever update again.** Back it up once:
`generate_keys --account Squish -x sparkle-squish.key` and keep the file somewhere
safe, off this machine. The matching public key is `SUPublicEDKey` in
`Support/Info.plist`.

If the key is lost: generate a new pair, put the new public key in Info.plist, set
the new secret, and tell users to download the next release by hand. To rotate: ship
one release signed with the old key whose Info.plist carries the new public key,
then switch the secret.

### 4. The website

`CLOUDFLARE_ACCOUNT_ID` is set; `CLOUDFLARE_API_TOKEN` must be added (see
`web/README.md`). Without it the Website workflow fails and the site keeps offering
the previous release; the app release itself is unaffected.

### 5. The first release

Push a code change to `main`, or run the Release workflow from the Actions tab with
**Run workflow** (only `main` is honoured). Until the secrets exist, every code push
produces one red Release run that stops at the secrets check; that is expected.

## When it fails

- **missing repository secrets**: the first step names them; add and re-run.
- **notarization ended with status Invalid**: the step prints Apple's log. Usual
  causes are a binary without the hardened runtime or timestamp; the build step
  checks both, so look at what changed (a new executable `build-app.sh` does not sign).
- **create-dmg could not apply the window layout**: a warning only.
- **Sign the update and write the appcast failed**: usually `SPARKLE_PRIVATE_KEY` is
  missing or not the exported key. Fix and re-run; nothing was tagged.
- **The tag exists**: a previous run tagged but failed to publish. The notarized dmg,
  zip and `appcast.xml` are attached to that run as artifacts. Publish all three by
  hand as release `vX.Y.Z`, or delete the tag (`git push origin :refs/tags/vX.Y.Z`) and
  re-run.
- **Rebuild the website failed**: the release is out; run the Website workflow from
  the Actions tab.
