# Theme Mixing and Feature Switches

This document defines cross-theme mixing, per-feature switches, and application semantics in MarkTheme 0.2.6.
It is both a user guide and a behavior contract between the Manager, Compiler, and Runtime.

## Complete Feature List

Theme Details always presents every feature supported by MarkTheme instead of limiting the list to resources
already present in the current theme. The supported groups include:

- static App icons and dynamic Calendar and Clock icons;
- Settings and Share icons;
- folders, icon masks, overlays, badges, and icon shadows;
- status-bar resources and dialer controls.

A row remains visible when the current theme lacks that resource. The user can keep the native appearance or
select another imported theme that supplies the feature, so the base theme does not need complete coverage.

## Source Selection

The current theme is the base of the mix. Each feature independently selects one of these sources:

1. the current theme;
2. another imported theme that actually supplies the feature;
3. the native system appearance, by disabling the feature.

The source list marks a theme as available only when it has real resources for that feature. If a source theme
is deleted, its Library revision changes, or the capability report is refreshed, Theme Details reprojects the
selection. An invalid source is never silently interpreted as a different theme.

Capabilities with configuration dependencies, including dynamic Calendar and Clock icons, resolve their required
resources together. Static App icons continue to select the best resource by App Bundle ID; mixing does not widen
the Runtime identity match.

## Feature Switches and Native Fallback

Each switch controls whether its feature enters the next Generation:

- enabled: the Compiler resolves and writes the feature from its selected source;
- disabled: the Compiler omits the feature and the Runtime returns the original system result for that surface;
- missing, damaged, or ABI-incompatible resources: only that feature falls back to native, without disabling other
  validated features.

Disabling a feature is not a preview-only change and does not leave its old resources active. Applying the mix
publishes a new Generation that explicitly omits that capability.

## Overlay Semantics

The icon overlay is independent and does not have to come from the same theme as App icons:

- disabling overlays omits overlay configuration and assets from the new Generation;
- changing the overlay source publishes only the newly selected source;
- a theme without overlay resources cannot be a valid overlay source;
- Runtime caches are bounded by the current Generation and resource identity, so disable, switch, and rollback
  cannot retain a stale overlay.

When both mask and overlay are enabled, composition remains “mask → overlay.” Overlays may independently cover
ordinary icons and folders, while still passing size, integrity, and target-surface validation.

## Persistence, Preview, and Application

Sources and switches are persisted per base theme. Editing Theme Details does not immediately rewrite the active
Runtime Store. After the user taps the bottom apply button, the Manager reads the current Library, compiles a
deterministic Generation, and publishes it atomically through the fixed Helper.

Compilation is cancellable and checks cancellation at feature boundaries. A failure cannot leave a partially
published Generation; active and previous Generations retain rollback and last-known-good semantics. A Respring
is required after application so target processes load the new Runtime image and Generation state.

## UI and Accessibility

- Home provides a lightweight Theme Details entry; it is completely hidden for the system default because there
  is no theme entity to open;
- Theme Details exposes explicit source selection regardless of whether the base theme has resources;
- sheets with a close button or an explicit Later action do not duplicate that affordance with a top grabber;
- visually compact entries still retain a minimum 44-point hit target and an independent actionable accessibility
  name.

