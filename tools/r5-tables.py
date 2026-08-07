#!/usr/bin/env python3
"""rows.tsv + client.tsv 에서 라운드 5 표를 통째로 찍는다.

RESULTS.md 는 내가 볼 만하다고 고른 지표만 실었다 — pipeline·chain 축에
latency 가 아예 없었다. 여기서는 추적기가 낸 42열을 **하나도 빼지 않고**
축별 표로 낸다. 무엇을 강조할지는 본문에서 하고, 표는 전부 담는다.
"""
import sys, pathlib, collections

SF = pathlib.Path('experiments/semi_final')
ROWS = SF / 'rows.tsv'

# 42열 중 워크로드별로 의미 있는 묶음
GET_COLS = ['Mops', 'get_s', 'busy', 'Gv3_avg', 'Gv3_p50', 'Gv3_p99',
            'Gadmit', 'Gv2', 'Gxfer', 'Gcrypto', 'Gsync']
SET_COLS = ['Sv3_avg', 'Sv3_p50', 'Sv3_p99', 'Sadmit', 'Sv2', 'Sret',
            'Sxfer', 'Scrypto']
CLI_COLS = ['srv', 'srv_p50', 'srv_p99', 'que', 'bk']
CHK_COLS = ['secs', 'set_s', 'err5', 'badcrc', 'hit_pct']
WL = {1: 'YCSB-C', 2: 'YCSB-B', 3: 'YCSB-A'}


def load():
    lines = ROWS.read_text().strip().split('\n')
    hdr = lines[0].split('\t')
    idx = {n: i for i, n in enumerate(hdr)}
    out = collections.defaultdict(dict)
    for ln in lines[1:]:
        f = ln.split('\t')
        lbl, seq = f[0], int(f[1])
        out[lbl][WL.get(seq, str(seq))] = {n: f[i] for n, i in idx.items()}
    return out


def num(v):
    try:
        return f'{float(v):g}'
    except (TypeError, ValueError):
        return v or '—'


def table(rows, cells, cols, keyname):
    """cells: [(표시이름, 라벨)] / cols: 열 이름"""
    out = ['| ' + keyname + ' | 워크로드 | ' + ' | '.join(cols) + ' |',
           '|---|---|' + '---|' * len(cols)]
    for disp, lbl in cells:
        if lbl not in rows:
            out.append(f'| {disp} | — | ' + ' | '.join(['미측정'] * len(cols)) + ' |')
            continue
        for wl in ('YCSB-C', 'YCSB-B', 'YCSB-A'):
            r = rows[lbl].get(wl)
            if not r:
                continue
            out.append(f'| {disp} | {wl} | ' + ' | '.join(num(r.get(c)) for c in cols) + ' |')
    return '\n'.join(out)


AXES = [
    ('P 파이프라인', 'pipeline', [(str(p), f'R5-P{p}') for p in
                            [1, 8, 32, 64, 128, 256, 384, 512]]),
    ('E 클라×파이프', 'c×pipe', [(f'{c}×{p}', f'R5-E{c}x{p}') for c, p in
                            [(1,1024),(2,512),(4,256),(8,128),(16,64),(32,32),(64,16),(128,8)]]),
    ('D 값 크기', 'd(B)', [(str(d), f'R5-D{d}') for d in
                       [4, 8, 16, 24, 32, 48, 64, 96, 128]]),
    ('C 체인', 'chain', [(str(c), f'R5-C{c}') for c in range(1, 17)]),
    ('Q nqp', 'nqp', [(str(q), f'R5-Q{q}') for q in [1, 2, 4, 8, 16, 64]]),
    ('O ORD', 'ORD', [(('협상16' if o == 0 else str(o)),
                       f'R5-O{16 if o == 0 else o}') for o in [1, 2, 4, 8, 0]]),
    ('S 형태(wire 256)', '형태', [(f'{q}×{o}', f'R5-S{q}x{o}') for q, o in
                              [(16,16),(32,8),(64,4),(128,2),(256,1)]]),
    ('T 스레드', 'mcT', [(str(m), f'R5-T{m}') for m in
                     [1, 2, 4, 8, 12, 16, 24, 28, 30]]),
    ('가드', '셀', [('시작점', 'R5-OP'), ('끝점', 'R5-OP-r2')]),
]


def main():
    rows = load()
    print('<!-- tools/r5-tables.py 가 생성한다. 손으로 고치지 말 것. -->\n')
    for title, key, cells in AXES:
        print(f'### {title}\n')
        print('**처리량과 read 측 span 분해**\n')
        print(table(rows, cells, GET_COLS, key), '\n')
        print('**update 측 span 분해**\n')
        print(table(rows, cells, SET_COLS, key), '\n')
        print('**클라이언트 계층 · 유효성 게이트**\n')
        print(table(rows, cells, CLI_COLS + CHK_COLS, key), '\n')


if __name__ == '__main__':
    sys.exit(main())
