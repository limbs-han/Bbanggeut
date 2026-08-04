# 무중단 배포 (blue-green 슬롯)

## 구조

백엔드는 두 슬롯 중 하나에서 돈다 — systemd 인스턴스 `william-james@8081`,
`william-james@8082`. nginx는 포트를 직접 가리키지 않고 upstream을 본다.

```
nginx (443) ── upstream william_james ──> 127.0.0.1:8081  (활성)
                                          127.0.0.1:8082  (대기)
```

- **활성 슬롯의 사실상의 상태 저장소는 `/etc/nginx/conf.d/wj-upstream.conf`다.**
  배포 스크립트가 이 파일에 활성 포트를 쓴다. 릴리스에 담긴 같은 이름의 파일은
  **없을 때만** 설치된다 — 덮어쓰면 배포마다 슬롯이 8081로 되돌아간다.
- JAR도 슬롯별로 따로 둔다(`app/server-8081.jar`, `app/server-8082.jar`).
  실행 중인 JVM이 읽고 있는 파일을 덮어쓰면 nested jar 로딩이 깨진다.
  `app/server.jar`은 "가장 최근 배포본" 참조로 계속 유지한다(백업·롤백 경로).

## 배포 순서 (wj-deploy-backend가 자동 수행)

1. 활성 슬롯을 읽어 반대 슬롯을 대상으로 정한다.
2. 새 JAR을 대상 슬롯 파일에 설치하고 `systemctl restart william-james@<대상>`.
3. `127.0.0.1:<대상>/actuator/health`가 응답할 때까지 최대 90초 대기.
4. upstream 파일을 대상 포트로 바꾸고 `nginx -t` → `systemctl reload nginx`.
   nginx reload는 기존 워커가 진행 중인 요청을 마친 뒤 종료하므로 요청이 끊기지 않는다.
5. 5초 뒤 구 슬롯을 정지한다(진행 중이던 요청 유출 시간).

실패 시 롤백: upstream을 구 슬롯으로 되돌리고 reload한 뒤 대상 슬롯을 내린다.
구 슬롯은 그대로 살아 있으므로 사용자에게는 영향이 없다.

## 마이그레이션 규칙 (중요)

새 슬롯이 기동하며 Flyway를 적용하는 동안 **구 슬롯이 아직 구 코드로 서비스한다.**
따라서 마이그레이션은 항상 **backward-compatible**해야 한다.

- 허용: 테이블·컬럼·인덱스 추가, enum 값 추가, nullable 컬럼 추가
- 금지(두 단계 릴리스로 나눌 것): 컬럼·테이블 삭제, 타입 변경, NOT NULL 강화,
  이름 변경

두 슬롯이 겹치는 몇 초 동안 스케줄러도 양쪽에서 돈다. 알림은
`(user_id, dedupe_key)` 유일 제약으로, 스트림·삭제 워커는
`FOR UPDATE SKIP LOCKED`로 중복이 무해하다.

## 2026-08-04 실측

전환 중 다운타임이 실제로 0인지 부하를 걸어 확인했다.

```
20 VU로 https://i15e201.p.ssafy.io/health 를 60초간 호출하는 도중
8081 → 8082 슬롯 전환(upstream 교체 + nginx reload + 구 슬롯 정지)

요청 94,042건 / 실패 0건 (1,567 req/s, p95 24ms)
```

## 수동 조작

```bash
# 지금 활성 슬롯 확인
grep -oE '127\.0\.0\.1:[0-9]+' /etc/nginx/conf.d/wj-upstream.conf

# 수동 롤백(구 슬롯이 아직 살아 있을 때)
sudo tee /etc/nginx/conf.d/wj-upstream.conf >/dev/null <<'EOF'
upstream william_james {
    server 127.0.0.1:8081;
    keepalive 32;
}
EOF
sudo nginx -t && sudo systemctl reload nginx

# 슬롯 로그
sudo journalctl -u william-james@8082 -f
```

단일 유닛 시절의 `william-james.service`는 2026-08-04에 정지·disable했다.
부팅 시에는 `william-james@<활성포트>`만 올라온다.
