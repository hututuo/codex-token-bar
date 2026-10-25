#!/usr/bin/env python3
"""Validate the API price table and the currency table, and price responses with them (METRICS section 9).

  python3 spec/tools/prices.py                                         # validate everything (below)
  python3 spec/tools/prices.py --resolve MODEL [--provider P] [--table PATH]
  python3 spec/tools/prices.py --report HISTORY.jsonl [--table PATH]   # models of a --dump-history output

Validation covers spec/assets/prices.json (schema, prices, aliases, normalization lists, its own `tests`),
spec/assets/currencies.json (codes, digits, symbols, fallback rates, names in spec/strings.json) and the stable
fixture tables in spec/fixtures/prices/ with spec/fixtures/price-cases.json. Only the Python standard library is
used; reference.py imports this module.
"""
import argparse
import json
import os
import re
import sys
from collections import Counter, OrderedDict
from datetime import datetime, timezone
from decimal import ROUND_HALF_UP, Decimal, InvalidOperation

SPEC = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TABLE = os.path.join(SPEC, "assets", "prices.json")
CURRENCIES = os.path.join(SPEC, "assets", "currencies.json")
STRINGS = os.path.join(SPEC, "strings.json")
FIXTURES = os.path.join(SPEC, "fixtures")

SCHEMA = 1
PRICE_FIELDS = ("input", "cachedInput", "cacheWrite", "cacheWrite1h", "output")
REQUIRED_PRICES = ("input", "output")
STATUSES = {"current", "preview", "legacy", "deprecated", "retired"}
NORMALIZE_LISTS = ("freeProviders", "cloudSuffixes", "bedrockRegions", "bedrockVendors", "freeSuffixes",
                   "variantSuffixes", "fastSuffixes", "dateSuffixPrefixes", "dotHyphenPrefixes")
NORMALIZE_KEYS = set(NORMALIZE_LISTS) | {"rewrites", "modifierSuffixes"}
MODEL_KEYS = {"id", "provider", "name", "status", "free", "prices", "tiers", "offPeak", "periods", "fast", "aliases",
              "source", "checked", "note"}
MAX_PRICE = Decimal(10000)
MAX_CLASS_TOKENS = 100_000_000
MAX_MODELS = 2000
DATE = re.compile(r"^\d{4}-\d{2}-\d{2}\Z", re.ASCII)
INSTANT = re.compile(r"^\d{4}-\d{2}-\d{2}(T\d{2}:\d{2}Z)?\Z", re.ASCII)
WINDOW = re.compile(r"^(\d{2}):(\d{2})-(\d{2}):(\d{2})\Z", re.ASCII)
ID = re.compile(r"^[a-z0-9][a-z0-9._:+-]*\Z")
DATE_SUFFIX = re.compile(r"-\d{8}$")
BEDROCK_VERSION = re.compile(r"-v\d+(?::\d+)?$")
VERTEX_DATE = re.compile(r"@(\d{8})$")
VERTEX_TAG = re.compile(r"@[^@/]*$")
BRACKETS = re.compile(r"\[[^\]]*\]")
LANGUAGES = ("zh-Hant", "zh-Hans", "en", "ja")


class SpecError(Exception):
    pass


# ---------------------------------------------------------------- prices


def micro(value):
    """USD per million tokens -> integer micro-USD per million tokens (= pico-USD per token)."""
    try:
        d = Decimal(repr(value)) * 1_000_000 if isinstance(value, float) else Decimal(value) * 1_000_000
    except (InvalidOperation, TypeError, ValueError):
        raise SpecError("not a price: %r" % (value,))
    if d != d.to_integral_value():
        raise SpecError("price %r has more than 6 decimals" % (value,))
    return int(d)


def instant_ms(text):
    """`YYYY-MM-DD` (00:00 UTC) or `YYYY-MM-DDTHH:MMZ` -> Unix ms."""
    fmt = "%Y-%m-%dT%H:%MZ" if "T" in text else "%Y-%m-%d"
    return int(datetime.strptime(text, fmt).replace(tzinfo=timezone.utc).timestamp() * 1000)


def is_off_peak(rule, at_ms):
    """METRICS 9.1 offPeak: peak only inside a UTC window on a peak weekday that is not an offPeakDate."""
    at = datetime.fromtimestamp(at_ms / 1000, tz=timezone.utc)
    if at.strftime("%Y-%m-%d") in rule.get("offPeakDates", []) or at.isoweekday() not in rule["peakWeekdays"]:
        return True
    minute = at.hour * 60 + at.minute
    for window in rule["peakUtc"]:
        h0, m0, h1, m1 = map(int, WINDOW.match(window).groups())
        if h0 * 60 + m0 <= minute < h1 * 60 + m1:
            return False
    return True


def pricing_of(entry, r, fast=False):
    """The prices and tiers that apply to response `r` (METRICS 9.1, 9.3), or None when fast mode has no price."""
    if fast:
        return entry.get("fast")
    at = r.get("endMs")
    source = entry
    if at is not None:
        for period in entry.get("periods") or []:
            if ("from" not in period or instant_ms(period["from"]) <= at) and (
                    "to" not in period or at < instant_ms(period["to"])):
                source = period
                break
        if source.get("offPeak") and is_off_peak(source["offPeak"], at):
            source = source["offPeak"]
    return source


def price_set(pricing, input_tokens):
    """(tier index or None, integer prices in micro-USD per million tokens) for a response of `input_tokens`."""
    chosen, index = pricing["prices"], None
    for i, tier in enumerate(pricing.get("tiers") or []):
        if input_tokens > tier["above"]:
            chosen, index = tier, i
    p_in = micro(chosen["input"])
    p_cached = micro(chosen["cachedInput"]) if chosen.get("cachedInput") is not None else p_in
    p_write = micro(chosen["cacheWrite"]) if chosen.get("cacheWrite") is not None else p_in
    p_write_1h = micro(chosen["cacheWrite1h"]) if chosen.get("cacheWrite1h") is not None else p_write
    return index, dict(input=p_in, cachedInput=p_cached, cacheWrite=p_write, cacheWrite1h=p_write_1h,
                       output=micro(chosen["output"]))


def token_classes(r):
    """Disjoint billed token classes of a normalized response (METRICS 3.2, 9.3)."""
    write = r.get("cacheWriteInput", 0)
    write_1h = min(r.get("cacheWrite1hInput", 0), write)
    cached = r.get("cachedInput", 0)
    classes = dict(input=max(0, r.get("input", 0) - cached - write), cachedInput=cached, cacheWrite=write - write_1h,
                   cacheWrite1h=write_1h, output=r.get("output", 0))
    return {k: min(v, MAX_CLASS_TOKENS) for k, v in classes.items()}


def cost_pico(pricing, r):
    """Exact cost in pico-USD (integer) and the tier index used."""
    tier, prices = price_set(pricing, r.get("input", 0))
    classes = token_classes(r)
    return sum(classes[f] * prices[f] for f in PRICE_FIELDS), tier


def round_micro(pico):
    """pico-USD -> micro-USD, half up (all values are non-negative)."""
    return (pico + 500_000) // 1_000_000


class Resolution:
    def __init__(self, kind, entry=None, candidate=None, reason=None, fast=False):
        self.kind, self.entry, self.candidate, self.reason, self.fast = kind, entry, candidate, reason, fast

    @property
    def label(self):
        return (self.entry["id"] + (" fast" if self.fast else "")) if self.kind == "priced" else self.kind

    def __repr__(self):
        return "Resolution(%s, %r)" % (self.label, self.candidate)


class Index:
    def __init__(self, table):
        self.table = table
        self.version = table["version"]
        self.norm = table["normalize"]
        self.by_key = {}
        for m in table["models"]:
            for k in [m["id"]] + list(m.get("aliases") or []):
                self.by_key[k] = m
        self.unknown_exact = {u["value"]: u for u in table.get("unknown") or [] if u["match"] == "exact"}
        self.unknown_prefix = [u for u in table.get("unknown") or [] if u["match"] == "prefix"]

    def lookup(self, key, fast):
        if key in self.by_key:
            m = self.by_key[key]
            if m.get("free"):
                return Resolution("free", m, key)
            if fast and "fast" not in m:
                return Resolution("unknown", None, key, "no fast-mode price")
            return Resolution("priced", m, key, fast=fast)
        if key in self.unknown_exact:
            return Resolution("unknown", None, key, self.unknown_exact[key]["reason"])
        for u in self.unknown_prefix:
            if key.startswith(u["value"]):
                return Resolution("unknown", None, key, u["reason"])
        return None

    def candidates(self, model):
        """The normalization steps of METRICS 9.2, in order; each yields (step, key, fast)."""
        n = self.norm
        k = re.sub(r"\s+", " ", BRACKETS.sub(" ", model)).strip().lower()
        yield "exact", k, False
        if "/" in k:
            k = k.rsplit("/", 1)[1]
            yield "route", k, False
        for region in n["bedrockRegions"]:
            rest = k[len(region) + 1:]
            if k.startswith(region + ".") and any(rest.startswith(v + ".") for v in n["bedrockVendors"]):
                k = rest
                break
        for v in n["bedrockVendors"]:
            if k.startswith(v + "."):
                k = BEDROCK_VERSION.sub("", k[len(v) + 1:])
                break
        k = VERTEX_TAG.sub("", VERTEX_DATE.sub(r"-\1", k))
        yield "cloud", k, False
        if any(k.endswith(s) and len(k) > len(s) for s in n["freeSuffixes"]):
            yield "free", None, False
            return
        stripped = True
        while stripped:
            stripped = False
            for s in n["variantSuffixes"]:
                if k.endswith(s) and len(k) > len(s):
                    k, stripped = k[:-len(s)], True
        yield "variant", k, False
        for rule in n["rewrites"]:
            if k.startswith(rule["prefix"]):
                k = rule["to"] + k[len(rule["prefix"]):]
                break
        yield "rewrite", k, False
        fast = False
        for s in n["fastSuffixes"]:
            if k.endswith(s) and len(k) > len(s):
                k, fast = k[:-len(s)], True
                break
        if fast:
            yield "fast", k, True
        if any(k.startswith(p) for p in n["dateSuffixPrefixes"]):
            k = DATE_SUFFIX.sub("", k)
        yield "date", k, fast
        for rule in n["modifierSuffixes"]:
            if k.startswith(rule["prefix"]):
                stripped = True
                while stripped:
                    stripped = False
                    for s in rule["suffixes"]:
                        if k.endswith(s) and len(k) > len(rule["prefix"]) + len(s):
                            k, stripped = k[:-len(s)], True
                break
        yield "modifier", k, fast
        if any(k.startswith(p) for p in n["dotHyphenPrefixes"]):
            k = k.replace(".", "-")
        yield "dotHyphen", k, fast

    def resolve(self, model, provider=None):
        if isinstance(provider, str) and provider.strip().lower() in self.norm["freeProviders"] and not (
                isinstance(model, str) and model.strip().lower().endswith(tuple(self.norm["cloudSuffixes"]))):
            return Resolution("free", None, None, "free provider")
        if not isinstance(model, str) or not model.strip():
            return Resolution("unknown", None, None, "no model")
        seen = set()
        for step, key, fast in self.candidates(model):
            if step == "free":
                return Resolution("free", None, None, "free suffix")
            if (key, fast) in seen or not key:
                continue
            seen.add((key, fast))
            hit = self.lookup(key, fast)
            if hit is not None:
                return hit
        return Resolution("unknown", None, None, "not in table")

    def price(self, r):
        """Integer micro-USD of one normalized response, or None when its price is unknown (METRICS 9.3)."""
        res = self.resolve(r.get("model"), r.get("provider"))
        if res.kind == "free":
            return 0
        if res.kind == "unknown":
            return None
        pricing = pricing_of(res.entry, r, res.fast or r.get("fast") is True)
        return None if pricing is None else round_micro(cost_pico(pricing, r)[0])


class DayPricing:
    """Day -> price table version bindings (METRICS 9.7): a day keeps the table it was first priced with."""

    def __init__(self, tables, bindings=None):
        self.indexes = {t["version"]: Index(t) for t in tables}
        self.current = max(self.indexes)
        self.bindings = dict(bindings or {})

    def version_for(self, date):
        version = self.bindings.get(date)
        if version not in self.indexes:
            version = self.bindings[date] = self.current
        return version

    def price(self, date, r):
        """The day's bound table; a response it cannot price takes the current table (late pricing, 9.7)."""
        cost = self.indexes[self.version_for(date)].price(r)
        return self.indexes[self.current].price(r) if cost is None else cost


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f, object_pairs_hook=OrderedDict)


# ---------------------------------------------------------------- money formatting (DESIGN 9)

TINY = Decimal("0.0000005")
MILLION = Decimal(1_000_000)
NBSP = "\u00a0"


def round_sig(v, digits):
    """Round a positive Decimal half up to `digits` significant digits (at most 6 decimals)."""
    q = Decimal(1).scaleb(max(v.adjusted() - digits + 1, -6))
    return v.quantize(q, rounding=ROUND_HALF_UP)


def plain(v):
    text = format(v, "f")
    return text


def trim(text, d):
    """Drop trailing fractional zeros beyond `d` decimals, then pad to `d` decimals."""
    whole, _, frac = text.partition(".")
    while len(frac) > d and frac.endswith("0"):
        frac = frac[:-1]
    frac = frac.ljust(d, "0")
    return whole + ("." + frac if frac else "")


def group(text):
    whole, dot, frac = text.partition(".")
    out = ""
    while len(whole) > 3:
        out = "," + whole[-3:] + out
        whole = whole[:-3]
    return whole + out + dot + frac


def compact(v):
    """METRICS 7 for values of at least one million: 1.28M, 12.8M, 128M, 1.28B ..."""
    for unit, scale in (("M", Decimal(10) ** 6), ("B", Decimal(10) ** 9)):
        x = v / scale
        for limit, places in ((10, 2), (100, 1), (1000, 0)):
            r = x.quantize(Decimal(1).scaleb(-places), rounding=ROUND_HALF_UP)
            if x < limit and r < limit:
                return plain(r) + unit
        if unit == "B":
            return group(plain(x.quantize(Decimal(1), rounding=ROUND_HALF_UP))) + "B"
    raise AssertionError


def format_number(value, d, form):
    """The digits of a money value (DESIGN 9 Money formatting); form is "rate" or "amount"."""
    v = Decimal(value)
    if v == 0:
        return "0" if form == "rate" or d == 0 else "0." + "0" * d
    if v < TINY:
        return "<0.000001"
    if v < 1:
        w = round_sig(v, 2)
        if w < 1:
            return trim(plain(w), d)
    if form == "rate" and v < 100:
        w = round_sig(v, 3)
        if w < 100:
            return trim(plain(w), d)
    if v < MILLION:
        w = v.quantize(Decimal(1) if form == "rate" else Decimal(1).scaleb(-d), rounding=ROUND_HALF_UP)
        if w < MILLION:
            return group(plain(w))
    return compact(v)


def symbol_of(currency, language):
    return currency.get("symbols", {}).get(language, currency["symbol"])


def with_symbol(symbol, number):
    sep = NBSP if symbol[-1].isalpha() else ""
    return ("<" + symbol + sep + number[1:]) if number.startswith("<") else symbol + sep + number


def format_money(value, currency, language, form):
    """(number, text): an amount with its symbol in front, a rate followed by its unit (DESIGN 9)."""
    d = currency["digits"]
    number = format_number(value, d, form)
    symbol = symbol_of(currency, language)
    text = with_symbol(symbol, number) if form == "amount" else number + " " + symbol + "/s"
    return number, text


# ---------------------------------------------------------------- exchange rates (NETWORK 4)

RATE_PROVIDERS = ("open.er-api.com", "currency-api", "frankfurter")


def parse_rates(provider, body, supported):
    """(date ms, {code: Decimal}) of one provider response, or raises SpecError."""
    if not isinstance(body, dict):
        raise SpecError("not an object")
    if provider == "open.er-api.com":
        if body.get("result") != "success" or body.get("base_code") != "USD":
            raise SpecError("not a successful USD response")
        stamp = body.get("time_last_update_unix")
        if not is_number(stamp) or stamp <= 0:
            raise SpecError("no update time")
        date_ms, raw = int(stamp) * 1000, body.get("rates")
    elif provider == "currency-api":
        if not isinstance(body.get("date"), str) or not DATE.match(body["date"]):
            raise SpecError("no date")
        date_ms, raw = instant_ms(body["date"]), body.get("usd")
    elif provider == "frankfurter":
        if body.get("base") != "USD" or not isinstance(body.get("date"), str) or not DATE.match(body["date"]):
            raise SpecError("not a USD response with a date")
        date_ms, raw = instant_ms(body["date"]), dict(body.get("rates") or {}, USD=1)
    else:
        raise SpecError("unknown provider")
    if not isinstance(raw, dict):
        raise SpecError("no rates")
    rates = {}
    for code, value in raw.items():
        code = str(code).upper()
        if code in supported:
            if not is_number(value) or not value > 0 or value != value or value == float("inf"):
                raise SpecError("bad rate for %s" % code)
            rates[code] = Decimal(repr(value)) if isinstance(value, float) else Decimal(value)
    rates["USD"] = Decimal(1)
    return date_ms, rates


DAY_MS = 86_400_000


def accept_rates(date_ms, rates, selected, now_ms, last=None, fallback=None, other=None):
    """NETWORK 4 checks 3-5 for the selected currency; `last` = (date ms, accepted ms, rates) or None."""
    if date_ms > now_ms + 2 * DAY_MS:
        return False, "date in the future"
    if last is not None and date_ms < last[0]:
        return False, "older than the stored rates"
    if selected not in rates:
        return False, "selected currency missing"
    if last is not None and now_ms - last[1] <= 30 * DAY_MS:
        reference = last[2].get(selected)
    elif last is None:
        reference = fallback.get(selected) if fallback else None
    else:
        reference = None
    new = rates[selected]
    if reference is not None:
        ok = Decimal("0.5") * reference <= new <= 2 * reference
        return ok, "within bounds" if ok else "outside x0.5..x2"
    if other is None or selected not in other:
        return False, "needs a second provider"
    ok = abs(new - other[selected]) <= Decimal("0.03") * other[selected]
    return ok, "providers agree" if ok else "providers disagree"


# ---------------------------------------------------------------- validation


def is_number(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def check_price(value, where, errors):
    if not is_number(value):
        errors.append("%s: not a number" % where)
        return
    if value < 0 or Decimal(repr(value) if isinstance(value, float) else value) > MAX_PRICE:
        errors.append("%s: %r out of range 0..%s" % (where, value, MAX_PRICE))
        return
    try:
        micro(value)
    except SpecError as e:
        errors.append("%s: %s" % (where, e))


def check_price_set(prices, where, errors):
    if not isinstance(prices, dict):
        errors.append("%s: not an object" % where)
        return
    for k in prices:
        if k not in PRICE_FIELDS and k != "above":
            errors.append("%s: unknown field %s" % (where, k))
    for k in REQUIRED_PRICES:
        if prices.get(k) is None:
            errors.append("%s: %s is required" % (where, k))
    for k in PRICE_FIELDS:
        if prices.get(k) is not None:
            check_price(prices[k], "%s.%s" % (where, k), errors)


def check_pricing(p, where, errors, allowed, off_peak=True):
    """`prices` plus optional ascending `tiers` with the same fields, and optionally `offPeak` (9.1)."""
    if not isinstance(p, dict):
        errors.append("%s: not an object" % where)
        return
    for k in p:
        if k not in allowed:
            errors.append("%s: unknown field %s" % (where, k))
    check_price_set(p.get("prices"), where + ".prices", errors)
    base = p.get("prices") if isinstance(p.get("prices"), dict) else {}
    fields = {k for k in PRICE_FIELDS if base.get(k) is not None}
    if "above" in base:
        errors.append("%s.prices: above belongs in tiers" % where)
    last = 0
    tiers = p.get("tiers", [])
    if not isinstance(tiers, list):
        errors.append("%s: tiers must be a list" % where)
        tiers = []
    for j, tier in enumerate(tiers):
        tw = "%s.tiers[%d]" % (where, j)
        check_price_set(tier, tw, errors)
        if not isinstance(tier, dict):
            continue
        above = tier.get("above")
        if not isinstance(above, int) or isinstance(above, bool) or above <= last:
            errors.append("%s: above must be an integer greater than the previous threshold" % tw)
        else:
            last = above
        if {k for k in PRICE_FIELDS if tier.get(k) is not None} != fields:
            errors.append("%s: must set exactly the price fields of the base prices %s" % (tw, sorted(fields)))
    if "offPeak" in p:
        if not off_peak:
            errors.append("%s: offPeak is not allowed here" % where)
            return
        rule = p["offPeak"]
        ow = where + ".offPeak"
        check_pricing(rule, ow, errors, {"peakUtc", "peakWeekdays", "offPeakDates", "prices", "tiers"}, False)
        if not isinstance(rule, dict):
            return
        windows = rule.get("peakUtc")
        if not isinstance(windows, list) or not windows or any(
                not isinstance(w, str) or not WINDOW.match(w) or not (
                    0 <= int(w[:2]) * 60 + int(w[3:5]) < int(w[6:8]) * 60 + int(w[9:11]) <= 1440) for w in windows):
            errors.append("%s.peakUtc: windows HH:MM-HH:MM with start < end <= 24:00" % ow)
        days = rule.get("peakWeekdays")
        if not isinstance(days, list) or not days or any(d not in range(1, 8) or isinstance(d, bool) for d in days):
            errors.append("%s.peakWeekdays: ISO weekdays 1 (Monday) .. 7" % ow)
        dates = rule.get("offPeakDates", [])
        if not isinstance(dates, list) or any(not isinstance(d, str) or not DATE.match(d) for d in dates):
            errors.append("%s.offPeakDates: YYYY-MM-DD dates" % ow)


def validate_table(t, run_tests=True):
    """Returns the list of problems of a price table (empty = valid). Apps apply the same rules (NETWORK 3)."""
    errors = []
    if not isinstance(t, dict):
        return ["table is not an object"]
    if t.get("schema") != SCHEMA:
        errors.append("schema must be %d" % SCHEMA)
    if not isinstance(t.get("version"), int) or isinstance(t.get("version"), bool) or t["version"] < 1:
        errors.append("version must be a positive integer")
    if not isinstance(t.get("updated"), str) or not DATE.match(t["updated"]):
        errors.append("updated must be YYYY-MM-DD")
    if t.get("currency") != "USD" or t.get("unit") != "perMillionTokens":
        errors.append('currency must be "USD" and unit "perMillionTokens"')
    providers = t.get("providers")
    if not isinstance(providers, dict) or not providers:
        errors.append("providers must be a non-empty object")
        providers = {}
    for key, p in providers.items():
        if not ID.match(key) or not isinstance(p, dict) or not p.get("name") or not str(p.get("url", "")).startswith(
                "https://"):
            errors.append("provider %s: needs name and an https url" % key)
    norm = t.get("normalize")
    if not isinstance(norm, dict) or set(norm) != NORMALIZE_KEYS:
        errors.append("normalize must have exactly %s" % sorted(NORMALIZE_KEYS))
        return errors

    def lowercase_list(values):
        return isinstance(values, list) and all(isinstance(v, str) and v and v == v.strip().lower()
                                                for v in values) and len(set(values)) == len(values)

    for k in NORMALIZE_LISTS:
        if not lowercase_list(norm[k]):
            errors.append("normalize.%s must be unique lowercase strings" % k)
    rewrites = norm["rewrites"]
    if not isinstance(rewrites, list) or any(not isinstance(r, dict) or set(r) != {"prefix", "to"} or
                                             not lowercase_list([r["prefix"], r["to"]]) for r in rewrites):
        errors.append("normalize.rewrites must be {prefix, to} objects with lowercase strings")
    modifiers = norm["modifierSuffixes"]
    if not isinstance(modifiers, list) or any(not isinstance(r, dict) or set(r) != {"prefix", "suffixes"} or
                                              not lowercase_list([r["prefix"]]) or not lowercase_list(r["suffixes"])
                                              for r in modifiers):
        errors.append("normalize.modifierSuffixes must be {prefix, suffixes} objects with lowercase strings")
    if errors:
        return errors
    models = t.get("models")
    if not isinstance(models, list) or not models or len(models) > MAX_MODELS:
        errors.append("models must be a list of 1..%d entries" % MAX_MODELS)
        return errors
    keys = Counter()
    for i, m in enumerate(models):
        where = "models[%d] %s" % (i, m.get("id") if isinstance(m, dict) else "?")
        if not isinstance(m, dict):
            errors.append("%s: not an object" % where)
            continue
        if not isinstance(m.get("id"), str) or not ID.match(m["id"]):
            errors.append("%s: id must be lowercase [a-z0-9._:+-]" % where)
        if m.get("provider") not in providers:
            errors.append("%s: provider %r is not in providers" % (where, m.get("provider")))
        if not isinstance(m.get("name"), str) or not m["name"].strip():
            errors.append("%s: name is required" % where)
        if m.get("status") not in STATUSES:
            errors.append("%s: status must be one of %s" % (where, sorted(STATUSES)))
        if not str(m.get("source", "")).startswith("https://"):
            errors.append("%s: source must be an https URL" % where)
        if not isinstance(m.get("checked"), str) or not DATE.match(m["checked"]) or (
                isinstance(t.get("updated"), str) and m["checked"] > t["updated"]):
            errors.append("%s: checked must be YYYY-MM-DD, not after updated" % where)
        if "note" in m and not isinstance(m["note"], str):
            errors.append("%s: note must be a string" % where)
        if m.get("free") is True:
            extra = set(m) - {"id", "provider", "name", "status", "free", "aliases", "source", "checked", "note"}
            if extra:
                errors.append("%s: a free model has no %s" % (where, ", ".join(sorted(extra))))
        elif "free" in m:
            errors.append("%s: free must be true or absent" % where)
        else:
            check_pricing(m, where, errors, MODEL_KEYS)
            if "fast" in m:
                check_pricing(m["fast"], where + ".fast", errors, {"prices", "tiers"}, False)
            periods = m.get("periods", [])
            if not isinstance(periods, list):
                errors.append("%s: periods must be a list" % where)
                periods = []
            spans = []
            for j, period in enumerate(periods):
                pw = "%s.periods[%d]" % (where, j)
                if not isinstance(period, dict) or ("from" not in period and "to" not in period) or any(
                        not isinstance(period.get(k), str) or not INSTANT.match(period[k]) for k in ("from", "to")
                        if k in period):
                    errors.append("%s: needs from and/or to (YYYY-MM-DD or YYYY-MM-DDTHH:MMZ, UTC)" % pw)
                    continue
                lo = instant_ms(period["from"]) if "from" in period else -2 ** 63
                hi = instant_ms(period["to"]) if "to" in period else 2 ** 63
                if lo >= hi:
                    errors.append("%s: from must be before to" % pw)
                if any(lo < b and a < hi for a, b in spans):
                    errors.append("%s: overlaps another period" % pw)
                spans.append((lo, hi))
                check_pricing(period, pw, errors, {"from", "to", "prices", "tiers", "offPeak", "note"})
        aliases = m.get("aliases", [])
        if not isinstance(aliases, list) or any(not isinstance(a, str) or not a or a != a.strip().lower()
                                                for a in aliases):
            errors.append("%s: aliases must be trimmed lowercase strings" % where)
            aliases = []
        for k in [m.get("id")] + aliases:
            if isinstance(k, str):
                keys[k] += 1
    for k, n in keys.items():
        if n > 1:
            errors.append("id or alias %r is used %d times" % (k, n))
    unknown = t.get("unknown", [])
    if not isinstance(unknown, list):
        errors.append("unknown must be a list")
        unknown = []
    for i, u in enumerate(unknown):
        if not isinstance(u, dict) or u.get("match") not in ("exact", "prefix") or not isinstance(u.get("value"), str) \
                or not u["value"] or u["value"] != u["value"].strip().lower() or not u.get("reason"):
            errors.append("unknown[%d]: needs match exact|prefix, a lowercase value and a reason" % i)
            continue
        for k in keys:
            if (u["match"] == "exact" and k == u["value"]) or (u["match"] == "prefix" and k.startswith(u["value"])):
                errors.append("unknown[%d] %r shadows the id or alias %r" % (i, u["value"], k))
    if errors:
        return errors
    index = Index(t)
    for m in models:
        for k in [m["id"]] + list(m.get("aliases") or []):
            res = index.resolve(k)
            want = "free" if m.get("free") else "priced"
            if res.kind != want or res.entry is not m or res.fast:
                errors.append("%r does not resolve to %s (got %s)" % (k, m["id"], res.label))
    tests = t.get("tests", [])
    if not isinstance(tests, list):
        errors.append("tests must be a list")
        tests = []
    if run_tests:
        errors += run_resolve_tests(index, tests, "tests")
    return errors


def run_resolve_tests(index, tests, where):
    errors = []
    for i, case in enumerate(tests):
        if not isinstance(case, dict) or not isinstance(case.get("expect"), str) or "model" not in case:
            errors.append("%s[%d]: needs model and expect" % (where, i))
            continue
        got = index.resolve(case["model"], case.get("provider")).label
        if got != case["expect"]:
            errors.append("%s[%d]: %r (provider %r) expected %s got %s" % (
                where, i, case["model"], case.get("provider"), case["expect"], got))
    return errors


def validate_currencies(c, strings=None):
    errors = []
    if not isinstance(c, dict) or c.get("schema") != 1:
        return ["currencies: schema must be 1"]
    currencies = c.get("currencies")
    if not isinstance(currencies, list) or not currencies:
        return ["currencies: currencies must be a non-empty list"]
    codes = []
    commons = []
    allowed = {"code", "digits", "symbol", "symbols", "common"}
    for i, cur in enumerate(currencies):
        where = "currencies[%d] %s" % (i, cur.get("code") if isinstance(cur, dict) else "?")
        if not isinstance(cur, dict):
            errors.append(where + ": not an object")
            continue
        if set(cur) - allowed:
            errors.append("%s: unknown fields %s" % (where, sorted(set(cur) - allowed)))
        code = cur.get("code")
        if not isinstance(code, str) or not re.match(r"^[A-Z]{3}\Z", code):
            errors.append(where + ": code must be ISO 4217 (three capital letters)")
            continue
        codes.append(code)
        if cur.get("digits") not in (0, 1, 2, 3):
            errors.append(where + ": digits must be 0..3")
        if not isinstance(cur.get("symbol"), str) or not cur["symbol"] or cur["symbol"] != cur["symbol"].strip():
            errors.append(where + ": symbol must be a trimmed non-empty string")
        symbols = cur.get("symbols", {})
        if not isinstance(symbols, dict) or any(k not in LANGUAGES or not isinstance(v, str) or not v
                                                for k, v in symbols.items()):
            errors.append(where + ": symbols maps languages to symbols")
        common = cur.get("common")
        if common is not None:
            if not isinstance(common, int) or isinstance(common, bool) or common < 1:
                errors.append(where + ": common must be a positive integer or null")
            else:
                commons.append(common)
        if strings is not None:
            entry = strings.get("currency." + code)
            if not isinstance(entry, dict) or any(not entry.get(lang) for lang in LANGUAGES):
                errors.append("%s: spec/strings.json needs currency.%s in %s" % (where, code, ", ".join(LANGUAGES)))
    if len(set(codes)) != len(codes):
        errors.append("currencies: duplicate codes")
    if "USD" not in codes:
        errors.append("currencies: USD is required")
    if sorted(commons) != list(range(1, len(commons) + 1)):
        errors.append("currencies: common ranks must be 1..n without gaps")
    fb = c.get("fallbackRates")
    if not isinstance(fb, dict) or fb.get("base") != "USD" or not isinstance(fb.get("date"), str) or not DATE.match(
            fb["date"]) or not str(fb.get("source", "")).startswith("https://") or not isinstance(fb.get("rates"),
                                                                                                    dict):
        errors.append("fallbackRates needs base USD, date, an https source and rates")
    else:
        for code in codes:
            rate = fb["rates"].get(code)
            if not is_number(rate) or rate <= 0:
                errors.append("fallbackRates: %s needs a positive rate" % code)
        if fb["rates"].get("USD") != 1:
            errors.append("fallbackRates: USD must be 1")
        extra = set(fb["rates"]) - set(codes)
        if extra:
            errors.append("fallbackRates: rates for unsupported currencies %s" % sorted(extra))
    return errors


def at_ms(case):
    return instant_ms(case["at"]) if "at" in case else None


def check_cases(path=None):
    """Fixture tables and cases (stable, independent of real prices)."""
    path = path or os.path.join(FIXTURES, "price-cases.json")
    cases = load(path)
    errors = []
    indexes = {}
    for name, rel in cases["tables"].items():
        table = load(os.path.join(FIXTURES, rel))
        errors += ["%s: %s" % (rel, e) for e in validate_table(table)]
        indexes[name] = Index(table)
    if errors:
        return errors
    for i, case in enumerate(cases["resolve"]):
        idx = indexes[case["table"]]
        got = idx.resolve(case["model"], case.get("provider"))
        if got.label != case["expect"]:
            errors.append("resolve[%d] %r: expected %s got %s" % (i, case["model"], case["expect"], got.label))
    for i, case in enumerate(cases["cost"]):
        idx = indexes[case["table"]]
        r = dict(case["tokens"], model=case["model"], provider=case.get("provider"), endMs=at_ms(case),
                 fast=case.get("fast", False))
        res = idx.resolve(r["model"], r["provider"])
        pricing = pricing_of(res.entry, r, res.fast or r["fast"]) if res.kind == "priced" else None
        if pricing is not None:
            pico, tier = cost_pico(pricing, r)
            got = dict(costPicoUsd=pico, costMicroUsd=round_micro(pico), tier=tier)
        else:
            got = dict(costPicoUsd=0 if res.kind == "free" else None, costMicroUsd=idx.price(r), tier=None)
        if got["costMicroUsd"] != idx.price(r):
            errors.append("cost[%d] %s: Index.price disagrees" % (i, case["name"]))
        for k, v in case["expect"].items():
            if got[k] != v:
                errors.append("cost[%d] %s: %s expected %r got %r" % (i, case["name"], k, v, got[k]))
    tables = [idx.table for idx in indexes.values()]
    for i, case in enumerate(cases.get("days", [])):
        days = DayPricing(tables, case["bindings"])
        r = dict(case["tokens"], model=case["model"], provider=case.get("provider"), endMs=at_ms(case))
        got = (days.price(case["date"], r), days.version_for(case["date"]))
        if got != (case["costMicroUsd"], case["version"]):
            errors.append("days[%d] %s: expected %r got %r" % (i, case["name"], (case["costMicroUsd"],
                                                                                 case["version"]), got))
    return errors


def check_money_cases():
    errors = []
    cur = {c["code"]: c for c in load(CURRENCIES)["currencies"]}
    money = load(os.path.join(FIXTURES, "money-format.json"))
    for i, case in enumerate(money["cases"]):
        value = case["value"] if "value" in case else Decimal(case["costMicroUsd"]) * Decimal(case["rate"]) / MILLION
        got = format_money(value, cur[case["currency"]], case["language"], case["form"])
        if got != (case["number"], case["text"]):
            errors.append("money[%d] %r: expected %r got %r" % (i, case, (case["number"], case["text"]), got))
    rates = load(os.path.join(FIXTURES, "rates-cases.json"))
    supported = set(rates["supported"])
    for i, case in enumerate(rates["parse"]):
        try:
            date_ms, got = parse_rates(case["provider"], case["body"], supported)
            got = {"dateMs": date_ms, "rates": {k: plain(v) for k, v in sorted(got.items())}}
        except SpecError:
            got = None
        if got != case["expect"]:
            errors.append("rates.parse[%d] %s: expected %r got %r" % (i, case["name"], case["expect"], got))
    for i, case in enumerate(rates["accept"]):
        dec = lambda m: {k: Decimal(v) for k, v in m.items()} if m is not None else None  # noqa: E731
        last = (case["last"]["dateMs"], case["last"]["acceptedMs"], dec(case["last"]["rates"])) if case.get(
            "last") else None
        ok, _ = accept_rates(case["dateMs"], dec(case["rates"]), case["selected"], case["nowMs"], last,
                             dec(case.get("fallback")), dec(case.get("other")))
        if ok != case["accept"]:
            errors.append("rates.accept[%d] %s: expected %r got %r" % (i, case["name"], case["accept"], ok))
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--table", default=TABLE)
    parser.add_argument("--resolve", metavar="MODEL")
    parser.add_argument("--provider", default=None)
    parser.add_argument("--report", metavar="HISTORY_JSONL")
    args = parser.parse_args()
    table = load(args.table)
    if args.resolve is not None:
        res = Index(table).resolve(args.resolve, args.provider)
        e = res.entry or {}
        print(json.dumps({"model": args.resolve, "provider": args.provider, "result": res.label,
                          "matchedKey": res.candidate, "reason": res.reason,
                          "pricing": e.get("fast") if res.fast else {k: e[k] for k in
                                                                     ("prices", "tiers", "offPeak", "periods")
                                                                     if k in e}}, ensure_ascii=False))
        return 0
    if args.report:
        idx = Index(table)
        counts = Counter()
        for line in open(args.report, encoding="utf-8"):
            row = json.loads(line)
            for model, v in row.get("models", {}).items():
                counts[model] += v["requests"]
        for model, n in counts.most_common():
            res = idx.resolve(model)
            print("%8d  %-40s %s%s" % (n, repr(model), res.label, "  (%s)" % res.reason if res.reason else ""))
        return 0
    errors = ["prices.json: " + e for e in validate_table(table)]
    strings = load(STRINGS) if os.path.exists(STRINGS) else None
    if os.path.exists(CURRENCIES):
        errors += ["currencies.json: " + e for e in validate_currencies(load(CURRENCIES), strings)]
    else:
        errors.append("currencies.json is missing")
    errors += check_cases()
    errors += check_money_cases()
    if errors:
        print("\n".join("error: " + e for e in errors), file=sys.stderr)
        return 1
    print("ok: prices.json v%d (%s, %d models, %d tests), currencies.json (%d currencies), price-cases.json, "
          "money-format.json, rates-cases.json" % (
        table["version"], table["updated"], len(table["models"]), len(table.get("tests", [])),
        len(load(CURRENCIES)["currencies"])))
    return 0


if __name__ == "__main__":
    sys.exit(main())
