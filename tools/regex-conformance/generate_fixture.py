#!/usr/bin/env python3
"""Generate deterministic regex fixtures with a position-set matching oracle."""
import argparse
from functools import lru_cache
import json
from pathlib import Path
import random

def build_fixture():
    rng = random.Random(2912)
    patterns = []

    def add(pattern, pairs):
        patterns.append({'pattern': pattern, 'cases': [{'subject': s, 'expected': v} for s, v in pairs]})
    add('', [('', True), ('a', True)])
    add('^a$', [('a', True), ('a\n', False), ('ba', False), ('', False)])
    add('^.$', [('\r', True), ('\n', False), ('\x00', True), ('\x7f', True), ('ab', False)])
    add('a$', [('ba', True), ('a\n', False), ('a\r', False)])
    add('^a|b$', [('az', True), ('zb', True), ('zabz', False)])
    add('^[a-z0-9_-]{1,4}$', [('a-2', True), ('_', True), ('', False), ('abcdz', False), ('A', False)])
    add('^[^a-z]{1,2}$', [('1\n', True), ('\r', True), ('a', False), ('1a', False)])
    add('^a{0,2}$', [('', True), ('a', True), ('aa', True), ('aaa', False)])
    add('^a{64}$', [('a' * 64, True), ('a' * 63, False), ('a' * 65, False)])
    add('^(ab|c){1,2}$', [('ab', True), ('cc', True), ('abc', True), ('abab', True), ('', False), ('abcc', False)])
    add('^(|a)b$', [('b', True), ('ab', True), ('aab', False)])
    add('^(){2}$', [('', True), ('a', False)])
    add('^[\\x00-\\x7f]$', [('\x00', True), ('\n', True), ('\x7f', True), ('', False)])
    add('^[^\\x00-\\x7f]$', [('', False), ('a', False)])
    add('^\\.\\[\\]\\{\\}\\(\\)\\|\\^\\$\\\\$', [('.[]{}()|^$\\', True), ('.', False)])
    add('^[\\]\\-\\^]{1,3}$', [(']-^', True), ('a', False)])
    add('^[-a]{1,2}$', [('-', True), ('a-', True), ('b', False)])
    add('^[a-]{1,2}$', [('-', True), ('-a', True), ('b', False)])
    add('^\\n\\r\\t\\f\\v$', [('\n\r\t\x0c\x0b', True), ('\n\r\t\x0c', False)])
    add('^\\*\\+\\?$', [('*+?', True), ('*+', False)])
    add('.', [('é', 'unsupported_regex_subject')])

    def generate(depth):
        if depth == 0:
            return rng.choice([('lit', rng.choice([0, 9, 10, 13, 97, 98, 127])), ('set', (97, 98)), ('dot',), ('seq', ())])
        kind = rng.choice(['seq', 'alt', 'rep', 'atom'])
        if kind == 'atom':
            return generate(0)
        if kind in ['seq', 'alt']:
            return (kind, tuple((generate(depth - 1) for _ in range(rng.randrange(1, 4)))))
        low = rng.randrange(0, 3)
        high = rng.randrange(low, 4)
        return ('rep', generate(depth - 1), low, high)

    def spelling(node):
        kind = node[0]
        if kind == 'lit':
            return f'\\x{node[1]:02x}'
        if kind == 'set':
            return '[' + ''.join((f'\\x{b:02x}' for b in node[1])) + ']'
        if kind == 'dot':
            return '.'
        if kind == 'start':
            return '^'
        if kind == 'end':
            return '$'
        if kind == 'seq':
            return '(' + ''.join((spelling(n) for n in node[1])) + ')'
        if kind == 'alt':
            return '(' + '|'.join((spelling(n) for n in node[1])) + ')'
        if kind == 'rep':
            return '(' + spelling(node[1]) + '){' + str(node[2]) + ',' + str(node[3]) + '}'

    def oracle(node, subject):

        @lru_cache(None)
        def ends(n, pos):
            kind = n[0]
            if kind == 'start':
                return frozenset([pos]) if pos == 0 else frozenset()
            if kind == 'end':
                return frozenset([pos]) if pos == len(subject) else frozenset()
            if kind == 'lit':
                return frozenset([pos + 1]) if pos < len(subject) and ord(subject[pos]) == n[1] else frozenset()
            if kind == 'set':
                return frozenset([pos + 1]) if pos < len(subject) and ord(subject[pos]) in n[1] else frozenset()
            if kind == 'dot':
                return frozenset([pos + 1]) if pos < len(subject) and subject[pos] != '\n' else frozenset()
            if kind == 'alt':
                return frozenset().union(*(ends(child, pos) for child in n[1]))
            if kind == 'seq':
                current = frozenset([pos])
                for child in n[1]:
                    current = frozenset().union(*(ends(child, p) for p in current))
                return current
            if kind == 'rep':
                current = frozenset([pos])
                result = current if n[2] == 0 else frozenset()
                for iteration in range(1, n[3] + 1):
                    current = frozenset().union(*(ends(n[1], p) for p in current))
                    if iteration >= n[2]:
                        result |= current
                return result
        return any((ends(node, p) for p in range(len(subject) + 1)))
    subjects = ['', 'a', 'b', 'ab', 'aa', 'ba', 'a\n', '\n', '\r', '\x00', '\x7f', 'ab\r']
    for _ in range(100):
        tree = generate(3)
        if rng.choice([True, False]):
            tree = ('seq', (('start',), tree, ('end',)))
        add(spelling(tree), [(s, oracle(tree, s)) for s in subjects])
    payload = {'version': 1, 'dialect': 'portable_v1', 'semantics': {'subjects': 'ASCII bytes', 'anchors': 'absolute start/end', 'dot': 'all ASCII bytes except LF', 'repetition_max': 64}, 'patterns': patterns}
    return payload

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    fixture = build_fixture()
    rendered = json.dumps(fixture, ensure_ascii=False, indent=2) + '\n'
    target = Path(__file__).resolve().parents[2] / 'test/fixtures/regex-v1.json'
    if args.check:
        if target.read_text() != rendered:
            raise SystemExit('Regex fixture drift: run tools/regex-conformance/generate_fixture.py')
    else:
        target.write_text(rendered)
    print(f"PASS: {len(fixture['patterns'])} reproducible regex patterns")
if __name__ == '__main__':
    main()
