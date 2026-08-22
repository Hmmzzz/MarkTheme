# MarkTheme64e

MarkTheme64e is a modular theme engine and manager built for modern iOS jailbreak environments, supporting both conventional rootless and RootHide architectures. 

It ensures high compatibility with mainstream theme assets (SnowBoard / IconBundles style `.theme` packages), but fundamentally changes how themes are processed. All theme parsing and compilation is securely handled within the un-injected manager App. The injected process only runs an incredibly lightweight Runtime, built with a strict "fall back to the native system appearance" philosophy whenever a failure occurs.

The current version is `v0.1.9-64e-b1`. The two jailbreak environments use different packages, so please do not mix them.

## Screenshots

<p align="center">
  <img src="screenshots/home.png" width="45%" alt="MarkTheme64e Home Library">
  <img src="screenshots/theme-detail.png" width="45%" alt="MarkTheme64e Theme Details & Component Selection">
</p>

## Features

- **Safe Importing**: Import ZIP, DEB, TAR archives or extracted directories, and fully review the parsed results before saving.
- **Strict Asset Validation**: Includes two-pass ZIP decoding audits, static PNG structure and full-pixel validation, and quota-limited plist reading.
- **Reversible Library Revisions**: Each import generates a recoverable Library revision, supporting crash residue recovery and atomic switching.
- **Secure Runtime**: Compiled outputs are published as root-owned, immutable generations. The Runtime only has read-only access to them.
- **Extensive UI Theming**: Themes SpringBoard home screen icons, folders, badges, Spotlight, Settings, Phone UI, Photo Sharing, and System Sharing icons.
- **Masks**: Supports custom author masks or reuses the system's native rounded corner masks.
- **Non-Destructive Hooks**: Applying or rolling back themes never modifies the system view hierarchy—it only replaces image contents.
- **Localization**: Supports both Simplified Chinese and English.

## Compatibility

| Package Scheme | Environment | `.deb` Architecture |
| --- | --- | --- |
| `rootless` | Conventional rootless (e.g., Dopamine) | `iphoneos-arm64` |
| `roothide` | RootHide (e.g., Relaxin) | `iphoneos-arm64e` |

- **Minimum System Requirements**: iOS 16.0+. The App, Helper, and Runtime all contain both `arm64` and `arm64e` slices.
- **Unsupported Environments**: Rootful jailbreaks are not supported. Do not mix packages between the two package schemes.
- **Dependencies**: Requires `uikittools` and `ellekit (>= 1.2)`.

The Runtime currently supports hooking the following system processes: SpringBoard, Spotlight, Preferences, Photos, MobilePhone, SharingUIService, UIKit ShareUI, and sharingd. Share icon entry points on iOS 16 and iOS 17 are covered individually based on the actual host. ShareSheet Activity, SharingUI provider, and UIKit App icon production entry points can be installed independently and lazily.

Each process matches its corresponding module by `bundle ID + executable name`. At runtime, the adapter strictly validates the target class, implementation mirror path, selector, method signature, and (when necessary) ivar types and offsets before installing the hook.

> The adapter layer does not rely on system builds or Mach-O UUID whitelists to infer compatibility. If any real-time ABI validation fails, the corresponding UI surface will safely retain its native appearance without guessing private interfaces. A few surfaces that depend on object layout (e.g., badge backgrounds) additionally pin ivar offsets, so on system versions with layout changes, they will silently revert to the native appearance instead of crashing.
> The current ABI maintenance baseline includes iOS 16.2 (RootHide user diagnostics), iOS 16.4 Simulator runtime, and iOS 17.3.1 (RootHide real device). Other minor system versions and conventional rootless combinations may require real-device validation.

## Installation & Safety

Download the package that matches your jailbreak environment from Releases, and install it using your preferred package manager, or manually via terminal:

```bash
dpkg -i com.hmmzzz.marktheme64e_<version>_<arch>.deb
```

After installation, open MarkTheme64e on your home screen, import a theme package, and apply it. After switching themes, a Respring is required to let the new Runtime image take effect (the App will prompt you when the application is complete).

Incomplete theme assets or system incompatibility may affect your home screen's display. Before installing and switching themes, please ensure you know how to enter your jailbreak's safe mode and remove MarkTheme64e via your package manager. Do not manually modify MarkTheme64e's Runtime Store or Library data.

## Implementation Boundaries

- The injected process is strictly limited to running the Runtime. All parsing, compilation, and I/O are completed on the manager App side.
- The product package only contains the manager App, a short-lived root Helper, and a Runtime. There are no daemons, no IPC hot paths, and no polling.
- Adapters only replace image contents; they do not add, delete, or rearrange views/layers.
- Any identity, ABI, size, or resource validation failure immediately returns the original system result—absolutely no guessing.

## Building

Requires macOS/Xcode, [RootHide Theos](https://github.com/roothide/theos), a compatible iOS SDK, `ldid`, and `rg`.

```bash
git clone https://github.com/Hmmzzz/MarkTheme64e.git
cd MarkTheme64e
export THEOS=/path/to/roothide-theos

make package-roothide
make package-rootless
# Or build both packages sequentially
make package-all
```

The generated `.deb` files are located in `packages/`. The targets above will automatically call `scripts/verify-package` to check scheme layouts, Mach-O slices, minimum system versions, linking, entitlements, file permissions, and Runtime process whitelists. 
You can also independently audit existing packages:

```bash
./scripts/verify-package packages/<marktheme64e.deb>
```

## Testing

```bash
./tests/run
```

Tests only compile and run on the host machine. They will not connect to a device, deploy packages, apply themes, Respring, or reboot.

## Directory Structure

| Path | Contents |
| --- | --- |
| `app/` | UIKit manager App & localized resources |
| `core/` | Shared base types & utilities across layers |
| `ingestion/`, `importers/` | Archive validation, ZIP decoding audits & theme metadata parsing |
| `compiler/`, `library/` | Generation compilation & Library revision management |
| `workflow/` | Import state machine & coordination |
| `store/`, `helper/` | Runtime Store & restricted root helper |
| `runtime/`, `modules/` | Injected images, process adapters & theme resource modules |
| `platform/` | Jailbreak environment path resolution (rootless / RootHide) |
| `layout/` | Debian package lifecycle |
| `scripts/`, `tests/` | Dual-package build audits & host regressions |

## Contributing

Issues and pull requests are welcome. For feature changes, please run the host regressions. Changes involving paths, permissions, package lifecycle, or schemes should also build and audit both rootless and RootHide packages separately. Do not submit `.theos/`, `packages/`, `.deb`, device data, keys, or other local machine artifacts.

## Acknowledgements

- [SnowBoard](https://sparkdev.me/): The de facto standard for theme asset formats and the IconBundles ecosystem, which MarkTheme64e bases its asset compatibility on.
- [RootHide](https://github.com/roothide/Developer): RootHide architecture and compatibility foundation.
- [Theos](https://theos.dev/): iOS jailbreak development and packaging toolchain.
- [ElleKit](https://github.com/evelyneee/ellekit): The method replacement implementation used by the Runtime.

For third-party licenses, see [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

## Theme Licensing & Disclaimer

MarkTheme64e does not provide, sell, authorize, review, or distribute any third-party themes or icon assets. Users should independently confirm that they hold the necessary rights to import, use, copy, or distribute the relevant assets; this project's GPL license does not grant any rights to third-party assets.

This software is provided "as is", without warranty of any kind. Project maintainers and contributors are not responsible for unauthorized use of theme assets, or device anomalies, data loss, and system instability caused by incompatibility or improper operation. For full terms, see sections 15 and 16 of GPLv3.

This project is not affiliated with Apple Inc., nor is it affiliated with any theme authors or existing theme engines.

## License

Copyright (C) 2026 Hmmzzz.

Licensed under the [GNU General Public License v3.0 only](LICENSE).
