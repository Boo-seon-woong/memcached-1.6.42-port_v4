#!/usr/bin/env python3
"""rows.tsv 에서 라운드 6 표를 통째로 찍는다 (분포 2벌 × 워크로드 3종).

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


def classify(r):
    """워크로드를 순번이 아니라 **실측 set 비율**로 판별한다.

    한 창에 부하가 3개보다 많이 들어갈 수 있다(GO 를 다시 낸 셀, genie 가
    옛 라벨로 한 번 더 돈 경우). 순번으로 매기면 엉뚱한 부하가 YCSB 이름을
    달게 되므로, 측정된 read/update 비율로 되짚는다. YCSB 셋 중 어디에도
    안 맞는 부하(옛 MIX 1:9, 옛 SET 1:0)는 버린다.
    """
    try:
        g, st = float(r.get('get_s') or 0), float(r.get('set_s') or 0)
    except ValueError:
        return None
    tot = g + st
    if tot <= 0:
        return None
    f = st / tot
    if f < 0.01:
        return 'YCSB-C'          # 0:1
    if 0.025 <= f <= 0.085:
        return 'YCSB-B'          # 1:19 → 5%
    if 0.40 <= f <= 0.60:
        return 'YCSB-A'          # 1:1 → 50%
    return None                  # 옛 MIX(10%) · 옛 SET(100%) 등


def void_cells():
    """명시적 무효 목록. 클라 DONE 줄이 지워져도 서버측 행은 남는다 —
    사고 셀이 조용히 표에 들어가는 것을 여기서 한 번 더 막는다."""
    f = SF / 'void-cells.txt'
    if not f.exists():
        return set()
    out = set()
    for ln in f.read_text().split('\n'):
        ln = ln.split('#')[0].strip()
        if ln:
            out.add(ln)
    return out


def sanity(out):
    """값을 몰라도 아는 이상. 지금까지 내 검사는 "다른 게 섞였나" 만 봤고
    "말이 되나" 를 안 봤다 — genie 가 R6-P64-U 에서 B>C 로 잡아낸 부류다.

      C ≥ B ≥ A   읽기 전용이 가장 빠르다. 쓰기가 늘수록 느려진다
      Z ≤ U       skew 가 이득일 수 없다
    """
    bad = []
    for lbl, wls in sorted(out.items()):
        try:
            c, b, a = (float(wls[w]['Mops']) for w in ('YCSB-C', 'YCSB-B', 'YCSB-A'))
        except (KeyError, ValueError):
            continue
        if b > c * 1.01:
            bad.append(f'`{lbl}` B({b:.3f}) > C({c:.3f}) — 읽기 전용이 더 느릴 수 없다')
        if a > b * 1.01:
            bad.append(f'`{lbl}` A({a:.3f}) > B({b:.3f}) — 쓰기가 많은데 더 빠를 수 없다')
    for base in sorted({k[:-2] for k in out if k.endswith(('-U', '-Z'))}):
        for w in ('YCSB-C', 'YCSB-B', 'YCSB-A'):
            try:
                u = float(out[base + '-U'][w]['Mops']); z = float(out[base + '-Z'][w]['Mops'])
            except (KeyError, ValueError):
                continue
            if z > u * 1.02:
                bad.append(f'`{base}` {w}: Z({z:.3f}) > U({u:.3f}) — skew 가 이득일 수 없다')
    if bad:
        print('> ⚠ **말이 안 되는 값** — 셀 사고를 의심할 것.\n>')
        for m in bad:
            print('> ' + m)
        print()


def load():
    voids = void_cells()
    lines = ROWS.read_text().strip().split('\n')
    hdr = lines[0].split('\t')
    idx = {n: i for i, n in enumerate(hdr)}
    out = collections.defaultdict(dict)
    counts = collections.Counter()
    dropped = 0
    for ln in lines[1:]:
        f = ln.split('\t')
        rec = {n: f[i] for n, i in idx.items() if i < len(f)}
        if rec[hdr[0]] in voids:
            dropped += 1
            continue
        wl = classify(rec)
        if wl is None:
            dropped += 1
            continue
        counts[rec[hdr[0]]] += 1
        out[rec[hdr[0]]][wl] = rec      # 같은 워크로드가 반복되면 나중 것이 남는다
    if dropped:
        print(f'<!-- YCSB 비율에 안 맞아 버린 부하 {dropped}개 -->\n')

    # 창 하나에는 부하가 정확히 3개여야 한다(C·B·A). 더 많으면 그 창에 다른
    # 부하가 섞였다는 뜻이다 — 라운드 전환 때 낡은 GO 를 따라온 부하가 실제로
    # 그렇게 들어왔다(2026-08-07). 비율도 이름도 형식상 맞아 자동으로는 못
    # 가르므로, **개수로 신고만** 한다. 값 판단은 사람이 한다.
    sanity(out)
    odd = {k: v for k, v in counts.items() if v != 3}
    if odd:
        print('> ⚠ **창 안 부하 수가 3이 아닌 셀** — 다른 부하가 섞였을 수 있다.\n>')
        for k in sorted(odd):
            print(f'> `{k}` {odd[k]}개')
        print()
    return out


def num(v):
    try:
        return f'{float(v):g}'
    except (TypeError, ValueError):
        return v or '—'


DISTS = (('U', 'uniform'), ('Z', 'zipfian'))


def table(rows, cells, cols, keyname):
    """cells: [(표시이름, 라벨접두)] — 라벨은 <접두>-U / <접두>-Z 로 갈린다.

    분포는 서버측 지표로 구분할 수 없다(비율이 같다). GO 를 U·Z 로 따로 내서
    manifest 창이 갈리므로 라벨이 곧 분포다 — 순서 추정을 쓰지 않는다.
    """
    out = ['| ' + keyname + ' | 분포 | 워크로드 | ' + ' | '.join(cols) + ' |',
           '|---|---|---|' + '---|' * len(cols)]
    for disp, base in cells:
        for suf, dname in DISTS:
            lbl = f'{base}-{suf}'
            if lbl not in rows:
                out.append(f'| {disp} | {dname} | — | '
                           + ' | '.join(['미측정'] * len(cols)) + ' |')
                continue
            for wl in ('YCSB-C', 'YCSB-B', 'YCSB-A'):
                r = rows[lbl].get(wl)
                if not r:
                    continue
                out.append(f'| {disp} | {dname} | {wl} | '
                           + ' | '.join(num(r.get(c)) for c in cols) + ' |')
    return '\n'.join(out)


AXES = [
    ('P 파이프라인', 'pipeline', [(str(p), f'R6-P{p}') for p in
                            [1, 8, 32, 64, 128, 256, 384, 512]]),
    ('E 클라×파이프', 'c×pipe', [(f'{c}×{p}', f'R6-E{c}x{p}') for c, p in
                            [(1,1024),(2,512),(4,256),(8,128),(16,64),(32,32),(64,16),(128,8)]]),
    ('D 값 크기', 'd(B)', [(str(d), f'R6-D{d}') for d in
                       [4, 8, 16, 24, 32, 48, 64, 96, 128]]),
    ('C 체인', 'chain', [(str(c), f'R6-C{c}') for c in range(1, 17)]),
    ('Q nqp', 'nqp', [(str(q), f'R6-Q{q}') for q in [1, 2, 4, 8, 16, 64]]),
    ('O ORD', 'ORD', [(('협상16' if o == 0 else str(o)),
                       f'R6-O{16 if o == 0 else o}') for o in [1, 2, 4, 8, 0]]),
    ('S 형태(wire 256)', '형태', [(f'{q}×{o}', f'R6-S{q}x{o}') for q, o in
                              [(16,16),(32,8),(64,4),(128,2),(256,1)]]),
    ('T 스레드', 'mcT', [(str(m), f'R6-T{m}') for m in
                     [1, 2, 4, 8, 12, 16, 24, 28, 30]]),
    ('분포 (9번 축 전용 대조)', '셀', [('운영점', 'R6-DIST')]),
    ('가드', '셀', [('시작점', 'R6-OP'), ('끝점', 'R6-OP-r2')]),
]


def ratio_table(rows, cells, keyname):
    """Z/U 비 — 라운드 6 의 핵심 비교. 측정값이 아니라 파생값이라 별도 표로 낸다
    (측정 열은 아래 세 표에 하나도 빼지 않고 다 들어간다)."""
    out = ['| ' + keyname + ' | YCSB-C | YCSB-B | YCSB-A |', '|---|---|---|---|']
    any_row = False
    for disp, base in cells:
        u, z = rows.get(f'{base}-U'), rows.get(f'{base}-Z')
        cells_out = []
        for wl in ('YCSB-C', 'YCSB-B', 'YCSB-A'):
            try:
                uu = float(u[wl]['Mops']); zz = float(z[wl]['Mops'])
                cells_out.append(f'{(zz - uu) / uu * 100:+.1f}%' if uu else '—')
                any_row = True
            except (TypeError, KeyError, ValueError):
                cells_out.append('—')
        out.append(f'| {disp} | ' + ' | '.join(cells_out) + ' |')
    return '\n'.join(out) if any_row else None


def main():
    rows = load()
    print('<!-- tools/r5-tables.py 가 생성한다. 손으로 고치지 말 것. -->\n')
    for title, key, cells in AXES:
        print(f'### {title}\n')
        rt = ratio_table(rows, cells, key)
        if rt:
            print('**분포 효과 (zipfian 이 uniform 대비 몇 % 인가)**\n')
            print(rt, '\n')
        print('**처리량과 read 측 span 분해**\n')
        print(table(rows, cells, GET_COLS, key), '\n')
        print('**update 측 span 분해**\n')
        print(table(rows, cells, SET_COLS, key), '\n')
        print('**클라이언트 계층 · 유효성 게이트**\n')
        print(table(rows, cells, CLI_COLS + CHK_COLS, key), '\n')


if __name__ == '__main__':
    sys.exit(main())
