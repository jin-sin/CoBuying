# 오렌담마켓 (CoBuying)

셀러와 고객을 연결하는 공동구매 마켓. 정식 서비스명은 **오렌담마켓**, 축약명은 **오렌담**, 영문은 **ORENDAM**이다.

[브랜드 기준·출시 전 이름 검토](docs/brand.md)에 변경 위치, 사업자 상호 구분, 이름 중복 조사와 대안을 기록한다.

## 방송판매 MVP 개발

[판매자 요구사항 v1](docs/plans/broadcast-orders/requirements-v1.md)을 기준으로 개발에 착수했다. 방송 중 직원 모바일 입력을 정산·발주·입고·출고까지 재사용한다. 신상 사전등록과 특가 현장등록을 모두 지원한다.

- [계획·B00~B09 티켓](docs/plans/broadcast-orders/README.md)
- [단계별 버전·완료 게이트](docs/plans/broadcast-orders/stage-versions.md)
- [화면/API](docs/plans/broadcast-orders/interfaces.md) / [타입](docs/plans/broadcast-orders/contracts.d.ts)
- [시안](docs/prototypes/broadcast-orders/index.html) / [체험 안내](docs/prototypes/broadcast-orders/README.md)
- [지침](AGENTS.md) / [작업표와 실제 완료 범위](docs/plans/broadcast-orders/worklog.md)

직원 입력은 `BROADCAST_ORDERS_ENABLED=true` 테스트 빌드의 `/seller/broadcast`에서 개발한다. 신규 마이그레이션은 테스트 DB에서만 적용한다. 시안 성공과 실제 서버/중국 실기기 검증은 구분한다. 운영에는 아직 방송판매 기능을 배포하지 않았다.

## 프로젝트 검토 기록

- [2026-09-12 프로젝트 파악 및 검토](docs/reviews/2026-09-12-project-review.md) — 구조, 검사 결과, 미해결 사항과 후속 검증 항목.
- [2026-09-12 중국 시청자를 위한 라이브 도입 검토](docs/reviews/2026-09-12-china-live-streaming.md) — 중국 접속 요구사항, 전송망 후보와 실제 회선 검증 순서.
- [2026-09-13 중국 라이브 스트리밍 심층 검토](docs/research/2026-09-13-china-live-streaming-feasibility.md) — 한국 개인사업자·한국 매장 송출·100명 이상 조건의 가입 가능성, 비용, 브라우저와 연길 시험 계획. 서비스 선정 전 참고 자료.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Lab: Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Cookbook: Useful Flutter samples](https://docs.flutter.dev/cookbook)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
