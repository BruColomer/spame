# Spame

Unsubscribe from every newsletter in your Gmail with one click, right from the Omarchy bar.

Spame scans your mailbox for senders that carry a `List-Unsubscribe` header
(newsletters, promos, "updates", etc.), shows them as a checklist, and when you
press **Done** it unsubscribes you from everything you ticked. A second tab
lists what you've unsubscribed from and lets you resubscribe.

Senders are grouped into sections built from *your* mailbox: recurring
interests become their own section (a magician gets **Magic**, a cyclist gets
**Cycling**), and the rest land in Finance, Tech, Courses, Shopping, Games &
entertainment, Travel, Social or News. Only sections you actually have are shown.

It never deletes, blocks, labels or spam-marks mail. Order confirmations and
personal mail from the same companies keep arriving.

![preview](preview.png)

## Install

```bash
omarchy plugin add https://github.com/BruColomer/spame --enable
```

Requirements: Omarchy 4 (Quattro), `python3` and `secret-tool` (libsecret). Both ship with Omarchy.
Optional: `pip install playwright` so Spame can also click through JavaScript unsubscribe pages.

## Setup

1. Turn on 2-Step Verification for your Google account.
2. Create an app password at <https://myaccount.google.com/apppasswords> (name it "Spame").
3. Click the envelope in the bar, enter your Gmail address and the 16-character password, press **Connect**.

The password is stored in your keyring (`secret-tool`, service `spame`). It is
never written to disk in plain text and is only sent to Google's IMAP/SMTP servers.

## How unsubscribing works

For each sender you tick, Spame tries these in order and stops at the first success:

1. **One-click** (RFC 8058): a background POST to the sender's unsubscribe URL.
2. **Unsubscribe email**: sends the sender's `mailto:` unsubscribe request from your Gmail.
3. **Web page**: opens the unsubscribe page, submits its unsubscribe/confirm form and checks for a confirmation message.
4. **Headless browser**: only if Playwright is installed.
5. Anything still left opens in your browser at the end so you can confirm it yourself.

## Resubscribing

Email has no standard "resubscribe". Spame opens the sender's unsubscribe
page (most offer a resubscribe button) or their website, and drops them from
the unsubscribed list so they show up again on the next scan.

## Usage

| Action | How |
|---|---|
| Open / close | click the envelope, or `omarchy-shell io.github.brucolomer.spame toggle` |
| Rescan | middle-click the envelope, or `r` in the panel |
| Filter (name, domain or subject) | `/` in the panel |
| Select a whole section | the checkbox on the section header |
| Collapse a section | click the section header |
| Switch tabs | `1` / `2` |

The envelope pulses while Spame is scanning or unsubscribing; hover it to see how many senders are left.
Setting: **Months of mail to scan** (default 6).

## Files

| Path | Contents |
|---|---|
| `~/.config/spame/config.json` | your Gmail address |
| `~/.cache/spame/scan.json` | last scan (sender names, domains, unsubscribe links) |
| `~/.local/state/spame/state.json` | senders you unsubscribed from |

## Remove

```bash
python3 ~/.config/omarchy/plugins/io.github.brucolomer.spame/helper/spame.py forget
omarchy plugin remove io.github.brucolomer.spame
rm -rf ~/.config/spame ~/.cache/spame ~/.local/state/spame
```

Then delete the app password in your Google account.

## Development

```bash
python3 -m unittest discover -s tests
omarchy plugin validate .
```

MIT licensed.
