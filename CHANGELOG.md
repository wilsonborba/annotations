## [unreleased]

### 🚀 Features

- *(telemetry)* Adopt shared tracking with mapped Annotations controls
- *(core)* Add platform profiles and feature availability

### 🐛 Bug Fixes

- *(local)* Set the installed app identifier to com.asodya.annotations
- *(local)* Show Annotations as the installed app name

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

### 🚜 Refactor

- *(workspace)* Split the app into apps/cloud, apps/local and common/annotations_shared

### 📚 Documentation

- *(changelog)* Record frontend telemetry adoption
- *(changelog)* Record the shared tracking revision alignment
- *(changelog)* Record the workspace split
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
