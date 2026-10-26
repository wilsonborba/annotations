# Annotations

Annotations is the Asodya public notes and article reader, built for Flutter Web.
It presents multilingual publications, topic search, external media and individual
Reports embeds. A separate temporary sharing view exchanges text, links and files
between browsers.

## Status

This repository currently contains the project baseline. Application implementation
is tracked in the [milestones](https://github.com/wilsonborba/annotations/milestones).
There is no runnable frontend or deployed Annotations site yet.

## Architecture

The application separates configuration (`core`), data access (`dal`), domain services
and presentation. Frontend components, interaction handlers, responsive screens and
selected assets belong in `lib/presentation/frontend/`.

The [Annotations API](https://github.com/wilsonborba/annotations_api) supplies content
and owns business validation. Public reading requires no login. Permanent publishing
is API-only in the first release.

## Development

Flutter setup, verification and Cloudflare Pages delivery are specified in the linked
implementation issues. Setup and usage commands will be added when their targets exist.
