#!/usr/bin/env python3
"""rows.tsv 를 축별 csv 로 다시 가른다. 캠페인 끝에 한 번 돌리면 된다.

구동기 안의 같은 로직에 SF3-O 분기가 빠져 있어 O 축이 etc.csv 로 샜다
(값은 온전했다). 이미 떠 있는 구동기 사본은 못 고치므로 마무리용으로 둔다.
"""
import pathlib

SF = pathlib.Path('experiments/semi_final')
rows = (SF / 'rows.tsv').read_text().strip().split('\n')
hdr, buckets = rows[0], {}

def axis(label):
    for p in ('SLOTAB', 'SF3-OP', 'SF3-O', 'SF3-P', 'SF3-E', 'SF3-D',
              'SF3-C', 'SF3-Q', 'SF3-S', 'SF3-T', 'SF-O'):
        if label.startswith(p):
            return p
    return 'etc'

for r in rows[1:]:
    buckets.setdefault(axis(r.split('\t')[0]), []).append(r)

(SF / 'csv').mkdir(exist_ok=True)
for k, v in buckets.items():
    (SF / 'csv' / f'{k}.csv').write_text(hdr + '\n' + '\n'.join(v) + '\n')
    print(f'{k}.csv  {len(v)} 행')
