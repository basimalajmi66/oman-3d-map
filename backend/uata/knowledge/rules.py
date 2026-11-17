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


def extract_rules(text: str, location: str = "") -> list[CandidateRule]:
    out = []
    for sent in SENTENCE_SPLIT.split(text):
        s = sent.strip(" -•*\t")
        if len(s) < 12 or len(s) > 400:
            continue
        if not CONDITION_MARKERS.search(normalize(s)) and not CONDITION_MARKERS.search(s):
            continue
        cs = concepts(s)
        acts = sorted(c for c in cs if c in ACTIONS)
        if not acts:
            continue
        conds = sorted(c for c in cs if c not in ACTIONS)
        tfs = [m.group(0) for m in TF_RE.finditer(normalize(s))]
        out.append(CandidateRule(s, acts, conds, tfs, location))
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
