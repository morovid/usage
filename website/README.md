# Usage website

Mobile-first static HTML, CSS, and a little optional JavaScript. No build step,
framework, analytics, or runtime dependencies. DM Sans, Space Grotesk, and IBM
Plex Mono are self-hosted in `public/fonts/` with their OFL licenses; system
fallbacks work when fonts are unavailable.

## Local preview

Requires a current Node.js LTS release.

```sh
cd website
npm install
npm run dev
```

Open the localhost URL printed by Wrangler.

## Deploy to Cloudflare Pages

```sh
cd website
npm install
npx wrangler login
# First deployment only: create the Pages project.
npx wrangler pages project create usage --production-branch main
npm run deploy
```

Wrangler prints the deployment URL. If `usage` is already taken in your account,
choose another project name and update `wrangler.jsonc` and the deploy script in
`package.json`. The deploy script explicitly targets the production branch
`main`, so it also works from a local feature branch.

For CI, provide `CLOUDFLARE_API_TOKEN` (Cloudflare Pages edit permission) and
`CLOUDFLARE_ACCOUNT_ID` as secrets instead of running `wrangler login`.
Never commit these values.

For optional Cloudflare Git integration: set the root directory to `website`,
leave the build command empty, and set the output directory to `public`.
Custom domains can be attached in the Pages project's **Custom domains** settings.

## Hero screenshot

The large hero area currently contains a responsive HTML illustration, explicitly
labeled as an illustrative preview. It reserves space for the real app screenshot
without a broken or empty image.

1. Add your screenshot as `public/images/usage-hero.webp` (roughly 2400 × 1400).
2. In `public/index.html`, replace the entire `.preview-stage` element with:

   ```html
   <img class="hero-image" src="/images/usage-hero.webp"
        width="2400" height="1400"
        alt="Usage showing multiple AI accounts in the macOS menu bar"
        fetchpriority="high">
   ```

3. Update the figure caption from “Illustrative preview” to “Usage on macOS”.

The primary CTA links to GitHub Releases. Publish a signed and notarized DMG
there before announcing a download; a distributable release is not yet verified.
Provider support and the fixed 70% /
100% subscription alerts reflect the app README; API billing does not have quota
alerts.
