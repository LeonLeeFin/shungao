"""Conservative Chinese script alignment. No network, no language model guesses."""
import bisect
import re
import unicodedata
from collections import defaultdict
from difflib import SequenceMatcher
from pypinyin import lazy_pinyin, Style

OPEN = {'（': '）', '(': ')', '[': ']', '【': '】', '{': '}', '［': '］'}


def normalize(text):
    chars, offsets, annotations, stack = [], [], [], []
    utf16 = 0
    for c in text:
        size = len(c.encode('utf-16-le')) // 2
        if c in OPEN:
            stack.append(OPEN[c])
        if stack:
            annotations.append((utf16, size))
            if c == stack[-1]:
                stack.pop()
        else:
            for n in unicodedata.normalize('NFKC', c).lower():
                if n.isalnum():
                    chars.append(n)
                    offsets.append(utf16)
        utf16 += size
    return ''.join(chars), offsets, annotations


def phonetic(s):
    return lazy_pinyin(s, style=Style.NORMAL, errors=lambda x: list(x))


class Matcher:
    def __init__(self, text=''):
        self.set_script(text)

    def set_script(self, text):
        self.original = text
        self.text, self.offsets, self.annotations = normalize(text)
        self.py = phonetic(self.text)
        self.index = defaultdict(list)
        for i in range(len(self.py) - 1):
            self.index[tuple(self.py[i:i+2])].append(i)
        self.position = 0
        self.pending = None
        self.last_query = ''
        self.last_partial = False
        self.backward_pending = None

    def locate(self, utf16):
        self.position = min(len(self.text), bisect.bisect_left(self.offsets, utf16))
        self.pending = None
        self.last_query = ''
        self.last_partial = False
        self.backward_pending = None

    def result(self, accepted=False, score=0, reason='等待清晰语音'):
        offset = self.offsets[min(self.position, len(self.offsets)-1)] if self.offsets else 0
        if self.position >= len(self.offsets):
            offset = len(self.original.encode('utf-16-le')) // 2
        return dict(accepted=accepted, offset=offset, confidence=round(score, 3),
                    reason=reason, progress=self.position / max(1, len(self.text)))

    def feed(self, transcript, final=False, partial=False):
        q, _, _ = normalize(transcript)
        # Very short hypotheses are useful only as exact nearby evidence.
        # They cannot relocate to another sentence or a distant repetition.
        if 3 <= len(q) < 5 and self.text and q != self.last_query:
            hits = []
            for start in range(max(0,self.position-len(q)), min(len(self.text),self.position+4)):
                end = start+len(q)
                if self.text[start:end] == q and 0 < end-self.position <= 7:
                    hits.append(end)
            if len(hits) == 1:
                self.position = hits[0]
                self.last_query = q
                self.last_partial = partial
                return self.result(True, 1, '正在跟随')
        if len(q) < 5 or not self.text:
            return self.result(reason='语音过短，保持位置')
        if q == self.last_query and (partial or not self.last_partial):
            return self.result(reason='识别内容未变化')
        self.last_query = q
        self.last_partial = partial
        # Suffix windows allow an ad-lib before returning to the script.
        lengths = sorted(set([min(len(q), k) for k in (14, 26, 46, 72)]), reverse=True)
        candidates = []
        for length in lengths:
            sub = q[-length:]
            qp = phonetic(sub)
            votes = defaultdict(int)
            for j in range(len(qp)-1):
                hits = self.index.get(tuple(qp[j:j+2]), ())
                # Common anchors are poor evidence in long scripts.
                if len(hits) > 200:
                    hits = sorted(hits, key=lambda x: abs(x-self.position))[:60]
                for hit in hits:
                    votes[hit-j] += 1
            starts = sorted(votes, key=lambda x: (-votes[x], abs(x-self.position)))[:45]
            starts.extend([self.position-k for k in (length, length//2, 0)])
            for start in set(starts):
                a = max(0, start - 8)
                b = min(len(self.text), max(0, start) + length + 18)
                if b <= a:
                    continue
                # Block alignment handles missing words, insertions and repairs.
                blocks = SequenceMatcher(None, qp, self.py[a:b], autojunk=False).get_matching_blocks()[:-1]
                if not blocks:
                    continue
                first, last = blocks[0], blocks[-1]
                matches = sum(x.size for x in blocks)
                span = last.b + last.size - first.b
                coverage = matches / length
                score = 2 * matches / (length + span) * min(1, coverage / .70)
                # Do not accept a result whose tail was mostly unrelated.
                tail = length - last.a - last.size
                score *= max(.45, 1-tail/max(6, length)*.7)
                end = a + last.b + last.size
                begin = a + first.b
                exact = SequenceMatcher(None, sub, self.text[begin:end], autojunk=False).ratio()
                score = .78 * score + .22 * exact
                nearby = abs(end-self.position) <= 100
                rank = score + (.065 if nearby else 0) + min(.025, length/2000)
                candidates.append((rank, score, end, begin, length, coverage))
        if not candidates:
            self.pending = None
            return self.result(reason='未找到文稿依据，保持位置')
        candidates.sort(reverse=True)
        best = candidates[0]
        _, score, end, begin, length, coverage = best
        rivals = [c for c in candidates if abs(c[2]-end)>max(16, length//2)]
        margin = best[0] - (rivals[0][0] if rivals else 0)
        delta = end-self.position
        # The decoder emits the beginning of an overlapping window first.
        # These intermediate prefixes must not look like intentional rereading.
        if partial and delta <= 0:
            return self.result(score=score, reason='识别正在补全，保持位置')
        distant = delta > 100 or delta < -40
        if score < (.80 if distant else .68) or coverage < .60:
            self.pending = None
            return self.result(score=score, reason='匹配不足，保持位置')
        if margin < .045:
            return self.result(score=score, reason='文稿有重复片段，等待更多上下文')
        if distant:
            if partial:
                return self.result(score=score, reason='等待完整识别确认跳读')
            if length < 10:
                return self.result(score=score, reason='跳读依据过短，保持位置')
            # Two different hypotheses must agree on the same remote region.
            confirmed = self.pending and abs(self.pending[0]-end) < max(35, length) and self.pending[1] != q
            self.pending = (end, q)
            if not confirmed:
                return self.result(score=score, reason='正在确认跳读位置')
        else:
            self.pending = None
        # Partial prefixes of a fresh overlapping window cannot rewind.
        # A true local retake needs two different complete hypotheses advancing
        # inside the earlier region; small one-off decoder revisions stay put.
        reread = False
        if delta <= 0:
            if score < .88 or length < 6 or delta > -3:
                self.backward_pending = None
                return self.result(score=score, reason='重复或修订，保持位置')
            pending = self.backward_pending
            confirmed_back = (pending is not None and pending[1] != q
                and pending[0]-2 <= end <= pending[0]+max(18,length)
                and end < self.position-2)
            self.backward_pending = (end,q)
            if not (confirmed_back or distant):
                return self.result(score=score, reason='正在确认回读位置')
            reread = True
        else:
            self.backward_pending = None
        self.position = end
        result = self.result(True, score, '已确认回读' if reread else ('已重新定位' if distant else '正在跟随'))
        result.update(reread=reread, relocated=distant)
        return result
