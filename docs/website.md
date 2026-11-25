# Usage website

The static website is in `website/`. It uses HTML, CSS, and optional JavaScript
with no build step or runtime dependencies. Fonts are hosted locally in
`website/fonts/` with their OFL licenses.

## Local preview

From the repository root:

```sh
python3 -m http.server 8000 --directory website
```

Open `http://localhost:8000`. Cloudflare-specific headers in `_headers` are
applied by Pages, not by the Python preview server.

## Cloudflare Pages Git deployment

Create a **Pages** project connected to the repository and use:

- Production branch: `main`
- Root directory: `website`
- Build command: `exit 0`
- Build output directory: `.`

Pages publishes the contents of `website/` directly. Keep build configuration,
documentation, and other non-public files outside that directory. Attach
`usage.morovid.com` under the project's **Custom domains** settings.

The primary CTA links to GitHub Releases. Publish a signed and notarized DMG
there before announcing a download; a distributable release is not yet verified.

## Hero screenshot

The hero currently contains a responsive illustration labeled as an illustrative
preview. To replace it:

1. Add a screenshot as `website/images/usage-hero.webp` (roughly 2400 × 1400).
2. In `website/index.html`, replace the entire `.preview-stage` element with:

   ```html
   <img class="hero-image" src="/images/usage-hero.webp"
        width="2400" height="1400"
        alt="Usage showing multiple AI accounts in the macOS menu bar"
        fetchpriority="high">
   ```

3. Update the figure caption from “Illustrative preview” to “Usage on macOS”.
