# 윌리엄 제임스

> 웃음과 호출의 순간을 놓치지 않고, 그 직전 장면부터 자동으로 기록해 주는 IoT 추억 카메라.

## 프로젝트 정보

| 항목 | 내용 |
| --- | --- |
| 개발 기간 | 7월 20일 ~ 7월 31일 |
| 모바일 | Flutter |
| 백엔드 | Java 21, Spring Boot, PostgreSQL |
| IoT·AI | Jetson Orin Nano, Raspberry Pi 5, Python, YAMNet, YOLO |
| 영상 | FFmpeg, H.264/AAC MP4, HLS |
| 저장소 | MinIO 또는 AWS S3 |

## 핵심 MVP

1. 웃음 감지 시 감지 전후 1분 영상을 저장한다.
2. 호출어 또는 터치 시 직전 2분 영상을 저장한다.
3. 반복 웃음을 하나의 이벤트 영상으로 병합한다.
4. 앱에서 영상 조회·구간 편집·다운로드와 시청 세션이 있을 때만 켜지는 실시간 보기를 제공한다.
5. 사용자는 여러 기기에, 기기는 여러 사용자에 연결되며 기기별 `OWNER/MEMBER` 역할로 영상 접근을 제한한다.

## 산출물 바로가기

- [전체 산출물 인덱스](docs/00_산출물_인덱스.md)
- [프로젝트 기획서](윌리엄_제임스_프로젝트_기획서.md)
- [요구사항 명세서](docs/01_요구사항_명세서.md)
- [사용자 스토리·유스케이스](docs/02_사용자_스토리_및_유스케이스.md)
- [ERD](docs/사람이%20읽을%20문서/빵긋%20ERD.png)
- [OpenAPI 명세](api/openapi.yaml)
- [API 문서 웹 페이지](docs/api/index.html)
- [테스트 계획서](docs/08_테스트_계획서.md)
- [클릭형 앱 와이어프레임](docs/wireframes/index.html)
- [CI/CD 구성](docs/12_CI_CD_구성.md)
- [제출양식 최종본](outputs/019f6394-d326-70f0-9c57-b1b14071b407/윌리엄_제임스_제출양식_최종본.xlsx)

## Figma 산출물

- [앱 와이어프레임](https://www.figma.com/design/kDAk0NTRltBHJsaIeyyXQd)
- [시스템 아키텍처](https://www.figma.com/board/eQtOYa4DFb7SpEO0E4fPjf)

![앱 와이어프레임 현재본 미리보기](docs/wireframes/app-wireframe-preview.png)

## 로컬 인프라

```powershell
Copy-Item infra/.env.example infra/.env
# infra/.env의 CHANGE_ME 값을 교체
docker compose --env-file infra/.env -f infra/docker-compose.yml up -d
```

API 문서 페이지는 `http://127.0.0.1:8081`에서 확인할 수 있다. 실제 애플리케이션 코드는 아직 없으므로 테스트 결과와 배포 정보는 현재 `미실행·미배포` 상태다.

## 협업

브랜치, 커밋, Pull Request 완료 기준은 [CONTRIBUTING.md](CONTRIBUTING.md)를 따른다. 실제 비밀번호, 등록 코드, 토큰, 기기 인증서와 사용자 영상은 Git에 커밋하지 않는다.
