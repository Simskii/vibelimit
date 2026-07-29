# Vibelimit Design QA

## Evidence

- Source visual truth: `design-qa-assets/codexbar-reference.png`
- Focused source crop: `design-qa-assets/codexbar-reference-focus.png`
- Implementation screenshot: `design-qa-assets/vibelimit-redesign.png`
- Side-by-side comparison: `design-qa-assets/side-by-side.png`
- Source pixels: 716 × 1418; focused crop normalized to 344 × 312.
- Implementation pixels: 344 × 162 at the native 344-point panel width.
- Comparison viewport: native macOS menu-bar panel on the 3440 × 1440 desktop.
- Density normalization: the reference crop was resized to the implementation's
  344-pixel width. The implementation was captured at native 1× screenshot density.
- State: live Codex limits, one weekly window, connected, two reset credits.

## Full-view comparison evidence

The implementation keeps the reference's strongest hierarchy: provider and
freshness first, followed by named limit windows with a horizontal usage bar,
then percentage and reset time on one aligned row. Provider switching, costs,
status links, and settings rows are intentionally omitted because Vibelimit is
a single-provider read-only monitor.

Vibelimit retains its near-black surface, green remaining-capacity semantics,
rounded floating panel, and compact footprint. The resulting 344 × 162 panel is
substantially shorter than the multi-provider reference while preserving the
same scanning pattern.

## Focused comparison evidence

The side-by-side artifact shows both panels at the same width. Labels, bars,
percentages, reset countdowns, dividers, and footer controls remain readable, so
an additional crop is unnecessary.

- Fonts and typography: native SF text is used throughout. The 16-point provider
  heading, 12-point window heading, and 10-point metadata produce a clear
  three-level hierarchy without the previous tiny monospaced summary.
- Spacing and layout rhythm: 18-point horizontal padding, 13-point section
  spacing, 5-point bars, and a 38-point footer create a consistent compact rhythm.
- Colors and visual tokens: the existing dark surface and capacity colors are
  preserved. Secondary text opacity is intentionally restrained while all live
  limit values remain readable.
- Image quality and asset fidelity: neither the chosen reference region nor the
  implementation requires raster assets. Native SwiftUI shapes and SF Symbols
  are appropriate for these standard controls.
- Copy and content: each limit window has one title, one bar, one remaining value,
  and one reset countdown. Reset credits and actions remain in the footer.

## Interaction evidence

- The installed-style Debug app opened with live account data.
- The actions button exposed Refresh, Launch at Login, Notifications, and Quit.
- The panel resized to its live single-window content without animated movement.
- No controls were clipped or truncated in the captured state.

## Findings

No actionable P0, P1, or P2 differences remain. Differences from CodexBar's
provider tabs, light material, usage-as-used semantics, and additional rows are
intentional product-boundary choices.

## Comparison history

- Initial comparison: the redesigned implementation established the same
  provider → window → usage/reset hierarchy as the reference. No blocking visual
  mismatch was found.
- Build verification surfaced a redundant AppKit layout call. It was removed so
  data refreshes retain stable geometry without layout recursion.
- Post-fix evidence: the 344 × 162 live panel and actions menu were recaptured and
  inspected with no clipping, hierarchy, spacing, or interaction regression.

## Follow-up polish

- P3: Capture an additional two-window state if the API exposes primary and
  secondary Codex windows simultaneously.

## Implementation checklist

- [x] Remove the duplicated summary strip.
- [x] Add named limit sections with progress bars.
- [x] Align remaining capacity and reset countdown.
- [x] Reduce panel width from 380 to 344 points.
- [x] Keep reset credits and actions in a compact footer.
- [x] Verify the live panel and actions menu.

final result: passed
