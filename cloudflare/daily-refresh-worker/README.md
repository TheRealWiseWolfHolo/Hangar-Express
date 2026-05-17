# Hangar Express Refresh Worker

Triggers the Cloudflare Pages deploy hook every 12 hours using a Cloudflare Workers Cron Trigger.

The deploy hook URL must be stored as the `DEPLOY_HOOK_URL` Worker secret.

## Schedule

The cron expression is `0 9,21 * * *`, which runs at 09:00 UTC and 21:00 UTC.

## Commands

```bash
npm install
npx wrangler secret put DEPLOY_HOOK_URL
npm run deploy
```

For local scheduled testing:

```bash
npm run dev
curl "http://localhost:8787/__scheduled?cron=0+9,21+*+*+*"
```
