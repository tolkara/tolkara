# Without a Mac (experimental)

Tolkara is built by its users on a Mac, and that remains the supported way.
This page is the route for someone who has no Mac: the unsigned build from a
release, installed with a sideloading tool, running in External JIT. Since
0.3.1 the pieces for it exist; **it has not been run end to end by the
project**, so treat it as something to try and report on
([COMPATIBILITY.md](../COMPATIBILITY.md)).

## What you need

- An iPhone or iPad with Developer Mode on, and a sideloading tool that signs
  with your Apple ID. A free Apple ID is enough to install; see the limits
  below. Setting these tools up needs a computer once (Windows works).
- A JIT enabler. On current systems that is
  [StikDebug](https://github.com/StikDebug/StikDebug): its README and
  PAIRING.md describe installing it, the pairing file and LocalDevVPN. A
  sideloading tool's own "Enable JIT" only works on older systems and devices
  ([SideStore's notes](https://docs.sidestore.io/docs/advanced/jit)).
- Free space: an application such as World of Warcraft downloads tens of
  gigabytes of its own data.

## Steps

1. Install `Tolkara-unsigned.ipa` from the
   [latest release](https://github.com/tolkara/tolkara/releases/latest) with
   your sideloading tool (the release notes carry install links). It starts in
   External JIT.
2. Open Tolkara. For World of Warcraft Forever, tap **+** and choose
   **Download World of Warcraft Forever… (Experimental)**, read the notice,
   pick your region and language. Tolkara fetches the game's application
   (about 200 MB) from Blizzard's servers and adds it to the library
   ([profiles/wow-forever](../profiles/wow-forever/README.md)).
3. Tap the game. Opened without JIT, Tolkara says **JIT Not Enabled**: choose
   **Ask StikDebug**, allow the request in StikDebug, and come back to
   Tolkara. When it says **JIT Is Ready**, tap the game again.
4. At its first start the game downloads the data it needs and shows its
   progress; keep Tolkara open. Then log in inside the game as usual.

JIT belongs to one run of Tolkara: after closing it, repeat step 3. One
application starts per run.

## How JIT is requested

Tolkara asks StikDebug with the link StikDebug documents for apps
(`stikdebug://enable-jit`, with Tolkara's bundle identifier, its process and
the script name `universal.js`). That script answers the requests for
executable memory that `runtime/DebuggerArena.c` makes. Enabling JIT for
Tolkara by hand in StikDebug without that script attaches and leaves, and
Tolkara's request then ends the app: use **Ask StikDebug**, or assign
`universal.js` to Tolkara in StikDebug first. Running Tolkara inside
LiveContainer needs LiveContainer's "Use LiveContainer's Bundle ID" setting
for the request to name the right app.

## Known limits and what is untested

- **External JIT has not been run on a device by the project**, with StikDebug
  or any other enabler. The request and the memory protocol follow
  StikDebug's integration guide; whether they work together is the first thing
  to find out.
- **Memory on a free Apple ID.** The build declares the increased memory limit
  and extended virtual addressing capabilities, but a free account may not be
  granted them, and a large game may then not fit. Not measured.
- **Login.** The published build verifies the game's login servers against
  Mozilla's public root certificates
  ([translation/Security/PublicRoots](../translation/Security/PublicRoots/README.md)).
  Blizzard's login servers verify against that list; a login from this build
  has not been tried.
- **iPhone.** World of Warcraft Forever has been played on an iPhone 16 Pro
  Max with Developer service ([IPHONE.md](IPHONE.md)), not with External JIT.
- A free certificate's apps stop opening after 7 days until the sideloading
  tool refreshes them; Tolkara's folder and the game's files stay.
