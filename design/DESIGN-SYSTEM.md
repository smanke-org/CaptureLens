# SnagAnything design system

SnagAnything keeps Apple's look: system controls, system colors, the user's accent. The
tokens in `Sources/CaptureLens/UI/Tokens.swift` cover only what the system doesn't. Use them
instead of raw numbers, so one change here changes the whole app.

## Space

A 4-point grid: `xxs 2`, `xs 4`, `sm 8`, `md 12`, `lg 16`, `xl 20`, `xxl 24`, `section 32`.

- Related controls sit `sm` apart; groups `xl`–`xxl`; sections `section`.
- Bars and strips pad `md` across and `sm` up and down.
- Raw numbers are 0, 1, 2 or a multiple of 4. Older views still have a few others; move
  them to a token when you touch them.

## Radius

`xs 4` thumbnails' pictures · `sm 6` chips, key caps, labels over pictures ·
`control 8` buttons, selection fills, rail icons · `card 12` grouped boxes, bars ·
`panel 16` a floating panel with controls 8 pt in.

- Nested corners are concentric: inner = outer − the padding between them (the capture
  bar is `card` with 4 pt padding, so its segments are `control`).
- Image edits (a capture's border corners) are data, not UI; they don't use these.

## Motion

`Motion.quick` hovers and presses · `Motion.fold` lists folding · `Motion.ui` panes and
panels moving.

- Every animation goes through `Motion`, so Reduce Motion turns them all off.
- Search results, filters and selection don't animate. Speed wins.
- Never animate a view's first layout.

## Surfaces

- `Surfaces.canvas`: behind the picture being viewed or marked up, and behind the tool strip.
  Mid gray in Light mode so a white capture's edges show; the system's under-page gray in Dark.
- `Surfaces.shadow(_:)`: the picture's shadow on the canvas.
- Everything else uses system colors: `.primary`, `.secondary`, `.tertiary`, `.bar`, the
  accent through `.tint` or `Color.accentColor`. Never a fixed white, black or gray in chrome;
  text over pictures sits on a dark scrim.

## Liquid Glass

- Glass is for controls floating over content: the tool strip, the dial and its bar, the
  zoom buttons, the capture bar and its labels. Content (thumbnails, the picture) gets none.
- Never glass on glass. A glass view made once keeps its look, so give it an `.id` that
  changes with the appearance it follows (the capture bar's Light/Dark setting).
- Tint only to carry meaning: red for recording.

## Library layout

- Grid beside the picture by default. While Markup is on with one picture selected, the
  picture fills the width and the captures become a filmstrip under it.
- The picture keeps one place in the view tree in every layout (`CaptureDetail` is always the
  same child): moving it rebuilds the canvas, which reloads its capture into the editor.
- Toolbar items sit over the column they act on; every toolbar button also has a menu item.

## Rules

- Style controls with `ButtonStyle` and `ToggleStyle`; never rebuild one from shapes.
- One prominent button per panel (Record is red, `.borderedProminent`).
- Text is 10 pt or more. Shortcut letters go in tooltips and menus, not on buttons.
- Long text truncates with its full value in a tooltip.
