# Notices

Tolkara is original work released under the MIT License. Its default build uses
Apple's public SDK frameworks and the Python standard library, without bundled
third-party source code or libraries.

An optional, builder-supplied native [MoltenVK](https://github.com/KhronosGroup/MoltenVK)
runtime can be bundled with `TOLKARA_VULKAN_RUNTIME`. MoltenVK is under the
[Apache License 2.0](https://github.com/KhronosGroup/MoltenVK/blob/main/LICENSE).
It translates Vulkan to Metal; no MoltenVK source or binary is stored in this
repository. Keep its supplied licence with any runtime you distribute.

The following public material was consulted as **reference documentation** for
protocols and formats. No code was copied or translated from these projects.

- Remote Pairing protocol description by Jackson Coxson
  (jkcoxson.com/blog/rppairing-spec)
- pymobiledevice3 (GPL-3.0), consulted for RemoteXPC and service-discovery
  message layouts
- StikJIT integration notes (executable-region preparation protocol)
- Apple HomeKit ADK (Apache-2.0), Pair Verify reference
- Apple open-source objc4 headers, for the Objective-C image registration SPI
- LLVM libunwind_ext.h (Apache-2.0 WITH LLVM-exception), for the Darwin dynamic
  unwind-section lookup SPI declarations; registration code is original
- GDB remote serial protocol and LLDB `debugserver` extension documentation
- SteamRE SteamKit (MIT), consulted for Valve’s public Steam client message
  numbers and protobuf schemas; the native TLS Cloud client is original code
- RFC 9293 (TCP), RFC 8200 (IPv6), RFC 7748 (X25519), RFC 5054 (SRP)

`translation/CoreServices/USKeyMap.h` is a table of the characters produced by
a standard US ANSI keyboard, checked against macOS behaviour. System trust roots
are not stored in this repository; `tools/export_system_anchors.m` exports the
public certificates from the builder's own Mac at build time. The unsigned build
published with releases leaves them out.

If you contribute code derived from another project, say so in the pull request
and add its licence here.
