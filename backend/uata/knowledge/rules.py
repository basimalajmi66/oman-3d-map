"""Heuristic extraction of trading rules and conflict detection (no LLM, fully local).

A *candidate rule* is a sentence that contains a condition marker
("إذا / عندما / عند / if / when / only when") **and** an action (buy, sell, enter,
avoid, exit). Candidates are proposals shown in the learning report — they are
never used until the user approves them.

Two rules *conflict* when they share at least two condition concepts (e.g. RSI +
overbought) but prescribe incompatible actions (buy vs sell, enter vs avoid).
"""

from __future__ import annotations

import re
from dataclasses import asdict, dataclass

from uata.knowledge.textnorm import concepts, normalize

CONDITION_MARKERS = re.compile(
    r"(?<![؀-ۿ])(اذا|إذا|عندما|عند|حين|لما|متي|بشرط)(?![؀-ۿ])|\b(if|when|whenever|only when|once|after)\b",
    re.IGNORECASE)
SENTENCE_SPLIT = re.compile(r"(?<=[.!?؟؛;\n])\s+|\n+")

ACTIONS = ("act_buy", "act_sell", "act_enter", "act_avoid", "act_exit")
INCOMPATIBLE = {frozenset({"act_buy", "act_sell"}), frozenset({"act_enter", "act_avoid"}),
                frozenset({"act_buy", "act_avoid"}), frozenset({"act_sell", "act_avoid"})}
TF_RE = re.compile(r"(\d{1,3})\s*(ثانيه|ثواني|دقيقه|دقائق|ساعه|ساعات|sec|secs|s|min|mins|m|h)(?![\w\u0600-\u06FF])"
                   r"|(?<![\u0600-\u06FF])(دقيقتين|دقيقتان|ساعتين|دقيقه واحده)(?![\u0600-\u06FF])", re.IGNORECASE)


@dataclass
class CandidateRule:
    text: str
    actions: list[str]
    conditions: list[str]   # concepts in the sentence other than actions
    timeframes: list[str]
    location: str

    def to_dict(self) -> dict:
        return asdict(self)


# chart patterns have a direction of their own: "when the neckline breaks" after "head and shoulders" means sell
CHART_PATTERN_SIDE = {"double_top": "act_sell", "double_bottom": "act_buy", "head_shoulders": "act_sell",
                      "bull_flag": "act_buy", "ascending_triangle": "act_buy"}
CONTEXT_SENTENCES = 3  # a pattern named in one of the previous sentences is what "it" refers to
# "wait for the price to reach the gap, then enter" is a conditional ENTRY, not a no-trade rule
WAIT_THEN_ENTER = re.compile(r"\bwait (?:for|until)\b.*\benter\b|(?<![؀-ۿ])انتظر(?![؀-ۿ]).*(?<![؀-ۿ])(?:ثم )?ادخل(?![؀-ۿ])")


def extract_rules(text: str, location: str = "") -> list[CandidateRule]:
    out = []
    context: tuple[str, str] | None = None  # (pattern concept, the sentence that named it)
    age = 0
    for sent in SENTENCE_SPLIT.split(text):
        s = sent.strip(" -•*\t")
        cs = concepts(s) if s else set()
        named = sorted(c for c in cs if c in CHART_PATTERN_SIDE)
        if named:
            context, age = (named[0], s), 0
        else:
            age += 1
            if age > CONTEXT_SENTENCES:
                context = None
        if len(s) < 12 or len(s) > 400:
            continue
        wait_enter = bool(WAIT_THEN_ENTER.search(normalize(s)))
        marker = CONDITION_MARKERS.search(normalize(s)) or CONDITION_MARKERS.search(s) or wait_enter
        carried = not named and context is not None and "breakout" in cs
        if not marker and not carried:
            continue
        text_out = s
        if carried:
            cs = cs | {context[0]}
            text_out = f"{context[1]} {s}"
        acts = sorted(c for c in cs if c in ACTIONS)
        if wait_enter and "act_avoid" in acts:
            acts.remove("act_avoid")
            if "act_enter" not in acts:
                acts = sorted(acts + ["act_enter"])
        if "act_avoid" in acts and "act_enter" in acts:
            acts.remove("act_enter")  # "do not enter" / "لا تدخل" is a no-entry rule, not an entry
        pats = sorted(c for c in cs if c in CHART_PATTERN_SIDE)
        if not acts and len(pats) == 1 and "breakout" in cs:
            acts = [CHART_PATTERN_SIDE[pats[0]]]
        if not acts:
            continue
        conds = sorted(c for c in cs if c not in ACTIONS)
        tfs = [m.group(0) for m in TF_RE.finditer(normalize(s))]
        out.append(CandidateRule(text_out, acts, conds, tfs, location))
    return out


def _main_action(actions: list[str]) -> set[str]:
    # "enter" is implied by buy/sell; keep the most specific actions
    a = set(actions)
    if a & {"act_buy", "act_sell"}:
        a.discard("act_enter")
    return a


def conflicts(new: CandidateRule, existing: list[dict]) -> list[dict]:
    """``existing``: [{'item_id', 'text', 'actions', 'conditions'}] of approved rules."""
    found = []
    na = _main_action(new.actions)
    nc = set(new.conditions)
    for ex in existing:
        ea = _main_action(ex["actions"])
        shared = nc & set(ex["conditions"])
        if len(shared) < 2 and not (shared and len(nc) == len(shared) == len(set(ex["conditions"]))):
            continue
        if any(frozenset({x, y}) in INCOMPATIBLE for x in na for y in ea):
            found.append({"item_id": ex["item_id"], "existing_text": ex["text"], "new_text": new.text,
                          "shared_conditions": sorted(shared), "new_actions": sorted(na),
                          "existing_actions": sorted(ea)})
    return found
