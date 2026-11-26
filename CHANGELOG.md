## [unreleased]

### 🚀 Features

- *(telemetry)* Adopt shared tracking with mapped Annotations controls
- *(core)* Add platform profiles and feature availability
- *(core)* Share settings, logs, screen_trail tracking and client errors
- *(domain)* Add lossless versioned note document models (#19)
- *(domain)* Add offline editor placement rules with shared rule fixtures (#20)
- *(domain)* Add one Notes command history with 100 steps and no history in Instant (#21)
- *(domain)* Add the ink model with four brushes, editable nodes, shapes and partial erasing (#22)
- *(editor)* Pin flutter_quill 11.5.0 behind the Annotations text adapter (#23)
- *(domain)* Add the selection and clipboard model for blocks, ink and groups (#24)
- *(dal)* Add the durable local note store with managed attachments and crash recovery (#25)
- *(ui)* Build the Annotations design system with tokens, typography, Spectrum 2 icons and solid surfaces (#18)
- *(canvas)* Build the long paper canvas with zoom and pan, paper backgrounds, hover borders and honest save states (#26)
- *(ui)* Add typed text blocks with the text tools and the type C limit feedback (#27)
- *(ui)* Add Type and Draw modes, the four pens, tool settings and shapes (#28)
- *(ui)* Add Figma-style point and curve editing for drawings and shapes (#29)
- *(ui)* Add the normal and dangerous erasers with live erasing (#30)
- *(ui)* Add the toolbar icons from Spectrum 2 (#31)
- *(ui)* Add the toolbar with docking, floating, collapse and contextual controls (#31)
- *(domain)* Compact samples, item-row autosave and sync operations (#19)
- *(ui)* Selection, move, resize, grouping, clipboard and the Undo notice (#32)
- *(ui)* View lock, finger settings and Focus (#33)
- *(ui)* Attachments and cards for pictures, files, links, websites, YouTube, CSV and PDF (#34)
- *(ui)* Simple typed editor for phones and read-only notes (#35)
- *(domain)* Add manual private sync, publication, deletion scopes, projects/tags, and backup (#37)
- *(dal)* Add public discovery, reader and synced notes adapters (#39)
- *(domain)* Add PDF export mapper for Original and Typed with B13 print rules (#41)
- *(dal)* Add Instant room adapter with revisions, sharing states and expiry (#43)
- *(domain)* Add transcription drafts, typed ordering, and changed-part updates (#46)
- *(dal)* Add optional Cortex content-job adapter with resume (#47)
- *(dal)* Add task card adapter for /me/tasks (#50)
- *(dal)* Add FINAL native handoff sign-in and secure session storage (#36)
- *(ui)* Build the v2 landing pages (#53)
- *(ui)* Add the 43 landing images with their licence manifest (#53)
- *(ui)* Redesign the landing pages after the owner's design review (#53)
- *(#41)* Wire krilla + icu_segmenter PDF backend via FFI and wasm32
- *(#41)* Rename pdf_krilla, add build_pdf_krilla.sh, wire macOS/iOS, remove tracked wasm
- *(domain)* Share Instant room edits per item, with room operations for groups and the page (#44)
- *(domain)* The editor saves through a port; an Instant room shares through it (#44)
- *(domain)* Instant room files for the editor (#44)
- *(ui)* The Instant room page with the shared editor (#44)
- *(ui)* Simple typed controls for an Instant room on phones (#44)
- *(44)* Add QR sharing for active rooms
- Add Reports embed data adapters
- *(reports)* Merge authorized embed adapters (#49)
- *(ui)* Browser account menu, sign-in flow and My notes, work in progress (#38)
- *(ui)* Installed intro, writer workspace and note editor route, work in progress (#38)
- *(ui)* Installed sign-in with the native handoff and match code (#38)
- *(ui)* Sync, publish, unpublish and delete everywhere in the writer workspace (#38)
- *(ui)* Projects and tags for a note from the workspace menu (#38)
- *(ui)* Public browsing, author and project pages and the reader, work in progress (#40)
- *(64)* Link landing notes to public reader
- *(65)* Add local expandable QR sharing
- Reuse canonical QR share control in Instant rooms
- Add Certifications browser continuation adapter
- *(notes)* Prepare and resume selected quiz sources
- *(instant)* Integrate reviewed room editor and sharing fixes (#44)

### 🐛 Bug Fixes

- *(local)* Set the installed app identifier to com.asodya.annotations
- *(local)* Show Annotations as the installed app name
- *(changelog)* Restore released sections after regeneration
- *(privacy)* Exclude Instant content from tracking and error reports (#17)
- *(editor)* Resolve the text engine font family to the package fonts (#59)
- *(ui)* Keep the space limit message readable over short text blocks (#27)
- *(domain)* Place structured blocks on the invisible grid and allow CSV and PDF cards in Instant (#20)
- *(ui)* Make ink transparent in Type mode and give text the pen palette (#27, #60)
- *(ui)* Add the explicit Apply pen style action for selected strokes (#28)
- *(domain)* Erase part of a shape in partial mode (#22)
- *(domain)* Copy text and pictures together and duplicate to the first free place (#24)
- *(ui)* Hide the eraser line choice while Delete anything is on (#30)
- *(shell)* Give each page its own scroll view (#58)
- *(annotations#37)* Align sync, publication, conflict, deletion, and catalog with annotations_api
- *(annotations#39)* Parse real annotations_api public discovery and reader shapes
- *(annotations#43)* Align InstantRoomService routes and 409/upload shapes with annotations_api
- *(annotations#46)* Persist transcription drafts and write accepted Typed note into LocalNoteStore
- *(annotations#47)* Align content job client_job_id, kind, SSE ?after/Last-Event-ID, and /me/files upload
- *(annotations#50)* Use status open/completed and persist task_card reference in LocalNoteStore
- *(ui)* Show the first page in the PDF card with pdfrx (#34)
- *(annotations#36)* Map api_for_apps data.code, add OS secure storage handlers, and wire log/telemetry redaction
- *(annotations#36)* Extract pure-Dart log redactor so local_store_writer runs without dart:ui
- *(annotations#37,#43,#47)* Align request bodies with annotations_api and add strict contract fake
- *(ui)* Replace three landing images with text or symbol problems (#53)
- *(ui)* Use escapes instead of dash characters in the landing code (#53)
- *(pdf)* Honour CARGO_TARGET_DIR in scripts/build_pdf_krilla.sh (#41)
- *(pdf)* Build both x86_64 and arm64 iOS simulator slices via lipo (#41)
- *(krilla)* Pass fresh-worktree analyze and test gates (#41)
- *(sync)* Persist server note identity and revisions for cloud calls (#63)
- *(sync)* Isolate conflict copies and require revision ids (#63)
- *(ui)* A shared change to the open text block closes it (#44)
- Enforce Reports reference and cache identity
- *(66)* Retain typed body focus across rebuilds
- *(editor)* Merge retained phone body focus (#66)
- *(ui)* The installed login says when it cannot start (#38)
- *(ui)* Installed login messages in the interface language (#38)
- Retry publication for local notes
- *(workspace)* Isolate notes by verified account
- *(auth)* Guard installed session checks against replacement
- *(web)* Keep native device store out of bundle
- Prevent narrow app bar overflow
- Prevent app bar overflow across viewport widths
- Scale wide navigation cutoff with text size
- *(ui)* Reader and browse use the app icons; the typed page lines up with its title (#40)
- *(ui)* Resolve #40 project author lookup, transient error retry, and restricted card guard
- *(40)* Sync browse query with route
- Remove unused QR component import
- Use public QR origin in native development
- Guard instant room lifecycle and page conflicts
- *(notes)* Parse study detail and stop stale prepare flows
- Stop room file selection when disconnected
- Close instant room failure and edit gates
- Report disabled room edits as editor rejections

### 💼 Other

- Back-merge v1.1.0 into feature/main
- Add mapped frontend telemetry (#13)
- Align Annotations shared tracking revision (#13)
- Replace asodya_tracking with screen_trail (#14)
- Split the app into a Dart workspace (#15)
- Record the workspace split in the changelog (#15)
- Set the installed app identifier (#15)
- Show Annotations as the installed app name (#15)
- Add platform profiles and feature availability (#16)
- Record platform profiles in the changelog (#16)
- Restore the released changelog sections (#16)
- Share settings, logs, tracking and client errors (#17)
- Exclude Instant content from telemetry (#17)
- Add lossless note document models (#19)
- Add offline editor placement rules (#20)
- Add one Notes command history (#21)
- Add the ink model (#22)
- Pin the text engine behind the Annotations adapter (#23)
- Add the selection and clipboard model (#24)
- Add the durable local note store (#25)
- Add the Annotations design system (#18)
- Add the paper canvas (#26)
- Resolve the text engine font family (#59)
- Add typed text blocks (#27)
- Keep the space limit message readable (#27)
- Add Type and Draw modes and the pens (#28)
- Place structured blocks on the invisible grid and allow CSV and PDF cards in Instant (#20)
- Make ink transparent in Type mode and give text the pen palette (#27, #60)
- Add the explicit Apply pen style action for selected strokes (#28)
- Erase part of a shape in partial mode (#22)
- Copy text and pictures together and duplicate to the first free place (#24)
- Add point and curve editing for drawings and shapes (#29)
- Add the normal and dangerous erasers with live erasing (#30)
- *(ui)* Toolbar with docking, collapse, More and contextual controls (#31)
- *(ui)* Toolbar tests, touch selection, narrow layout (#31)
- Add the editor toolbar (#31)
- Hide the eraser line choice while Delete anything is on (#30)
- *(domain)* Compact stroke samples in the app (#19)
- Compact samples, larger notes, item-row autosave and sync operations (#19)
- Check only the changed items of each edit (#62)
- *(ui)* Selection gestures, move, resize and object actions (#32)
- Selection, move, resize, grouping, clipboard and the Undo notice (#32)
- *(ui)* View lock, finger settings and Focus (#33)
- View lock, finger settings and Focus (#33)
- *(ui)* Card layouts, attachment cache and attachment handler (#34)
- *(ui)* Attachments wiring, drop, paste, card menu (#34)
- Attachments and cards (#34)
- Give each shell page its own scroll view (#58)
- *(ui)* Phone typed editor and read-only notes (#35)
- Phone typed editor and read-only notes (#35)
- *(ui)* Try pdfrx for the PDF card page (#34)
- PDF card shows the first page (#34)
- *(#41)* Option B krilla 0.7.0 + icu_segmenter 2.4.0 Thai PDF spike
- Annotations#63 account isolation and revision fixes
- Integrate verified-account workspace and session guards (#38)
- Compact language switch for narrow app bar
- Accept reviewed responsive navigation and locale coverage
- Add readable public note and room QR sharing controls (#65)

### 🚜 Refactor

- *(workspace)* Split the app into apps/cloud, apps/local and common/annotations_shared
- *(ui)* One join link for the Instant room (#44)

### 📚 Documentation

- *(changelog)* Record frontend telemetry adoption
- *(changelog)* Record the shared tracking revision alignment
- *(changelog)* Record the workspace split
- *(changelog)* Record platform profiles
- *(changelog)* Record shared settings, logs and tracking
- *(changelog)* Record Instant telemetry privacy correction
- *(changelog)* Record versioned note document models
- *(changelog)* Record offline editor placement rules
- *(changelog)* Record the Notes command history
- *(changelog)* Record the ink model
- *(changelog)* Record the text engine adapter
- *(changelog)* Record the selection and clipboard model
- *(changelog)* Record the durable local note store
- *(changelog)* Record the Annotations design system
- *(changelog)* Record the paper canvas
- *(changelog)* Record the text engine font fix
- *(changelog)* Record typed text blocks
- *(changelog)* Record Type and Draw modes and the pens
- *(changelog)* Record Reports embed adapters (#49)
- *(changelog)* Record retained phone input focus (#66)
- *(changelog)* Record installed workspace and verified session isolation
- *(changelog)* Record browser storage build fix (#69)

### ⚡ Performance

- *(editor)* Check only the changed items of each edit (#62)

### 🎨 Styling

- Format integrated writer shell

### 🧪 Testing

- *(ui)* Selection gestures, move, resize, actions and the Undo notice (#32)
- *(annotations#41)* Split PDF export tests per scope item and verify redaction with pdftotext + image XObject check
- *(ui)* Signed-in state everywhere, dead session and My notes tests (#38)
- *(ui)* The fake gateway answers 401 on /me without a session (#38)
- *(ui)* Installed intro and writer workspace tests (#38)
- *(ui)* Installed sign-in, match code, Finish, dead session and Fernet reference (#38)
- *(auth)* Initialize preferences for integrated sign-out checks
- Cover annotations toolbar breakpoints
- Update wide navigation boundary expectations
- *(ui)* Browsing, author and project pages, reader views and locks (#40)
- *(64)* Expect legacy article not found
- Scope QR dialog label assertion
- Cover stale prepared handoff cancellation
- Make prepared editor race fixtures explicit

### ⚙️ Miscellaneous Tasks

- *(test)* Format contract files and fix backend references/content_jobs text rule
- *(changelog)* Record public reader and QR sharing
- *(changelog)* Record prepared quiz handoff

## [1.1.0] - 2026-10-26

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
- Promote v1.1.0

### 🧪 Testing

- Cover waitlist error, empty and failing catalog, and preview fallback (#10)
- Merge acceptance state coverage (#10)

### ⚙️ Miscellaneous Tasks

- *(release)* V1.1.0
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
- *(release)* Document Annotations v1.0.0
