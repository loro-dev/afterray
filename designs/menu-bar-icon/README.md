# AfterRay menu bar icon

The menu bar mark is a small-size redraw of the app icon, not a scaled copy.
One ray is shown at two moments: the present path enters from the lower left;
its afterimage exits at the upper right. Both wrap around a circular negative
space, preserving the app icon's gravitational-lensing motion without its
color, bloom, texture, or filled background.

## Construction

- Canvas: 18 × 18 pt
- Mark: two rotationally balanced cubic paths around a 7.4 pt negative core
- Ray: 1.55 pt stroke with round caps and joins
- Afterimage: the opposing path uses 58% alpha within the same template mask
- Safe margin: 1.35 pt at the ray tips
- Rendering: monochrome template image; AppKit supplies light/dark/highlight colors
- Paused state: the same mark at 46% opacity

`afterray-menubar-template.svg` is the portable vector reference. The app draws
the same paths with AppKit in `AfterRayMenuBarIcon.swift`, so the development
bundle does not need another copied resource.
