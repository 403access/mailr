# Mailr documentation

The documentation site for Mailr, built with [Docusaurus](https://docusaurus.io/)
and deployed to GitHub Pages by `.github/workflows/deploy-docs.yml`.

## Local development

```bash
npm install
npm run start      # http://localhost:3000/mailr/
```

## Production build

```bash
npm run build
npm run serve
```

The build output goes to `build/` and is uploaded as the Pages artifact by CI.

## Deployment

Pushing changes under `website/` to `main` triggers the deploy workflow. In the
repository settings, set **Pages → Build and deployment → Source** to
**GitHub Actions**.

The site is published at <https://403access.github.io/mailr/>. If the repository
moves, update `url`, `baseUrl`, `organizationName`, and `projectName` in
`docusaurus.config.ts`.
