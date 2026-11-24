## [unreleased]

### 🚀 Features

- Add Reports embed data adapters

- *(telemetry)* Adopt shared tracking with mapped Annotations controls
- *(core)* Add platform profiles and feature availability
- *(core)* Share settings, logs, screen_trail tracking and client errors
- *(domain)* Add lossless versioned note document models (#19)
- *(domain)* Add offline editor placement rules with shared rule fixtures (#20)
- *(domain)* Place structured blocks on the invisible 8-unit grid, snap moves, resizes, pastes and new text blocks to it, and allow CSV tables and PDF previews in Instant (#20)
- *(domain)* Add one Notes command history with 100 steps and no history in Instant (#21)
- *(domain)* Add the ink model with four versioned brushes, editable nodes, shapes and partial erasing (#22)
- *(domain)* Erase part of a shape in partial mode: the untouched outline stays as editable open paths (#22)
- *(editor)* Pin flutter_quill 11.5.0 behind the Annotations text adapter with the type C guard and the one Notes history (#23)
- *(domain)* Add the selection and clipboard model for blocks, ink and groups (#24)
- *(domain)* Copy text and pictures to other apps as one clipboard item, render several pictures as laid out, and duplicate to the first free grid place below (#24)
- *(dal)* Add the durable local note store with managed attachments, autosave states and crash recovery (#25)
- *(ui)* Build the Annotations design system with tokens, typography, Spectrum 2 icons and solid surfaces (#18)
- *(canvas)* Build the long paper canvas with zoom and pan, paper backgrounds, hover borders and honest save states (#26)
- *(ui)* Add typed text blocks with the text tools and the type C limit feedback (#27)
- *(ui)* Make ink transparent to input in Type mode, offer the pen palette and a custom color for text, and play the space-limit shake also with reduced motion (#27, #60)
- *(ui)* Add Type and Draw modes, the four pens with remembered settings, color choices with a custom picker, and shapes with Edit as path (#28)
- *(ui)* Add Edit points: drag points and curve handles, add, remove, corner, smooth and handle modes, with buttons and keys, one Undo step per change (#29)
- *(ui)* Add the eraser: live partial and whole-line erasing of drawings, the pen eraser end, and the red Delete anything mode that removes whole objects and turns off when the eraser is left (#30)
- *(ui)* Hide the eraser line choice while Delete anything is on and bring back the previous choice after (#30)
- *(ui)* Add the editor toolbar: dock at any edge or float with a move handle and a position menu, contextual tools, collapse with the active tool and the Delete anything mark, a More menu on narrow screens, Notes Undo and Redo, placement kept on the device, keyboard avoidance and long-press names on touch (#31)
- *(ui)* Add selection, move and resize with the proposed place and red rejected drops, box, lasso and touch selection, group, ungroup, copy, cut, paste, duplicate and delete with shortcuts and a touch menu, arrow and size controls, and the Undo notice (#32)
- *(ui)* Add the corner view lock for every input kind, the finger navigation and finger drawing settings, and Focus with Exit Focus (#33)
- *(ui)* Add pictures, files, links, websites, YouTube, CSV tables and PDF previews as cards from the file picker, paste and drag and drop, with copy progress, Retry and Cancel, and the card actions (#34)
- *(ui)* Add the simple typed editor for phones and open every other note read-only there without changing it (#35)
- *(ui)* Add the explicit Apply pen style action that reshapes only the selected strokes in one step (#28)
- *(domain)* Store stroke samples as compact varint columns, allow 50,000 items and 64 MB per note, autosave only changed items and build sync operations against the base revision (#19)
- *(domain)* Check only the changed items of each edit, Undo and Redo included, so a stroke on a 30-page note takes a few milliseconds (#62)

### 🐛 Bug Fixes

- Enforce Reports reference and cache identity

- *(sync)* Persist server note identity and revisions for cloud calls (#63)
- *(sync)* Isolate conflict copies and require revision ids (#63)
- *(privacy)* Exclude Instant content from tracking and error reports (#17)
- *(editor)* Resolve the text engine font family to the package fonts so notes use Ubuntu Sans with the Thai fallback (#59)
- *(shell)* Give each page its own scroll view so a route transition never overflows the outgoing page (#58)

### 💼 Other

- Back-merge v1.1.0 into feature/main
- Add mapped frontend telemetry (#13)
- Split the app into a Dart workspace (#15)
- Add platform profiles and feature availability (#16)
- Share settings, logs, tracking and client errors (#17)

### 🚜 Refactor

- *(workspace)* Split the app into apps/cloud, apps/local and common/annotations_shared

### 📚 Documentation

- *(changelog)* Record frontend telemetry adoption
- *(changelog)* Record platform profiles
- *(changelog)* Record shared settings, logs and tracking

## [1.1.0] - 2026-10-27

### 🚀 Features

- Remove Instant Share items, paper writing sheet and shell polish (#11)
- Merge Instant Share removal and shell polish (#11)

### 🐛 Bug Fixes

- Use Workers-compatible redirect mode for share metadata (#7)
- Merge Workers-compatible share metadata fetch (#7)
- Top bar language switcher, content language dropdown and linked author (#12)
- Merge language controls and linked author (#12)
- Full-width author section divider (#12)
- Merge author divider width (#12)
- Show a not-found state for missing or private notes (#2)
- Merge not-found state (#2)

### 💼 Other

- Promote release/v1.0.0 to development
- Promote feature/main to development for v1.1.0

### 🧪 Testing

- Cover waitlist error, empty and failing catalog, and preview fallback (#10)
- Merge acceptance state coverage (#10)

## [1.0.0] - 2026-10-26

### 🚀 Features

- Add Asodya Flutter shell and independent locale preferences (#2)
- Merge public frontend shell (#2)
- Build public landing and persistent waitlist feedback (#3)
- Merge landing and waitlist (#3)
- Browse public notes by query, topic and publication (#4)
- Merge public catalog (#4)
- Render default articles and independent content translations (#5)
- Merge translated article reader (#5)
- Render provider cards and individual report frames (#6)
- Merge media and embed rendering (#6)
- Add anonymous temporary sharing rooms (#8)
- Merge temporary room interface (#8)
- Add branded release builds and Pages deployment (#9)
- Merge Cloudflare deployment workflow (#9)
- Render public article metadata for shared links (#7)
- Merge article sharing metadata (#7)
- Merge public site delivery verification (#10)

### 🧪 Testing

- Verify responsive reading and temporary browser exchange (#10)

### ⚙️ Miscellaneous Tasks

- Initialise repository root
- Add project baseline and ignore local context (#1)
- Merge repository bootstrap (#1)
