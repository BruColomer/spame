# Spame — design

Date: 2026-09-29 · Status: approved (user authorized autonomous build)

## Goal

An Omarchy shell plugin that finds every newsletter / promo sender in a Gmail
mailbox, lets the user tick the ones they don't want, and unsubscribes from all
of them with one "Done" press. A second tab lists past unsubscribes and lets the
user resubscribe. Built for the Omarchy Plugin Marketplace, so it must work for
any Gmail user, not just the author.

Non-goals: blocking, deleting, labelling or spam-marking mail. Non-Gmail IMAP
providers (possible later; the helper only hard-codes Gmail hosts).

## Shape

Omarchy Quattro shell plugin, `kind: bar-widget`, id `io.github.brucolomer.spame`.

```
manifest.json      bar-widget manifest, setting: scanMonths (1–24, default 6)
Panel.qml          bar icon + count badge, popup with Setup / Unsubscribe / Resubscribe
Service.qml        runs the helper, parses JSON, exposes models to Panel.qml
SpameIcon.qml      envelope glyph
helper/spame.py    all Gmail + HTTP work, Python stdlib only
tests/             unittest suite for the helper
```

QML never touches the network. It calls `python3 helper/spame.py <cmd>` and
reads JSON from stdout (one JSON object per line for streaming commands).

## Helper commands

| command | input | output |
|---|---|---|
| `status` | — | `{configured, email, lastScan, pending}` |
| `setup` | stdin: `email\napp-password\n` | verifies IMAP login, stores password in libsecret via `secret-tool`, `{ok}` |
| `forget` | — | removes stored credentials |
| `scan [--months N]` | — | `{senders:[…]}`; also cached to `~/.cache/spame/scan.json` |
| `unsubscribe` | stdin: JSON array of sender ids | JSON lines, one per sender: `{id,status,method,url?}` then `{summary}` |
| `list-unsubscribed` | — | `{senders:[…]}` from state |
| `resubscribe <id>` | — | opens the best page in the browser, removes from state, `{ok,url}` |

Credentials: email in `~/.config/spame/config.json`; the app password lives only
in the user's keyring (`secret-tool store service spame account <email>`).
It is passed via stdin, never argv. `SPAME_APP_PASSWORD` env overrides for tests.

## Scan

IMAP `imap.gmail.com:993`, folder `[Gmail]/All Mail` (falls back to INBOX),
`SEARCH SINCE <date>`, then batched `FETCH BODY.PEEK[HEADER.FIELDS (FROM DATE
LIST-UNSUBSCRIBE LIST-UNSUBSCRIBE-POST)]`. Only messages carrying
`List-Unsubscribe` count. No bodies are downloaded.

Grouping key = sender domain (registrable part). For shared sending platforms
(shopifyemail.com, mailchimpapp.com, brevosend.com, ccsend.com, convertkit.com,
substack.com, beehiiv.com, patreon.com, gumroad.com, …) the key is
`domain|display name`, so two Shopify stores stay separate. Proton Pass /
SimpleLogin reverse aliases (`x_at_shop_com_abc@passmail.net`) are decoded to
the real sender domain. Each group keeps: display name, domain, email count,
last date, and the unsubscribe options from its newest message.

## Unsubscribe ladder (per sender, stop at first success)

1. **One-click** — `List-Unsubscribe-Post: List-Unsubscribe=One-Click` + https
   URL → POST `List-Unsubscribe=One-Click`. 2xx/3xx = done.
2. **Mailto** — send the unsubscribe mail via `smtp.gmail.com:465` with the app
   password (to, subject, body taken from the mailto URL).
3. **Page auto-submit** — GET the https URL; if the page already confirms, done.
   Otherwise find the unsubscribe/confirm form (or confirm link), submit it with
   its hidden fields, and look for a confirmation phrase (EN/ES/CA/FR/DE/IT/PT).
4. ~~Playwright~~ — removed in 0.1.2 after marketplace review (browser redirects bypass
   `page.route`, so a headless browser can't be confined to public addresses).
5. Otherwise status `needs-you`; after the run all `needs-you` pages open in the
   default browser and a `notify-send` summary is shown.

Results are written to `~/.local/state/spame/state.json`.

## Resubscribe

There is no standard resubscribe. `resubscribe` opens the sender's stored
unsubscribe page (many offer "resubscribe") or, if none, `https://<domain>`,
then removes the sender from state so it shows up again on the next scan.

## UI

- Setup view (not configured): email field, password field, "Create app password"
  link to `https://myaccount.google.com/apppasswords`, Connect button.
- Unsubscribe tab: filter field, Select all / Clear, rows with check glyph,
  name, `domain · N emails`, live status glyph; footer "Unsubscribe N".
- Resubscribe tab: rows with name, date, method, Resubscribe button.
- Bar icon badge = number of senders still subscribed from the last scan.
- Auto-scan when the panel opens and the cache is older than 12 h; manual rescan button.

## Errors

Helper always exits 0 with `{error: "..."}` for expected failures (auth,
network, missing secret-tool); QML shows it in the status line. Every network
call has a timeout. Output is bounded in QML like other plugins.

## Testing

`python -m unittest` over: header parsing, mailto parsing, grouping/alias
decoding, form discovery + confirmation detection (fixture HTML), ladder order
with mocked transports, state round-trip. Manual: `omarchy plugin validate`,
install via symlink, open panel, scan a real mailbox.
