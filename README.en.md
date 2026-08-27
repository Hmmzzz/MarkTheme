# MarkTheme

[简体中文](README.md) | English

MarkTheme is a modular theme engine and manager for modern jailbroken iOS environments, with support
for both conventional rootless jailbreaks and RootHide. It is compatible with mainstream theme assets,
including SnowBoard- and IconBundles-style `.theme` packages. Theme parsing and compilation happen
entirely inside the non-injected Manager app, while injected processes run only a deliberately small
Runtime. When anything fails validation, returning to the native system appearance is always the correct
outcome.

The current version is `v0.2.1`. The two jailbreak environments use different packages and the packages
must not be mixed.

`v0.2.1` temporarily raises the installation minimum to iOS 17.0. Icon overlays now adapt to the live
icon carrier's actual size and display scale, fixing releases of iOS 17 where overlays appeared in the
share sheet but not on the Home Screen. The same overlay also covers folders above their background and
native miniature icons. Diagnostics now include compact conclusions and counters for the Home Screen
overlay path and can export `MarkTheme-Diagnostics.txt` in one step.

## Screenshots

<p align="center">
  <img src="screenshots/home.png" width="45%" alt="MarkTheme theme library home screen">
  <img src="screenshots/theme-detail.png" width="45%" alt="MarkTheme theme details and component selection">
</p>

## Features

- Import ZIP, DEB, TAR-family archives, or expanded directories and review every recognized asset before saving
- Recognize supported resources in deep, scattered, or wrapper-less layouts, retain useful ecosystem names, and materialize them into the MarkTheme standard theme layout
- Strict asset validation, including two-pass ZIP decoding audits, structural and full-pixel PNG validation,
  and bounded plist parsing
- Recoverable Library revisions for every import, with crash-residue recovery and atomic switching
- Publication of compiled output as immutable, root-owned generations that the Runtime can only read
- Theming for SpringBoard Home Screen and Notification Center icons, folders, badges, Spotlight, Settings,
  Phone, the Photos share sheet, and system share-sheet icons
- The folder-background module requires a base background and accepts an optional light variant; icon
  overlays can cover folders independently
- Author-provided masks, underlays, and icon overlays, or the native system corner mask; masks are composed
  before overlays
- Image-content replacement on ordinary surfaces; the return-to-Home path adds a temporary square proxy
  only inside a verified system crossfade container, removes it when the animation ends, and leaves the
  system view hierarchy, app-snapshot geometry, and animation timeline unchanged
- Simplified Chinese and English localization

## Compatibility

See the [import adapter and resource-layout extension guide](docs/IMPORT_ADAPTER_GUIDE.md)
for classification confidence, the MarkTheme directory contract, and the checklist for new modules.

| Package scheme | Environment | `.deb` architecture |
| --- | --- | --- |
| `rootless` | Conventional rootless jailbreaks such as Dopamine | `iphoneos-arm64` |
| `roothide` | RootHide jailbreaks such as Relaxin | `iphoneos-arm64e` |

- Installation requires iOS 17.0 or later. The actively maintained range is iOS 17.x through 18.x.
  iOS 16 is temporarily unsupported and package managers will reject installation. Later versions are
  not promised compatibility and fall back to the native appearance according to live ABI checks.
- The app, Helper, and Runtime each include both `arm64` and `arm64e` slices.
- Rootful environments are unsupported, and packages from the two schemes must not be mixed.
- Packages depend on `uikittools` and `ellekit (>= 1.2)`.

The Runtime currently adapts SpringBoard, Spotlight, Preferences, Photos, MobilePhone,
SharingUIService, and sharingd. Ordinary apps receive the share adapter lazily and only after loading the
system ShareSheet framework. Sharing icon paths in the supported range are covered according to their
actual host processes; ShareSheet Activity, SharingUI provider, and UIKit app-icon producer entry points
can be installed independently and after framework loading.

Each process is first matched to a module using its `bundle ID + executable name`. The adapter then
validates every target class, implementation image path, selector, method signature, and—where required—
ivar type and offset before installing a hook.

> The adaptation layer never infers compatibility from a system-build or Mach-O UUID allowlist. If any
> live ABI check fails, that surface remains native instead of guessing how to call a private API. A small
> number of object-layout-dependent surfaces, such as badge backgrounds, additionally pin ivar offsets;
> they silently fall back rather than crash when the layout changes. Current ABI maintenance baselines
> include iOS 17.0 and 17.2.1 user diagnostics, an iOS 17.3.1 RootHide device, and iOS 18 icon-delivery
> regression coverage. Other iOS point releases and conventional rootless
> combinations still require device validation.

## Installation and Safety

Download the package matching your jailbreak environment from Releases and install it with your preferred
package manager, or use:

```bash
dpkg -i com.hmmzzz.marktheme_<version>_<arch>.deb
```

After installation, open MarkTheme from the Home Screen, import a theme package, and apply it. Switching
themes requires one Respring so that every target process loads the new Runtime image; the app prompts you
after applying.

Incomplete or incompatible assets can affect Home Screen rendering. Before installing or switching themes,
make sure you can enter your jailbreak's safe mode and remove MarkTheme through a package manager. Do not
manually modify MarkTheme's Runtime Store or Library data.

## Implementation Boundaries

- Injected processes run only the Runtime; theme parsing, compilation, and writable I/O stay in the Manager app.
- The package contains the Manager app, one short-lived root Helper, and one Runtime. It has no daemon,
  IPC hot path, or polling loop.
- Outside the return-to-Home animation and folder overlays, adapters replace image content. A folder
  overlay uses one transparent, non-interactive image view above the folder background and native miniatures.
- The return-to-Home animation uses one transition-scoped square proxy layer to isolate themed source pixels
  from the non-uniform morph. It activates only when the icon actually contains current MarkTheme pixels and
  the complete crossfade ABI has passed validation. It follows the native source fade, restores the source
  layer, and removes itself before the system's `cleanup` completes. The adaptation does not hook the morph
  fraction and adds no `layoutSubviews` hot-path work.
- Any identity, ABI, size, or resource validation failure returns the original system result. Private APIs
  are never called based on a guess.

## Building

Building requires macOS/Xcode, [RootHide Theos](https://github.com/roothide/theos), a compatible iOS SDK,
`ldid`, and `rg`.

```bash
git clone https://github.com/Hmmzzz/MarkTheme.git
cd MarkTheme
export THEOS=/path/to/roothide-theos

make package-roothide
make package-rootless
# Or build both packages in sequence
make package-all
```

Generated `.deb` files are placed in `packages/`. These targets automatically run `scripts/verify-package`
to audit scheme layout, Mach-O slices, minimum OS version, linking, entitlements, permissions, and the
Runtime process allowlist. You can also audit an existing package directly:

```bash
./scripts/verify-package packages/<marktheme.deb>
```

## Testing

```bash
./tests/run
```

The test suite compiles and runs only on the host. It does not connect to a device, deploy packages, apply
themes, Respring, or reboot.

## Repository Layout

| Path | Contents |
| --- | --- |
| `app/` | UIKit Manager app and localized resources |
| `core/` | Shared foundational types and utilities |
| `ingestion/`, `importers/` | Archive validation, ZIP decoding audits, and theme metadata parsing |
| `compiler/`, `library/` | Generation compilation and Library revision management |
| `workflow/` | Import workflow state machine and coordination |
| `store/`, `helper/` | Runtime Store and constrained root helper |
| `runtime/`, `modules/` | Injected image, process adapters, and theme resource modules |
| `platform/` | Jailbreak path resolution for rootless and RootHide |
| `layout/` | Debian package lifecycle |
| `scripts/`, `tests/` | Dual-package build audits and host regression tests |

## Contributing

Issues and pull requests are welcome. Run the host regression suite for functional changes. Changes involving
paths, permissions, package lifecycle, or schemes should also build and audit both rootless and RootHide
packages. Do not commit `.theos/`, `packages/`, `.deb` files, device data, keys, or other machine-local
artifacts.

## Acknowledgements

- [SnowBoard](https://sparkdev.me/) for establishing the de facto theme-asset and IconBundles ecosystem
  that informs MarkTheme's compatibility
- [RootHide](https://github.com/roothide/Developer) for the RootHide architecture and compatibility foundation
- [Theos](https://theos.dev/) for the iOS jailbreak development and packaging toolchain
- [ElleKit](https://github.com/evelyneee/ellekit) for the Runtime method-replacement implementation

See [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) for third-party license notices.

## Theme Licensing and Disclaimer

MarkTheme does not provide, sell, license, review, or distribute any third-party themes or icon assets. Users
are responsible for confirming that they have the rights required to import, use, copy, or distribute those
assets. This project's GPL license grants no rights to third-party assets.

This software is provided “as is,” without warranty. Maintainers and contributors are not liable for
unauthorized use of theme assets or for device issues, data loss, or system instability caused by
incompatibility or improper operation. See Sections 15 and 16 of GPLv3 for the complete terms.

This project is not affiliated with Apple Inc., any theme author, or any existing theme engine.

## License

Copyright (C) 2026 Hmmzzz.

Licensed under the [GNU General Public License v3.0 only](LICENSE).
