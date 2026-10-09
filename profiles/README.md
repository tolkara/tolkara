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
- `codePool`: megabytes (1 to 1024) of prepared executable memory after the
  images, for a runtime that writes its own code (an emulator's JIT, the
  native modules it loads). `${CodePool}` in an `environment` value then
  stands for it as `0x<start>-0x<end>@0x<alias>`: code runs from start to end
  and is written through the writable alias, since iPadOS runs only memory
  prepared for it and never again a page that was made writable. Preparing
  memory takes time at every launch (about a minute for 64 MB with Developer
  service), so ask for what the runtime needs. Only with `runtime`; Local
  signing cannot provide it.

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
- `risk` (optional): the notice the user must accept before choosing an
  online game. Keep `summary` short, factual and plain. Each `history` entry
  must be backed by one of the `links` (https), and say no more than its
  source does. If the wording changes, users are asked to accept it again.

A profile with a `runtime` cannot have `setup` yet. `tools/check_profile.py`
validates all of this, and `management/App/Core/Profile.swift` follows the
same rules.
