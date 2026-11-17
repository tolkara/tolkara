# Application profiles

A profile tells the launcher what a tested application is called and where its
files live inside the Tolkara app's Documents folder. It is data only: no code,
no patches, no settings for the application itself.

```json
{
  "id": "example",
  "name": "Example",
  "workingDirectory": "Example",
  "executable": "Example.app/Contents/MacOS/Example",
  "tested": "Example 2.1, iPad Pro M5",
  "notes": "Anything a user should know."
}
```

- `workingDirectory`: folder under Documents that becomes the working directory.
- `executable`: path of the macOS executable, relative to `workingDirectory`.
  Keeping the `.app` bundle structure lets the application find its resources.
- Both paths must be relative and stay inside Documents; `tools/check_profile.py`
  rejects anything else and any unknown key.
- `caseAliases` (optional): `{"archive/mac": "Mac"}` means the application
  opens `archive/mac/…` while its installer wrote `archive/Mac`. macOS's file
  system ignores case by default and iPadOS's does not, so before each start
  the launcher adds `archive/mac` as a relative symbolic link to `Mac` when the
  link is missing and `archive/Mac` exists. Each alias is a path relative to
  `workingDirectory`; its target is the alias's last component in another case,
  in the same folder. Nothing outside the working directory is created or
  followed. The link stays in your copy of the files, visible in the Files app.

An application that is itself run by a compatibility runtime (a Windows
program under Wine, say) names that runtime instead of a macOS `.app`:

```json
{
  "id": "example-windows",
  "name": "Example (Windows)",
  "workingDirectory": "Example/prefix/drive_c/Example",
  "runtime": "Example/Wine",
  "executable": "lib/wine/aarch64-unix/wine",
  "arguments": ["Example.exe"],
  "libraries": ["lib/wine/aarch64-unix/ntdll.so"],
  "environment": { "WINEPREFIX": "${Documents}/Example/prefix" }
}
```

- `runtime`: folder under Documents holding the runtime; `executable` is then
  relative to it, and `workingDirectory` stays the application's own folder.
- `arguments`: the runtime's command line after its executable, at most 64
  strings. `environment`: variables set before it starts, at most 64;
  `${Documents}` in a value stands for the absolute Documents folder.
  Both are plain strings: no code, and nothing that changes the application.
- `libraries`: the runtime's own libraries that it opens by path at run time
  instead of linking them (Wine's Unix side), relative to `runtime`, at most
  64. They are loaded with the executable as if it carried them, with what
  they link, and the runtime's `dlopen` of one gets that copy; the whole
  runtime folder then counts as the application's folder. Only with `runtime`.
- `codePool`: megabytes (1 to 2048) of prepared executable memory after the
  images, for a runtime that writes its own code (an emulator's JIT, the
  native modules it loads). `${CodePool}` in an `environment` value then
  stands for it as `0x<start>-0x<end>@0x<alias>`: code runs from start to end
  and is written through the writable alias, since iPadOS runs only memory
  prepared for it and never again a page that was made writable. Preparing
  memory takes time at every launch (about a minute for 64 MB with Developer
  service), so ask for what the runtime needs. Only with `runtime`; Local
  signing cannot provide it.
- `processes`: how many runtime process instances are available during one
  iPad app session (1 to 8, default 1), for a program that starts
  others, such as a launcher or a client with helper processes. Each process
  beyond the first gets its own placed copy of the runtime's `libraries` and
  an equal share of
  `codePool`; it starts when the runtime spawns its own executable. Finished
  instances and their used code pools remain retired until Tolkara exits, so
  sequential game launches need additional slots and prepared memory. See
  [docs/MULTIPROCESS.md](../docs/MULTIPROCESS.md). Only with `runtime`.
- `steamCloud`: Steam Cloud saves the launcher keeps in step before each
  start, every minute while the application runs and after it exits:
  `appID`, the saves' Steam Cloud folder `remoteDirectory`, their
  Documents folder `localDirectory`, their `fileNames` (1 to 64), and
  optionally `uploadsEnabled` (local changes are uploaded) and `required`
  (the application does not start unless Steam Cloud is signed in on the
  device, so its saves never diverge). The sign-in stays in the device's
  Keychain; sync state, backups and `sync.log` are in
  `Documents/SteamCloud/<id>/`. On a device with no sync state yet, the
  first sync takes the Cloud's files and backs up the local ones there.
- `download` (experimental): what the launcher fetches for a user who has no
  Mac to copy the application from. With it, **+** in the launcher offers
  **Download <name>…** while the application is not in Documents. The
  launcher fetches only the application itself, straight from its
  publisher's content servers to the device, and checks each file against
  the publisher's own file list; Tolkara hosts and bundles none of it. Its
  keys depend on `service`. For `"blizzard"` (Blizzard's public version and
  content servers, which need no account): `product`, the `regions` on offer
  (each `id`, `name` and the `portal` the game calls it), the `locales`, the
  `tags` of the publisher's file list that select this system's files, the
  list's `folder` that is the application, the install's top folder `root`
  (the working directory or a folder above it), and optionally `settings`:
  the game's settings `file` and the names of its `region`, `text` and
  `audio` settings, written once with the user's choices. Not for a profile
  with a `runtime`.
  For `"steam"` (the Windows Steam client, from Valve's public update server,
  which needs no account; only for a profile with a `runtime`), exactly:
  `root`, the top folder in Documents that holds the profile's `runtime` and
  working directory; `runtime`, the archive of the Windows runtime Steam runs
  in (Tolkara's own build of Wine and FEX with an empty Windows prefix), as
  its https `url` (at most 512 characters), its `sha256` (64 lowercase
  hexadecimal digits) and its `size` in bytes (up to 4 GiB); and `client`,
  the name of Valve's list of the client's files (`steam_client_win64`). The
  launcher fetches the archive, checks it against `sha256` and unpacks it
  into `root`; then it fetches Steam's packages, checks each against the
  SHA-256 in Valve's list, unpacks the installer package into the working
  directory and keeps the others in its `package` folder, where Steam looks
  for them at its first start. A prefix that is already there (it has a
  `prefix/system.reg`) is left alone: it holds the user's Steam and sign-in.
  The archive is a plain ZIP (stored or deflated entries, no ZIP64, no
  encryption, no links) of `root`'s contents. The executable bit of its
  entries is kept. Its optional top-level `tolkara-links.txt` is not
  unpacked: each line, `<destination><tab><source>` with both paths inside
  `root`, makes the destination a copy of the unpacked source that shares
  its storage, so files the prefix repeats from the runtime are stored once.
  `tools/package_windows_runtime.py` packs the archive and
  `tools/publish_windows_runtime.sh <n>` publishes it as the release
  `windows-runtime-<n>` and pushes the profile that names it. A published
  archive is never replaced: a change gets the next number.

Every profile in `profiles/` is built into the app. When the files a profile
describes are present in Documents, the launcher adds that app to its library
under the profile's name. A profile outside this folder can be added with
`TOLKARA_PROFILE=/path/to/profile.json` in `local.env`.

Profiles are optional: any executable added with **+** in the launcher is
remembered too. Inside Documents it runs in place (the folder containing its
`.app` becomes the working directory); elsewhere only the executable is copied.

A profile folder may include a helper script that copies the user's **own**
installed files to the iPad. It must never download or contain the application.

## Setting up with Tolkara Management

[Tolkara Management](../docs/MANAGEMENT.md), the Mac setup app, offers a
profile that has a `setup` block. The block is data only. The iPad launcher
ignores it.

```json
"setup": {
  "source": "/Applications/Example",
  "destination": "Example",
  "installer": "install.py",
  "getApp": {
    "name": "Example Store",
    "url": "https://example.com/download",
    "path": "/Applications/Example Store.app",
    "steps": ["Install Example from Example Store."]
  },
  "firstRun": {
    "settings": "Example/Config.txt",
    "keys": ["portal", "textLocale"],
    "steps": ["Start Example once from Example Store, choose your region, then quit."]
  },
  "risk": {
    "summary": "Example is an online game. Your account could be suspended or banned; that risk is yours alone.",
    "history": [{ "when": "2020", "text": "What the publisher has said or done about compatibility layers." }],
    "links": [{ "title": "Source", "url": "https://example.com/statement" }]
  }
}
```

- `source` (optional): the usual absolute path of the Mac folder that
  becomes `Documents/<destination>`. The user can choose another folder.
  Without it, the user always chooses.
- `destination` (optional): that folder under Documents. It defaults to the
  first component of `workingDirectory`, and it must be `workingDirectory`
  or a folder above it. The app finds the executable at `source` followed by
  `workingDirectory/executable` minus `destination`.
- `installer` (optional): the profile folder's copy helper. The app runs it
  as `python3 <installer> --source <folder> --device <UDID>`, with
  `local.env` written. Only built-in profiles' helpers run. Without one, or
  for a profile the user added, the folder is copied with `devicectl`.
- `getApp` (optional): where to get the application. `url` must be https,
  and `path` is where its installer app usually lives. `steps` holds at most
  16 short instructions, and `**bold**` is allowed in them.
- `firstRun` (optional): a settings file the application writes the first
  time it starts on the Mac, relative to `source`, and the `keys` (1 to 16
  names) it must then hold as `SET <key> "<value>"` lines, the form of World
  of Warcraft's `WTF/Config.wtf`. Until every key has a value, the app shows
  `steps` (at most 16, `**bold**` allowed) with a button that opens `getApp`,
  checks again by itself, and does not copy the game. The app only reads the
  file. The WoW helpers copy just these keys (`tools/first_run.py`), merged
  into the device's own copy of the file.
- `risk` (optional): the notice the user must accept before choosing an
  online game. Keep `summary` short, factual and plain. Each `history` entry
  must be backed by one of the `links` (https), and say no more than its
  source does. If the wording changes, users are asked to accept it again.

A profile with a `runtime` cannot have `setup` yet. `tools/check_profile.py`
validates all of this, and `management/App/Core/Profile.swift` follows the
same rules.
