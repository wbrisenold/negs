# Negs UX source of truth

## What counts as truth

There is no single layout recipe that is correct for every product or every photographer. Use this evidence hierarchy when making UX decisions:

1. **Observed task success with intended users** is the product-specific evidence. Give people realistic work to do, observe where they hesitate or make errors, revise, and repeat.
2. **Human-centred design and usability standards** set the process and outcome vocabulary. ISO 9241-210 is the current human-centred design standard; ISO 9241-11 defines usability as outcomes in a specified context of use, considered through effectiveness, efficiency, and satisfaction.
3. **Current macOS Human Interface Guidelines** decide platform conventions for windows, navigation, toolbars, input, and customization.
4. **Interaction heuristics and accessibility guidance** are design checks that help find likely problems. They do not replace testing with people doing real work.

Treat this as a working design standard, not a claim of ISO conformance. Record the task, user context, evidence, decision, and follow-up result for substantial changes.

## Research findings that apply across product types

- **Design around real goals and context.** ISO 9241-210 covers human-centred design throughout the life cycle of interactive systems, including desktop software, websites, and consumer products. ISO 9241-11 makes usability an outcome of use, rather than a property inferred from a clean-looking screen.
- **Make the current state and next action legible.** Nielsen Norman Group's established heuristics include visibility of system status, match to users' language, user control and freedom, consistency, error prevention, recognition over recall, and a focused visual hierarchy. Apply these as a review checklist, then verify the actual tasks.
- **Use Mac space for the work.** Apple's current macOS guidance describes the platform as suited to in-depth work on large, high-resolution displays. It recommends fewer nested levels, comfortable information density, resizable and hideable views, keyboard support, precision input, and personalization.
- **Put controls where their role is recognizable.** Apple's toolbar guidance distinguishes navigation, view title, and frequent actions; groups controls by purpose; and warns against overcrowding. A toolbar is for useful navigation and commands, not an unstructured cluster of unrelated controls.
- **Use a sidebar for navigation, an inspector for details.** Apple's guidance says a sidebar navigates between app areas or collections and consumes substantial width. The macOS window guidance places detailed information in a trailing inspector. Those roles should stay visually and behaviorally distinct.
- **Support more than one way to act.** Keyboard and pointer workflows both matter on Mac. For web surfaces, WCAG 2.2 sets a 24-by-24 CSS-pixel minimum target criterion with exceptions; that is not a macOS AppKit sizing rule, but it is a useful accessibility warning against tiny, crowded targets.
- **Evaluate the right thing with the right method.** Qualitative usability sessions reveal breakdowns and their causes; task success, time, errors, and satisfaction can measure change. NN/g recommends iterative testing with representative users and realistic tasks; its guidance says five users are often enough for qualitative issue-finding, while quantitative estimates require substantially larger samples. AI or expert review can help prioritize, but should not be presented as observed user evidence.

## What the supplied Develop screenshot tells us

This is direct product evidence from the user's screenshot, not a generalized design rule:

- The Library/Develop switch floats at the top center and does not read like a clear return/navigation affordance.
- Film and paper choices sit below the image, visually detached from the controls that change the image.
- The trailing inspector takes a large share of the window and stacks a histogram, tool tabs, and many adjustments into a dense column.
- The image, its identity, its stock choices, and its editing controls do not read as one coherent editing workspace.

The screenshot also shows a long editing session with a real photo and actual parameter values, so prioritize a stable canvas, clear location, and short paths for common edits over decorative chrome.

## Proposed Negs Develop design direction

Use this as the implementation brief for the next UI pass:

1. **Top frame:** move Library/Develop navigation to the leading side of a standard, compact macOS toolbar, grouped with navigation. Keep the current image/context title nearby and high-frequency actions, such as Export and inspector visibility, on the trailing side. Do not let the app name compete with the content title.
2. **Canvas header:** place Film and Paper selectors together in a compact, clearly labeled row immediately above the photo. Keep them adjacent because choosing the pair defines the rendering recipe; avoid placing them under the image where they look like metadata or a footer.
3. **Canvas:** make the photograph the dominant flexible area. Keep the filmstrip/status at the bottom secondary, with its existing hide/show behavior available. Preserve the photo's orientation, fit, zoom, compare, and original-view controls.
4. **Inspector:** keep it trailing, but reduce its default width and visual weight. Use a clear hierarchy: a compact scope/clip readout, then grouped adjustment areas with progressive disclosure. Keep controls available by scroll and keyboard; do not delete tools to make the panel look smaller. Keep hide/show discoverable and preserve the current shortcut.
5. **Responsive behavior:** at narrower window sizes, collapse secondary panels before squeezing the photograph and slider targets. Persist user resizing and visibility. At full-screen or image-only, retain a reliable way back to the editing workspace.

These are hypotheses inferred from the screenshot, macOS conventions, and the actual task structure. Validate them against tasks such as: open a photo from Library, choose a film/paper pair, correct exposure, identify clipped highlights, sharpen detail without amplifying grain, compare against the original, and export.

## Release criteria for future UX revisions

Before calling a redesign successful, observe representative users attempt the tasks above without coaching. Record completion, time, mis-clicks/backtracking, errors, and a short ease rating per task. Compare the revised layout with the current one. Also inspect at the user's normal window size and a narrower window, and check keyboard-only navigation, VoiceOver labels, focus visibility, and whether controls remain reachable when panels are hidden.

## Sources

- ISO, [9241-210:2019 Human-centred design for interactive systems](https://www.iso.org/standard/77520.html). ISO says it was reviewed and confirmed in 2025 and remains current.
- ISO, [9241-11:2018 Usability: Definitions and concepts](https://www.iso.org/standard/63500.html). Current edition as confirmed by ISO in 2023.
- Apple, [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos) (current HIG, updated October 28, 2026).
- Apple, [Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars), [Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars), and [Windows](https://developer.apple.com/design/human-interface-guidelines/windows).
- Nielsen Norman Group, [10 Usability Heuristics for User Interface Design](https://www.nngroup.com/articles/ten-usability-heuristics/) and [Usability 101: Introduction to Usability](https://www.nngroup.com/articles/usability-101-introduction-to-usability/).
- W3C, [Web Content Accessibility Guidelines (WCAG) 2.2](https://www.w3.org/TR/WCAG22/), especially Success Criterion 2.5.8 (web target size; cited here as an accessibility reference, not a native macOS requirement).
- Fitts, P. M. (1954), [The information capacity of the human motor system in controlling the amplitude of movement](https://www2.psychology.uiowa.edu/faculty/mordkoff/InfoProc/pdfs/Fitts%201954.pdf), *Journal of Experimental Psychology*, 47(6), 381–391. Foundational pointing research; use it to motivate generous, well-spaced pointer targets, not to claim one magic button size.

## Sharpening implementation reference

Negs' scanner sharpening uses a Gaussian unsharp mask with radius, amount, and a soft threshold: blur the scan, measure the high-pass difference, discard differences below the threshold, and add the remaining detail back. This follows the same established control model documented in darktable's open-source [sharpen module](https://github.com/darktable-org/darktable/blob/master/src/iop/sharpen.c). The current Negs implementation is its own Rust/WGSL/CUDA pipeline; it does not copy darktable source. The darktable module is GPL-3.0-or-later, while the module's source is useful as an inspectable reference for Gaussian radius, amount, threshold, border handling, and preview scaling.

The amount, radius, and noise-threshold controls are grouped in a dedicated **Sharpening** panel. The threshold suppresses small high-pass differences, which can reduce noise amplification; it cannot distinguish every real fine texture from noise. Compare at 100% before settling on a value.
