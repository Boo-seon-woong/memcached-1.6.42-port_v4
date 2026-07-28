# ariel–genie 협업 프로토콜 (v2)

v1에서 운용하던 conversation/commit 시스템을 v2에 재도입한다(2026-07-28
결정). 개발·배포·실측에서 guest(ariel)와 memory node(genie) 양측의 협조가
필요하므로, 모든 cross-machine 조율은 이 채널로만 한다.

## 채널

- **매체**: 이 저장소의 `conversation.md`. append-only, 항목 포맷은 v1과 동일:

  ```
  ## [YYYY-MM-DD KST] <author> — <one-line subject>

  <본문: 요청/보고/근거. 상대가 실행에 필요한 정보를 전부 담는다.>

  NEXT: <token holder>
  ```

- **author/commit prefix**: `[ariel]`(guest·개발 측), `[genie]`(memory
  node 측), `[admin]`(사람). commit subject는 반드시 `[author] ...` 형식.
- **NEXT 토큰**: 마지막 항목의 `NEXT:`가 행동 주체다. 자기 차례가 아니면
  fabric/서버 상태를 바꾸지 않는다 (HCA 간섭 방지 — v1 규칙 계승).

## commit monitor (Claude 세션 규칙)

각 측 Claude 세션은 작업 중 다음을 상시 유지한다:

1. **감시**: `SELF=<자기이름> tools/commit-monitor.sh`를 백그라운드로 상시
   실행. non-self commit이 origin/main에 나타나면 스크립트가 종료되며
   세션을 깨운다. 깨어나면 `cat .monitor/pending_summary.txt` → `git pull`
   → conversation.md의 새 항목 처리 → 응답 항목 작성 → commit/push →
   monitor 재무장.
2. **발신**: 상대 행동이 필요한 시점(genie_memd 재기동, virgin MR
   준비, 게이트 실행 협조 등)에는 conversation.md에 항목을 append하고
   `[자기이름]` 커밋을 push한다. push까지 해야 상대 monitor가 깨어난다.
3. **작업 커밋**: porting 단계 커밋(P0, P1, …)도 push한다 — 상대측이
   배포 시점을 아는 수단이다. 단계 커밋 subject에는 phase를 명시한다
   (예: `[ariel] P2a: worker-inline GET read path`).

## v2에서의 역할 분담 (V2_REMODIFICATION_SPEC §4와 연동)

| 시점 | ariel | genie |
|---|---|---|
| P0–P2b 게이트 | 빌드·배포·correctness 실행 | virgin `genie_memd` 유지 |
| P3 | memtier와 memcached를 guest에서 실행, span/CPU 수집 | remote MR용 `genie_memd` 유지 |

측정 중 HCA 간섭 금지, 측정 종료는 `HCA free — <run name> done` 문구로
토큰 반환 — v1 관례 그대로.

## 세션 기동 체크리스트 (양측 공통)

- [ ] `git pull` 후 conversation.md 마지막 항목과 NEXT 확인
- [ ] `.monitor/handled`를 현재 tip으로 갱신 후 monitor 백그라운드 기동
- [ ] 자기 차례 작업 수행 → 항목 append → commit/push → monitor 재무장
