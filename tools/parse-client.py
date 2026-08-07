#!/usr/bin/env python3
"""genie 의 채널 보고에서 셀별 클라이언트 지연을 뽑아 client.tsv 로 만든다.

  python3 tools/parse-client.py > experiments/night-20260806/client.tsv

서버측 rows.tsv 에는 클라이언트 지연이 없다(내 추적기는 서버 카운터만 읽는다).
그래서 F1·F2a 처럼 **x=처리량, y=클라이언트 지연** 인 그림을 못 그리고 있었다.
genie 의 `CELL <id> DONE` 줄이 유일한 출처이고 형식이 일정하다:

  CELL ST-A-P384 DONE  1.168 M  avg 39.34486 / p50 35.32700 / p99 79.87100 / p99.9 92.67100 ms
"""
import re, sys

# genie 가 사고분에 붙이는 표시. 대소문자·한글 모두 받는다.
VOID = re.compile(r"무효|VOID|invalid|void", re.I)

PAT = re.compile(
    r"^CELL\s+(?P<cell>[A-Za-z0-9_.\-]+)\s+DONE\s+(?P<ops>[\d.]+)\s*M"
    r"(?:.*?avg\s+(?P<avg>[\d.]+)\s*/\s*p50\s+(?P<p50>[\d.]+)"
    r"\s*/\s*p99\s+(?P<p99>[\d.]+)(?:\s*/\s*p99\.9\s+(?P<p999>[\d.]+))?)?")


def main(path="conversation.md"):
    seen = {}
    for line in open(path):
        line = line.strip()
        m = PAT.match(line)
        if not m:
            continue
        # 무효로 표시된 줄은 값이 아니라 사고 기록이다. 그걸 읽으면 게이트가
        # 멀쩡한 캠페인을 세운다(2026-08-07: 겹침 사고분 3.294 M 을 읽고 중단).
        if VOID.search(line):
            continue
        d = m.groupdict()
        # 같은 셀이 두 번 보고되면 **나중 것**을 쓴다 (재시행이 정본)
        seen[d["cell"]] = d
    print("cell\tops_M\tavg_ms\tp50_ms\tp99_ms\tp999_ms")
    for c, d in seen.items():
        print("\t".join([c, d["ops"], d["avg"] or "", d["p50"] or "",
                         d["p99"] or "", d["p999"] or ""]))
    print(f"cells={len(seen)}", file=sys.stderr)


main(*sys.argv[1:])
