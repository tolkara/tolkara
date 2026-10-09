# Tolkara Management

Tolkara Management is a Mac app that sets Tolkara up for you. It checks
each requirement and explains how to meet it. It builds Tolkara on your
Mac with your own Apple developer account, installs it on your iPad or
iPhone and copies your game over. Afterwards its library shows the games on
the device, updates them after the game changed on the Mac, and removes
them. You don't need the command line or a checkout of
this repository. Under the hood it runs the same scripts this repository
documents in [BUILDING.md](BUILDING.md), on a copy of Tolkara's source
that it carries inside.

It is a guided way to build Tolkara yourself, not a prebuilt copy of it.
Tolkara is still compiled on your Mac, signed with your identity and
installed on your device.

## Getting it

Each [release](https://github.com/tolkara/tolkara/releases) carries
`Tolkara-Management.dmg`. Open it and drag **Tolkara Management** to
Applications.

If macOS says it cannot check the app, open System Settings › Privacy &
Security and click **Open Anyway**. A release built without the project's
Developer ID is signed ad hoc, so macOS asks once.

To build the app from a checkout instead:

```bash
tools/package_management.sh
```

## What it does, step by step

| Step | What it checks | How it helps |
| --- | --- | --- |
| Developer Account | A paid Apple Developer Program membership. It looks at what Xcode already keeps on this Mac: the teams of signed-in accounts and the provisioning profiles Xcode downloaded. A paid membership's profiles last a year. A free Personal Team's last seven days, and free teams cannot sign the Network Extension capability Tolkara needs. No credentials are asked for and nothing is sent anywhere. | Explains how to sign in to Xcode or join the program. If your team is not listed, you can type in its Team ID, and the first build confirms it. |
| This Mac | Xcode installed and set up (licence and components), XcodeGen, Python 3, free space. | Opens Xcode in the App Store. Installs XcodeGen through Homebrew, or from its official GitHub release if Homebrew is not installed. |
| iPad or iPhone | Connected, trusts this Mac, Developer Mode on, and Xcode new enough for its iPadOS or iOS. The page refreshes by itself every few seconds. With several devices connected, you choose one. | Shows the Trust prompt on the device. Walks you through turning on Developer Mode. On an iPhone, says how the on-screen controls work. |
| Game | A profile is chosen, the game is found on this Mac, and its account-risk notice is accepted. | Lists the profiles this app can set up, with WoW Forever first. Opens Battle.net or its download page. Finds the game in its usual place, or lets you choose its folder. Shows the version and size. Profiles can be added from a file or an https link. |
| Install Tolkara | Built for this team, iPad and source version, and enrolled for Developer service. | Writes `local.env`, runs `tools/install.sh`, then `tools/enroll.sh`. Shows what the build is doing, explains common failures in plain words and links to the step that fixes them. Shows when the signature expires. |
| Copy Game | Copied to this iPad from the chosen folder. | Runs the profile's own `install.py`. An added profile has no script, so its folder is copied with `devicectl`. |
| Play | — | Opens Tolkara on the device, explains the VPN prompt, and saves `native-guest.log` from the device. |

When Tolkara is already on the device under another bundle ID, for example
one installed by hand with `tools/install.sh`, the Install step and the
library offer to manage that copy instead. Its games, settings and
enrolment stay, and the next build installs over it.

## The library

**Library**, under the device in the sidebar, lists what Tolkara has on the
device. It reads the folders in Tolkara's Documents, the launcher's own
list of apps and each game's `Info.plist`, and changes nothing while
reading. Games are grouped by folder, because games can share one: both
WoW clients live in "World of Warcraft" and share its `Data`. For each game
it shows the version, when it was last played, and whether the copy on this
Mac is different.

- **Update** appears when the game changed on this Mac, for example after
  Battle.net updated it, because the version or the executable differs.
  If the executable changed since Tolkara was built, Tolkara is built and
  installed again first, since the build is made for that executable. Then
  the game is copied; files that did not change are skipped.
- **Copy Again** copies the game without rebuilding.
- **Remove from iPad…** in a folder's menu deletes that folder from the
  device after you confirm, along with every game in it. devicectl cannot
  delete files, so the app asks Tolkara on the device to do it
  (`--remove-app-folder <folder>`; `TKAppLibrary removeApplicationFolder:`).
  Tolkara removes only a folder that holds an application, never its own
  folders or anything else in Documents, and the game comes back in its
  library when it is copied again. This needs a Tolkara built by this
  version of the app, which knows the request.
- Games this app can set up that are not on the device yet are listed with
  **Set Up…**.

Tolkara Management uses the Developer service execution mode, which needs
nothing but the one-time enrolment. Local signing for the WoW clients needs
a capture of their final code pages, which Tolkara cannot produce yet
([README](../README.md#three-ways-to-run-code)).

## Where it keeps things

Everything stays in `~/Library/Application Support/Tolkara Management/`:

- `Tolkara/<commit>/`: the unpacked source. It also holds the `local.env`
  the app writes and the build output (`build/`, `logs/`). You can run
  Tolkara's scripts there by hand. **Settings › Advanced › Show Work
  Folder** opens it.
- `Profiles/`: profiles you added.
- `Tools/`: XcodeGen, when it was not installed through Homebrew.
- `state.json`: your choices (team, iPad, games, accepted notices).

**Settings › Advanced** can point the app at your own checkout of Tolkara
instead of the copy inside. It also changes the app identifier, which
defaults to `local.tolkara.<your team ID>`. **Start Over** forgets your
choices and leaves your iPad untouched.

## Profiles and the account-risk notice

The app reads an optional `setup` block in a profile
([profiles/README.md](../profiles/README.md#setting-up-with-tolkara-management)).
The block says where the game usually is on a Mac, how to get it, which
helper copies it, and the account risk to show before it is set up.

The notice for an online game must be accepted, with a checkbox, before
the game can be chosen. It says that the publisher does not support
Tolkara, that a suspension or ban is possible, and that the risk belongs to
the user alone. It also summarises how the publisher has treated
compatibility layers in the past, with sources. If the profile's notice
changes, the app asks the user to accept it again.

The app only runs helper scripts from the profiles built into Tolkara's
own source. A profile you add is data only: the app checks it with the
same rules as `tools/check_profile.py`, and copies its folder without
running anything from it. Profiles whose application runs through a
compatibility runtime, such as Heroes III, are still set up from the
command line.

## For maintainers

The app lives in [`management/`](../management): SwiftUI, macOS 14 or
later, and not sandboxed, because it runs Xcode's tools. Its XcodeGen spec
embeds the source through `tools/embed_management_source.sh`: files git
tracks or does not ignore, never `local.env`, build output or `.claude/`.

```bash
tools/test_management.sh        # unit tests, warnings as errors
tools/package_management.sh     # Release build in a .dmg
```

To show one step when the app starts, for screenshots, launch it with
`-showStep <welcome|membership|mac|iPad|game|install|copy|play|library>`.
To open a profile's risk notice as well, add `-showRisk <profile id>`. With
`TOLKARA_MANAGEMENT_SUPPORT=<folder>` in its environment, the app keeps its
state in that folder, so a second copy leaves yours alone.

To run the opt-in test that reads a real device's library, add
`TEST_RUNNER_TOLKARA_LIVE_DEVICE=<UDID>` and
`TEST_RUNNER_TOLKARA_LIVE_BUNDLE=<bundle ID>` to the environment of
`xcodebuild test`.

A local build carries your working copy of the source: committed files,
plus your changes and new files git does not ignore. A release, built from
a clean checkout of its tag, carries exactly the tag. The app unpacks a
fresh copy, and asks for a new build, whenever the content changes.

A `v*` tag runs `.github/workflows/release.yml`. It builds the unsigned
`.ipa`, then builds `Tolkara-Management.dmg` and attaches it to the
release. To have the app signed with a Developer ID and notarized, so that
macOS opens it without asking, add these repository secrets:

| Secret | Contents |
| --- | --- |
| `MANAGEMENT_DEVELOPER_ID_P12` | A "Developer ID Application" certificate with its private key, exported as .p12, base64-encoded. |
| `MANAGEMENT_DEVELOPER_ID_PASSWORD` | The .p12's password. |
| `NOTARY_KEY_P8` | An App Store Connect API key (.p8), base64-encoded, with the Developer role. |
| `NOTARY_KEY_ID`, `NOTARY_ISSUER` | That key's ID and its issuer ID. |

Without these secrets the release still gets the app, signed ad hoc.
