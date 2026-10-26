# Annotations

Flutter Web reader for public Asodya and Wilson Borba study notes. It provides a
Notion-inspired landing page, topic/search/channel discovery, available article
translations, light/dark themes, English/Portuguese/Thai interface labels, waitlist
registration and temporary browser sharing. The font is self-hosted Ubuntu Sans
with Thai fallback. Selected Asodya illustrations and branding are local assets.

Publishing and private JSON operations belong to the API. There is no frontend
editor, administrative dashboard, login requirement for public reading, comments
or automatic translation. Article language and interface language are independent.
An author can distribute the same post through multiple channels.

## Development and verification

Run `flutter pub get`, `flutter analyze` and `flutter test`. To use the isolated
backend, run `cargo run --example browser_fixture` in the sibling `annotations_api`
repository, then explicitly populate its localhost API with `scripts/populate_demo.py`.
Build this frontend with:

```
API_BASE_URL=http://127.0.0.1:18111 scripts/build_cloudflare.sh
```

Serve `build/web` with an SPA fallback to `index.html` for browser checks. Production
builds default to the central gateway and set `DEVELOPMENT_MODE=false`. They include
an explicit Bangkok build timestamp in the footer. To verify initial HTML metadata,
run `node test/web/share_worker_test.mjs` with an available Node runtime.

## Routes and media

- `/v1/home`: landing, recent articles and informational waitlist.
- `/v1/menu?q=&topic=&channel=`: searchable public catalog.
- `/v1/menu/{channel}/{slug}?lang={available-language}`: one public translation.
- `/v1/instant` and `/v1/instant/{code}`: public temporary exchange across browsers.

The reader supports source/provider cards, external PDF links, images, YouTube and
individual Reports embeds. Charts/tables remain rendered by Reports. The client
only renders server data and server validation errors; it does not grant publishing
permissions or own content validation/quota/expiry rules.

Rooms use a fixed 15-minute lifetime from creation. Anyone with the code can read
and edit during that interval. Upload progress is the browser's actual transfer
progress; a separate saving state remains until the server acknowledges storage.
The server enforces 50,000,000 bytes per file and per active uploader IP. Polling
keeps two browsers updated. Errors, stale edits and expiry remain visible. Files
are downloaded through expiry-checked service URLs, not permanent storage links.

## Cloudflare Pages

Run `scripts/deploy_cloudflare.sh`. It follows the existing Asodya Pages API upload
protocol, loads credentials through the established workspace helper, attaches the
Pages advanced-mode worker, and configures `annotations.asodya.com`. No credentials
are included in browser assets. `_worker.js` is uploaded as a worker, not a public
static file. It derives article metadata from the public API only, escapes HTML,
preserves content language and returns generic metadata for unavailable/private
posts. The deployer requires the sibling `domain` or `certifications` deployment
helper and the existing local Cloudflare credential configuration.

## Telemetry

The pinned `asodya_tracking` package sends errors and mapped usage to separate
SQL-backed gateway routes. `tracking_manifest.json` lists screens, actions,
labels, tree paths and descriptions. The matching Dart constants live in
`lib/core/tracking_manifest.dart`.

Navigation uses the router observer and concrete-route listener. The root listener
records mapped clicks and scrolling. Existing field controllers supply typed input.
Form callbacks record submits. No control layout or authentication flow changes.
Instant Share capability values and room path tokens are excluded on the device.
Existing consent remains in place. Tests inject fake transports and disable periodic
network delivery. The API adapter also reports handled service failures.
