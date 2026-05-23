#!/usr/bin/env python3
"""
Extract the *meaningful* parts of the Dampfloktage page so we can diff it
robustly and classify ticket availability.

Usage:
    python3 extract.py <outdir> <base_url>   # HTML on stdin

Writes into <outdir>:
    content.txt          normalized visible text of the page body
    links.txt            ticket-relevant hyperlinks (text -> url), sorted+unique
    ticket_context.txt   only the text lines that mention tickets (+context)
    status.txt           one token: on_sale | sold_out | coming_soon | unknown
    signals.txt          the booleans behind the status decision (for humans)

The goal is to strip away everything that changes between requests for reasons
unrelated to tickets (scripts, styles, nav menus, footers, cookie banners,
tracking query params) so that a diff only fires on content we care about.
"""
import sys
import os
import re
from html.parser import HTMLParser
from urllib.parse import urljoin, urlsplit, urlunsplit, parse_qsl, urlencode

# Subtrees whose *contents* are dropped entirely. All of these are non-void
# (they always have a matching end tag), so depth counting stays balanced.
SKIP_TAGS = {"script", "style", "noscript", "svg", "template", "iframe",
             "head", "nav", "footer"}

# Tags that should introduce a line break in the extracted text, so the output
# has stable line structure we can grep for context.
BLOCK_TAGS = {"p", "div", "section", "article", "header", "main", "aside",
              "ul", "ol", "li", "h1", "h2", "h3", "h4", "h5", "h6", "br",
              "tr", "td", "th", "table", "figure", "figcaption", "button",
              "dl", "dt", "dd", "blockquote"}

# Known (mostly German) ticketing vendors. A link to any of these is a strong
# "you can buy now" signal.
VENDOR = re.compile(
    r"(reservix|eventim|ticket\.io|pretix|adticket|\betix\b|ticketmaster|"
    r"easyticket|see-?tickets|vivenu|yvent|frankenticket|ticket-regional|"
    r"okticket|eventbrite|ticketpay|hellotickets|ticket-onlineshop|"
    r"ticketshop|kartenhaus|ztix|ticketino)", re.I)

# Words that mark ticket-related text/links anywhere on the page.
TICKET_KW = re.compile(
    r"ticket|karten|vorverkauf|eintritt|kaufen|sichern|buchen|reservier|preis",
    re.I)

# Text on a button/link that means "buy".
BUY_TEXT = re.compile(
    r"sichern|kaufen|buchen|bestellen|jetzt.{0,15}ticket|ticket.{0,15}kaufen|"
    r"karten.{0,15}kaufen|zum\s+ticketshop|tickets?\s+bestellen", re.I)

# "tickets are not here yet" phrasing.
COMING = ["bald hier", "bald verf", "demnächst", "in kürze",
          "in vorbereitung", "noch nicht verf", "noch nicht buchbar",
          "noch nicht erh", "folgt in kürze", "folgen in kürze",
          "kommen bald", "in planung", "coming soon"]

# "tickets are available now" phrasing. Only used as a positive signal when no
# COMING phrase is present, so a leftover "demnächst" can't be overridden by an
# ambiguous word. NOTE: deliberately excludes the button label "tickets
# sichern", which is on the page even while tickets are only "coming soon".
ON_SALE = ["jetzt erhältlich", "ab sofort erhältlich", "ab sofort buchbar",
           "tickets erhältlich", "karten erhältlich", "jetzt buchen",
           "jetzt kaufen", "verkauf gestartet", "verkauf läuft",
           "verkauf hat begonnen", "im verkauf", "tickets verfügbar",
           "karten verfügbar", "jetzt im vorverkauf", "geöffnet"]

TRACKING_PARAMS = ("utm_", "mc_", "pk_", "matomo_")
TRACKING_EXACT = {"fbclid", "gclid", "_ga", "gad", "gad_source", "gclsrc",
                  "msclkid", "igshid", "ref", "ref_src"}


class Extract(HTMLParser):
    def __init__(self, base):
        super().__init__(convert_charrefs=True)
        self.base = base
        self.skip = 0
        self.parts = []
        self.pairs = []          # (raw_href, anchor_text)
        self._a = None           # [href, [text parts]]

    def handle_starttag(self, tag, attrs):
        if tag in SKIP_TAGS:
            self.skip += 1
            return
        if self.skip:
            return
        if tag in BLOCK_TAGS:
            self.parts.append("\n")
        if tag == "a":
            href = dict(attrs).get("href", "") or ""
            self._a = [href, []]

    def handle_startendtag(self, tag, attrs):
        if self.skip:
            return
        if tag == "br":
            self.parts.append("\n")

    def handle_endtag(self, tag):
        if tag in SKIP_TAGS:
            if self.skip:
                self.skip -= 1
            return
        if self.skip:
            return
        if tag == "a" and self._a is not None:
            text = " ".join("".join(self._a[1]).split())
            self.pairs.append((self._a[0], text))
            self._a = None
        if tag in BLOCK_TAGS:
            self.parts.append("\n")

    def handle_data(self, data):
        if self.skip or not data:
            return
        self.parts.append(data)
        if self._a is not None:
            self._a[1].append(data)


def normalize_text(raw):
    lines = []
    for ln in raw.split("\n"):
        ln = ln.replace(" ", " ")
        ln = re.sub(r"[ \t\r\f\v]+", " ", ln).strip()
        if ln:
            lines.append(ln)
    return "\n".join(lines)


def clean_url(href, base):
    if not href:
        return None
    href = href.strip()
    if not href or href.startswith(("#", "mailto:", "tel:", "javascript:",
                                    "data:")):
        return None
    u = urljoin(base, href) if base else href
    s = urlsplit(u)
    if s.scheme not in ("http", "https"):
        return None
    q = [(k, v) for k, v in parse_qsl(s.query, keep_blank_values=True)
         if not (k.lower().startswith(TRACKING_PARAMS)
                 or k.lower() in TRACKING_EXACT)]
    s = s._replace(query=urlencode(q), fragment="")
    return urlunsplit(s)


def main():
    outdir = sys.argv[1] if len(sys.argv) > 1 else "."
    base = sys.argv[2] if len(sys.argv) > 2 else ""
    os.makedirs(outdir, exist_ok=True)

    html = sys.stdin.read()
    p = Extract(base)
    try:
        p.feed(html)
    except Exception as e:           # never crash on malformed markup
        sys.stderr.write("parse warning: %s\n" % e)

    content = normalize_text("".join(p.parts))
    low = content.lower()
    base_netloc = urlsplit(base).netloc.lower() if base else ""

    # --- ticket-relevant links -------------------------------------------
    relevant = []                    # (url, text)
    seen = set()
    for href, text in p.pairs:
        url = clean_url(href, base)
        if not url:
            continue
        path = urlsplit(url).path
        if VENDOR.search(url) or TICKET_KW.search(text) or TICKET_KW.search(path):
            key = (url, text)
            if key not in seen:
                seen.add(key)
                relevant.append((url, text))

    def is_external(url):
        nl = urlsplit(url).netloc.lower()
        return bool(nl) and nl != base_netloc

    has_vendor = any(VENDOR.search(u) for u, _ in relevant)
    has_external_buy = any(BUY_TEXT.search(t) and (VENDOR.search(u) or is_external(u))
                           for u, t in relevant)
    has_internal_ticket_link = any((not is_external(u)) and TICKET_KW.search(urlsplit(u).path)
                                   for u, _ in relevant)

    # --- text signals -----------------------------------------------------
    has_sold_out = ("ausverkauft" in low) or ("sold out" in low)
    has_coming = any(c in low for c in COMING) and \
        ("ticket" in low or "karten" in low or "verfügbar" in low)
    has_vorverkauf = ("vorverkauf" in low) and bool(
        re.search(r"\d{1,2}\.\d{1,2}\.", content) or "€" in content
        or "eur" in low or re.search(r"\bab\s*\d", low))
    price_near_ticket = bool(re.search(
        r"(ticket|karte|eintritt)[^\n]{0,40}(\d+[.,]\d{2}\s?€|\d+\s?€|€\s?\d)",
        low))

    has_onsale_text = any(s in low for s in ON_SALE)

    strong = (has_vendor or has_external_buy or has_vorverkauf
              or price_near_ticket or (has_onsale_text and not has_coming))

    if has_sold_out:
        status = "sold_out"
    elif strong:
        status = "on_sale"
    elif has_internal_ticket_link and not has_coming:
        status = "on_sale"
    elif has_coming:
        status = "coming_soon"
    elif has_internal_ticket_link:
        status = "on_sale"
    else:
        status = "unknown"

    # --- ticket context (matching lines + 1 line of context) -------------
    clines = content.split("\n")
    keep = set()
    for i, ln in enumerate(clines):
        if TICKET_KW.search(ln) or "verfügbar" in ln.lower() \
                or "€" in ln or "ausverkauft" in ln.lower():
            keep.update((i - 1, i, i + 1))
    ctx = [clines[i] for i in sorted(keep) if 0 <= i < len(clines)]

    # --- write files ------------------------------------------------------
    def w(name, text):
        with open(os.path.join(outdir, name), "w", encoding="utf-8") as f:
            f.write(text.rstrip("\n") + "\n")

    w("content.txt", content)
    w("links.txt", "\n".join(sorted("%s -> %s" % (t or "(no text)", u)
                                     for u, t in relevant)))
    w("ticket_context.txt", "\n".join(ctx))
    w("status.txt", status)
    w("signals.txt", "\n".join([
        "status=%s" % status,
        "has_coming=%s" % has_coming,
        "has_onsale_text=%s" % has_onsale_text,
        "has_sold_out=%s" % has_sold_out,
        "has_vendor_link=%s" % has_vendor,
        "has_external_buy_button=%s" % has_external_buy,
        "has_internal_ticket_link=%s" % has_internal_ticket_link,
        "has_vorverkauf=%s" % has_vorverkauf,
        "price_near_ticket=%s" % price_near_ticket,
        "relevant_links=%d" % len(relevant),
        "content_lines=%d" % len(clines),
    ]))

    sys.stderr.write("status=%s  relevant_links=%d  content_lines=%d\n"
                     % (status, len(relevant), len(clines)))


if __name__ == "__main__":
    main()
