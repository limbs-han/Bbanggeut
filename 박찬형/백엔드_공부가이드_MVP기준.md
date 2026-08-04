# 빵긋 백엔드 공부 가이드

> 대상: 백엔드를 처음 공부하는 팀원
> 기준일: **2026-08-04** / 기준 코드: `master` + `develop` (Flyway V39)
> 성격: 설계 희망사항이 아니라 **지금 서버에서 돌고 있는 것**을 코드로 확인해 쓴 as-built 가이드
> 읽는 법: **1장부터 순서대로.** 앞에서 정의한 용어만 써서 뒤를 설명한다.

---

## 이 문서를 읽는 법

이 프로젝트를 한 번에 이해하려고 하면 HTTP, MQTT, JWT, PostgreSQL, MinIO, MediaMTX, WebRTC가
동시에 튀어나와서 길을 잃는다. 모르는 게 정상이다. 그래서 이 문서는 이렇게 배치했다.

| 부 | 무엇 | 언제 읽나 |
| --- | --- | --- |
| 1부 (1~5장) | 배경 지식 — 서버·네트워크·HTTP, 우리가 쓰는 도구들이 각각 무엇인지 | 처음이면 여기부터. 이미 안다면 5장 표만 보고 넘어간다 |
| 2부 (6~11장) | 시스템 전체 그림 — 무엇이 어디에 있고 요청이 어디로 흐르나 | **가장 중요.** 여기만 이해하면 절반은 끝이다 |
| 3부 (12~22장) | 기능별 흐름 — 로그인, 기기 등록, 영상 저장, 라이브, 알림, 편집, 통계 | 코드를 열어 놓고 함께 읽는다 |
| 4부 (23~27장) | 백엔드 공통 원리 — 3층 구조, 트랜잭션, DB, 워커 | 3부를 읽다 막히면 돌아온다 |
| 5부 (28~33장) | 인프라·배포·관측성·보안 | 발표와 면접에서 가장 많이 물어보는 부분 |
| 6부 (34~38장) | 실제로 겪은 장애 5건 | 이야기로 남아서 기억에 제일 잘 붙는다 |
| 7부 (39~42장) | 공부 순서, 로컬 실행, 예상 질문 69개, 한 장 요약 | 시험 전날처럼 볼 부분 |

한 번에 다 읽지 말고 2부까지 읽은 다음 3부를 하루 한 장씩 코드와 대조하는 게 낫다.

### 문서끼리 충돌할 때 믿는 순서

1. 실제 실행 코드와 테스트
2. `자료/api/openapi.yaml`, `자료/api/mqtt-contract.md` (파트 간 계약)
3. `자료/docs/사람이 읽을 문서/` 최신 문서, `자료/docs/ADR-001-editor-api-경계.md`
4. `backend/BACKEND_STATUS.md`, 각 파트 README
5. `자료/docs/old/`

`old` 폴더에는 폐기된 설계가 남아 있다. 공부에는 도움이 되지만 "현재 이렇게 동작한다"의
근거로 쓰면 안 된다. **이 문서와 코드가 다르면 코드가 맞다.** 그때는 이 문서를 고쳐야 한다.

---

# 1부. 배경 지식

## 1. 컴퓨터, 프로세스, 서버, 클라이언트

### 컴퓨터와 프로그램, 프로세스

컴퓨터는 입력을 받아 정해진 명령을 실행하고 결과를 내놓는 기계다. 노트북, 스마트폰, AWS EC2,
Jetson, Raspberry Pi가 전부 컴퓨터다. 성능과 운영체제, 맡은 일만 다르다.

- **프로그램**: 디스크에 저장된 명령 묶음. 아직 실행되지 않은 상태. 우리 백엔드의 `server.jar`가 그것이다.
- **프로세스**: 그 프로그램을 실제로 실행해 메모리를 차지하고 있는 상태. 같은 프로그램을 두 번 실행하면 프로세스는 두 개다.

이 구분이 중요한 이유가 뒤에 나온다. 우리는 **같은 `server.jar`를 포트만 다르게 두 프로세스로
띄워서** 무중단 배포를 한다(30장).

컴퓨터의 자원은 이렇게 쓰인다.

| 자원 | 하는 일 | 우리 프로젝트에서 |
| --- | --- | --- |
| CPU | 계산 | 영상 분석, JSON 파싱, 비밀번호 해시 |
| 메모리(RAM) | 실행 중 데이터를 임시 보관 | Spring이 처리 중인 요청, Redis의 데이터 |
| 디스크 | 전원이 꺼져도 남는 저장 | PostgreSQL 데이터, MinIO의 영상 파일 |
| 네트워크 | 다른 컴퓨터와 통신 | 앱↔서버, 기기↔서버 |

우리 서버는 EC2 한 대(Ubuntu, 4 vCPU / 16 GB)다. **이 한 대 안에 10개가 넘는 프로세스가
같이 산다.** 그래서 "서버"라는 말이 나올 때마다 그게 EC2라는 기계인지, 그 안의 Spring
프로세스인지 구분해서 들어야 한다.

### 클라이언트와 서버

- **클라이언트**: 먼저 요청하는 쪽. 우리 프로젝트에서는 Flutter 앱, 홈캠 기기, 그리고 `curl`.
- **서버**: 요청을 기다리다가 응답하는 쪽.

역할이지 기계 종류가 아니다. **하나가 둘 다일 수 있다.** 우리 Spring 백엔드는 앱에게는
서버지만, MinIO에게 서명을 요청할 때는 클라이언트다. 홈캠 기기도 서버에게는 클라이언트지만
영상을 송출할 때는 스트림 제공자다.

**"백엔드"는 사용자가 직접 화면으로 보지 않는 쪽 전체**를 말한다. 우리 프로젝트에서 백엔드
파트가 책임지는 건 Spring 서버 + 그 서버가 쓰는 인프라(DB, Redis, 저장소, 브로커, 미디어
서버, nginx, 배포)다.

## 2. 네트워크: IP, 도메인, 포트, TCP/UDP

### IP와 도메인

IP 주소는 네트워크에서 컴퓨터를 가리키는 번호다(`43.201.xxx.xxx`). 사람이 외우기 어려워서
**도메인**이라는 이름을 붙이고, DNS가 이름 → IP로 바꿔 준다.

- `127.0.0.1` (= `localhost`): **자기 자신**. 이 주소로 열린 문은 그 컴퓨터 안에서만 닿는다.
- `0.0.0.0`: 모든 네트워크 인터페이스. 이 주소로 열면 **외부에서도 닿는다.**

이 두 줄이 우리 보안 설계의 핵심이다. PostgreSQL·Redis·MinIO·Grafana는 전부 `127.0.0.1`에만
바인딩되어 있다. 인터넷에서 우리 서버의 DB에 직접 접속을 시도해도 문이 없다. 오직 nginx와
SSH만 외부에 열려 있고, 나머지는 그 둘을 통과해야 닿는다.

### 포트

한 컴퓨터 안에서 프로그램들을 구분하는 번호다. IP가 건물 주소면 포트는 호실이다.
같은 포트를 두 프로그램이 동시에 쓸 수 없다.

우리 서버의 포트 지도. **외부에 열린 것만 굵게**.

| 포트 | 누구 | 외부 공개 |
| --- | --- | --- |
| **22** | SSH | **O** (관리자) |
| **80 / 443** | nginx (HTTP / HTTPS) | **O** |
| **8883** | Mosquitto MQTTS | **O** (기기 전용) |
| **8322** | MediaMTX RTSPS | **O** (기기 전용) |
| **8189/UDP** | WebRTC 미디어 | **O** |
| 8081 / 8082 | Spring Boot 슬롯 두 개 | X |
| 5432 | PostgreSQL | X |
| 6379 | Redis | X |
| 9000 | MinIO S3 API | X (nginx 경유) |
| 8889 | MediaMTX WHEP/WHIP 신호 | X (nginx 경유) |
| 9997 | MediaMTX 관리 API | X |
| 18080 | editor-api (FastAPI) | X (nginx 경유) |
| 9090 / 3000 | Prometheus / Grafana | X (SSH 터널) |
| 8080 | Jenkins | X |

"외부에 뭐가 열려 있냐"는 면접에서 거의 반드시 나온다. **다섯 갈래뿐이고, 그중 둘은 기기
전용이며, 나머지는 전부 loopback**이라고 답하면 된다.

### TCP와 UDP

| | TCP | UDP |
| --- | --- | --- |
| 성격 | 연결을 맺고 순서·도착을 보장 | 그냥 던진다 |
| 대가 | 재전송 때문에 지연이 생김 | 유실될 수 있음 |
| 우리 프로젝트 | HTTP(API), MQTT, RTSP | WebRTC 미디어 |

라이브 영상이 UDP인 이유가 이 표에 다 있다. 실시간 영상은 **0.3초 늦게 도착한 프레임보다
버려진 프레임이 낫다.** 반대로 로그인 요청은 늦어도 반드시 도착해야 하니 TCP다.

## 3. HTTP, REST, JSON, HTTPS

### HTTP와 요청/응답

HTTP는 클라이언트가 요청을 보내면 서버가 응답하는 규칙이다. 요청 하나는 이렇게 생겼다.

```http
POST /api/auth/login HTTP/1.1
Host: bbanggeut.example.com
Content-Type: application/json
Authorization: Bearer eyJhbGciOi...

{"email":"a@b.com","password":"secret"}
```

- **메서드**: `GET`(조회) `POST`(생성·실행) `PATCH`(부분 수정) `PUT`(전체 교체) `DELETE`(삭제)
- **경로**: `/api/auth/login`
- **헤더**: 부가 정보. 인증 토큰이 여기 실린다
- **본문(body)**: 실제 데이터. 보통 JSON

응답에는 **상태 코드**가 붙는다. 이건 외워 두는 게 이득이다.

| 코드 | 뜻 | 우리 서버에서 언제 |
| --- | --- | --- |
| 200 / 201 / 204 | 성공 / 생성됨 / 성공인데 본문 없음 | 정상 |
| 400 | 요청 형식이 잘못됨 | 필수 필드 누락, 형식 위반 |
| 401 | **당신이 누군지 모름** | 토큰 없음·만료·회수됨 |
| 403 | 누군지는 아는데 **권한이 없음** | 남의 금고 영상 조회 |
| 404 | 없음 | 존재하지 않는 리소스. **숨기고 싶은 것도 404로 답한다** |
| 409 | 상태 충돌 | 이미 등록된 기기, 업로드 무결성 불일치 |
| 429 | 너무 많이 시도함 | 로그인·claim 폭주 차단 |
| 500 | 서버가 터짐 | 우리 잘못. 로그를 봐야 한다 |

**401과 403의 차이**는 반드시 구분해서 말해야 한다. 401은 "신분증을 가져와라", 403은
"신분증은 맞는데 여긴 못 들어간다"다.

### REST와 JSON

REST는 "자원을 URL로 가리키고, 그 자원에 할 일은 HTTP 메서드로 표현한다"는 스타일이다.

```
GET    /api/videos           영상 목록
GET    /api/videos/{id}      영상 하나
DELETE /api/videos/{id}      영상 삭제
POST   /api/videos/{id}/play-url   그 영상의 재생 URL 발급 (동작이라 POST)
```

JSON은 데이터를 글자로 표현하는 형식이다. 언어가 달라도(Dart, Java, Python) 같은 JSON을
읽을 수 있어서 파트 간 계약에 쓴다. 우리 프로젝트의 계약서가 `자료/api/openapi.yaml`이고,
**여기에 없는 API를 앱이 쓰면 CI가 막는다**(31장).

### HTTPS와 TLS

HTTP는 내용이 그대로 흐른다. 같은 와이파이에 있는 사람이 비밀번호를 볼 수 있다. TLS로
암호화한 HTTP가 HTTPS다. 세 가지를 준다.

1. **암호화** — 중간에서 읽을 수 없다
2. **무결성** — 중간에서 바꿀 수 없다
3. **인증** — 접속한 서버가 진짜 그 도메인의 서버다(인증서로 증명)

우리는 nginx가 443에서 TLS를 처리하고, 내부의 Spring에는 평문 HTTP로 넘긴다(같은 기계
안 loopback이라 안전하다). 이걸 **TLS termination**이라고 한다. MQTT도 TLS를 씌워 MQTTS
8883, RTSP도 씌워 RTSPS 8322로 쓴다. 즉 **외부로 나가는 모든 통신은 암호화되어 있다.**

## 4. 우리가 쓰는 도구, 한 줄씩

여기는 훑고 지나가도 된다. 3부에서 실제로 쓰이는 자리에서 다시 설명한다.

### 서버 애플리케이션

- **Java 17**: 백엔드 언어. JVM 위에서 돈다.
- **Spring Boot 3**: Java로 웹 서버를 만드는 프레임워크. HTTP 요청을 받아 우리 코드로 넘겨 주고, 객체를 알아서 만들어 연결해 준다(의존성 주입).
- **Gradle**: 빌드 도구. 라이브러리를 받아오고 컴파일하고 테스트를 돌려 `server.jar` 하나를 만든다.
- **JAR**: 실행 가능한 압축 파일. `java -jar server.jar`로 띄운다. 우리 JAR 안에는 Tomcat(웹 서버)까지 들어 있어서 별도 설치가 필요 없다.

### 데이터

- **PostgreSQL 16**: 관계형 데이터베이스. 사용자·기기·영상 메타데이터 같은 **틀린 값이 있으면 안 되는 데이터**를 트랜잭션으로 지킨다.
- **SQL**: DB에 질의하는 언어.
- **MyBatis**: Java에서 SQL을 직접 쓰게 해 주는 도구. 우리는 애노테이션에 SQL을 적는다.
- **Flyway**: DB 스키마 변경을 번호 붙은 파일로 관리한다. `V39__...sql`까지 와 있다. 서버가 뜰 때 아직 적용 안 된 파일만 순서대로 실행한다.
- **Redis 7**: 메모리 기반 저장소. 빠르지만 **꺼지면 날아간다.** 그래서 "날아가도 되는 것"만 넣는다 — 로그인 시도 횟수, 기기 접속 상태.

### 파일과 미디어

- **MinIO**: S3와 같은 API를 쓰는 객체 저장소. 우리는 여기에 영상 파일을 넣는다. AWS S3로 갈아탈 때 코드를 거의 안 고칠 수 있다.
- **객체 저장소 vs 파일 시스템**: 폴더 개념이 없고 **키 → 바이트 덩어리** 매핑만 있다. `2026/08/04/<uuid>.mp4` 같은 키는 폴더처럼 보이지만 그냥 이름의 일부다.
- **presigned URL**: "이 키에 15분 안에 한 번 올려도 된다"는 **서명이 URL 안에 박힌 임시 주소**. 이게 우리 업로드 설계의 핵심이다(16장).
- **MediaMTX**: 미디어 서버. 기기가 RTSP로 보낸 영상을 받아 브라우저·앱이 볼 수 있는 WebRTC로 바꿔 흘려 준다.
- **RTSP / WebRTC / WHEP / WHIP**: RTSP는 기기가 송출할 때 쓰는 프로토콜. WebRTC는 브라우저가 저지연으로 받는 기술. WHEP는 "WebRTC로 **보여 주세요**"를 HTTP 한 번으로 시작하는 규격, WHIP는 반대로 "**보낼게요**"(우리는 발화 기능에 쓴다).
- **FFmpeg / 코덱 / remux / transcode**: 영상은 H.264(비디오)·Opus(오디오) 같은 코덱으로 압축돼 있다. **remux**는 압축을 풀지 않고 포장만 바꾸는 것(CPU 거의 안 씀), **transcode**는 다시 인코딩하는 것(CPU 많이 씀). 우리는 라이브에서 **remux만** 한다.

### 통신

- **MQTT**: 작은 메시지를 주고받는 경량 프로토콜. **발행/구독** 모델이라 서로의 주소를 몰라도 된다. 기기가 이동 통신망에 있어 IP가 계속 바뀌어도, 기기가 브로커로 접속해 두면 서버가 명령을 보낼 수 있다.
- **Mosquitto**: 우리가 쓰는 MQTT 브로커. **Dynamic Security 플러그인**으로 기기마다 계정과 토픽 권한을 따로 준다.
- **FCM**: Firebase Cloud Messaging. 앱이 꺼져 있어도 휴대폰에 알림을 띄우는 통로.

### 그 밖

- **nginx**: 앞단에서 요청을 받아 뒤로 나눠 보내는 리버스 프록시. TLS 처리, 경로별 분기, 업로드 크기 제한, 라이브 토큰 검증을 맡는다.
- **Docker / Docker Compose**: 프로그램을 실행 환경째로 포장한 것이 컨테이너. Compose는 여러 컨테이너를 파일 하나로 정의해 함께 띄운다. 우리 인프라 8종이 이 방식이다. **Spring 서버만 컨테이너가 아니라 systemd 서비스로 돈다**(무중단 배포 때문에 — 30장).
- **FastAPI**: Python 웹 프레임워크. editor-api가 이걸로 만들어졌다. 영상 분석에 필요한 MediaPipe·PyAV가 Python 생태계에만 있어서 이 서비스가 따로 존재한다.
- **Jenkins**: CI/CD 서버. 브랜치를 push하면 테스트를 돌리고, master는 승인 후 배포한다.
- **Prometheus / Grafana**: 서버 지표를 모으는 도구 / 그걸 그래프로 보는 도구.
- **k6**: 부하 테스트 도구. 가상 사용자를 여러 명 만들어 API를 두드린다.

## 5. 이름을 종류별로 다시 정리

여기까지 나온 이름이 40개가 넘는다. 헷갈릴 때 돌아올 표다.

| 종류 | 이름 |
| --- | --- |
| 프로그래밍 언어 | Java, Dart, Python, SQL |
| 프레임워크 | Spring Boot, Flutter, FastAPI |
| 프로토콜 | HTTP(S), TCP, UDP, TLS, MQTT(S), RTSP(S), WebRTC(WHEP/WHIP), SMTP |
| 서버 프로그램 | nginx, PostgreSQL, Redis, MinIO, Mosquitto, MediaMTX, Prometheus, Grafana, Jenkins |
| 라이브러리·도구 | MyBatis, Flyway, Gradle, Paho(MQTT 클라이언트), micrometer, k6, FFmpeg |
| 클라우드·서비스 | AWS EC2, Firebase FCM |
| 하드웨어 | Jetson, Raspberry Pi |
| 우리가 만든 것 | Spring 백엔드(`wj-server`), editor-api, Flutter 앱, 기기 에이전트 |
| 개념 | JWT, presigned URL, 트랜잭션, 멱등성, 팬아웃, 무중단 배포 |

---
# 2부. 시스템 전체 그림

여기가 이 문서의 심장이다. 2부만 제대로 읽으면 나머지는 세부 사항이다.

## 6. 빵긋은 무슨 서비스인가

집에 놓은 홈캠이 아이의 **웃음**을 스스로 알아채 그 순간만 잘라 저장하고, 가족이 앱에서 보고
편집해 나눠 갖는 서비스다. 24시간 녹화를 다 올리는 게 아니라 **의미 있는 순간만** 남긴다는
게 핵심이다.

사용자가 앱에서 하는 일은 이렇다.

1. 회원가입하고 로그인한다
2. 홈캠을 등록한다 (기기 화면에 뜬 코드를 입력)
3. 지금 집을 실시간으로 본다 (라이브)
4. 홈캠이 웃음을 감지해 저장한 영상을 본다
5. 그 영상을 편집해 완성본을 만들고 가족과 나눈다
6. 완성본을 휴대폰 갤러리에 저장한다
7. 이번 주에 몇 번 웃었는지 리포트로 본다

이 7개가 MVP다. 3부의 장 구성이 이 순서와 거의 같다.

### 파트가 셋이라는 걸 먼저 알아야 한다

| 파트 | 만드는 것 | 언어 |
| --- | --- | --- |
| 프론트엔드 | Flutter 앱 | Dart |
| 백엔드 (우리) | Spring 서버 + 인프라 + 배포 | Java |
| 임베디드/AI | 홈캠 기기(Jetson·Raspberry Pi) 위의 에이전트, 웃음 감지 | Python |

**웃음을 감지하는 AI는 기기 안에서 돈다.** 서버가 영상을 받아 분석하는 게 아니다. 이 사실이
아키텍처 전체를 결정했다(16장에서 이유를 설명한다).

## 7. 서버 한 대 안에 무엇이 사는가

우리는 EC2 **한 대**에 전부 올렸다. 실제로 지금 돌고 있는 그림이다.

```
 [Flutter 앱]                          [홈캠 기기: Jetson / Raspberry Pi]
    │ REST (HTTPS 443)                    │ MQTTS 8883      (상태·명령·이벤트)
    │ WHEP  (WebRTC, UDP 8189)            │ RTSPS 8322      (라이브 송출)
    │ presigned PUT/GET (HTTPS)           │ presigned PUT   (이벤트 영상 업로드)
    ▼                                     ▼
┌───────────── EC2 한 대 (Ubuntu, 4 vCPU / 16 GB) ─────────────────────────────┐
│                                                                             │
│  nginx  :80 → :443  (TLS 종료, 경로별 분기)                                  │
│    ├─ /api/                    → upstream william_james → Spring 8081|8082  │
│    ├─ /health                  → Spring actuator                            │
│    ├─ /william-james-videos    → MinIO 9000   (원본·완성본 영상)             │
│    ├─ /william-james-edit      → MinIO 9000   (편집 부산물)                  │
│    ├─ /editor/                 → editor-api 18080  (분석·추천 계산)          │
│    ├─ /webrtc/live/{id}/whep   → MediaMTX 8889  (auth_request로 토큰 검증)   │
│    └─ /webrtc/talkback/{id}/whip → MediaMTX 8889  (발화)                     │
│                                                                             │
│  systemd:  william-james@8081 (활성)   william-james@8082 (대기)  ← Spring   │
│                                                                             │
│  docker compose 컨테이너 8종 (전부 127.0.0.1 바인딩):                        │
│    postgres 5432 · redis 6379 · minio 9000 · mosquitto 8883                 │
│    mediamtx 8322/8889/9997 · editor-api 18080 · prometheus 9090 · grafana 3000│
│                                                                             │
│  Jenkins 8080 + 빌드 에이전트 컨테이너 (CI/CD)                               │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 왜 한 대인가

정직하게 말하면 **비용과 팀 규모** 때문이다. SSAFY 프로젝트 기간에 인스턴스를 여러 대 두고
관리할 여력이 없었다. 대신 한 대라는 제약 안에서 할 수 있는 것은 했다.

- 배포 다운타임은 프로세스를 두 개 띄워 없앴다(30장)
- 내부 서비스를 전부 loopback에 묶어 공격면을 줄였다
- 지표와 알림을 붙여 죽은 걸 늦게 알지 않도록 했다

이게 한 대의 한계이기도 하다. **이 기계가 죽으면 서비스가 죽는다.** 면접에서 "가용성은
어떻게 보장하나" 물으면 "지금은 단일 인스턴스라 보장하지 못한다. 다중화의 전제 조건인
무상태성과 외부화는 갖춰 뒀다"고 답하는 게 맞다. 없는 걸 있다고 하면 안 된다.

### 무상태성 — 다중화의 전제

Spring 프로세스 안에는 **사라지면 안 되는 데이터가 없다.** 세션은 DB, 잠깐 쓰는 건 Redis,
파일은 MinIO에 있다. 그래서 프로세스를 죽이고 다시 띄워도, 두 개를 동시에 띄워도 문제가
없다. 무중단 배포가 가능한 이유도 이것이다. **인스턴스를 늘리려면 로드밸런서만 앞에 붙이면
된다** — 코드를 바꿀 필요가 없다.

## 8. 요청이 흐르는 다섯 갈래

이 표가 이 문서에서 가장 중요하다. 외워도 좋다.

| 무엇 | 어디로 | 인증 방법 |
| --- | --- | --- |
| ① 앱 → 서버 API | nginx `/api/` → Spring | **사용자 JWT**. 요청마다 세션·`token_version`을 DB에서 대조 |
| ② 앱·기기 → 영상 파일 | nginx → MinIO | **presigned URL**. 서명이 URL 안에 있어 헤더가 필요 없다 |
| ③ 앱 → 편집 계산 | nginx `/editor/` → editor-api | 같은 키로 서명된 사용자 토큰. 금고 권한은 백엔드에 되물음 |
| ④ 기기 ↔ 서버 | MQTTS 8883, 토픽 `{env}/wj/v2/devices/{id}/…` | **기기별 브로커 계정 + 토픽 ACL** |
| ⑤ 앱 → 라이브 영상 | nginx `/webrtc/…/whep` → MediaMTX | nginx `auth_request` → Spring introspect (**30초 토큰**) |

### 제어 평면과 데이터 평면

다섯 갈래를 한 문장으로 줄이면 이렇다.

> **백엔드는 판단하고 기록한다. 바이트는 다른 놈이 옮긴다.**

백엔드가 하는 판단:

- 이 사람은 누구인가
- 이 사람이 이 기기·이 영상에 접근해도 되는가
- 올려도 되는가 / 올라온 게 정말 그건가
- 지금 라이브를 시작·연장·종료해야 하는가
- 통계에 넣을 수 있는 정상 데이터인가

실제 바이트를 옮기는 놈:

- 영상 파일 → **MinIO**
- 라이브 영상 → **MediaMTX**
- 휴대폰 알림 → **FCM**

이 분리를 **제어 평면(control plane) / 데이터 평면(data plane)** 이라고 부른다. 500 MB
영상이 Spring을 통과하지 않으므로 서버 메모리와 CPU가 파일 크기에 흔들리지 않는다. 이게
presigned URL을 쓰는 이유다.

## 9. 무엇이 어디에 저장되나

| 저장소 | 들어가는 것 | 사라지면 |
| --- | --- | --- |
| **PostgreSQL** | 사용자, 금고, 기기, 영상 메타데이터, 알림, 세션, 감사 로그 | **치명적.** 이게 원본(system of record)이다 |
| **MinIO** | 영상 파일 바이트, 편집 부산물 JSON | 치명적. 영상을 잃는다 |
| **Redis** | 로그인 시도 횟수, 기기 접속 상태(TTL 90초) | **괜찮다.** 잠깐 판단이 둔해지고 스스로 회복한다 |
| Prometheus | 15일치 지표 | 괜찮다. 과거 그래프만 잃는다 |
| 기기 로컬 디스크 | 감지된 원본 클립 (업로드 전) | 업로드 전이면 그 클립을 잃는다 |

**"Redis가 죽으면 어떻게 되나"는 면접 단골 질문**이다. 우리 답은: 로그인 횟수 제한이
판단을 못 하게 되고 그때는 **통과시킨다(fail-open)**. 가용성을 골랐다. 그 대신 BCrypt 해싱이
2차 방어로 남고 경고 로그가 찍힌다. 헬스체크에서도 Redis를 일부러 뺐다 — Redis가 없어도
서비스는 되니까 인스턴스를 "죽었다"고 표시하면 배포가 오히려 위험해진다.

이건 취향이 아니라 **선택이고, 근거를 댈 수 있어야 한다.** 반대로 골랐다면(fail-closed)
Redis 장애가 곧 전체 로그인 불가가 된다.

## 10. 도메인 소유 관계 — 이걸 모르면 코드가 안 읽힌다

```
users (사용자)
  │
  │  vault_memberships (OWNER 1명 / MEMBER n명)
  ▼
memory_vaults (금고 = 가족 단위)          ← 보관 기간·구독이 여기 붙는다
  │
  │  device_bindings ([bound_at, ended_at) 구간 기록)
  ▼
devices (홈캠)
  │
  ▼
videos (영상)  ── video_comments (댓글)
```

핵심을 하나씩.

**금고(Memory Vault)가 중심이다.** 처음에는 "계정 → 기기 → 영상"이었는데 문제가 있었다.
기기를 새로 사거나 소유자를 바꾸면 **과거 영상이 딸려 사라졌다.** 추억을 모으는 서비스에서
기기 교체가 추억 삭제가 되면 안 된다. 그래서 영상이 귀속되는 단위를 기기에서 떼어 **금고**로
옮겼다. 기기는 금고에 **연결(binding)**될 뿐이다.

**금고에는 OWNER가 정확히 한 명이다.** 여러 명을 허용하면 "삭제 권한을 누가 갖는가",
"구독료는 누가 내는가", "마지막 OWNER가 나가면 금고는 어떻게 되는가"가 전부 애매해진다.
한 명으로 못 박고 필요하면 **소유권 이전**을 하게 했다.

**연결에 시작·종료 시각이 있다.** `device_bindings`가 `[bound_at, ended_at)` 구간을 남긴다.
이게 왜 중요한가 — 기기를 다른 집에 팔았을 때, **그 기기가 우리 금고에 있던 기간의 이벤트만**
우리 통계에 들어가야 한다. 이 구간 기록이 없으면 남의 집 웃음이 우리 리포트에 섞인다(21장).

**영상은 금고를 넘어 이동하지 않는다.** `device_id`는 "어느 기기가 찍었나"라는 출처 기록이고
바꾸지 않는다. 접근 권한을 결정하는 건 `vault_id`다.

## 11. 백엔드 폴더 지도

```
backend/
├── server/                       ← Spring Boot 애플리케이션
│   └── src/main/java/com/wj/server/
│       ├── auth/          회원가입·로그인·JWT·비밀번호·시도 제한
│       ├── vault/         금고, 구성원, 금고 단위 통계
│       ├── device/        기기 claim·해제·소유권 이전·presence
│       ├── invitation/    이메일 초대, 받은 초대함
│       ├── iot/           기기 credential, MQTT 송수신, 원시 이벤트
│       ├── video/         업로드·재생·삭제·보관·편집 완성본·댓글
│       ├── storage/       MinIO(S3) presigned URL 발급
│       ├── stream/        라이브 세션·WHEP 토큰·introspection·발화
│       ├── notification/  인앱 알림·FCM 푸시·알림 설정·리포트 발송
│       ├── schedule/      캘린더 일정 CRUD
│       ├── subscription/  구독(보관 기간 연장)
│       ├── editor/        editor-api 서비스 이벤트 수신
│       ├── home/          홈 화면 요약
│       ├── audit/         접근 감사 로그
│       ├── provisioning/  기기 초기 등록(내부 관리용)
│       ├── config/        보안·JWT·MQTT·저장소 설정
│       └── common/        공통 오류·요청 ID·rate limit
│   └── src/main/resources/db/migration/   ← Flyway V1 ~ V39
├── deploy/                       ← 인프라 정의 (여기가 인프라 공부의 시작)
│   ├── docker-compose.yml        컨테이너 8종
│   ├── nginx-william-james.conf  경로 분기
│   ├── nginx-wj-upstream.conf    활성 슬롯 지시자
│   ├── william-james@.service    systemd 템플릿 유닛
│   ├── mediamtx.yml, mosquitto/  미디어·브로커 설정
│   ├── prometheus.yml, grafana-datasources.yml
│   ├── provision-secrets.sh      시크릿 생성·마이그레이션
│   ├── check-william-james.sh    5분 주기 자체 점검
│   └── ZERO_DOWNTIME.md          무중단 배포 문서
video_editor/                     ← editor-api (FastAPI, Python)
Jenkinsfile                       ← 파이프라인 (저장소 루트)
ci/
├── jenkins/
│   ├── scripts/                  테스트·검증 스크립트
│   └── server/deploy/wj-deploy-backend   ← 실제 배포 스크립트
└── load/k6-read-path.js          부하 테스트
자료/api/openapi.yaml              ← 파트 간 REST 계약
자료/api/mqtt-contract.md          ← 파트 간 MQTT 계약
```

### 각 도메인 폴더의 내부 구조는 항상 같다

```
video/
├── api/           Controller + 요청·응답 record   ← HTTP를 아는 층
├── application/   Service + 워커                  ← 규칙을 아는 층
├── persistence/   Mapper (MyBatis 인터페이스)      ← SQL을 아는 층
└── domain/        Row record                      ← 데이터 모양
```

이 네 폴더 규칙만 알면 처음 보는 기능도 위치를 짐작할 수 있다. "영상 목록 로직이 어디
있나?" → `video/application/`. "그 SQL은?" → `video/persistence/`.

---
# 3부. 기능별 흐름

이제 기능 하나씩 따라간다. 코드를 옆에 열어 놓고 읽는 게 좋다. 각 장 끝에 **코드 위치**와
**예상 질문**이 있다.

## 12. 회원가입, 로그인, 세션 유지

### 인증과 인가

- **인증(authentication)**: 너 누구냐 → 실패하면 **401**
- **인가(authorization)**: 너 이거 해도 되냐 → 실패하면 **403**

우리 서버는 요청 하나마다 이 둘을 순서대로 확인한다. 인증은 필터가, 인가는 서비스 계층이
주로 담당한다.

### 회원가입

```
POST /api/auth/signup {email, password, displayName}
  → 이메일 중복 확인
  → 비밀번호를 BCrypt로 해시
  → users INSERT
```

금고는 여기서 만들지 **않는다.** 첫 기기를 claim할 때 만들어진다(14장). 기기가 없는 사용자에게
빈 금고를 미리 만들어 둘 이유가 없기 때문이다.

**비밀번호를 그대로 저장하지 않는 이유.** DB가 유출되면 모든 계정이 즉시 털린다. 게다가
사람들은 비밀번호를 재사용하니까 다른 서비스까지 털린다. 그래서 **되돌릴 수 없는 해시**만
저장한다.

BCrypt는 단순 SHA-256보다 두 가지가 낫다.

1. **느리다** — 의도적으로. 공격자가 초당 시도할 수 있는 횟수를 줄인다
2. **salt가 자동으로 붙는다** — 같은 비밀번호라도 해시가 달라진다. 미리 계산한 표(레인보우 테이블)가 무력해진다

### 로그인

```
POST /api/auth/login {email, password}
  1. Redis 슬라이딩 윈도우로 시도 횟수 확인
       rl:login:email:{email}   10분에 5회
       rl:login:ip:{ip}         10분에 5회
     초과 → 429
  2. 이메일로 사용자 조회 → BCrypt 대조
  3. 실패 → auth_login_attempts에 기록(PostgreSQL) + Redis 카운트 증가 → 401
  4. 성공 → auth_sessions INSERT (refresh 토큰의 해시를 저장)
          → Redis의 이메일·IP 카운트 정리
          → access token + refresh token 반환
```

**왜 Redis와 PostgreSQL 둘 다 쓰나.** 목적이 다르다.

| | Redis | PostgreSQL |
| --- | --- | --- |
| 목적 | **지금 막을지 판단** | **나중에 조사** |
| 성격 | 빠름, 휘발 | 느림, 영구 |
| 우리 쓰임 | 슬라이딩 윈도우 카운터 | `auth_login_attempts` 감사 이력 (파티션) |

Redis 하나만 쓰면 재시작 후 공격 이력이 사라져 조사를 못 한다. PostgreSQL만 쓰면 로그인마다
쓰기가 생겨 느려진다. 그래서 **판단은 Redis, 기록은 PostgreSQL**로 나눴다.

### access token과 refresh token

| | access token | refresh token |
| --- | --- | --- |
| 수명 | **15분** | **14일** |
| 쓰는 곳 | 모든 API 요청의 `Authorization: Bearer` | `/api/auth/refresh` 에서만 |
| 저장 | 앱 메모리·보안 저장소 | 앱 보안 저장소 |
| 서버 저장 | 저장 안 함(JWT 자체로 검증) | **해시**를 `auth_sessions`에 저장 |

**왜 두 개로 나누나.** 하나로 하면 딜레마에 빠진다. 수명이 길면 훔쳐 갔을 때 오래 쓰이고,
짧으면 사용자가 15분마다 다시 로그인해야 한다. 그래서 **자주 쓰이는 건 짧게(access), 오래
쓰이는 건 아껴 쓰게(refresh)** 나눴다.

### JWT란

`헤더.페이로드.서명` 세 덩어리를 점으로 이은 문자열이다.

```
eyJhbGciOiJIUzI1NiJ9 . eyJzdWIiOiI...In0 . 4pcPyMD09olPSyXn
    헤더(알고리즘)         페이로드(주장)        서명
```

- 페이로드는 **암호화가 아니라 인코딩**이다. 누구나 열어 볼 수 있다. **비밀을 넣으면 안 된다.**
- 서명은 서버의 비밀 키로 만든다. 내용을 한 글자 바꾸면 서명이 깨져서 서버가 거부한다.
- 그래서 JWT는 "내용을 숨기는 것"이 아니라 **"내용이 위조되지 않았음을 증명하는 것"**이다.

우리 access token의 주요 claim:

| claim | 뜻 |
| --- | --- |
| `iss` | 발급자. `wj-server` |
| `sub` | 사용자 UUID |
| `sid` | 세션 UUID |
| `tv` | `token_version` |
| `exp` | 만료 시각 |

### 요청마다 DB를 보는 이유 — JWT의 약점을 메운다

JWT의 교과서적 장점은 "서버가 상태를 안 가져도 된다"는 것이다. 서명만 확인하면 되니까 DB를
안 봐도 된다. 그런데 여기 함정이 있다.

> **한 번 발급한 JWT는 만료까지 취소할 수 없다.**

비밀번호를 바꿔도, 로그아웃해도, 기기를 분실해 세션을 회수해도, 이미 나간 access token은
15분 동안 계속 유효하다. 홈캠 서비스에서 15분은 너무 길다.

그래서 우리는 **요청마다 DB를 본다**(`AccessTokenValidator`).

```
서명 검증 → exp 확인 → sid로 auth_sessions 조회
  → 세션이 회수됐나?         → 401
  → users.token_version 이 토큰의 tv와 같나? → 다르면 401
```

`token_version`은 사용자 단위 카운터다. 비밀번호를 바꾸거나 전 세션을 회수하면 이 숫자를
올린다. 그러면 **이전에 발급된 모든 access token이 즉시 무효**가 된다. 세션 하나만 끊고
싶으면 그 세션만 회수하면 된다.

**"그러면 JWT를 쓰는 의미가 없지 않나?"** 좋은 질문이고 실제로 자주 나온다. 답:

- 상태를 아예 안 보는 순수 JWT는 **취소 불가**라는 대가를 치른다. 우리는 그 대가를 받아들일 수 없었다
- 대신 조회는 세션 1건 + 사용자 1건, 인덱스로 찾는 가벼운 읽기다. 부하 테스트에서 350 VU까지 p95 9 ms였다(32장)
- JWT 덕에 여전히 **서버 메모리에 세션을 들고 있지 않다.** 그래서 프로세스를 두 개 띄워도(무중단 배포) 문제가 없다

즉 우리는 "완전 무상태"를 포기하고 **"공유 저장소 기반 무상태"**를 골랐다. 이건 트레이드오프고
근거가 있다.

### refresh 회전과 도난 감지

```
POST /api/auth/refresh {refreshToken}
  → 토큰을 해시해서 auth_sessions에서 찾는다
  → 있으면: 그 세션을 회수하고 새 refresh + 새 access 발급  (회전)
  → 없으면: 이미 회수된 것 중에 같은 해시가 있나 확인
       있으면 → 도난 의심! 그 사용자의 전 세션 회수 + 경고 로그
       없으면 → 그냥 401
```

**회전(rotation)**: refresh를 쓸 때마다 새 것으로 바꾼다. 그러면 훔쳐 간 토큰의 유효 기간이
"14일"에서 "정당한 사용자가 다음에 갱신할 때까지"로 줄어든다.

**재사용 감지**: 이미 회전으로 폐기된 토큰이 다시 오면, 그건 **같은 토큰을 두 주체가 쥐고
있었다는 뜻**이다. 정당한 사용자는 새 토큰을 받았으니 옛것을 쓸 이유가 없다. 그래서 도난
신호로 보고 그 사용자의 세션을 전부 끊는다. 사용자는 다시 로그인해야 하지만, 공격자도
쫓겨난다.

주의할 점: **응답은 평범한 401**이다. "도난이 감지되었습니다"라고 알려 주면 공격자에게
탐지 사실을 가르쳐 주는 셈이다.

### 비밀번호 변경과 재설정

| | 변경(change) | 재설정(reset) |
| --- | --- | --- |
| 누가 | 로그인한 사람 | 비밀번호를 잊은 사람 |
| 확인 방법 | **현재 비밀번호**를 함께 받아 대조 | **이메일로 보낸 토큰** |
| 끝나면 | `token_version` 증가 → 전 세션 무효 | 같음 |

재설정 토큰도 **원문을 저장하지 않는다.** 해시만 `password_reset_tokens`에 넣고, 30분 만료,
한 번 쓰면 소모한다. 존재하지 않는 이메일로 요청해도 **응답은 성공과 같다** — 다르면 어떤
이메일이 가입돼 있는지 알려 주는 통로(계정 열거)가 된다.

### Spring Security 필터 체인이 셋인 이유

우리 서버에는 성격이 다른 클라이언트가 들어온다. 하나의 인증 규칙으로 묶을 수 없다.

| 순서 | 경로 | 인증 방식 |
| --- | --- | --- |
| 1 | `/internal/admin/**` | 관리자 키 (loopback 전용, 불일치는 **404로 위장**) |
| 2 | `/api/iot/**` | **기기 credential** (사용자 JWT가 아니다) |
| 3 | `/api/editor/**` | editor-api 서비스 토큰 (`iss=wj-editor`) — 서비스가 직접 검증 |
| 4 | 나머지 | 사용자 JWT |

3번 체인이 왜 따로 있는지는 **실제 장애에서 나왔다.** 35장에서 자세히 다룬다. 요약하면
`permitAll`은 **인가** 규칙이라서, Bearer 헤더가 실려 들어오면 그 **앞의 인증 필터**가 먼저
검증을 시도해 실패하고 401을 낸다. 인증 필터를 태우지 않으려면 체인을 분리해야 한다.

### 코드 위치

| 무엇 | 파일 |
| --- | --- |
| 회원가입·로그인·refresh·비밀번호 | `auth/application/AuthService.java` |
| 요청마다 세션 검증 | `auth/application/AccessTokenValidator.java` |
| 토큰 생성 | `auth/application/JwtTokenService.java` |
| 시도 제한 | `auth/application/LoginAttemptService.java` |
| 필터 체인 | `config/SecurityConfig.java` |
| 디코더 두 종류 | `config/JwtConfig.java` |
| 스키마 | `db/migration/V1__auth.sql`, `V14__login_rate_limit.sql`, `V25`, `V28` |

### 예상 질문

- **JWT를 쓰면서 왜 DB를 보나?** → 취소 가능성을 얻기 위해. 순수 JWT는 만료까지 무효화가 안 된다
- **`token_version`은 왜 필요한가?** → 세션 단위가 아니라 **사용자 단위**로 한 번에 끊어야 할 때(비밀번호 변경)
- **Redis가 죽으면 로그인이 되나?** → 된다(fail-open). 가용성을 골랐고 BCrypt와 감사 로그가 남는다
- **refresh 회전을 하면 무엇이 좋아지나?** → 도난 토큰의 유효 기간이 줄고, 재사용이 **탐지 신호**가 된다
- **비밀번호 재설정 응답을 왜 성공으로 통일했나?** → 계정 열거를 막기 위해

## 13. 금고(Memory Vault)와 구성원

### 왜 금고를 도입했나

10장에서 말한 그대로다. "계정 → 기기 → 영상" 구조에서는 기기를 바꾸면 추억이 사라졌다.
금고를 중간에 넣어 **영상이 기기가 아니라 가족에 귀속**되게 했다.

### 권한 모델

| 역할 | 할 수 있는 것 |
| --- | --- |
| OWNER (1명) | 전부. 구성원 초대·제거, 기기 연결·해제, 영상 삭제, 구독, 소유권 이전, 금고 폐쇄 |
| MEMBER (n명) | 영상 보기·재생·다운로드, 라이브 보기, 댓글, 편집 |

권한 확인은 **모든 조회에서** 한다. `GET /api/videos/{videoId}` 하나만 봐도 "이 영상이 속한
금고에 이 사용자가 ACTIVE 구성원인가"를 확인한다. 이걸 빠뜨리면 **IDOR**(남의 id를 넣어
남의 데이터를 보는 취약점)이 된다.

### 초대 두 가지

| 방식 | 흐름 | 언제 |
| --- | --- | --- |
| **이메일 초대** | OWNER가 이메일 지정 → 초대 대상만 수락 가능 | 상대 계정을 알 때 |
| **초대 링크** | OWNER가 링크 생성 → 링크로 가입 요청 → OWNER 승인 | 이메일을 모를 때 |

이메일 초대는 **초대장이 대상 이메일에 귀속**된다. 다른 계정이 링크를 주워도 수락할 수 없다.
초대 링크는 링크만 있으면 누구나 **요청**은 할 수 있지만 OWNER 승인이 필요하다. 두 방식 모두
"링크 유출 = 즉시 가입"이 되지 않게 설계했다.

초대 유효 기간은 7일이다.

### 구독과 보관 기간

| | 기본 | 구독 |
| --- | --- | --- |
| 영상 보관 | **30일** | **365일** |

보관 기간은 **금고에 붙는다**(`memory_vaults.retention_days`). 기기가 아니라 금고에 붙은
이유: 기기를 바꿔도 보관 정책이 유지돼야 하고, 구독료는 가족 단위로 내니까.

구독이 끝나면 **유예 기간 30일**을 준다. 유예 중에는 기존 영상이 갑자기 사라지지 않는다.

### 코드 위치

`vault/`, `invitation/`, `subscription/`, `db/migration/V29`~`V31`, `V30__vault_lifecycle_and_vault_invitations.sql`

### 예상 질문

- **OWNER를 왜 한 명으로 제한했나?** → 삭제·과금·폐쇄 권한의 주체를 명확히 하기 위해. 필요하면 이전한다
- **영상의 소유 금고를 바꿀 수 있나?** → 일반 로직에서는 안 된다. 승인된 운영 복구만 예외(36장)
- **기기를 해제하면 영상이 사라지나?** → 아니다. 금고에 남는다. 이게 금고를 만든 이유다

## 14. 기기 등록

### 등록에는 두 단계가 있다

여기서 대부분 헷갈린다. **"기기 등록"은 하나가 아니다.**

```
① 기기 프로비저닝 (공장/개발자 작업)
   기기가 서버에 처음 신고하고 자기 credential을 받는다
   POST /api/iot/enrollment  ← 부트스트랩 credential 사용
   → 운영용 credential(수명 30일) + MQTT 계정 발급

② 사용자 claim (사용자 작업)
   사용자가 앱에서 기기 화면의 코드를 입력해 내 금고에 붙인다
   POST /api/devices/claim {registrationCode}
```

①은 기기가 하고, ②는 사람이 한다. 앱 화면의 "기기 등록"은 ②만 가리킨다.

### 왜 사람의 JWT를 기기에 주지 않나

기기에 사용자 토큰을 넣으면 이런 일이 생긴다.

- 기기를 분해해 토큰을 꺼내면 **그 사용자의 계정 전체**를 쓸 수 있다
- 사용자가 비밀번호를 바꾸면 기기가 죽는다
- 기기를 팔거나 넘길 때 사용자 계정과 얽힌다

그래서 **주체가 다르면 자격증명도 다르다**는 원칙을 세웠다.

| | 사용자 | 기기 |
| --- | --- | --- |
| 자격증명 | JWT (access/refresh) | 기기 전용 credential + MQTT 계정 |
| 수명 | 15분 / 14일 | 부트스트랩 15분 / 운영 30일 |
| 서버 저장 | refresh는 해시 | **secret의 SHA-256 해시만** |
| 회수 단위 | 세션·사용자 | 기기 |

**서버는 기기 secret의 원문을 갖고 있지 않다.** DB가 유출돼도 기기를 흉내낼 수 없다. 반대로
말하면 서버는 secret을 알려 줄 수 없으니, 잃어버리면 재발급뿐이다.

### claim 흐름

```
POST /api/devices/claim {registrationCode, vaultId}
  1. Redis로 시도 제한 확인
       rl:claim:user:{userId}  10분 5회
       rl:claim:ip:{ip}        10분 5회
  2. registration_codes 조회 — 존재·미사용·미만료 + 기기가 UNCLAIMED인지 확인
  3. 하나의 트랜잭션에서:
       devices 상태 갱신 (markClaimed)
       registration_codes 소모 표시 (markUsed)
       vaultId가 없으면 → 금고 생성("나의 추억") + 요청자를 OWNER로
       vaultId가 있으면 → 그 금고의 OWNER인지 확인
       device_bindings INSERT (bound_at = now)
       기기 구성원 목록을 금고 구성원과 동기화
  4. 감사 로그 기록
  5. 실패는 device_claim_attempts에 기록
```

**첫 기기를 붙일 때 금고가 생긴다.** 두 번째 기기부터는 `vaultId`를 지정해 같은 금고에 붙인다.
그때는 **그 금고의 OWNER만** 붙일 수 있다 — MEMBER가 남의 가족 금고에 기기를 끼워 넣지
못하게 한다.

**왜 트랜잭션이어야 하나.** 중간에 실패하면 "코드는 소모됐는데 기기는 안 붙은" 상태가 된다.
사용자는 다시 시도할 수 없고 기기는 고아가 된다. 전부 성공하거나 전부 되돌려야 한다.

**등록 코드 보안**: 짧은 코드는 무작위 시도로 맞힐 수 있다. 그래서 ① 짧은 유효 기간 ②
1회용 ③ 사용자·IP 양쪽 시도 제한 ④ 실패 이력 기록을 걸었다. 사용자 단위만 막으면 계정을
바꿔 가며 시도할 수 있고, IP 단위만 막으면 한 계정으로 여러 IP에서 시도할 수 있다. **둘 다**
필요하다.

**등록 코드를 MQTT로 보내지 않는 이유**: claim 전의 기기는 아직 어떤 금고 소속도 아니다.
브로커에서 이 기기에 줄 수 있는 토픽 권한이 없다. 게다가 코드는 사람이 눈으로 확인해
입력하는 것이라 채널이 화면이어야 한다.

### MQTT 계정과 ACL

기기마다 브로커 계정이 따로 있고, **자기 토픽만** 접근할 수 있다.

```
{env}/wj/v2/devices/{deviceId}/status          기기 → 서버  (쓰기 허용)
{env}/wj/v2/devices/{deviceId}/heartbeat       기기 → 서버  (쓰기 허용)
{env}/wj/v2/devices/{deviceId}/events          기기 → 서버  (쓰기 허용)
{env}/wj/v2/devices/{deviceId}/commands        서버 → 기기  (읽기 허용)
{env}/wj/v2/devices/{deviceId}/commands/ack    기기 → 서버  (쓰기 허용)
```

`{env}`는 `local`(개발) 또는 `prod`(운영)다. 기기 A는 기기 B의 토픽을 읽거나 쓸 수 없다.
이게 없으면 기기 하나가 뚫렸을 때 **모든 집의 명령과 상태**를 볼 수 있다.

Mosquitto의 **Dynamic Security** 플러그인을 쓰기 때문에 브로커를 재시작하지 않고 계정과
권한을 추가·회수할 수 있다.

### 코드 위치

`device/`, `iot/auth/`, `provisioning/`, `db/migration/V3`, `V11`, `V16`, `V21`~`V24`

### 예상 질문

- **MQTT key가 뭔가?** → 기기가 브로커에 접속할 때 쓰는 **기기 전용 계정 비밀**. 사용자 JWT와 무관하고 서버는 해시만 갖는다
- **claim이 왜 트랜잭션인가?** → 코드 소모와 기기 연결이 갈라지면 복구 불가 상태가 생긴다
- **claim 시도 제한을 사용자·IP 둘 다 왜?** → 한쪽만 막으면 다른 축으로 우회된다

## 15. 기기 상태와 presence

앱의 기기 목록에 ONLINE / OFFLINE이 뜬다. 이 값이 어디서 오는가.

### 두 저장소, 우선순위가 있다

```
1순위: Redis  presence:device:{deviceId}   TTL 90초
2순위: PostgreSQL devices.status           (fallback)
```

기기는 **heartbeat를 90초보다 훨씬 자주** 보낸다. 서버는 heartbeat를 받으면 Redis 키를
갱신하고 TTL을 90초로 다시 설정한다.

**핵심은 TTL을 쓰면 "꺼졌다"를 판단할 코드가 필요 없다는 것이다.** 기기가 조용해지면 키가
스스로 사라진다. 만약 DB에만 상태를 두면 "마지막 heartbeat가 90초 넘었으면 OFFLINE으로
바꾸는" 스캔 작업을 주기적으로 돌려야 한다. 기기가 많아질수록 그 스캔이 부담이 된다.

Redis가 죽으면 PostgreSQL의 마지막 상태를 보여 준다. 조금 낡은 값이지만 화면이 비지 않는다.

### retained 메시지와 Last Will

MQTT의 두 기능이 여기서 쓰인다.

- **retained**: 브로커가 그 토픽의 **마지막 메시지를 보관**한다. 서버가 재시작해서 구독을 새로 걸면, 기기가 다시 보내 줄 때까지 기다리지 않고 **즉시 마지막 상태를 받는다.** 그래서 `/status`와 `/registration`은 retain을 쓴다.
- **Last Will (LWT)**: 기기가 접속할 때 "내가 비정상적으로 끊기면 이 메시지를 대신 보내 줘"라고 브로커에 맡겨 두는 것. 전원이 뽑혀도 브로커가 OFFLINE을 알려 준다.

**heartbeat는 retain을 쓰지 않는다.** 지나간 자원 사용량을 보관할 이유가 없고, 오히려 낡은
값이 남으면 오해를 만든다. QoS도 0이다 — 하나 빠져도 다음 것이 곧 온다.

### 기기 상태 값

`UNCLAIMED` → `ONLINE` ↔ `OFFLINE` → `REVOKED`

`CLAIMED`라는 상태는 **없다.** claim되면 곧 ONLINE/OFFLINE으로 관리된다.

### 코드 위치

`iot/telemetry/DevicePresenceStore.java`, `iot/mqtt/`, `device/application/DeviceService.java`,
`db/migration/V15__device_presence.sql`

### 예상 질문

- **presence를 왜 Redis에?** → TTL이 만료 판단을 대신해 준다. 스캔 작업이 필요 없다
- **Redis가 죽으면 기기 상태가?** → DB의 마지막 값으로 보여 준다. 낡을 수 있지만 비지 않는다
- **retain을 어디에 쓰고 어디에 안 쓰나?** → 상태(`/status`)에는 쓰고 heartbeat에는 안 쓴다. 낡은 heartbeat는 해롭다

---
## 16. 이벤트 감지 영상 — 이 프로젝트의 핵심 흐름

가장 중요한 장이다. 여기 나오는 presigned URL, 2단계 업로드, 멱등성, 상태 머신은 다른
기능에서도 계속 재사용된다.

### 왜 감지를 서버가 아니라 기기에서 하나

서버에서 웃음을 감지하려면 **24시간 영상 전체를 서버로 올려야 한다.**

| | 기기에서 감지 (선택) | 서버에서 감지 |
| --- | --- | --- |
| 네트워크 | 웃은 순간만 올린다 | 24시간 전부 올린다 |
| 저장 비용 | 클립만 | 전부 저장 후 버림 |
| 프라이버시 | 웃지 않은 시간은 **집을 떠나지 않는다** | 전부 서버로 나간다 |
| 서버 비용 | 낮음 | GPU 필요 |
| 지연 | 즉시 | 업로드 + 분석 시간 |

프라이버시 항목이 결정적이다. 가정 내 영상을 다루는 서비스에서 **"불필요한 영상은 집 밖으로
나가지 않는다"**는 건 마케팅 문구가 아니라 설계 결정이다.

### MQTT 이벤트는 "영상 만들어라"가 아니다

여기서 오해가 자주 생긴다.

```
기기: 웃음 감지 → 로컬 디스크에 클립을 이미 저장함
     → MQTT /events 로 "이런 이벤트가 있었다"고 통지        ← 통지일 뿐
     → 별도로 HTTP presigned 업로드를 진행
```

MQTT 이벤트는 **이미 일어난 일에 대한 통지**다. 서버가 그걸 받아서 영상을 만드는 게 아니다.
왜 이렇게 나눴나 — MQTT는 작은 메시지에 맞는 프로토콜이고, 영상 파일(수십~수백 MB)을 MQTT로
보내면 브로커가 죽는다. **작은 사실은 MQTT, 큰 바이트는 HTTP**다.

### presigned 업로드 2단계

```
1단계: 권한 요청
  기기 → POST /api/iot/videos/upload-url
         헤더: Idempotency-Key: {sourceEventId}
         본문: {sourceEventId, triggerType, eventTypes,
                capturedStartAt, capturedEndAt, sizeBytes, sha256}
  서버 → Idempotency-Key가 sourceEventId와 같은지 확인 (다르면 거절)
       → 크기 상한 확인 (500 MiB 초과 → 413 VIDEO_TOO_LARGE)
       → capturedEndAt > capturedStartAt 확인
       → 기기가 claim 완료 상태인가 (아니면 409 DEVICE_NOT_CLAIMED)
       → (device_id, source_event_id)로 기존 행을 찾는다
            없으면 → videos INSERT (status = UPLOADING)
            있으면 → 같은 업로드인지 대조하고 재사용
       → storageKey = "private/{deviceId}/events/{videoId}.mp4"
       → MinIO presigned PUT URL 발급 (유효 15분) + 필수 헤더 목록
       → {videoId, alreadyCompleted, uploadUrl, method, requiredHeaders, expiresAt}

2단계: 업로드 후 완료 통지
  기기 → MinIO 로 직접 PUT (바이트는 서버를 통과하지 않는다)
  기기 → POST /api/iot/videos/complete {videoId, objectETag}
  서버 → MinIO에 stat 요청 (진짜 있나? 크기가 맞나?)
       → ETag 대조
       → videos UPDATE (status = READY, sizeBytes)
       → 금고 구성원 전원에게 알림 생성 + 푸시
```

### presigned URL이 왜 좋은가

- 500 MB 파일이 **Spring을 통과하지 않는다.** 서버 메모리·CPU가 파일 크기에 안 흔들린다
- 기기에 S3 access key를 주지 않는다. **이 키 하나, 15분, 한 번**만 허용된다
- 서명이 URL 안에 있으므로 **헤더가 필요 없다.** 이게 나중에 중요해진다(19장)

### presigned URL이 유출되면?

솔직한 답이 필요한 질문이다.

- 할 수 있는 것: 15분 안에 **그 키 하나에** 데이터를 올릴 수 있다
- 할 수 없는 것: 다른 영상 읽기, 삭제, 목록 조회, 버킷 관리

그리고 우리는 **올린 내용을 바꿔치기하는 것**까지 막는다. 3중 확인이다.

| 확인 | 방법 | 한계 |
| --- | --- | --- |
| ① 크기 | 1단계에서 받은 `sizeBytes` 상한 검사 | 기기 **자가 신고** |
| ② 내용 해시 | `x-amz-meta-sha256`을 **서명에 포함** | 기기 자가 신고 |
| ③ **ETag** | MinIO가 실제 바이트로 계산한 ETag vs 기기가 보고한 ETag | — |

①②는 기기가 스스로 말한 값이다. 서명 URL이 유출돼 다른 내용이 올라가면 ①②로는 못 잡는다.
③이 그걸 잡는다. 불일치면 **409 `UPLOAD_INTEGRITY_MISMATCH`**다.

> 옛 버전 기기 에이전트는 ETag를 보내지 않는다. 그때는 통과시킨다 — 안 그러면 업데이트되지
> 않은 기기의 업로드가 전부 실패한다. 이런 **하위 호환 처리**는 실서비스에서 늘 필요하다.

### 업로드 크기 상한을 두 곳에 맞춰야 하는 이유

```
서버:  MAX_UPLOAD_BYTES = 524_288_000L        (500 MiB)
nginx: client_max_body_size 512m              (512 MiB)
```

**한쪽만 크면 안 된다.** nginx가 2 GB를 허용하고 서버가 500 MB만 허용하면, 2 GB 본문이
디스크까지 다 도착한 뒤에야 거절된다. 대역폭과 디스크를 이미 쓴 다음이다. 그래서 nginx가
먼저 자르도록 두 값을 맞춰 두고, **배포 계약 테스트가 이 정합을 검사한다**(31장).

### 멱등성 — 같은 요청을 두 번 받아도 한 번만

네트워크는 불안정하다. 기기가 `upload-url`을 보냈는데 응답을 못 받으면 다시 보낸다. 서버가
그때마다 새 영상 행을 만들면 **같은 이벤트가 중복 저장**된다.

그래서 `(device_id, source_event_id)`에 **부분 유일 인덱스**를 걸었다.

```sql
CREATE UNIQUE INDEX ux_videos_device_event
    ON videos (device_id, source_event_id) WHERE source_event_id IS NOT NULL;
```

`WHERE ... IS NOT NULL`이 붙은 이유: 기기 이벤트가 아닌 영상(사용자 업로드, 편집 완성본)은
`source_event_id`가 없다. PostgreSQL에서 NULL은 서로 같지 않다고 보지만, 의도를 명시하는
편이 안전하다.

같은 요청을 몇 번 보내도 결과가 같은 성질을 **멱등성(idempotency)**이라고 한다. 우리 구현은
여기서 한 겹 더 나간다.

| 상황 | 서버 응답 |
| --- | --- |
| 처음 요청 | 새 행 + presigned URL |
| 같은 요청 재시도 (아직 UPLOADING) | **같은 행 + 새 URL** (URL은 15분이면 만료되므로 다시 발급) |
| 이미 업로드 완료(READY) | `alreadyCompleted = true`, URL 없음 — 기기가 다시 올리지 않는다 |
| 이전 시도가 FAILED | 재시도를 허용하고 상태를 UPLOADING으로 되돌린다 |
| 그 밖의 상태(DELETING 등) | 409 `VIDEO_STATE_CONFLICT` |
| 같은 event_id인데 **내용이 다름** | 거절 — 크기·시각·해시를 대조한다(`verifySameUpload`) |

마지막 줄이 중요하다. 멱등성은 "같은 키면 같은 결과"인데, **같은 키로 다른 내용을 보내는 건
멱등이 아니라 사고**다. 그걸 조용히 덮어쓰면 앞의 영상을 잃는다. 그래서 대조해서 거절한다.

`Idempotency-Key` 헤더도 받는데, **본문의 `sourceEventId`와 같아야 한다.** 헤더와 본문이
어긋난 요청은 클라이언트 버그이므로 처리하지 않고 거절한다.

멱등성은 이 프로젝트 전반에 나온다.

| 어디 | 어떻게 |
| --- | --- |
| 영상 업로드 | `(device_id, source_event_id)` 부분 유일 인덱스 + 내용 대조 |
| 알림 | `(user_id, dedupe_key)` 유일 제약 + `ON CONFLICT DO NOTHING` |
| 리포트 발송 | `dedupe_key = "weekly-report:{userId}:{연도}-W{주차}"` |
| 삭제 잡 | 상태 머신으로 재시도 안전 |

**알림 dedupe가 특히 예쁘다.** INSERT가 성공했을 때만 푸시를 보낸다. 그러면 스케줄러가 두 번
돌아도 사용자 휴대폰은 한 번만 울린다. "중복 방지 로직"을 따로 쓰지 않고 **DB 제약이 판단을
대신**하게 만든 것이다.

### 영상 상태 머신

```
UPLOADING ──(complete)──→ READY ──(보관 만료/사용자 삭제)──→ DELETING ──→ DELETED
    │
    └──(30분 지나도 안 옴)──→ FAILED
```

| 상태 | 뜻 |
| --- | --- |
| `UPLOADING` | 권한은 줬고 아직 안 왔다 |
| `READY` | 확인됐다. 목록에 보이고 재생된다 |
| `FAILED` | 끝내 안 왔다. 7일 보관 후 정리 |
| `DELETING` | 지우기로 결정. 목록에서 사라진다 |
| `DELETED` | MinIO 객체까지 지웠다 |

`PROCESSING`도 enum에 있지만 현재 흐름에서는 쓰지 않는다.

### 목록 조회 — 왜 offset 대신 cursor인가

```
GET /api/videos?vaultId=…&cursor=…&limit=20
```

`offset`(몇 개 건너뛰기)의 문제:

1. **느려진다.** `OFFSET 10000`은 DB가 10,000개를 세고 버린다
2. **중복·누락이 생긴다.** 1페이지를 본 뒤 새 영상이 추가되면, 2페이지에서 이미 본 항목이 다시 나온다

cursor는 "마지막으로 본 항목이 여기까지"를 기준으로 삼는다. 우리는 `(created_at, id)`를
인코딩해 커서로 쓴다. `id`를 같이 넣는 이유는 **같은 시각에 만들어진 영상이 있을 수 있어서**
정렬 기준이 유일해야 하기 때문이다.

### 재생과 다운로드

```
POST /api/videos/{videoId}/play-url      → presigned GET (5분)
POST /api/videos/{videoId}/download-url  → presigned GET + Content-Disposition
```

둘 다 **권한 확인 후 짧은 수명의 서명 URL**을 준다. 차이는 브라우저·앱이 재생하게 할지
저장하게 할지의 헤더뿐이다.

`GET`이 아니라 `POST`인 이유: 조회가 아니라 **발급(부수효과가 있는 동작)**이고, 감사 로그를
남긴다. 그리고 URL이 브라우저 히스토리·프록시 로그에 남지 않게 하려는 의도도 있다.

### 삭제와 보관 만료

```
사용자 삭제 또는 보관 만료
  → videos.status = DELETING
  → video_deletion_jobs INSERT
  → VideoDeletionWorker (5초 주기)
       → MinIO 객체 삭제 (먼저!)
       → videos.status = DELETED (나중)
```

**MinIO를 먼저 지우는 이유**가 중요하다. DB를 먼저 지우면 `storage_key`를 잃어버려서 **어떤
객체를 지워야 하는지 알 수 없게 된다.** 그러면 MinIO에 영원히 남는 고아 객체가 생긴다. 돈이
계속 나가고, 개인정보가 계속 남는다.

순서를 뒤집을 수 없다면 실패했을 때는? 잡을 `RETRY`로 두고 백오프하며 다시 시도한다. 최악의
경우 "MinIO는 지워졌는데 DB는 DELETING"인데, 이건 **재시도로 수렴**한다. 반대 방향의 사고는
수렴하지 않는다. **되돌릴 수 있는 쪽으로 실패하게 설계**하는 게 원칙이다.

### PostgreSQL과 MinIO의 역할 분담

| | PostgreSQL | MinIO |
| --- | --- | --- |
| 담는 것 | 영상의 **사실**(누가·언제·어느 기기·상태·크기) | 영상 **바이트** |
| 왜 | 권한·정렬·집계·트랜잭션이 필요 | 크고, 순차 읽기만 하면 됨 |
| 없으면 | 영상이 누구 것인지 모른다 | 재생이 안 된다 |

**둘 다 맞아야 영상이 있는 것이다.** DB만 `READY`이고 객체가 없으면 목록에는 보이지만 재생이
실패한다. 반대면 지워지지 않는 유령 파일이다. 36장의 복구 사례가 이 얘기다.

### 코드 위치

| 무엇 | 파일 |
| --- | --- |
| 업로드 2단계 | `video/application/IotVideoService.java` |
| 목록·상세·커서 | `video/application/VideoQueryService.java`, `VideoCursorCodec.java` |
| 재생·다운로드·삭제 | `video/application/VideoCommandService.java` |
| presigned URL 발급 | `storage/ObjectStorageService.java` |
| 워커 3종 | `video/application/{UploadStateSweepWorker,RetentionSweepWorker,VideoDeletionWorker}.java` |
| 스키마 | `V4__videos.sql`, `V5__video_deletion_jobs.sql`, `V19`, `V33` |

### 예상 질문

- **영상이 서버 메모리를 지나가나?** → 아니다. presigned URL로 MinIO에 직접 올라간다
- **업로드가 중간에 끊기면?** → `UPLOADING`으로 남고 30분 후 `FAILED`. 객체가 있으면 보관 만료가 정리한다
- **같은 이벤트가 두 번 올라오면?** → 기존 행을 재사용한다. 이미 READY면 `alreadyCompleted`로 알려 다시 올리지 않게 한다
- **같은 event_id로 다른 내용을 보내면?** → 거절한다. 그건 멱등이 아니라 사고다
- **왜 삭제할 때 MinIO를 먼저?** → DB를 먼저 지우면 `storage_key`를 잃어 고아 객체가 남는다
- **presigned URL이 유출되면?** → 15분간 그 키 하나에 쓰기만. 내용 치환은 ETag 대조로 막는다

## 17. 알림과 푸시

### 두 가지를 구분하라

| | 인앱 알림 | 푸시 알림 |
| --- | --- | --- |
| 어디 | 앱의 알림함 (`notifications` 테이블) | 휴대폰 상단, 앱이 꺼져 있어도 |
| 누가 보내나 | 우리 서버 | **FCM** |
| 사라지나 | 남는다 | 지나가면 끝 |

우리는 **둘을 함께** 만든다. DB에 알림 행을 넣고, 성공하면 FCM으로 푸시도 보낸다.

### 알림 종류

| type | 언제 |
| --- | --- |
| `LAUGHTER_VIDEO_READY` | 웃음 영상 업로드 완료 |
| `INVITATION_RECEIVED` / `INVITATION_ACCEPTED` | 초대 받음 / 내 초대가 수락됨 |
| `EDIT_ANALYSIS_READY` | 편집 분석 완료 |
| `EDIT_COMMENT_ADDED` | 내 편집본에 댓글 |
| `ANNIVERSARY` | 기념일 D-day |
| `WEEKLY_REPORT` | 주간 웃음 리포트 |

### 팬아웃 — 누구에게 만드나

영상 하나가 준비되면 **그 금고의 ACTIVE 구성원 전원**에게 각자의 알림 행을 만든다. 한 행을
여러 명이 공유하지 않는다. 읽음 여부가 사람마다 다르고, 나중에 나간 구성원의 알림을 지우기도
쉽다.

이렇게 한 사건이 여러 대상으로 퍼지는 걸 **팬아웃(fan-out)**이라고 한다.

### 트랜잭션 커밋 뒤에 보낸다

```java
dispatchAfterCommit(...)   // 커밋이 성공한 다음에 FCM 호출
```

**왜.** 트랜잭션 안에서 푸시를 보내면, 그 뒤에 트랜잭션이 롤백됐을 때 **DB에는 없는 알림이
휴대폰에는 도착**한다. 사용자가 알림을 눌렀는데 아무것도 없는 상황이 된다. 외부로 나가는
호출은 되돌릴 수 없으니 **커밋 후로 미룬다.**

### 푸시 토큰 관리

```
POST   /api/notifications/push-tokens {installationId, platform, token}
DELETE /api/notifications/push-tokens/{installationId}
```

- 앱 설치마다 `installationId`가 있다. 같은 사용자가 여러 기기를 쓸 수 있다
- FCM이 **"이 토큰은 죽었다"**고 답하면 그 토큰을 정리한다. 안 하면 죽은 토큰에 계속 보낸다
- 여러 토큰에 한 번에 보내는 **multicast**를 쓴다

### 알림 설정 — 기본값 설계가 포인트

```
GET  /api/notifications/preferences
PATCH /api/notifications/preferences
```

```sql
AND COALESCE(p.new_memory_alerts, true)
```

`COALESCE(..., true)`가 핵심이다. **설정 행이 없는 사용자는 "켜짐"으로 본다.** 이 기능이
생기기 전에 가입한 사용자는 설정 행이 없다. 만약 `= true`로만 비교하면 그 사람들의 알림이
**조용히 전부 꺼진다.** 기존 사용자를 깨지 않는 기본값을 고르는 건 마이그레이션의 기본이다.

### 기념일·주간 리포트 발송기

```
매일   09:00 KST → 기념일 D-day 알림
매주 월 09:00 KST → 주간 웃음 리포트
```

**서버가 09:00에 꺼져 있었으면?** cron은 지나간 시각을 다시 실행해 주지 않는다. 그래서 기동
시 보정을 넣었다.

```java
@EventListener(ApplicationReadyEvent.class)
void catchUpAfterStartup()   // 오늘 09:00이 이미 지났으면 한 번 실행
```

이게 안전한 이유는 **dedupe_key** 때문이다. 이미 보냈으면 INSERT가 `ON CONFLICT DO NOTHING`
으로 무시되고 푸시도 안 나간다. **재실행이 안전하게 설계돼 있으면 보정 로직을 마음 놓고
넣을 수 있다.** 반대로 멱등하지 않은 작업에 보정을 넣으면 중복 발송 사고가 난다.

### 코드 위치

`notification/application/{NotificationService,PushNotificationDispatcher,ReportNotificationScheduler}.java`,
`db/migration/V26`, `V34`, `V35`, `V36`, `V38`

### 예상 질문

- **왜 커밋 후에 푸시를?** → 롤백됐는데 푸시가 나가면 DB에 없는 알림이 휴대폰에 남는다
- **스케줄러가 두 번 돌면 두 번 보내나?** → 아니다. `(user_id, dedupe_key)` 유일 제약으로 한 번이다
- **서버 재시작으로 09:00을 놓치면?** → 기동 시 보정한다. dedupe 덕에 중복이 없다
- **알림 설정 행이 없는 옛 사용자는?** → `COALESCE(…, true)`로 켜진 것으로 본다

## 18. 라이브 스트리밍

### 헷갈리는 지점부터 정리

**MQTT로 영상이 흐르는 게 아니다.** MQTT는 "송출 시작해라 / 시작했다 / 멈춰라" 같은 **명령과
상태**만 나른다. 영상 바이트는 RTSP → MediaMTX → WebRTC로 흐른다.

```
[기기] ──RTSPS 8322──→ [MediaMTX] ──WHEP/WebRTC──→ [앱]
   ▲                                                 │
   │ MQTT commands (시작/중단)                        │ REST (세션 생성·heartbeat)
   └──────────────── [Spring 백엔드] ←────────────────┘
```

### 전체 흐름

```
1. 앱 → POST /api/devices/{deviceId}/stream-sessions
2. 서버: 금고 구성원 확인 → stream_sessions INSERT (PENDING)
        → device_streams 상태 STARTING
        → MQTT /commands 로 "송출 시작" 발행 (streamId, RTSP 목적지 포함)
3. 기기: RTSPS로 MediaMTX에 송출 시작
        → MQTT /stream/events 로 "준비됐다" 통지
4. 서버: 세션 READY + live token(30초) 발급
        → 앱에 whepUrl + token 반환
5. 앱: nginx의 /webrtc/live/{streamId}/whep 로 접속
6. nginx: auth_request 로 Spring /api/live/introspect 에 토큰 검증 요청
        → 200이면 MediaMTX로 통과, 아니면 거절
7. 앱: 15초마다 heartbeat → 세션 연장
8. 시청자가 사라지면 → 서버가 STOP 명령 발행
```

### 라이브는 WebRTC 전용이다

HLS는 **쓰지 않는다.** MediaMTX 설정이 `hls: false`이고 응답에도 `whepUrl`만 있다. 오디오
코덱은 AAC가 아니라 **Opus**다.

**왜 WebRTC인가.** 지연 시간이다. HLS는 영상을 몇 초 단위 조각으로 잘라 보내서 구조적으로
**5~20초** 늦는다. 홈캠에서 "지금 아이가 뭐 하나"를 5초 늦게 보는 건 실시간이 아니다.
WebRTC는 **1초 이내**다.

대가도 있다. WebRTC는 UDP와 NAT 통과가 필요해서 방화벽 환경에서 더 까다롭고, 브라우저·앱
구현이 복잡하다. HLS 폴백이 없으니 **WebRTC가 막힌 네트워크에서는 라이브를 못 본다.** 이건
알려진 한계다.

### remux만 하고 transcode는 하지 않는다

기기가 이미 H.264로 인코딩해서 보내므로 MediaMTX는 **포장만 바꾼다**(remux). 다시 인코딩하면
CPU가 폭발한다 — 4 vCPU 한 대에서 여러 집의 라이브를 동시에 트랜스코딩하는 건 불가능하다.
**인코딩을 기기에 맡긴 것이 서버 비용을 지킨 결정**이다.

### live token이 필요한 이유

MediaMTX는 우리 사용자·금고·권한을 모른다. WHEP 주소를 아는 사람은 누구나 볼 수 있다면 링크
하나로 **남의 집 거실**이 공개된다.

그래서 nginx가 중간에서 검사한다.

```nginx
location ~ "^/webrtc/live/(?<wj_stream_id>[0-9a-fA-F-]{36})/whep" {
    auth_request /_live_auth;      # 먼저 Spring에 물어본다
    proxy_pass http://127.0.0.1:8889;
}
location = /_live_auth {
    internal;
    proxy_pass http://william_james/api/live/introspect?streamId=…&token=…&scope=…;
}
```

`auth_request`는 **본 요청을 보내기 전에 다른 곳에 물어보고, 2xx면 통과시키는** nginx 기능이다.
이 패턴의 이름이 **introspection**이다.

live token의 성질:

- 수명 **30초**. 유출돼도 곧 죽는다
- `iss=wj-live`, `typ=live` — 액세스 토큰(`iss=wj-server`)으로는 통과할 수 없다
- **scope가 박혀 있다**: `PLAY`(보기) / `TALK`(발화). 재생 토큰으로 기기 스피커에 송출할 수 없다

scope 분리가 왜 필요한가 — 보는 권한과 **말하는 권한은 다르다.** 발화는 집 안에 소리를 내는
행위라 더 민감하다. 토큰 자체에 용도를 새겨서 재사용을 막았다.

### 세션 수명 — 세 가지 타이머

| 값 | 기본 | 뜻 |
| --- | --- | --- |
| `viewer-ttl` | 45초 | 이 안에 heartbeat가 없으면 그 시청자는 떠난 것 |
| `idle-timeout` | 60초 | 시청자가 아무도 없으면 송출을 멈춘다 |
| `edge-lease` | 120초 | 기기에 준 송출 허가의 최대 수명. 서버가 죽어도 기기가 무한 송출하지 않는다 |
| `heartbeat-interval` | 15초 | 앱이 보내는 주기 |
| `talkback-ttl` | 30초 | 발화 권한 수명. **heartbeat보다 길어야** 말하는 중에 끊기지 않는다 |

**왜 이렇게 여러 겹인가.** 각 층이 다른 실패를 막는다.

- 앱이 죽으면 → heartbeat가 끊겨 45초 후 시청자 목록에서 빠진다
- 모두 나가면 → 60초 후 송출 중단. 기기 전력과 네트워크를 아낀다
- **서버가 죽으면** → 기기의 lease가 120초에 만료돼 스스로 멈춘다

마지막 항목이 중요하다. 서버가 명령을 못 보내는 상황에서도 기기가 알아서 멈춘다. 이걸
**hard lease**라고 하고, 분산 시스템에서 "상대가 죽었을 때 자원이 영원히 잠기는 것"을 막는
표준 기법이다.

### 유령 세션 — heartbeat만으로는 못 잡는 장애

앱은 잘 있고 heartbeat도 오는데 **실제 영상이 안 흐르는** 경우가 있다. 기기 쪽 인코더가
죽었거나 RTSP 연결이 끊긴 상황이다. 서버가 보기에는 세션이 `RUNNING`이라 정상처럼 보인다.

그래서 `StreamMediaReconcileWorker`(15초 주기)가 **MediaMTX 관리 API에 직접 물어본다.**

```
MediaMTX API (127.0.0.1:9997) 에 경로 상태 조회
  → 미디어가 흐르나?
  → 연속 2회 확인 안 되면 세션 실패 처리
```

두 가지 설계 판단이 있다.

1. **연속 2회**(`misses-before-failure: 2`)여야 실패로 본다. 한 번의 일시적 조회 실패로 정상 세션을 죽이면 안 된다
2. 상태를 **`UNKNOWN`으로 답한 경우는 절대 죽이지 않는다.** MediaMTX API 자체가 불안정할 때 모든 세션을 학살하는 사고를 막는다

이게 **fail-safe** 설계다. "확실히 문제일 때만 개입한다."

### 코드 위치

`stream/application/{StreamService,LiveTokenService,StreamLifecycleWorker,StreamMediaReconcileWorker}.java`,
`stream/api/LiveIntrospectionController.java`, `stream/infrastructure/HttpMediaMtxClient.java`,
`backend/deploy/{nginx-william-james.conf,mediamtx.yml}`, `V10`, `V32`

### 예상 질문

- **MQTT로 영상이 흐르나?** → 아니다. 명령·상태만. 영상은 RTSP→MediaMTX→WebRTC
- **왜 HLS가 없나?** → 지연 때문에 WebRTC를 골랐다. 폴백이 없는 건 알려진 한계다
- **WHEP 주소를 알면 남의 집을 볼 수 있나?** → 못 본다. nginx `auth_request`가 30초 토큰을 검증한다
- **서버가 죽으면 기기가 계속 송출하나?** → 아니다. 120초 lease가 만료되면 스스로 멈춘다
- **heartbeat가 오는데 화면이 검으면?** → MediaMTX API로 실제 미디어 흐름을 확인해 잡는다

## 19. 영상 편집과 서비스 경계 (ADR-001)

### 편집은 어디서 일어나나

**휴대폰에서** 일어난다. 서버가 렌더링하지 않는다.

| | 로컬 편집 (선택) | 서버 렌더링 |
| --- | --- | --- |
| CPU | 사용자 휴대폰 | 우리 서버 (4 vCPU) |
| 비용 | 0 | 동시 편집 수에 비례 |
| 미리보기 | 즉시 | 왕복 대기 |

4 vCPU 한 대로 여러 사용자의 영상을 인코딩하는 건 불가능하다. 서버 렌더링 코드는 남아 있지만
앱이 쓰지 않는 **잠든 기능**이다.

### 그럼 editor-api는 뭘 하나

**계산만** 한다.

```
POST /v1/edit-recommendations   자동 편집 추천
PUT/GET /v1/edit-analyses/{id}  영상 분석 (음량·YAMNet 소리 분류·움직임·표정)
PUT/GET /v1/edit-projects/{id}  편집 초안 레시피
POST /v1/comic/{id}/script      4컷 만화 대본
POST /v1/comic/{id}/image       4컷 만화 그림
```

MediaPipe·PyAV·YAMNet 같은 Python 전용 라이브러리가 필요해서 별도 서비스로 뒀다. **이 분리
자체는 옳았다.** JVM으로 MediaPipe를 가져올 방법이 없다.

### 잘못 그었던 경계 — ADR-001

문제는 다른 데 있었다. editor-api가 태어난 뒤 **"이미 여기 저장 코드가 있으니"** 하면서 편집
완성본과 댓글까지 붙었다. 경로 의존(path dependence)이다.

경계가 틀렸다는 신호가 코드에 남아 있었다.

**의존 화살표가 양방향이었다.**
- editor-api → 백엔드: 권한을 알려고 매 요청 `GET /api/videos/{id}` 호출, 알림 보내려고 `/api/editor/events` 역호출
- 백엔드 → editor-api: 삭제할 때 editor의 **버킷 키 접두사를 직접 알고** 지웠다 (`edit-analyses/`, `edit-projects/`, `edited-videos/`)

API가 아니라 **저장소 레이아웃으로 결합**된 상태다. 이건 마이크로서비스가 아니라 그냥 나눠진
하나의 시스템이다.

그리고 실제 결함 4개가 나왔다.

| 증상 | 왜 생겼나 |
| --- | --- |
| 편집본이 **영구 보존** | 금고의 보관 정책이 닿지 않았다. 원본은 30일에 지워지는데 편집본은 남았다 |
| 댓글 **동시 작성 유실** | DB가 없어 `comments.json`을 읽고-붙이고-덮어썼다. 두 사람이 거의 동시에 쓰면 뒤 쓰기가 앞 댓글을 지웠다. `id = len(items)+1`이라 id 충돌도 가능했다 |
| 작성자 이름 **위조 가능** | `users` 테이블이 없어 앱이 보낸 표시 이름을 그대로 저장했다 |
| 업로드가 **운영에서 401** | 완성본은 OS 백그라운드 작업(WorkManager)이 올린다. 세션이 없어 Authorization 헤더를 붙일 수 없는데 editor-api는 모든 `/v1/*`에 Bearer를 요구했다. **기능이 깨진 채 배포돼 있었다** |

여기가 배울 지점이다. **이 4개는 독립된 버그가 아니라 오배치의 증상이다.** 백엔드에 있었다면
트랜잭션 INSERT와 `users` 조인, presigned URL(서명이 URL에 있어 헤더 불필요)로 **애초에 생기지
않았다.**

### 결정과 판단 기준

> **권한·보관·삭제·알림이 필요한 것은 시스템 오브 레코드(백엔드)에 둔다. 계산은 워커에 둔다.**

| editor-api에 남는다 (계산) | 백엔드로 옮겼다 (사용자 콘텐츠) |
| --- | --- |
| 영상 분석 4단계 | 완성본 → `videos`의 `EDIT_OUTPUT` 행 |
| 자동 편집 추천 | 목록 → `GET /api/vaults/{vaultId}/edits` |
| 4컷 만화 워커 | 재생 → 원본과 같은 `POST /api/videos/{id}/play-url` |
| 편집 초안 레시피(당분간) | 댓글 → `video_comments` + `GET·POST /api/videos/{id}/comments` |

### 옮긴 뒤의 흐름

```
1. 앱: 편집 완료 → POST /api/videos/{videoId}/edits
2. 서버: 금고 권한 확인
        → videos INSERT (source_type=EDIT_OUTPUT, status=UPLOADING)
          원본에서 vault_id·device_id·보관 정책을 상속
        → presigned PUT URL 발급 (Content-Type만 서명)
3. 앱: URL을 WorkManager에 넘긴다 (헤더 불필요 → 401 해소)
4. WorkManager: MinIO에 직접 PUT
5. 서버: EditUploadSweepWorker (15초) 가 객체 도착을 감지 → READY 승격
```

5번이 특이하다. **`/complete`를 부를 주체가 없다.** 백그라운드 업로더는 세션도 없고 완료
후 서버를 호출할 수단도 없다. 그래서 기기 업로드와 달리 **서버가 훑어서 승격**한다.

끝내 안 오면 기존 `UploadStateSweepWorker`가 30분 뒤 `FAILED`로 내린다. 새 실패 처리를 만들
필요가 없었다 — **같은 상태 머신에 편입했기 때문**이다. 이게 "같은 경로를 타게 만든다"의
실질적 이득이다.

### 얻은 것

- 편집본이 원본과 **같은 경로**를 탄다: 금고 권한, 보관 만료, 삭제 연쇄, 목록, presigned 재생
- 댓글은 INSERT 한 번이라 유실이 없고, 작성자는 **토큰의 사용자 UUID**로 기록되며 표시 이름은 서버가 `users`에서 조인한다 — 위조 불가
- 백그라운드 업로드가 동작한다 (401 해소)
- editor-api는 여전히 **DB가 필요 없다** — 의존성에 DB 드라이버가 없다

### 남은 부채 (정직하게)

- **편집 초안 레시피**는 아직 editor-api의 MinIO에 있다. 추천 엔진 산출물과 같은 스키마라는 응집성 논거가 있어 우선순위를 낮췄다
- **서버 렌더링**은 앱이 안 쓴다. 쓰기 시작하면 산출물을 백엔드 업로드 예약에 실어야 한다
- 백엔드가 삭제 시 **editor 버킷 접두사를 아는 결합**이 남아 있다. 초안까지 옮기면 사라진다

상세: `자료/docs/ADR-001-editor-api-경계.md`

### 예상 질문

- **왜 서비스를 나눴나?** → MediaPipe·PyAV가 Python 전용이라. 분리는 옳았고 **경계선이 틀렸다**
- **경계를 어떻게 다시 그었나?** → 권한·보관·삭제·알림이 필요한 것은 백엔드, 계산은 워커
- **경계가 틀렸다는 걸 어떻게 알았나?** → 의존 화살표가 양방향이었고, 저장소 레이아웃으로 결합돼 있었다
- **`/complete` 없이 어떻게 READY가 되나?** → 서버가 15초마다 객체 도착을 훑어 승격한다

## 20. 4컷 만화 — 처음부터 경계를 지킨 사례

만화 기능은 ADR-001의 원칙을 **처음부터** 지킨 사례다. 새 기능을 만들 때 따라야 할 모양이다.

```
앱 → POST /api/videos/{videoId}/comic/script   (백엔드)
     백엔드: 인증 + 금고 권한 확인
           → 사용자별 쿼터 확인 (1시간 20건)
           → 원본 영상의 presigned URL을 만들어
           → editor-api 워커 호출 (내부 네트워크)
     워커: ffmpeg로 프레임 추출 → Gemini로 대본·그림 생성
```

**앱이 editor-api를 직접 부르지 않는다.** Spring이 게이트웨이 역할을 하고 워커는 외부에
열리지 않는다. 얻는 것:

- 인증·권한 판정이 한 곳(백엔드)에만 있다
- **쿼터를 걸 수 있다.** 그림 한 장이 실제 크레딧을 쓰므로 사용자별 예산이 없으면 요금 구멍이 된다
- 워커는 presigned URL만 받으므로 저장소 자격증명이 필요 없다

`ComicGatewayService.java`를 보면 이 패턴이 그대로 있다.

## 21. 통계와 리포트

### 두 종류의 통계가 있다

| | 영상 통계 | 이벤트 통계 |
| --- | --- | --- |
| 세는 것 | 업로드된 **영상 행** | 기기가 보고한 **원시 이벤트** |
| API | `GET /api/devices/{id}/stats` | `GET /api/devices/{id}/event-stats`, `GET /api/vaults/{id}/event-stats` |
| 차이 | 업로드 실패·보관 만료로 사라진 건 빠진다 | 업로드와 무관하게 **실제로 일어난 일** |

"이번 주에 몇 번 웃었나"는 **이벤트 통계**가 맞다. 영상이 지워졌어도 웃은 사실은 있었다.

### 금고 단위 통계의 어려움 — binding 구간

`device_events`에는 `vault_id`가 없다. 이벤트는 기기가 보고하는 것이고, 기기는 금고를 옮겨
다닐 수 있다. 그러면 "이 금고의 이번 주 웃음"을 어떻게 세나?

```sql
JOIN device_bindings b ON b.device_id = e.device_id
 AND b.vault_id = #{vaultId}
 AND e.occurred_at >= b.bound_at
 AND (b.ended_at IS NULL OR e.occurred_at < b.ended_at)
```

**이벤트 발생 시각이 그 기기가 이 금고에 연결돼 있던 구간 안에 있을 때만** 센다.

이게 없으면 어떤 사고가 나는가 — 기기를 다른 집에 넘겼는데 그 집의 웃음이 우리 리포트에
섞인다. 반대로 우리가 남의 기기를 받으면 그 집의 과거가 우리 통계에 들어온다. **개인정보
누출**이다. 10장에서 `[bound_at, ended_at)` 구간을 남긴 이유가 여기서 드러난다.

수학에서 반열린 구간 `[a, b)`을 쓰는 이유도 같다. `ended_at`을 포함하면 연결이 끝나는 순간과
다음 연결이 시작되는 순간이 겹쳐 **한 이벤트가 두 금고에 잡힌다.**

### 시간대(timezone)가 왜 중요한가

DB에는 UTC로 저장한다(`timestamptz`). 그런데 사용자는 **한국 시간으로 "어제"**를 본다.

한국 시간 2026-08-04 오전 8시의 이벤트는 UTC로는 2026-08-03 23시다. UTC 기준으로 날짜별
집계를 하면 **아침 9시 전의 웃음이 전날로 밀린다.** 그래서 집계 쿼리에서 `Asia/Seoul`로
변환한 뒤 날짜를 자른다. 리포트 발송 시각도 `zone = "Asia/Seoul"`로 지정한다.

### 집계를 PostgreSQL에서 하는 이유

행을 전부 애플리케이션으로 가져와 Java에서 세지 않는다. `GROUP BY`로 DB가 센다.

- 네트워크로 옮기는 데이터가 수천 배 적다
- 인덱스를 쓸 수 있다
- DB가 이 일에 최적화돼 있다

지금 데이터 규모에서는 이걸로 충분하다. 실측에서 DB 커넥션 풀을 최대 4/10만 썼다(32장).
데이터가 훨씬 커지면 사전 집계 테이블이나 별도 분석 저장소를 볼 단계인데, **아직 그 단계가
아니다.** 필요 없는 걸 미리 넣지 않는 것도 판단이다.

### 코드 위치

`vault/application/VaultEventStatsService.java`, `vault/persistence/VaultEventStatsMapper.java`,
`video/application/VideoStatsService.java`, `iot/` 이벤트 수신, `V18`, `V33`

### 예상 질문

- **영상 통계와 이벤트 통계 중 리포트에 맞는 건?** → 이벤트 통계. 영상이 지워져도 사실은 남는다
- **기기를 양도하면 과거 통계가 오염되나?** → 안 된다. binding 구간과 겹치는 이벤트만 센다
- **왜 `[bound_at, ended_at)` 반열린 구간인가?** → 닫으면 경계 순간의 이벤트가 두 금고에 중복된다
- **집계를 왜 DB에서?** → 데이터 이동이 적고 인덱스를 쓴다. 현재 규모에서 충분하다

## 22. 캘린더 일정

가장 평범한 CRUD다. **처음 코드를 읽을 때 여기서 시작하는 게 좋다** — Controller → Service →
Mapper 3층이 군더더기 없이 들어 있다.

```
GET    /api/schedules
POST   /api/schedules
PATCH  /api/schedules/{scheduleId}
DELETE /api/schedules/{scheduleId}
```

일정에 기념일 플래그를 두면 `ReportNotificationScheduler`가 매일 09:00에 D-day 알림을 만든다
(17장). 즉 이 평범한 CRUD가 알림 도메인과 연결된다.

`schedule/`, `V36__user_schedules_and_notification_prefs.sql`

---
# 4부. 백엔드 공통 원리

3부에서 반복해 나온 것들을 여기 모아 정리한다.

## 23. 3층 구조와 트랜잭션

### Controller → Service → Mapper

```
HTTP 요청
  ↓
Controller   HTTP를 안다. 요청을 받아 검증하고 서비스에 넘긴다. 비즈니스 규칙은 없다
  ↓
Service      규칙을 안다. 권한 확인, 트랜잭션 경계, 여러 매퍼 조합
  ↓
Mapper       SQL을 안다. 그것만 안다
  ↓
PostgreSQL
```

**왜 나누나.** 섞으면 이런 일이 생긴다.

- Controller에 SQL이 있으면 → 같은 조회를 다른 API에서 재사용할 수 없다
- Service가 `HttpServletRequest`를 알면 → 테스트할 때 가짜 HTTP 요청을 만들어야 한다
- Mapper가 권한을 판단하면 → 권한 규칙이 SQL 여기저기 흩어져 감사가 불가능해진다

우리 테스트가 대부분 **Service 단위 테스트**인 것도 이 구조 덕이다. Mapper를 Mockito로
가짜로 두면 DB 없이 규칙을 검증할 수 있다.

### @Transactional

```java
@Transactional
public DeviceResponse claim(UUID userId, ClaimDeviceRequest request, String ip) { … }
```

이 애노테이션이 붙은 메서드는 **전부 성공하거나 전부 되돌려진다.** 중간에 예외가 나면 그
메서드 안에서 한 모든 DB 변경이 취소된다.

붙이는 기준:

- **DB를 두 번 이상 바꾸고, 중간 상태가 잘못된 상태라면** → 필수
- 읽기만 한다면 `@Transactional(readOnly = true)` — DB에 "안 바꿀 거야"라고 알려 최적화를 돕는다

**주의할 점 두 가지.**

1. **외부 호출을 트랜잭션 안에 넣지 마라.** FCM 푸시, editor-api 호출은 롤백할 수 없다. 그래서 커밋 후로 미룬다(17장)
2. **트랜잭션이 길면 락이 오래 걸린다.** 무거운 계산은 트랜잭션 밖에서 하고, DB 변경만 안에서 한다

### validation의 층

| 층 | 무엇을 검사 | 예 |
| --- | --- | --- |
| ① DTO 애노테이션 | 형식 | `@NotNull`, `@Email`, `@Size(max=500)` |
| ② Service | 규칙 | "이 사용자가 이 금고 구성원인가", "코드가 만료됐나" |
| ③ DB 제약 | 최후 방어 | `UNIQUE`, `CHECK`, `FOREIGN KEY` |

**세 층이 다 필요하다.** ①만 있으면 규칙을 어긴 요청이 통과한다. ②만 있으면 동시 요청 두
개가 각각 "괜찮다"고 판단해 둘 다 통과한다(경쟁 조건). ③이 그걸 막는다.

실제 예: 댓글 본문은 DTO에서 `@Size(max=500)`으로 막고, DB에도 걸어 뒀다.

```sql
CONSTRAINT ck_video_comments_body CHECK (char_length(btrim(body)) BETWEEN 1 AND 500)
```

`btrim`(공백 제거)까지 하는 이유 — 공백만 500자인 댓글을 막는다.

### 오류 응답 규약

```json
{
  "code": "UPLOAD_INTEGRITY_MISMATCH",
  "message": "업로드된 객체가 기기가 올린 것과 다릅니다.",
  "requestId": "req-0d08d115-13b3-4381-87c0-ac7785b60165",
  "fieldErrors": null
}
```

- `code`: **기계가 읽는** 값. 앱이 이걸로 분기한다. 절대 바꾸면 안 된다(계약)
- `message`: **사람이 읽는** 값. 바꿔도 앱이 안 깨진다
- `requestId`: 로그 추적용
- `fieldErrors`: 형식 오류일 때 어느 필드가 틀렸는지

**메시지로 분기하면 안 되는 이유**: 문구를 다듬는 순간 앱이 깨진다. 그래서 코드와 메시지를
분리한다.

### request ID

모든 요청에 UUID를 붙여 로그와 응답에 함께 남긴다. 사용자가 "오류가 났어요"라고 스크린샷을
보내면 그 ID로 **그 요청만** 로그에서 찾을 수 있다. 이게 없으면 같은 시각의 수천 줄을
눈으로 훑어야 한다.

`common/web/RequestIdFilter.java`

### 인가와 IDOR

**IDOR**(Insecure Direct Object Reference)는 남의 리소스 id를 넣어 남의 데이터를 보는 취약점이다.

```
GET /api/videos/11111111-…    ← 내 영상, 정상
GET /api/videos/22222222-…    ← 남의 영상 id를 넣어 본다
```

막는 방법은 하나다. **id로 찾은 다음, 그게 요청자 것인지 확인한다.**

```
영상 조회 → 그 영상의 vault_id 확인 → 요청자가 그 금고의 ACTIVE 구성원인가?
  아니면 → 403 (또는 존재를 숨겨야 하면 404)
```

**절대 하면 안 되는 것**: "앱이 자기 것만 요청할 테니까" 믿기. 앱은 우리 통제 밖이다. 누구나
`curl`로 아무 id나 넣어 볼 수 있다.

우리 코드에서 이 확인은 Service 계층에 있다. 모든 조회·수정 메서드가 금고 구성원 확인으로
시작한다. **한 곳이라도 빠지면 그 API가 구멍**이다. 그래서 새 API를 만들 때 가장 먼저 볼 것이
이 확인이다.

## 24. 해시, 암호화, 서명 — 그리고 우리가 쓰는 "키"들

### 세 가지를 구분하라

| | 되돌릴 수 있나 | 목적 | 우리 쓰임 |
| --- | --- | --- | --- |
| **해시** | ✗ 불가능 | 원문을 몰라도 대조 | 비밀번호(BCrypt), refresh 토큰, 기기 secret, 재설정 토큰 |
| **암호화** | ○ 키가 있으면 | 내용 숨기기 | TLS (전송 중) |
| **서명** | — (검증만) | **위조 방지** | JWT, presigned URL |

**핵심 구분**: 해시는 "숨기는 것"이 아니라 **"대조만 가능하게 하는 것"**이다. 서명은
"숨기는 것"이 아니라 **"바뀌지 않았음을 증명하는 것"**이다.

이걸 헷갈리면 "JWT를 쓰니까 안전하다"는 잘못된 말을 하게 된다. JWT의 페이로드는 **누구나 읽을
수 있다.**

### 우리 시스템의 "키"들 — 이름이 비슷해서 반드시 정리해야 한다

| 이름 | 누가 쓰나 | 정체 | 서버 저장 |
| --- | --- | --- | --- |
| access token | 앱 → 서버 API | JWT (`iss=wj-server`), 15분 | 저장 안 함 |
| refresh token | 앱 → `/auth/refresh` | 랜덤 문자열, 14일 | **해시**만 |
| live token | 앱 → nginx → MediaMTX | JWT (`iss=wj-live`), 30초, scope 포함 | 저장 안 함 |
| editor 서비스 토큰 | editor-api → 백엔드 | JWT (`iss=wj-editor`), 60초 | 저장 안 함 |
| 기기 credential | 기기 → `/api/iot/*` | 기기 전용 secret, 30일 | **SHA-256 해시**만 |
| MQTT 계정 | 기기 → Mosquitto | 브로커 계정 비밀 | 브로커가 관리 |
| presigned URL 서명 | 앱·기기 → MinIO | URL에 박힌 서명, 5~15분 | 저장 안 함 |
| `JWT_SIGNING_KEY` | 서버·editor-api | HS256 대칭 키 (96자) | 시크릿 파일 |
| `WJ_BACKEND_*` | 백엔드 → MinIO | MinIO 서비스 계정 (영상 버킷만) | 시크릿 파일 |
| `WJ_EDITOR_*` | editor-api → MinIO | MinIO 서비스 계정 (편집 버킷만) | 시크릿 파일 |
| MinIO root | 관리 작업만 | 버킷·정책·계정 관리 | 시크릿 파일 |
| 관리자 키 | `/internal/admin/*` | loopback 전용 | 시크릿 파일 |

**"MQTT key가 뭐예요?"라고 물으면** — 기기가 브로커에 붙을 때 쓰는 기기 전용 계정 비밀이고,
사용자 JWT와 아무 관계가 없으며, 서버는 해시만 갖고 있다고 답하면 된다.

**토큰마다 `iss`가 다른 이유**: 발급 목적이 다른 토큰을 서로 못 쓰게 하려고. 액세스 토큰으로
라이브를 볼 수 없고, 라이브 토큰으로 API를 부를 수 없다. 같은 키로 서명해도 **용도를 claim에
새겨** 구분한다.

## 25. PostgreSQL, Flyway, MyBatis 실전

### 왜 관계형 DB인가

- **관계**가 본질이다. 사용자–금고–기기–영상–댓글이 전부 연결돼 있다
- **트랜잭션**이 필요하다. claim처럼 여러 테이블을 한 번에 바꾸는 일이 많다
- **제약**으로 잘못된 데이터를 아예 못 들어오게 막을 수 있다
- **집계**를 DB가 해 준다

### 주요 테이블 (29개 + 파티션 자식 2개)

| 묶음 | 테이블 |
| --- | --- |
| 인증 | `users`, `auth_sessions`, `auth_login_attempts`(파티션), `password_reset_tokens` |
| 금고 | `memory_vaults`, `vault_memberships`, `device_bindings` |
| 기기 | `devices`, `device_credentials`, `device_memberships`, `registration_codes`, `device_claim_attempts`(파티션), `device_events` |
| 영상 | `videos`, `video_comments`, `video_deletion_jobs`, `video_edits` |
| 라이브 | `stream_sessions`, `device_streams`, `device_talkbacks` |
| 초대 | `invitations`, `device_invite_links`, `membership_request_links`, `join_requests` |
| 알림 | `notifications`, `notification_push_tokens`, `user_notification_preferences` |
| 기타 | `user_schedules`, `access_logs` |

### Flyway — 스키마 변경 관리

```
V1__auth.sql
V2__devices_and_memberships.sql
…
V39__edit_outputs_and_comments.sql
```

서버가 뜰 때 **아직 적용되지 않은 파일만 번호 순서대로** 실행하고 `flyway_schema_history`에
기록한다. 그래서 로컬·CI·운영의 스키마가 같아진다.

**규칙 세 개.**

1. **이미 적용된 파일을 수정하지 마라.** Flyway가 체크섬으로 잡아내고 기동을 거부한다. 고칠 게 있으면 새 번호로 추가한다
2. **번호가 겹치면 안 된다.** 팀원과 동시에 작업하면 실제로 겹친다 — 우리는 이걸 **세 번** 겪었다(38장)
3. **하위 호환이어야 한다.** 무중단 배포 중에는 구 코드와 신 스키마가 공존한다(30장)

`IF NOT EXISTS`를 즐겨 쓰는 이유도 여기 있다. 여러 환경의 상태가 조금씩 다를 수 있으니
**멱등한 마이그레이션**이 안전하다.

### MyBatis — SQL을 직접 쓴다

```java
@Select("""
    SELECT c.id, c.author_id AS authorId, u.display_name AS authorName,
           c.body, c.created_at AS createdAt
      FROM video_comments c
      JOIN users u ON u.id = c.author_id
     WHERE c.video_id = #{videoId}
     ORDER BY c.created_at, c.id
     LIMIT #{limit}
    """)
List<VideoCommentRow> findForVideo(@Param("videoId") UUID videoId, @Param("limit") int limit);
```

**`#{}`만 쓰고 `${}`는 절대 쓰지 않는다.**

| | `#{}` | `${}` |
| --- | --- | --- |
| 동작 | 값을 **바인딩**(PreparedStatement 파라미터) | **문자열을 그대로 붙인다** |
| SQL Injection | 안전 | **취약** |

`${}`를 쓰면 사용자 입력이 SQL 문법으로 해석된다. 우리 코드베이스에 `${}`는 없고, 새로
넣어서도 안 된다.

### MyBatis에서 실제로 물렸던 것

record를 결과 타입으로 쓸 때 **생성자 선택이 자동으로 안 되는 경우**가 있다. 생성자 후보가
여럿이면 MyBatis가 어느 것을 쓸지 못 고른다. 그러면 단위 테스트는 통과하는데 **운영에서 500**
이 난다. 37장에서 자세히 다룬다.

대응:

- record의 정식 생성자에 `@AutomapConstructor`를 지정한다
- 같은 record를 쓰는 쿼리들의 컬럼 목록·순서·타입을 통일한다
- **실제 PostgreSQL을 쓰는 통합 테스트**를 둔다. Mockito 단위 테스트로는 JDBC 타입 매핑을 검증할 수 없다

`map-underscore-to-camel-case: true` 설정이 있어 `author_id` → `authorId` 변환은 자동이지만,
조인 결과의 별칭은 명시적으로 `AS authorName`처럼 써 주는 편이 안전하다.

## 26. 백그라운드 워커 8종

**스케줄러를 이해하면 서버가 보인다.** 사용자 요청 없이도 서버가 계속 하는 일들이다.

| 워커 | 주기 | 하는 일 |
| --- | --- | --- |
| `StreamLifecycleWorker` | 5초 | 만료 세션 정리, 시청자 없는 스트림 STOP 발행, 발화 권한 회수 |
| `VideoDeletionWorker` | 5초 | **MinIO 먼저, DB 나중** 삭제. 백오프 재시도 |
| `StreamMediaReconcileWorker` | 15초 | MediaMTX API로 실제 미디어 흐름 확인. 연속 2회 미확인 시 실패 처리 |
| `EditUploadSweepWorker` | 15초 | 편집 완성본 객체 도착 감지 → READY 승격 |
| `UploadStateSweepWorker` | 60초 | 30분 넘은 `UPLOADING`을 `FAILED`로, 7일 보관 |
| `RetentionSweepWorker` | 60초 | 보관 만료 영상 `DELETING` 전환 + 삭제 잡 등록 |
| `ReportNotificationScheduler` | 매일 / 매주 월 09:00 KST | 기념일 D-day, 주간 리포트. 기동 시 보정 |
| `SecurityAttemptRetentionWorker` | 매일 04:15 KST | 시도 이력 파티션 정리 |

그 밖에 `PahoMqttGateway`가 10초마다 MQTT 재연결을 확인하고, `MqttTopicAclMigrationWorker`가
기동 후 토픽 ACL을 정리한다.

### 워커를 짤 때의 원칙

1. **한 번에 다 하지 않는다.** `BATCH = 50` 처럼 묶음을 제한한다. 한 번에 10만 건을 처리하면 트랜잭션이 길어지고 락이 걸린다
2. **실패는 다음 주기에 맡긴다.** `continue`하고 넘어간다. 재시도가 안전하도록 멱등하게 짠다
3. **주기는 필요한 만큼만.** 5초 주기 워커가 8개면 그것만으로도 DB에 부담이다
4. **로그를 남긴다.** 조용히 일하는 코드는 조용히 고장 난다

`EditUploadSweepWorker`가 좋은 예다. 저장소 조회가 실패하면(아직 안 왔거나 MinIO가 불안정)
그냥 `continue`한다. 다음 주기에 다시 본다. 끝내 안 오는 건 다른 워커가 정리한다. **각 워커가
자기 책임만 지고, 나머지는 다른 워커를 믿는다.**

## 27. Redis를 어디에 쓰나 — 그리고 어디에 안 쓰나

### 쓰는 곳

| 키 | 용도 | 만료 |
| --- | --- | --- |
| `rl:login:email:{email}` | 로그인 시도 제한 | 10분 슬라이딩 윈도우 |
| `rl:login:ip:{ip}` | 같음, IP 기준 | 10분 |
| `rl:claim:user:{userId}` | 기기 claim 시도 제한 | 10분 |
| `rl:claim:ip:{ip}` | 같음, IP 기준 | 10분 |
| `presence:device:{deviceId}` | 기기 온라인 상태 | **TTL 90초** |

공통점: **날아가도 서비스가 죽지 않는다.**

### 안 쓰는 곳 — 그리고 왜

| 안 쓰는 것 | 왜 |
| --- | --- |
| 세션 저장소 | DB에 있어야 감사·회수가 가능하다. Redis가 날아가면 전원 로그아웃된다 |
| 조회 캐시 | 아직 필요 없다. 실측에서 읽기 경로가 병목이 아니다(32장) |
| 큐 | 워커가 DB 테이블을 큐로 쓴다. 트랜잭션과 함께 묶을 수 있다 |

**"캐시를 왜 안 쓰나"**는 좋은 질문이다. 답: 부하 테스트에서 350 VU에 p95 9 ms, DB 풀 4/10.
**병목이 아닌 곳에 캐시를 넣으면 복잡성과 정합성 문제만 생긴다.** 넣을 근거가 생기면 넣는다.

이게 "기술을 안 써서 못 쓰는 것"과 "재 보고 안 쓰는 것"의 차이다. 후자는 근거를 댈 수 있다.

### fail-open을 고른 근거

`LoginAttemptService`는 Redis가 답을 못 하면 **통과시킨다.** 관련 설정까지 함께 봐야 이해가 된다.

```yaml
redis:
  timeout: 500ms          # 멈춘 Redis가 요청을 붙잡고 있지 않게 짧게
  connect-timeout: 500ms
management.health.redis.enabled: false   # Redis 없이도 서비스되므로 헬스에서 제외
```

세 설정이 **한 방향**을 향한다. "Redis는 있으면 좋은 보조 장치이고, 없으면 조금 둔해질 뿐
서비스는 계속된다." 타임아웃이 길면 fail-open의 의미가 없다 — 판단은 통과시켜도 **요청은
이미 느려져 있다.**

이런 게 설계의 일관성이다. 하나만 바꾸면 앞뒤가 안 맞게 된다.

---
# 5부. 인프라, 배포, 관측성, 보안

발표와 면접에서 가장 많이 물어보는 부분이다. 여기가 "그냥 CRUD 만들었어요"와 갈리는 지점이다.

## 28. 서버 구성 — 지금 실제로 돌고 있는 것

2026-08-04 기준으로 서버에서 확인한 상태다.

### Spring은 컨테이너가 아니다

```
systemd:  william-james@8081  →  active     (활성 슬롯)
          william-james@8082  →  inactive   (대기 슬롯)
```

인프라는 전부 Docker인데 **Spring만 systemd 서비스**다. 이유는 무중단 배포(30장) 때문이다.
systemd **템플릿 유닛**(`william-james@.service`)을 쓰면 `@8081`, `@8082`처럼 인스턴스 이름만
바꿔 같은 정의로 여러 프로세스를 띄울 수 있다.

```ini
ExecStart=/usr/bin/java -jar /home/ubuntu/william-james/app/server-%i.jar \
          --server.address=127.0.0.1 --server.port=%i
EnvironmentFile=/home/ubuntu/william-james/secrets/app.env
```

`%i`가 인스턴스 이름(포트)으로 치환된다. `--server.address=127.0.0.1`이 **외부 노출을
막는다** — nginx만 닿을 수 있다.

### 컨테이너 8종

```
william-james-postgres-1    PostgreSQL 16   127.0.0.1:5432
william-james-redis-1       Redis 7         127.0.0.1:6379
william-james-minio-1       MinIO           127.0.0.1:9000
william-james-mosquitto-1   Mosquitto       0.0.0.0:8883  ← 기기가 붙어야 하므로 공개
william-james-mediamtx-1    MediaMTX        8322(공개) / 8889·9997(loopback)
william-james-editor-api-1  FastAPI         127.0.0.1:18080
william-james-prometheus-1  Prometheus      127.0.0.1:9090
william-james-grafana-1     Grafana         127.0.0.1:3000
```

여기에 `minio-init`이 한 번 실행되고 끝난다 — 버킷을 만들고 **서비스 계정을 발급**한다(33장).

Jenkins와 빌드 에이전트 컨테이너들도 같은 기계에 있다. CI가 배포 대상과 같은 기계에서 도는
건 이상적이지 않지만(빌드가 CPU를 먹으면 서비스가 느려진다) 인스턴스가 하나라는 제약의 결과다.

### 왜 대부분 loopback인가

```yaml
ports:
  - "127.0.0.1:5432:5432"    # 이렇게
  # - "5432:5432"            # 이러면 인터넷에 DB가 열린다
```

`127.0.0.1:`을 앞에 붙이면 **호스트 안에서만** 닿는다. 이걸 빠뜨리면 Docker가 iptables 규칙을
만들어 **방화벽을 우회해서** 포트를 공개한다. 실제로 흔한 사고다. "UFW로 막았는데 왜 열려
있죠?"의 답이 이것이다.

## 29. nginx가 하는 일

nginx는 단순 프록시가 아니다. 네 가지를 한다.

### ① TLS 종료

443에서 인증서로 TLS를 처리하고, 내부에는 평문 HTTP로 넘긴다. 인증서 관리가 한 곳에 모인다.

### ② 경로별 분기

```nginx
location /api/                      → upstream william_james   (Spring)
location = /health                  → Spring actuator
location ^~ /william-james-videos   → MinIO 9000
location ^~ /william-james-edit     → MinIO 9000
location ^~ /editor/                → editor-api 18080
location ~ "…/whep"                 → MediaMTX 8889
```

**앱은 도메인 하나만 안다.** 뒤에 서비스가 다섯 개든 사용자는 모른다. 나중에 서비스를
추가·이동해도 앱을 안 고친다.

### ③ 업로드 크기 제한 — 경로마다 다르다

| 경로 | 상한 | 왜 |
| --- | --- | --- |
| 기본(`/api/` 포함) | **2m** | API 요청 본문은 작다. 크면 뭔가 잘못됐다 |
| `/william-james-videos` | **512m** | 영상 업로드. 서버의 500 MiB 상한과 맞춤 |
| `/william-james-edit` | **2m** | 편집 부산물 JSON만 |
| `/editor/` | **2g** | 분석용 업로드 |

**경로마다 다르게 두는 게 중요하다.** 전체를 2 GB로 열면 누가 `/api/auth/login`에 2 GB를
보내 디스크를 채울 수 있다. **가장 큰 값이 필요한 경로에만** 크게 준다.

### ④ 라이브 토큰 검증 (auth_request)

18장에서 본 그것이다. nginx가 미디어를 통과시키기 전에 Spring에 물어본다. **인증 판단은
Spring이 하고 nginx는 집행만 한다** — 권한 규칙이 두 곳에 흩어지지 않는다.

### upstream이 상태 저장소다

```nginx
# /etc/nginx/conf.d/wj-upstream.conf
# 배포 스크립트가 관리한다. 활성 슬롯 지시자이므로 손으로 고치지 말 것.
upstream william_james {
    server 127.0.0.1:8081;
    keepalive 32;
}
```

이 파일이 **"지금 어느 슬롯이 활성인가"의 유일한 진실**이다. 다음 장의 핵심이다.

`keepalive 32`는 nginx가 Spring과의 TCP 연결을 재사용하게 한다. 요청마다 새로 연결하면
핸드셰이크 비용이 계속 든다.

## 30. 무중단 배포 (blue-green)

### 문제

```bash
systemctl restart william-james    # 이러면?
```

JVM이 뜨는 데 수 초 걸린다. 그 사이 모든 요청이 502다. 더 나쁜 것은 **라이브를 보고 있던
사용자가 끊긴다.** 홈캠 서비스에서 이건 체감이 큰 결함이다.

### 해결 — 슬롯 두 개

```
현재:  nginx upstream → 8081 (활성)      8082 (꺼짐)

배포:
  1. 대기 슬롯(8082)에 새 JAR 배치
  2. 8082 기동 → /actuator/health 가 UP 될 때까지 대기
  3. upstream 파일을 8082로 고쳐 쓰고 nginx reload
  4. 5초 대기 (진행 중이던 요청이 끝나도록)
  5. 8081 정지

결과:  nginx upstream → 8082 (활성)      8081 (꺼짐)
```

**다운타임이 없는 이유**: 3번의 `nginx reload`는 프로세스를 죽이지 않는다. nginx가 새 설정으로
워커를 갈아 끼우면서 **진행 중인 연결은 그대로 유지**한다. 새 연결만 8082로 간다.

### 실패하면

upstream을 구 슬롯으로 되돌리고 nginx를 reload한다. **구 슬롯은 아직 살아 있으므로 사용자
영향이 0이다.** 이게 blue-green의 진짜 이득이다 — 롤백이 "재배포"가 아니라 "설정 한 줄
되돌리기"다.

### 슬롯마다 JAR을 따로 두는 이유

```
app/server-8081.jar
app/server-8082.jar
```

같은 파일을 공유하면 안 된다. **실행 중인 JVM이 읽고 있는 JAR을 덮어쓰면 nested jar 로딩이
깨진다.** Spring Boot의 실행 가능 JAR은 내부에 라이브러리 JAR을 품고 있어서, 실행 중에도
파일을 계속 읽는다. 그 파일이 바뀌면 클래스 로딩이 실패한다.

### 실측

20 VU 부하를 걸어 놓고 슬롯을 전환했다.

| 항목 | 결과 |
| --- | --- |
| 총 요청 | **94,042** |
| 실패 | **0건** |
| 처리량 | 1,567 req/s |
| p95 | 24 ms |

"무중단이라고 주장한다"와 "부하 중 94,042요청 무실패를 실측했다"는 다르다. **주장에 숫자를
붙이는 습관**이 중요하다.

### 무중단 배포가 만드는 제약 — 마이그레이션

여기가 진짜 배울 지점이다. 전환 중에는 이런 순간이 있다.

```
8082(새 코드) 기동 → Flyway 마이그레이션 적용
        ↓ 이 시점
8081(구 코드)이 아직 서비스 중 — 이미 바뀐 스키마 위에서
```

즉 **구 코드와 신 스키마가 잠시 공존한다.** 따라서 마이그레이션은 **backward-compatible**
이어야 한다.

| 안전 | 위험 — 두 단계 릴리스로 나눠야 함 |
| --- | --- |
| 컬럼 추가 (nullable 또는 DEFAULT 있음) | 컬럼·테이블 **삭제** |
| 테이블 추가 | 컬럼 **이름 변경** |
| 인덱스 추가 (`CONCURRENTLY` 고려) | 타입 변경 |
| 제약 추가 (기존 데이터가 만족할 때) | `NOT NULL` 강화 |

컬럼을 지워야 하면 이렇게 나눈다.

```
릴리스 1: 코드에서 그 컬럼을 안 쓰게 만든다 (스키마는 그대로)
릴리스 2: 컬럼을 지운다
```

이름을 바꿔야 하면 **추가 → 양쪽 쓰기 → 읽기 전환 → 삭제** 네 단계다. 귀찮지만 이게
무중단의 대가다.

상세: `backend/deploy/ZERO_DOWNTIME.md`

### 예상 질문

- **무중단을 어떻게 구현했나?** → systemd 템플릿 유닛 두 개 + nginx upstream 전환. 헬스 통과 후 교체, 실패 시 되돌림
- **활성 슬롯은 어디에 기록되나?** → `/etc/nginx/conf.d/wj-upstream.conf`. 릴리스 파일이 이걸 덮으면 매번 8081로 되돌아간다
- **무중단이면 마이그레이션에 어떤 제약이 생기나?** → 구 코드와 신 스키마가 공존하므로 추가 위주여야 한다. 삭제·타입 변경은 두 단계로
- **왜 슬롯마다 JAR을 따로 두나?** → 실행 중 JVM이 읽는 파일을 덮으면 nested jar 로딩이 깨진다

## 31. CI/CD와 배포 계약 테스트

### 파이프라인

```
기능 브랜치 push
  ↓
Jenkins 멀티브랜치가 브랜치 이름으로 스테이지를 고른다
    feat|fix/backend/**   → Backend + API Contract
    feat|fix/frontend/**  → Frontend + API Contract
    feat|fix/device/**    → Device + API Contract
    master, develop       → 네 개 전부
  ↓
Backend 스테이지
    ① 배포 계약 테스트     ← 아래 설명
    ② JAR 검증
    ③ gradle test
    ④ 배포 아티팩트 패키징
    ⑤ editor-api pytest
  ↓
master CI 성공 → Production 잡 자동 트리거 → 【사람이 승인】 → 배포
```

**왜 브랜치 이름으로 스테이지를 고르나.** 프론트 코드만 바꿨는데 기기 AI 테스트까지 돌리면
피드백이 느려진다. 파이프라인이 느리면 사람들이 CI를 우회하기 시작한다. **빠른 CI가 지켜지는
CI다.**

**왜 배포에 사람 승인을 두나.** CI 통과는 "코드가 맞다"는 뜻이고, 배포는 "지금 나가도 된다"는
판단이다. 둘은 다르다. 시연 5분 전에 자동 배포가 나가면 안 된다.

### 배포 계약 테스트 — 이 프로젝트에서 배울 게 가장 많은 파일

`ci/jenkins/scripts/test-backend-deploy-contract.sh`

이 스크립트는 코드의 정확성을 검증하지 않는다. **과거에 실제로 겪은 사고가 다시 일어날 수
없게 문자열 단위로 못 박는다.**

지금 걸려 있는 검사들:

| 검사 | 어떤 사고를 막나 |
| --- | --- |
| Flyway 버전 중복 | 팀원과 같은 번호를 써서 기동 실패 (3번 겪음) |
| 아티팩트 파일 집합 | 배포에 필요한 파일이 빠져서 배포 후 기동 실패 |
| editor-api 소스 포함 / 모델 제외 | 소스 누락, 또는 수백 MB 모델이 아티팩트에 섞임 |
| WebRTC·talkback URL, MediaMTX 포트 정합 | 설정 불일치로 라이브 실패 |
| Redis가 배포 정의에 있나 | 인프라 하나가 조용히 빠짐 |
| editor-api 자동 배포 4단계 | 수동 배포 시절로 되돌아감 |
| **MinIO root 자격증명 사용 금지** | 최소 권한 회귀 |
| nginx location 중복 | 병합 사고로 `/editor/` 블록이 두 벌 → nginx 기동 실패 (실제 발생) |
| 관측성 노출 설정 | Prometheus가 조용히 수집 중단 |
| **업로드 한도 정합** (`512m` ↔ `524_288_000L`) | 한쪽만 커서 큰 본문이 디스크에 도달 |
| 무중단 전환 4요소 | 슬롯 전환 로직이 유실 |
| Prometheus `file_sd_configs` | 슬롯 전환 후 수집 끊김 (실제 발생) |
| **`/api/editor/**` 전용 보안 체인** | 편집 분석 알림 미발송 (실제 발생 — 35장) |

원칙 한 줄:

> **같은 사고를 두 번 겪지 않으려면 계약으로 못 박는다.**

사람의 기억이나 문서에 의존하면 반드시 재발한다. 3개월 뒤 다른 사람이(또는 미래의 나가)
같은 실수를 한다. **CI가 막으면 재발하지 않는다.**

이 파일을 읽으면 이 프로젝트가 무엇을 겪었는지가 다 보인다. 발표에서 "우리는 사고를 이렇게
자산화했다"고 말할 수 있는 근거다.

### 배포 스크립트

`ci/jenkins/server/deploy/wj-deploy-backend` — 실제 배포를 수행한다. 순서가 설계돼 있다.

```
1. 아티팩트 풀기, 시크릿 확인
2. editor-api 이미지 빌드           ← 라이브 변경 전에 먼저 빌드
3. 인프라 compose 갱신
4. 대기 슬롯에 JAR 배치 → 기동 → 헬스 대기
5. nginx upstream 전환 + reload
6. Prometheus 타겟 파일 갱신
7. 구 슬롯 정지
실패 시: 롤백 (upstream 되돌림, editor-api :previous 태그 복원) 후 exit 1
```

**2번이 3번보다 앞인 이유**: 이미지 빌드는 실패할 수 있다. 라이브 인프라를 건드린 뒤에
빌드가 깨지면 반쪽 상태가 된다. **실패할 수 있는 일을 먼저** 한다.

**롤백 후 `exit 1`이 중요한 이유**는 34장에서 다룬다.

## 32. 관측성 — 죽은 걸 늦게 알지 않기

### 세 층

```
① 지표(metrics)   Spring Actuator + micrometer → /actuator/prometheus
                  Prometheus가 15초마다 수집 → Grafana가 그린다
② 자체 점검       check-william-james.sh 가 5분마다 → 실패 시 웹훅
③ 로그           journalctl -u william-james@8081
```

### Prometheus가 활성 슬롯을 따라가는 방법

고정 타겟(`static_configs`)을 쓰면 슬롯이 8081→8082로 바뀔 때 **수집이 조용히 끊긴다.**
그래프가 비는데 서비스는 정상이라 알아채기 어렵다. **실제로 겪었다.**

그래서 **파일 기반 서비스 디스커버리**로 바꿨다.

```yaml
scrape_configs:
  - job_name: spring
    file_sd_configs:
      - files: ["/etc/prometheus/targets/spring.json"]
        refresh_interval: 15s
```

배포 스크립트가 슬롯을 전환할 때 이 파일을 다시 쓴다.

```json
[{"targets": ["127.0.0.1:8081"], "labels": {"job": "spring", "slot": "8081"}}]
```

Prometheus는 파일이 바뀌면 알아서 새 타겟을 잡는다. 재시작이 필요 없다. `slot` 라벨이 붙어
있어서 **그래프에서 어느 슬롯이 서비스 중이었는지도 보인다.**

### 자체 점검 스크립트

`check-william-james.sh`가 5분마다 확인한다.

- 활성 슬롯의 프로세스와 헬스
- nginx 상태
- **컨테이너 8종이 모두 Running인가**
- TLS 인증서 남은 기간
- 디스크 사용률 (85% 넘으면 경고)

실패하면 `WJ_MONITOR_WEBHOOK_URL`로 알린다. 이 값을 채워야 실제로 알림이 온다 — 안 채우면
journal에만 남는다.

**디스크를 감시하는 이유**: 영상 서비스에서 디스크가 차면 업로드가 실패하고 PostgreSQL이
멈춘다. 그리고 디스크는 **천천히, 조용히** 찬다. 사람이 알아채는 시점은 보통 늦다.

### Grafana 처음 쓰는 방법

Grafana는 loopback 전용이라 SSH 터널로 접속한다.

```bash
ssh -i ~/Downloads/I15E201T.pem -L 3000:127.0.0.1:3000 ubuntu@i15e201.p.ssafy.io
```

그 상태로 브라우저에서 `http://localhost:3000` 을 연다. 데이터 소스(Prometheus)는 프로비저닝
파일로 이미 연결돼 있다.

**왜 외부에 열지 않나.** Grafana는 서버 내부 지표를 다 보여 준다. 공개하면 우리 시스템 구조와
부하 패턴이 노출된다. 게다가 Grafana 자체의 취약점이 나오면 그게 침입 경로가 된다. **볼 사람이
소수라면 터널이 맞다.**

처음 볼 지표 네 개:

| 지표 | 뜻 |
| --- | --- |
| `http_server_requests_seconds` | 요청 지연. p95를 본다 |
| `hikaricp_connections_active` | DB 커넥션 사용량. 풀 크기에 붙으면 병목 |
| `jvm_memory_used_bytes` | 힙 사용량. 계속 오르면 누수 의심 |
| `process_cpu_usage` | CPU |

**"평소 값"을 먼저 알아야 한다.** 이상을 판단하려면 정상을 알아야 한다. 아무 일 없을 때 한
번 보고 기억해 두는 게 첫 단계다.

### 부하 특성 (2026-08-04 실측)

| 시나리오 | 최대 VU | 처리량 | p95 | 실패율 |
| --- | ---: | ---: | ---: | ---: |
| 읽기 5종 | 50 | 112 req/s | 33 ms | 0.00% |
| 인증 읽기 2종 | 350 | **335 req/s** | **9 ms** | 0.00% |

읽어야 할 것:

- **한계를 못 찾았다.** 350 VU에서도 p95 9 ms, 실패 0. 읽기 경로는 병목이 아니다
- 50 VU 구간의 p95(33 ms)가 더 컸던 건 TLS 핸드셰이크가 섞였기 때문. 연결이 재사용되면 한 자릿수 ms다
- **DB 커넥션 풀을 최대 4/10만 썼다.** 캐시를 넣을 근거가 없다는 뜻이다
- k6를 **같은 인스턴스에서** 돌렸으므로 CPU를 나눠 썼다 — 보수적인 값이다

정직하게 말할 한계:

- 쓰기 경로(업로드·라이브·편집)는 **의도적으로 안 쟀다.** 운영 인스턴스가 하나라 데이터를 남기거나 미디어 서버를 흔들 수 없었다
- WHEP 동시 시청 한계는 모른다. 실제 병목은 여기일 가능성이 높다
- 진짜 위험은 처리량이 아니라 **단일 인스턴스 가용성**이다

스크립트: `ci/load/k6-read-path.js`, 결과: `ci/load/README.md`

## 33. 시크릿과 자격증명 용도 분리

### 왜 나누나 — 최소 권한

하나의 강력한 자격증명을 모두가 쓰면, **하나가 유출되면 전부 잃는다.** 그래서 주체마다 딱
필요한 만큼만 준다.

### MinIO 계정 세 개

| 계정 | 접근 범위 | 쓰는 곳 |
| --- | --- | --- |
| `WJ_BACKEND_*` | **영상 버킷만** | Spring 백엔드 |
| `WJ_EDITOR_*` | **편집 버킷만** | editor-api |
| root | 버킷·정책·계정 관리 | **관리 작업만.** 애플리케이션은 쓰지 않는다 |

예전에는 둘 다 root를 썼다. 그러면 editor-api가 뚫렸을 때 원본 영상 전체와 **버킷 삭제
권한**까지 넘어간다.

서버에서 실제로 교차 접근을 시도해 확인했다.

```
backend 계정 → 편집 버킷        DENIED
backend 계정 → 관리 API         DENIED
editor  계정 → 영상 버킷        DENIED
```

**"권한을 나눴다"고 말하는 것과 "거부되는 것을 확인했다"는 다르다.** 설정만 하고 검증하지
않으면 정책 문법 실수로 실제로는 안 나뉘어 있을 수 있다.

이 분리는 `minio-init` 컨테이너가 기동 시 `mc admin` 명령으로 만든다
(`docker-compose.yml`의 `make_scoped_user()`). 회귀를 막기 위해 **배포 계약 테스트가 root
사용을 금지**한다.

### 다른 시크릿들

| 시크릿 | 용도 |
| --- | --- |
| `JWT_SIGNING_KEY` | 사용자·라이브·editor 토큰 서명 (96자). editor-api의 `EDITOR_JWT_SECRET`과 **같은 값** |
| `DB_PASSWORD` | PostgreSQL |
| `MQTT_USERNAME/PASSWORD` | 백엔드가 브로커에 붙을 계정 (기기 계정과 별개) |
| `FIREBASE_*` | FCM |
| `DEVICE_PROVISIONING_ADMIN_KEY` | `/internal/admin/*` |
| `GMS_KEY` | 만화 그림 생성 |
| `WJ_MONITOR_WEBHOOK_URL` | 모니터 알림 |

저장 위치: 백엔드는 `/home/ubuntu/william-james/secrets/app.env`(systemd `EnvironmentFile`),
인프라는 `infra/.env`(docker compose). **둘 다 git에 없다.** `provision-secrets.sh`가 생성·
갱신한다.

### 보안 경계 총정리

| 경계 | 방법 | 왜 |
| --- | --- | --- |
| 사용자 세션 | 액세스 15분 + refresh 14일 회전. **요청마다** 세션·`token_version` DB 대조 | 회수·비밀번호 변경을 즉시 반영 |
| refresh 도난 | 이미 회전된 토큰이 다시 오면 전 세션 회수 + 경고 | 두 주체가 같은 토큰을 쥐었다는 신호. 응답은 평범한 401 |
| 로그인 폭주 | Redis 슬라이딩 윈도우(이메일·IP 5회/10분) + PostgreSQL 감사 이력 | Redis 장애 시 fail-open(가용성). BCrypt가 2차 방어 |
| 기기 인증 | 사용자 JWT와 분리된 credential. **SHA-256 해시만** 저장 | DB가 새도 기기를 흉내낼 수 없다 |
| 기기 간 격리 | Mosquitto 계정 + 토픽 ACL | 기기 하나가 뚫려도 남의 집 명령·상태를 못 본다 |
| 객체 저장소 | 버킷별 서비스 계정, root는 관리 전용 | 유출 피해를 버킷 하나로 묶는다. **거부를 실측 확인** |
| 업로드 무결성 | ① 크기 ② 서명된 sha256 ③ **MinIO ETag 대조** | ①②는 자가 신고. ③이 내용 치환을 잡는다 |
| 업로드 크기 | 서버 500 MiB = nginx `512m`, 경로별 상한 | 한쪽만 크면 초과 본문이 디스크에 도달한 뒤 거절된다 |
| 라이브 시청 | 30초 토큰 + nginx `auth_request` + scope(PLAY/TALK) | 링크 공유로 남의 집을 볼 수 없고, 재생 토큰으로 말할 수 없다 |
| 내부 API | `/internal/admin/*` loopback + 관리자 키, 불일치는 **404로 위장** | 존재 자체를 숨긴다 |
| 서비스 간 호출 | `iss`로 용도 구분(`wj-server`/`wj-live`/`wj-editor`), 전용 필터 체인 | 토큰을 다른 용도로 재사용할 수 없다 |
| 네트워크 | 외부 5갈래만 공개, 나머지 loopback | 공격면 축소 |
| SQL | MyBatis `#{}` 전용, `${}` 금지 | SQL Injection |
| IDOR | 모든 조회가 금고 구성원 확인으로 시작 | 남의 id로 남의 데이터를 못 본다 |

---
# 6부. 실제로 겪은 장애 5건

이 부분이 발표에서 가장 잘 통한다. 기능 목록은 누구나 말하지만, **무엇이 왜 깨졌고 어떻게
재발을 막았는지**는 실제로 겪은 팀만 말할 수 있다.

각 사례를 **증상 → 진짜 원인 → 고친 방법 → 배운 원칙** 순서로 정리했다.

## 34. 배포가 "성공"이라고 보고하면서 실패한 사건

### 증상

배포 #71, #72가 연달아 실패했다. 그런데 더 이상했던 건 **어떤 실행은 로그에 `status=SUCCESS`
를 남기고도 서비스가 옛 버전이었다**는 점이다.

### 원인 — 세 개가 겹쳤다

**① `set -o pipefail`에 걸려 조용히 죽었다**

```bash
editor_model_dir="$(grep -E '^EDITOR_MODEL_DIR=' "${infra_env}" | tail -1 | cut -d= -f2-)"
```

`.env`에 `EDITOR_MODEL_DIR`가 없으면 `grep`이 종료 코드 1을 반환한다. `pipefail` + `set -e`
아래에서는 **이 줄에서 스크립트가 죽는다.** 값이 없어도 되는 선택적 설정인데 배포 전체가
멈췄다. 그리고 죽은 위치가 로그의 초반이라 원인처럼 보이지 않았다.

```bash
# 고침
editor_model_dir="$(grep -E '^EDITOR_MODEL_DIR=' "${infra_env}" | tail -1 | cut -d= -f2- || true)"
```

**② 롤백 핸들러가 errexit를 무력화해서 "좀비 실행"이 됐다**

롤백 함수 안에서 `set +e`를 했다. 롤백 중에는 명령이 실패해도 계속 진행해야 하니 합리적으로
보였다. 문제는 **그 설정이 함수를 나가서도 유지됐다**는 것이다.

```
실패 발생 → 롤백 실행(set +e) → 롤백 끝
  → 스크립트가 계속 실행됨 (errexit가 꺼져 있으니 안 멈춘다)
  → 마지막 줄의 "status=SUCCESS" 기록까지 도달
```

즉 **롤백된 인프라 위에 성공 기록이 덮였다.** 가장 위험한 종류의 버그다 — 실패를 성공으로
보고하면 사람이 조사를 시작하지 않는다.

```bash
# 고침: 롤백 핸들러 끝에서 명시적으로 실패로 끝낸다
exit 1   # 롤백이 곧 배포 실패다
```

**③ nginx에 `/editor/` location이 두 벌 있었다**

브랜치 병합 사고로 같은 location 블록이 중복됐다. nginx는 `duplicate location "/editor/"`로
**기동을 거부**한다. 설정 파일 하나 때문에 전체 재적용이 실패했다.

고침: 두 블록을 하나의 상위집합으로 병합. 그리고 **배포 계약 테스트에 중복 location 검사**를
추가했다(URI를 정규화해서 비교한다 — `/editor` 와 `/editor/` 를 같은 것으로 봐야 한다).

추가로 롤백 경로가 정의되지 않은 서비스(prometheus·grafana)를 띄우려다 실패하는 문제가 있어
`compose config --services`로 존재를 확인하도록 가드를 넣었다.

### 배운 원칙

1. **선택적 설정 읽기에는 `|| true`를 붙인다.** `pipefail`은 강력하지만 "없어도 되는 것"을 구분해 주지 않는다
2. **`set +e`의 범위를 반드시 좁힌다.** 서브셸로 감싸거나, 함수 끝에서 상태를 명시적으로 끝낸다
3. **실패를 성공으로 보고하는 코드가 가장 위험하다.** 롤백은 성공이 아니라 실패다
4. **설정 파일도 테스트 대상이다.** nginx 문법 오류로 배포가 죽는다면 CI가 미리 잡아야 한다

면접식 한 문장:

> 배포 스크립트가 롤백 후에도 계속 실행돼 성공으로 기록하는 문제를 찾아 롤백을 명시적 실패로
> 끝내게 고쳤고, 원인이던 pipefail·중복 location을 배포 계약 테스트로 고정했습니다.

## 35. `permitAll`을 걸었는데 401 — 인증과 인가의 순서

이 사건은 **2026-08-04에 서버 로그를 확인하다 발견**했다. 문서를 쓰기 전에 상태를 검증한
덕에 찾았다.

### 증상

editor-api 컨테이너 로그에 이게 반복되고 있었다.

```
백엔드 알림 발신 실패: ANALYSIS_READY
Traceback (most recent call last):
  File "/app/video_editor/backend_events.py", line 54, in _notify
urllib.error.HTTPError: HTTP Error 401:
```

editor-api가 분석을 마치고 백엔드에 "알림 보내 줘"라고 호출하는데 계속 401이었다. 즉
**편집 분석 완료 알림이 한 건도 발송되지 않고 있었다.**

### 조사 — 하나씩 지웠다

```
① 시크릿이 다른가?      → 두 값의 길이·동일성 비교 → 일치
② permitAll이 배포됐나? → 배포된 JAR에서 문자열 확인 → 있다
③ 재현해 보자          → 응답 메시지가 결정적이었다
```

재현할 때 **알림이 실제로 생기지 않도록 일부러 잘못된 이벤트 타입**을 보냈다. 인증이 통과하면
422, 실패하면 401이 나오므로 부수효과 없이 구분할 수 있다.

```
Authorization 헤더 있음 → 401 {"message":"로그인이 필요합니다."}
Authorization 헤더 없음 → 422 {"fieldErrors":{"videoId":"must not be null"}}
```

**메시지가 범인을 지목했다.** `"로그인이 필요합니다"`는 `EditorEventService`가 내는 문구가
아니다(그건 `"편집 서버 토큰이 필요합니다"`다). 즉 **컨트롤러에 도달하지도 못했다.**

### 진짜 원인

```
permitAll  = 인가(authorization) 규칙
             ↑
        그 앞에 인증(authentication) 필터가 있다
```

Spring Security의 `oauth2ResourceServer`는 **`Authorization: Bearer` 헤더가 있으면 무조건
검증을 시도한다.** editor-api의 토큰은 `iss=wj-editor` 서비스 토큰이라 사용자 액세스 토큰
디코더(`AccessTokenValidator`: 세션·`token_version` 확인)를 통과할 수 없다. 인증 실패 →
필터가 401을 내고 끝. **`permitAll`은 그 뒤 단계라서 실행되지 않는다.**

그리고 헤더를 빼면 필터는 통과하지만 `EditorEventService`가 "토큰이 없다"고 401을 낸다.

> **즉 이 엔드포인트는 어느 경우에도 통과할 수 없었다.**

주석에는 "이 체인의 디코더로는 검증할 수 없으니 서비스가 직접 검증한다"고 **정확히 적혀
있었다.** 이유를 알고 있었는데 `permitAll`이 그 문제를 해결해 준다고 착각한 것이다. 인증과
인가의 순서를 놓쳤다.

### 고친 방법

`/api/editor/**`에 **인증 필터를 태우지 않는 전용 체인**을 만들었다. `/api/iot/**`가 이미
같은 모양이다 — 주체가 다르면 체인을 나눈다는 원칙이 이미 있었는데 editor만 예외로 두려 한
게 실수였다.

```java
@Bean
@Order(3)
public SecurityFilterChain editorEventFilterChain(HttpSecurity http) throws Exception {
    http
        .securityMatcher("/api/editor/**")
        .csrf(csrf -> csrf.disable())
        .sessionManagement(s -> s.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
        .authorizeHttpRequests(auth -> auth.anyRequest().permitAll());
    return http.build();
}
```

그리고 배포 계약 테스트에 **체인 분리**와 **`permitAll` 부활 금지**를 못 박았다.

라이브 introspect(`/api/live/introspect`)는 왜 같은 문제가 없었나 — 토큰을 **쿼리 파라미터**로
받는다. `Authorization` 헤더가 없으니 인증 필터가 손대지 않는다. 우연히 안전했던 셈이다.

### 배운 원칙

1. **인증과 인가는 순서가 있다.** `permitAll`은 인증 실패를 구제하지 못한다
2. **주체가 다르면 필터 체인을 나눈다.** 사용자·기기·서비스는 자격증명 종류가 다르다
3. **"최선 노력"으로 처리한 실패는 조용히 쌓인다.** 알림 발송은 실패해도 편집을 막지 않게 경고 로그만 남기도록 했는데, 그래서 **아무도 몰랐다.** 이런 경로는 지표나 알림으로 올려야 한다
4. **배포 후 로그를 한 번 읽는 것이 테스트만큼 값지다.** 이 버그는 어떤 단위 테스트도 잡을 수 없었다 — 각 조각은 정상이고 **조립된 순서**가 문제였다

면접식 한 문장:

> 편집 분석 알림이 운영에서 전혀 발송되지 않는 것을 로그에서 발견해, `permitAll`이 인가 규칙
> 이라서 인증 필터의 401을 막지 못한다는 원인까지 재현으로 좁히고, 서비스 주체별 필터 체인
> 분리로 고친 뒤 계약 테스트로 회귀를 막았습니다.

## 36. 삭제된 영상 복구 — 파일이 먼저, DB가 나중

### 증상

기기 해제 로직이 단순한 숨김이 아니라 **실제 삭제 파이프라인**이었다.

```
DELETING → video_deletion_jobs 등록 → 워커가 MinIO 객체 삭제 → DELETED
```

그래서 DB 상태만 `READY`로 되돌리면 **목록에는 보이지만 재생이 실패한다.** 객체가 이미 없다.

### 올바른 복구 순서

```
1. 복구 직전 PostgreSQL·MinIO 전체 백업 + 체크섬   ← 되돌릴 수 있는 지점을 먼저 만든다
2. 삭제 전 백업에서 대상 객체만 MinIO에 복원
3. 모든 객체의 존재와 실제 바이트 읽기 확인        ← 있다고 믿지 않고 읽어 본다
4. 하나의 트랜잭션에서 대상 행만 금고에 연결 + READY 전환
5. 예상 행 수가 정확한지 확인한 뒤 커밋
6. API 목록 → 스트리밍 응답 → 실제 앱 재생 순으로 검증
```

2026-07-29 작업에서 영상 20개를 이 순서로 복구했다. `device_id`는 **촬영 당시 출처**라
바꾸지 않고, 접근할 금고만 `vault_id`로 연결했다.

> 이건 "영상의 소유 금고를 바꿀 수 있다"는 뜻이 **아니다.** 백업 객체가 확인된 승인된 운영
> 복구의 예외다. 일반 비즈니스 로직에는 그런 경로가 없다.

### 배운 원칙

1. **복구는 새 백업부터.** 복구 작업 자체가 실패할 수 있다
2. **파일과 DB가 모두 맞아야 복구된 것이다.** 어느 한쪽만으로는 "복구했다"고 말할 수 없다
3. **"DB 20행 성공"과 "사용자가 실제로 본다"를 같은 의미로 보고하면 안 된다.** 서버 검증과 단말 검증을 구분해서 보고한다
4. 마이그레이션 성공을 Flyway 이력만으로 판단하지 말고 **핵심 불변식 쿼리**로도 확인한다

## 37. MyBatis record 생성자 매핑 — 단위 테스트가 통과하는 500

### 증상

운영에서 `GET /api/vaults/{vaultId}/members`가 500을 반환했다. 그런데 앱 화면에서는 **"기기가
OFFLINE"이나 "영상이 없음"처럼** 보였다.

### 원인

SQL이나 데이터 문제가 아니었다. **MyBatis의 생성자 선택**이었다.

조인 결과의 `joined_at`은 PostgreSQL JDBC에서 `Timestamp`로 온다. `MembershipRow` record에
생성자 후보가 여럿이면 MyBatis가 어느 것을 쓸지 결정하지 못한다.

**Mockito 단위 테스트로는 절대 잡을 수 없다.** 매퍼를 가짜로 두면 SQL도, JDBC 타입도, 생성자
선택도 실행되지 않는다. 테스트는 전부 초록색이었다.

### 고친 방법

- record의 정식 생성자에 `@AutomapConstructor`를 지정
- 같은 record를 쓰는 쿼리들의 projection을 **같은 컬럼·순서·타입으로 통일**
- **실제 PostgreSQL을 쓰는 매퍼 통합 테스트** 추가
- 다른 Flyway 통합 테스트와 병렬로 돌아도 충돌하지 않게 **전용 테스트 스키마** 사용

### 증상 해석에서 배운 것

앱이 초기화할 때 금고·구성원·기기를 **한 번에 모아** 화면을 만든다. 그래서 구성원 API 하나의
500이 화면에서는 **전혀 다른 증상**으로 보였다.

> 겉으로 보이는 증상으로 원인을 단정하지 말고, **같은 시각의 API별 상태 코드와 서버 로그를
> 먼저 분리해서** 봐야 한다.

35장의 조사 방식이 이 교훈의 적용이다 — 응답 메시지를 정확히 읽어서 어느 층이 낸 오류인지
구분했다.

### 배운 원칙

1. **단위 테스트 통과는 DB 프레임워크 매핑을 보장하지 않는다.** 실제 DB 통합 테스트가 필요한 영역이 있다
2. 프론트의 증상과 백엔드의 원인은 **직접 대응하지 않는다**
3. 테스트 종류마다 잡을 수 있는 버그가 다르다 — 단위(규칙), 통합(매핑·SQL), 계약(설정·배포)

## 38. 반복된 작은 사고들 — 그래서 계약 테스트가 생겼다

### Flyway 버전 충돌 (3번)

팀원과 동시에 작업하면 `V35`, `V36`, `V37`을 서로 모르고 같이 쓴다. 세 번 겪었다. 마지막에는
내 `V37`이 만화 팀 것과 겹쳐서 `git mv`로 `V38`로 옮기고 테스트의 버전 핀도 올렸다.

주목할 점: **중복 검사는 이미 계약 테스트에 있었다.** 그런데 그 검사가 **자기 브랜치 트리에서만**
돌아서 "합쳐진 결과"의 충돌을 못 봤다. 검사가 있어도 **검사 대상이 틀리면** 안 잡힌다.

### Prometheus가 조용히 수집을 멈춤

슬롯 전환(8081→8082) 후 고정 타겟이 옛 포트를 가리켜 수집이 끊겼다. **오류가 안 난다.**
그래프만 빈다. `file_sd_configs`로 바꿔 해결했다(32장).

### `/actuator/prometheus`가 401

관측성을 붙였는데 Prometheus가 수집을 못 했다. Spring Security가 인증을 요구했다. `permitAll`
추가로 해결 — 8081이 loopback 전용이라는 전제 위에서만 안전한 결정이라, **설정 파일에 그
전제를 주석으로 남겼다.**

```yaml
# prometheus는 8081이 외부에 공개되지 않는 전제의 노출이다(nginx는
# /api·/health만 프록시한다). 8081을 공개로 바꾸면 함께 재검토할 것.
```

### MediaMTX API가 401

유령 세션 대사 워커를 만들었는데 MediaMTX 관리 API가 거부했다. loopback 익명 사용자에 `api`
권한을 추가해 해결.

### 공통 교훈

이 사고들의 성격이 같다.

> **기능 코드는 맞았는데 설정·배포·순서가 틀렸다.**

그리고 대부분 **조용히** 실패했다. 오류 화면이 안 뜨고, 지표가 안 그려지고, 알림이 안 가고,
수집이 멈춘다. 사람이 알아채는 건 훨씬 나중이다.

그래서 두 가지를 갖췄다.

1. **배포 계약 테스트** — 사고를 문자열로 못 박아 CI가 재발을 막는다(31장)
2. **자체 점검 + 웹훅** — 조용한 실패를 5분 안에 소리 나게 만든다(32장)

---

# 7부. 공부 순서와 점검

## 39. 코드 읽기 7일 순서

혼자 읽을 때 길을 잃지 않는 순서다. 하루에 한 단계씩.

### 1일차 — 구조 감각 잡기

가장 단순한 CRUD로 3층 구조를 익힌다.

```
schedule/api/ScheduleController.java
schedule/application/ScheduleService.java
schedule/persistence/ScheduleMapper.java
V36__user_schedules_and_notification_prefs.sql
```

읽고 답해 볼 것: 요청이 어느 순서로 흐르나? 권한 확인은 어디 있나? SQL은 어디에 있나?

### 2일차 — 인증

```
config/SecurityConfig.java          ← 필터 체인 4개
config/JwtConfig.java               ← 디코더 두 종류가 왜 필요한가
auth/application/AuthService.java
auth/application/AccessTokenValidator.java   ← 요청마다 DB를 보는 이유
```

### 3일차 — 금고와 기기 claim

```
vault/application/VaultService.java
device/application/DeviceService.java   ← claim()의 @Transactional
device/application/ClaimAttemptService.java
V29__memory_vaults_and_device_bindings.sql
```

### 4일차 — MQTT

```
자료/api/mqtt-contract.md           ← 문서를 먼저
iot/mqtt/PahoMqttGateway.java
iot/telemetry/DevicePresenceStore.java
```

### 5일차 — 이벤트 영상 (핵심)

```
video/application/IotVideoService.java    ← 2단계 업로드, ETag
storage/ObjectStorageService.java         ← presigned URL
video/application/VideoQueryService.java  ← cursor pagination
video/application/VideoDeletionWorker.java ← MinIO 먼저
```

여기서 하루 더 써도 좋다. 이 프로젝트의 중심이다.

### 6일차 — 라이브

```
stream/application/StreamService.java
stream/application/LiveTokenService.java
stream/api/LiveIntrospectionController.java
backend/deploy/nginx-william-james.conf   ← auth_request 부분
```

### 7일차 — 인프라와 배포

```
backend/deploy/docker-compose.yml
backend/deploy/nginx-william-james.conf   ← 전체
ci/jenkins/server/deploy/wj-deploy-backend
ci/jenkins/scripts/test-backend-deploy-contract.sh   ← 이 프로젝트의 사고 역사
backend/deploy/ZERO_DOWNTIME.md
```

## 40. 로컬에서 실행해 보기

### 필요한 것

- JDK 17
- Docker (PostgreSQL, Redis, MinIO를 컨테이너로 띄우려면)

### 인프라 띄우기

```bash
cd backend/deploy
docker compose up -d postgres redis minio
```

### 서버 실행

```bash
cd backend/server
./gradlew bootRun
```

기본 프로필은 `local`이라 대부분 값이 기본값으로 채워진다. MQTT·FCM·메일은 설정이 없으면
꺼진 상태로 뜬다.

### 테스트

```bash
cd backend/server
./gradlew test
```

Docker가 꺼져 있으면 통합 테스트는 건너뛴다. 단위 테스트만 돌아도 규칙 검증은 된다.

### 배포 계약 테스트

```bash
bash ci/jenkins/scripts/test-backend-deploy-contract.sh
```

DB 없이 돈다. 설정 파일들만 검사하므로 빠르다.

### 서버 상태 확인

```bash
ssh -i ~/Downloads/I15E201T.pem ubuntu@i15e201.p.ssafy.io
```

```bash
systemctl is-active william-james@8081 william-james@8082
cat /etc/nginx/conf.d/wj-upstream.conf
sudo docker ps --format "{{.Names}}\t{{.Status}}"
curl -s http://127.0.0.1:8081/actuator/health
```

## 41. 예상 질문 69선

답이 앞 장에 다 있다. 장 번호를 붙여 뒀다.

### 전체 구조

1. 아키텍처를 30초로 설명해 보라 (7·8장)
2. 영상 바이트가 Spring을 지나가나? (8·16장)
3. 제어 평면과 데이터 평면을 나눈 이유는? (8장)
4. 서버 한 대인 이유와 그 한계는? (7장)
5. 외부에 열린 포트는 몇 개인가? (2·28장)
6. 인스턴스를 늘리려면 무엇을 바꿔야 하나? (7장)

### 인증·보안

7. 401과 403의 차이 (3장)
8. JWT를 쓰면서 왜 요청마다 DB를 보나? (12장)
9. `token_version`이 필요한 이유 (12장)
10. access/refresh를 나눈 이유 (12장)
11. refresh 회전이 주는 이득 (12장)
12. 회전된 토큰이 다시 오면? (12장)
13. 도난을 감지했는데 왜 응답에 안 알리나? (12장)
14. 비밀번호를 왜 해시로? BCrypt를 왜? (12장)
15. 비밀번호 재설정 응답을 왜 성공으로 통일했나? (12장)
16. 필터 체인이 넷인 이유 (12·35장)
17. `permitAll`을 걸었는데 401이 나는 이유 (35장)
18. 기기에 사용자 JWT를 주지 않는 이유 (14장)
19. MQTT key가 뭔가? (14·24장)
20. 토큰마다 `iss`가 다른 이유 (24장)
21. IDOR을 어떻게 막나? (23장)
22. SQL Injection을 어떻게 막나? (25장)
23. 해시·암호화·서명의 차이 (24장)
24. MinIO 계정을 세 개로 나눈 이유 (33장)
25. 나눴다는 걸 어떻게 확인했나? (33장)

### 영상

26. presigned URL이 뭐고 왜 쓰나? (16장)
27. presigned URL이 유출되면? (16장)
28. 업로드 무결성을 어떻게 보장하나? ETag가 필요한 이유 (16장)
29. 업로드 크기 상한을 두 곳에 맞추는 이유 (16·29장)
30. 같은 이벤트가 두 번 올라오면? 멱등성이란? (16장)
31. 업로드가 끊기면 어떻게 되나? (16장)
32. offset 대신 cursor를 쓰는 이유 (16장)
33. 삭제할 때 MinIO를 먼저 지우는 이유 (16장)
34. 재생 URL이 GET이 아니라 POST인 이유 (16장)
35. 감지를 서버가 아니라 기기에서 하는 이유 (16장)
36. MQTT 이벤트가 "영상 만들어라"인가? (16장)

### 라이브

37. MQTT로 영상이 흐르나? (18장)
38. WebRTC를 고른 이유와 HLS를 뺀 대가 (18장)
39. remux와 transcode의 차이, 왜 remux만? (18장)
40. WHEP 주소를 알면 남의 집을 볼 수 있나? (18장)
41. `auth_request`가 뭔가? (18·29장)
42. live token에 scope를 넣은 이유 (18장)
43. 서버가 죽으면 기기가 계속 송출하나? (18장)
44. heartbeat가 오는데 화면이 검으면? (18장)

### 데이터·도메인

45. 금고를 도입한 이유 (10·13장)
46. OWNER를 한 명으로 제한한 이유 (13장)
47. `[bound_at, ended_at)` 구간이 필요한 이유 (10·21장)
48. 기기를 양도하면 과거 통계가 오염되나? (21장)
49. 집계를 DB에서 하는 이유 (21장)
50. 시간대 처리를 왜 신경 쓰나? (21장)

### 인프라·운영

51. 무중단 배포를 어떻게 했나? (30장)
52. 활성 슬롯은 어디에 기록되나? (29·30장)
53. 무중단이면 마이그레이션에 어떤 제약이? (30장)
54. 슬롯마다 JAR을 따로 두는 이유 (30장)
55. Redis가 죽으면 로그인이 되나? 왜 그렇게 골랐나? (9·27장)
56. 캐시를 왜 안 쓰나? (27장)
57. 브랜치 이름으로 CI 스테이지를 고르는 이유 (31장)
58. 배포에 사람 승인을 두는 이유 (31장)
59. 배포 계약 테스트가 뭔가? (31장)
60. Prometheus가 슬롯 전환을 어떻게 따라가나? (32장)
61. Grafana를 외부에 열지 않는 이유 (32장)
62. 부하 테스트 결과와 그 한계 (32장)
63. 왜 쓰기 경로는 안 쟀나? (32장)

### 서비스 경계

64. editor-api를 왜 나눴나? (19장)
65. 경계가 틀렸다는 걸 어떻게 알았나? (19장)
66. 옮긴 판단 기준 한 줄 (19장)
67. `/complete` 없이 어떻게 READY가 되나? (19장)
68. 남은 부채는? (19장)
69. Kafka·K8s·MSA를 왜 안 쓰나? (42장)

## 42. 한 장 요약 — 시험 전날 볼 것

### 한 문장

> 앱과 서버는 REST로 대화하고, 서버와 홈캠은 MQTT로 작은 명령·상태를 주고받고, 큰 영상은
> presigned URL로 MinIO에 직접 오가며, 라이브는 MediaMTX가 WebRTC로 흘린다. 백엔드는
> 판단하고 기록하는 제어 평면이다.

### 숫자

| 항목 | 값 |
| --- | --- |
| access / refresh | 15분 / 14일 |
| live token / talkback | 30초 / 30초 |
| 업로드 URL / 재생 URL | 15분 / 5분 |
| 기기 credential | 부트스트랩 15분 / 운영 30일 |
| presence TTL | 90초 |
| 시청자 TTL / idle / edge lease | 45초 / 60초 / 120초 |
| 로그인·claim 제한 | 10분에 5회 (이메일·IP 각각) |
| 보관 기간 | 기본 30일 / 구독 365일 (+유예 30일) |
| 업로드 상한 | 500 MiB (nginx 512m) |
| Flyway | V39 |
| 테이블 | 29개 |
| 워커 | 8개 (+MQTT 재연결) |
| 컨테이너 | 8종 |
| 외부 공개 포트 | 5갈래 (22, 80/443, 8883, 8322, 8189/UDP) |
| 부하 실측 | 350 VU, 335 req/s, p95 9 ms, 실패 0 |
| 무중단 전환 실측 | 94,042요청 실패 0 |

### 설계 판단 5개와 근거

| 판단 | 근거 |
| --- | --- |
| 감지를 기기에서 | 프라이버시 + 네트워크·저장 비용. 웃지 않은 영상은 집을 떠나지 않는다 |
| presigned URL | 큰 바이트가 서버를 지나가지 않는다. 권한은 짧게 위임 |
| 요청마다 세션 DB 조회 | 취소 가능성을 얻기 위해 완전 무상태를 포기. 대가는 실측으로 확인(p95 9 ms) |
| Redis fail-open | 가용성 우선. BCrypt가 2차 방어, 경고 로그 남김 |
| 계산은 워커, 콘텐츠는 백엔드 | 권한·보관·삭제·알림이 필요한 것은 시스템 오브 레코드에 |

### 안 쓴 기술과 그 이유

면접에서 자주 나온다. **"몰라서 안 썼다"와 "재 보고 안 썼다"는 다르다.**

| 기술 | 왜 안 썼나 |
| --- | --- |
| **Kafka** | 이벤트 양이 초당 수십 건 수준이고, 순서 보장·재처리가 필요한 스트림 처리가 없다. DB 테이블을 큐로 쓰는 것으로 충분하고 트랜잭션과 함께 묶을 수 있다는 이득이 있다 |
| **Kubernetes** | 인스턴스가 하나다. K8s는 여러 노드의 스케줄링·자동 복구를 위한 도구인데, 노드가 하나면 복잡성만 늘어난다. 무중단 배포는 systemd + nginx로 달성했다 |
| **MSA** | 팀 규모(백엔드 1~2명)에 서비스 경계를 여러 개 두면 운영 비용이 개발 시간을 먹는다. 실제로 **하나 나눈 것(editor-api)의 경계도 잘못 그어서 되돌렸다**(19장). 그 경험이 "안 나누는 게 낫다"의 근거다 |
| **Redis 캐시** | 병목이 아니다. 실측에서 DB 풀 4/10, p95 9 ms |
| **CQRS·이벤트 소싱** | 읽기와 쓰기의 부하 차이가 크지 않고, 감사 요구는 감사 로그 테이블로 충족된다 |

핵심은 이렇게 말하는 것이다: **"쓸 근거가 없어서 안 썼다. 근거가 생기는 조건은 이것이다."**
조건까지 말할 수 있으면 기술을 이해한 것으로 들린다.

### 정직하게 말할 한계

발표에서 숨기지 않는 게 낫다. 물어보면 반드시 드러난다.

- **단일 인스턴스**다. 이 기계가 죽으면 서비스가 죽는다. 다중화의 전제(무상태, 외부화)는 갖췄지만 실제로 안 했다
- **쓰기 경로 부하를 안 쟀다.** WHEP 동시 시청 한계를 모른다
- **HLS 폴백이 없다.** WebRTC가 막힌 네트워크에서는 라이브를 못 본다
- **백업이 같은 인스턴스에 있다.** 인스턴스 손실 시 백업도 잃는다
- **중앙 로그 수집이 없다.** journalctl을 직접 본다
- ADR-001의 **남은 부채**: 편집 초안 레시피가 아직 editor-api에 있고, 백엔드가 editor 버킷 접두사를 안다
- 기기 파트와 함께 해야 하는 항목들이 남아 있다 (`llm/handoff/BACKLOG_HANDOFF_20260804.md`)

### 원문 찾아보기

| 알고 싶은 것 | 어디 |
| --- | --- |
| REST API 전체 목록 | `자료/api/openapi.yaml` |
| MQTT 토픽·메시지 | `자료/api/mqtt-contract.md` |
| 서비스 경계 결정 | `자료/docs/ADR-001-editor-api-경계.md` |
| 무중단 배포 상세 | `backend/deploy/ZERO_DOWNTIME.md` |
| 부하 테스트 결과 | `ci/load/README.md` |
| 배포 절차 | `ci/jenkins/BACKEND_INFRA_DEPLOY.md` |
| 남은 백로그 | `llm/handoff/BACKLOG_HANDOFF_20260804.md` |
| 구현 현황 | `backend/BACKEND_STATUS.md` |
| 기획·MVP 정의 | `자료/docs/사람이 읽을 문서/01-서비스기획.md` |

---

## 부록. 2026-08-04 서버 상태 스냅샷

문서를 쓰면서 실제로 확인한 값이다. 나중에 비교할 기준선으로 남긴다.

```
git          master == develop, Flyway V39
슬롯          william-james@8082 active / @8081 inactive
활성 upstream  127.0.0.1:8082
배포 시각      2026-08-04 07:15 UTC (06:57 배포 후 35장 수정으로 재배포)
컨테이너       8종 전부 Up (postgres·redis·minio·mosquitto·mediamtx·
              editor-api·prometheus·grafana)
Prometheus    job=spring health=up (file_sd가 8082를 따라감 — 슬롯 전환을
              실제로 추적하는 것을 이 배포로 확인했다)
공개 헬스      https://i15e201.p.ssafy.io/health → 200 {"status":"UP"}
DB            william_james / 사용자 william
```

**슬롯이 8081 → 8082로 바뀐 것이 무중단 배포가 실제로 돌아간 증거다.** 30장의 설명이
추상적으로 느껴지면 이 두 줄을 다시 보면 된다.

발견해서 고치고 **배포·검증까지 마친 것**:

- `/api/editor/events`가 인증 필터 때문에 항상 401 → 전용 보안 체인으로 분리 (35장).
  편집 분석 완료 알림이 그동안 한 건도 발송되지 않았다.
  배포 후 실측으로 확인했다:

  | 요청 | 배포 전 | 배포 후 |
  | --- | --- | --- |
  | 유효한 서비스 토큰(`iss=wj-editor`) | 401 `"로그인이 필요합니다"` (인증 필터) | **컨트롤러 도달** |
  | 잘못된 토큰 | 401 (인증 필터) | 401 `"편집 서버 토큰이 필요합니다"` (`EditorEventService`) |

  오른쪽 열이 중요하다. **통과시켜야 할 것은 통과하고, 막아야 할 것은 여전히 막힌다** —
  게다가 이제 401을 내는 주체가 의도한 그 코드다. 보안을 느슨하게 해서 고친 게 아니다.

사소한 정리 대상:

- `infra/.env`에 `EDITOR_JWT_SECRET`이 두 줄 있다. **값이 같아서 무해**하지만(dotenv는 뒤가 이긴다) 다음 시크릿 갱신 때 정리하면 좋다
