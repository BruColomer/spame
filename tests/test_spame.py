import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "helper"))
import spame  # noqa: E402


def raw_headers(frm, date="Mon, 28 Sep 2026 10:00:00 +0000", lu=None, lup=None):
    lines = [f"From: {frm}", f"Date: {date}"]
    if lu:
        lines.append(f"List-Unsubscribe: {lu}")
    if lup:
        lines.append(f"List-Unsubscribe-Post: {lup}")
    return ("\r\n".join(lines) + "\r\n\r\n").encode()


class ParseListUnsubscribe(unittest.TestCase):
    def test_splits_http_and_mailto(self):
        http, mailto = spame.parse_list_unsubscribe(
            "<mailto:unsub@shop.com?subject=bye>, <https://shop.com/u?id=1>"
        )
        self.assertEqual(http, "https://shop.com/u?id=1")
        self.assertEqual(mailto, "mailto:unsub@shop.com?subject=bye")

    def test_handles_folded_whitespace_and_missing_parts(self):
        http, mailto = spame.parse_list_unsubscribe("  <https://a.io/x>\r\n ")
        self.assertEqual(http, "https://a.io/x")
        self.assertIsNone(mailto)

    def test_empty(self):
        self.assertEqual(spame.parse_list_unsubscribe(""), (None, None))


class ParseMailto(unittest.TestCase):
    def test_subject_and_body(self):
        to, subject, body = spame.parse_mailto("mailto:u@x.com?subject=Unsub%20me&body=please")
        self.assertEqual((to, subject, body), ("u@x.com", "Unsub me", "please"))

    def test_defaults(self):
        to, subject, body = spame.parse_mailto("mailto:u@x.com")
        self.assertEqual(to, "u@x.com")
        self.assertEqual(subject, "unsubscribe")
        self.assertEqual(body, "unsubscribe")


class SenderKey(unittest.TestCase):
    def test_registrable_domain(self):
        self.assertEqual(spame.base_domain("news.mail.wallapop.com"), "wallapop.com")
        self.assertEqual(spame.base_domain("support.magicshop.co.uk"), "magicshop.co.uk")

    def test_passmail_alias_decoded(self):
        name, domain = spame.sender_identity(
            '"Magic Shop" <support_at_magicshop_co_uk_oaalsosl@passmail.net>'
        )
        self.assertEqual(domain, "magicshop.co.uk")
        self.assertEqual(name, "Magic Shop")

    def test_shared_platform_keeps_display_name(self):
        k1 = spame.sender_key("Store A", "shopifyemail.com")
        k2 = spame.sender_key("Store B", "shopifyemail.com")
        self.assertNotEqual(k1, k2)
        self.assertEqual(spame.sender_key("Fender", "fender.com"), "fender.com")

    def test_name_falls_back_to_domain(self):
        name, domain = spame.sender_identity("news@news.wallapop.com")
        self.assertEqual(domain, "wallapop.com")
        self.assertEqual(name, "Wallapop")


class GroupSenders(unittest.TestCase):
    def test_groups_and_keeps_newest_options(self):
        msgs = [
            raw_headers('"Shop" <a@shop.com>', "Mon, 01 Jun 2026 10:00:00 +0000", "<https://shop.com/old>"),
            raw_headers('"Shop" <b@mail.shop.com>', "Mon, 01 Sep 2026 10:00:00 +0000",
                        "<https://shop.com/new>", "List-Unsubscribe=One-Click"),
            raw_headers('"Friend" <f@gmail.com>'),  # no List-Unsubscribe → ignored
        ]
        senders = spame.group_senders(msgs)
        self.assertEqual(len(senders), 1)
        s = senders[0]
        self.assertEqual(s["id"], "shop.com")
        self.assertEqual(s["count"], 2)
        self.assertEqual(s["http"], "https://shop.com/new")
        self.assertTrue(s["oneClick"])
        self.assertEqual(s["method"], "one-click")

    def test_sorted_by_count(self):
        msgs = [raw_headers("a@a.com", lu="<https://a.com/u>")] + [
            raw_headers("b@b.com", lu="<https://b.com/u>") for _ in range(3)
        ]
        self.assertEqual([s["id"] for s in spame.group_senders(msgs)], ["b.com", "a.com"])


PAGE_WITH_FORM = """
<html><body><h1>Manage preferences</h1>
<form action="/unsub/confirm" method="post">
  <input type="hidden" name="token" value="abc123">
  <input type="email" name="email" value="me@example.com">
  <input type="checkbox" name="all" value="1" checked>
  <button type="submit" name="action" value="unsubscribe">Unsubscribe</button>
</form>
<form action="/search"><input name="q"><button>Search</button></form>
</body></html>
"""

PAGE_WITH_LINK = """<html><body><p>Click below</p>
<a href="/help">Help</a><a href="https://x.com/u/confirm?t=1">Confirm unsubscribe</a></body></html>"""


class PageLogic(unittest.TestCase):
    def test_finds_unsubscribe_form(self):
        form = spame.find_unsubscribe_form(PAGE_WITH_FORM, "https://shop.com/unsub?id=1")
        self.assertIsNotNone(form)
        self.assertEqual(form["action"], "https://shop.com/unsub/confirm")
        self.assertEqual(form["method"], "POST")
        self.assertEqual(form["fields"]["token"], "abc123")
        self.assertEqual(form["fields"]["email"], "me@example.com")
        self.assertEqual(form["fields"]["all"], "1")
        self.assertEqual(form["fields"]["action"], "unsubscribe")

    def test_finds_confirm_link(self):
        self.assertIsNone(spame.find_unsubscribe_form(PAGE_WITH_LINK, "https://x.com/u"))
        self.assertEqual(spame.find_confirm_link(PAGE_WITH_LINK, "https://x.com/u"),
                         "https://x.com/u/confirm?t=1")

    def test_confirmation_phrases(self):
        yes = ["You have been unsubscribed.", "You've been successfully unsubscribed",
               "Te has dado de baja correctamente", "Vous êtes désabonné",
               "You will no longer receive these emails", "Sie wurden abgemeldet"]
        no = ["Unsubscribe from our list", "Are you sure you want to unsubscribe?",
              "Manage preferences"]
        for t in yes:
            self.assertTrue(spame.looks_confirmed(t), t)
        for t in no:
            self.assertFalse(spame.looks_confirmed(t), t)


class Ladder(unittest.TestCase):
    def sender(self, **kw):
        base = {"id": "shop.com", "name": "Shop", "domain": "shop.com",
                "http": "https://shop.com/u", "mailto": "mailto:u@shop.com", "oneClick": True}
        base.update(kw)
        return base

    def test_one_click_first(self):
        t = mock.Mock()
        t.one_click.return_value = True
        r = spame.unsubscribe_one(self.sender(), t)
        self.assertEqual((r["status"], r["method"]), ("done", "one-click"))
        t.send_mailto.assert_not_called()

    def test_falls_through_to_mailto_then_page(self):
        t = mock.Mock()
        t.one_click.return_value = False
        t.send_mailto.side_effect = RuntimeError("smtp down")
        t.page.return_value = True
        r = spame.unsubscribe_one(self.sender(), t)
        self.assertEqual((r["status"], r["method"]), ("done", "page"))

    def test_needs_you_when_everything_fails(self):
        t = mock.Mock()
        t.one_click.return_value = False
        t.send_mailto.return_value = False
        t.page.return_value = False
        t.browser.return_value = None  # playwright not installed
        r = spame.unsubscribe_one(self.sender(), t)
        self.assertEqual(r["status"], "needs-you")
        self.assertEqual(r["url"], "https://shop.com/u")

    def test_mailto_only_sender(self):
        t = mock.Mock()
        t.send_mailto.return_value = True
        r = spame.unsubscribe_one(self.sender(http=None, oneClick=False), t)
        self.assertEqual((r["status"], r["method"]), ("done", "email"))
        t.one_click.assert_not_called()
        t.page.assert_not_called()


class AllMailFolder(unittest.TestCase):
    def test_finds_localized_all_mail_by_flag(self):
        listing = [
            b'(\\HasNoChildren) "/" "INBOX"',
            b'(\\HasChildren \\Noselect) "/" "[Gmail]"',
            b'(\\All \\HasNoChildren) "/" "[Gmail]/Todos"',
            b'(\\HasNoChildren \\Sent) "/" "[Gmail]/Enviados"',
        ]
        self.assertEqual(spame.find_all_mail(listing), '"[Gmail]/Todos"')

    def test_falls_back_to_inbox(self):
        self.assertEqual(spame.find_all_mail([b'(\\HasNoChildren) "/" "INBOX"']), "INBOX")


class StateStore(unittest.TestCase):
    def test_round_trip_and_resubscribe_target(self):
        with tempfile.TemporaryDirectory() as d:
            with mock.patch.dict(os.environ, {"XDG_STATE_HOME": d}):
                spame.record_results([
                    {"id": "shop.com", "name": "Shop", "domain": "shop.com", "status": "done",
                     "method": "one-click", "http": "https://shop.com/u"},
                ])
                listed = spame.load_state()["senders"]
                self.assertIn("shop.com", listed)
                self.assertEqual(spame.resubscribe_target(listed["shop.com"]), "https://shop.com/u")
                self.assertEqual(spame.resubscribe_target({"domain": "x.com"}), "https://x.com")
                spame.forget_sender("shop.com")
                self.assertNotIn("shop.com", spame.load_state()["senders"])
                data = json.loads((Path(d) / "spame" / "state.json").read_text())
                self.assertEqual(data["senders"], {})


if __name__ == "__main__":
    unittest.main()
