# Clarvy (public version)

Clarvy makes the call while you're still overthinking it. This version runs anywhere, for anyone, without a Claude login. The AI is OpenAI. Your key stays on the server, so visitors never see it.

## What's inside

- `public/index.html` is the whole app (the halo, the composer, the decision engine and the results).
- `api/ask.js` is the endpoint every reasoning step calls. It sends the prompt (and any images) to OpenAI and returns JSON.
- `api/search.js` handles live news. It uses OpenAI's web search tool and returns sources with excerpts.
- `lib/core.js` holds the shared server logic: the key, the access code, the rate limit and error handling.
- `server.js` is a tiny Node server, if you'd rather not use Vercel.

History is saved in each visitor's browser.

## Deploy on Vercel (about 5 minutes)

1. Put this folder in a GitHub repository.
2. Go to vercel.com, choose **Add New → Project**, and import the repository. No build settings are needed.
3. Under **Environment Variables**, add:
   - `OPENAI_API_KEY`: your key from platform.openai.com. **Required.**
   - `ACCESS_CODE`: optional. If set, visitors type this code once before they can ask. Strongly recommended while you test, so strangers can't spend your credit.
   - `OPENAI_MODEL`: optional, default `gpt-5.5`. Use any model your OpenAI account has.
4. Click **Deploy**. You get a public link such as `clarvy.vercel.app`, and you can attach your own domain under **Settings → Domains**.

## Run on any Node host (Render, Railway, a VPS, your laptop)

```
cp .env.example .env    # fill in OPENAI_API_KEY
export $(cat .env | xargs) && npm start
```

Then open http://localhost:3000. On Render or Railway, set the same environment variables and use `npm start` as the start command.

## Cost and limits

- One decision makes about 8 to 11 OpenAI calls: framing, the five independent minds and the judge, plus news search and file reading when they're used. Set a monthly budget in your OpenAI dashboard.
- Each visitor IP gets 80 requests per 10 minutes by default (`RATE_LIMIT_PER_10_MIN`), which is roughly 8 decisions. The limit is kept in memory per server instance, so it's a speed bump, not a wall. Use `ACCESS_CODE` for real protection.
- Requests on Vercel's free plan time out at 60 seconds. If a slow model times out, set `OPENAI_REASONING=low` or pick a faster model.
- Files are read in the visitor's browser. Only the extracted text (about 50 KB at most) and resized images go to the server.

## Before a real public launch

- Add accounts (for example Clerk or Supabase Auth) so history follows people across devices and you can meter usage per user.
- Add a privacy notice explaining that questions and files are sent to OpenAI for processing.
