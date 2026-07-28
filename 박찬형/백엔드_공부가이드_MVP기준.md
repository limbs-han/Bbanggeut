# ChanHyeong 백엔드 공부 가이드 — MVP 7개 흐름으로 코드 읽기

> 대상: 백엔드를 처음 공부하는 팀원  
> 기준일: 2026-07-27  
> 기준 브랜치: `codex/chanhyeong-study`  
> 가장 중요한 기준 문서: `자료/docs/사람이 읽을 문서/01-서비스기획.md`의 **8. MVP 정의**  
> 성격: 설계 희망사항이 아니라, 현재 저장소의 문서와 구현 코드를 함께 확인한 **공부용 as-built 가이드**

---

## 0. 이 문서를 읽는 법

이 프로젝트를 한 번에 전부 이해하려고 하면 HTTP, MQTT, JWT, PostgreSQL, MinIO, MediaMTX, YAMNet이 한꺼번에 튀어나와서 헷갈린다. 모르는 것이 정상이다. 아래 한 문장은 지금 이해하라는 설명이 아니라 앞으로 배울 대상의 지도다. 외우지 말고 한 번만 본 뒤 0.2절부터 순서대로 읽고, 0.16절에서 다시 돌아온다.

> **앱과 서버는 REST로 대화하고, 서버와 홈캠은 MQTT로 작은 명령·상태를 주고받고, 큰 영상 파일은 MinIO에 직접 올리며, 라이브 영상은 MediaMTX가 전달한다.**

백엔드는 모든 데이터를 직접 운반하지 않는다. 백엔드는 주로 다음을 판단하고 기록하는 **제어 평면(control plane)** 역할을 한다.

- 이 사용자는 누구인가?
- 이 사용자가 이 기기에 접근해도 되는가?
- 이 영상은 어느 기기에서 어떤 이벤트로 만들어졌는가?
- 업로드할 임시 권한을 줘도 되는가?
- 업로드가 정말 끝났는가?
- 지금 라이브 송출을 시작·연장·종료해야 하는가?
- 통계에 포함할 수 있는 정상 데이터인가?

반면 영상 바이트 자체를 옮기고 재생하는 일은 MinIO와 MediaMTX가 담당한다. 이것을 **데이터 평면(data plane)**이라고 생각하면 된다.

### 0.1 문서의 사실 우선순위

문서끼리 충돌할 때는 아래 순서로 믿는다.

1. 실제 실행 코드와 테스트
2. `자료/docs/사람이 읽을 문서`의 최신 4개 문서
3. `자료/api/openapi.yaml`, `자료/api/mqtt-contract.md`
4. `backend/BACKEND_STATUS.md`, 각 파트 README
5. `자료/docs/old` 문서

`old` 폴더에는 과거 설계가 남아 있다. 공부에는 도움이 되지만 현재 MVP를 판단할 때 그대로 믿으면 안 된다.

### 0.2 진짜 맨 처음: 컴퓨터, 프로그램, 프로세스, 서버

#### 컴퓨터

컴퓨터는 입력을 받고, 정해진 명령을 실행하고, 결과를 내놓는 기계다. 노트북, 스마트폰, EC2, Jetson, Raspberry Pi가 모두 컴퓨터다. 크기와 성능, 운영체제, 맡은 일이 다를 뿐이다.

컴퓨터 안의 중요한 자원은 다음과 같다.

| 자원 | 쉽게 말하면 | 이 프로젝트에서의 예 |
|---|---|---|
| CPU | 명령을 계산하는 일꾼 | Spring 코드 실행, SQL 결과 처리 |
| GPU | 같은 종류의 계산을 대량 병렬 처리하는 일꾼 | Jetson에서 AI 추론 |
| RAM | 지금 일하는 내용을 잠깐 펼쳐 놓는 책상 | 실행 중인 Java 객체, MQTT 메시지 |
| 디스크 | 전원을 꺼도 남는 서랍 | PostgreSQL 데이터, MinIO MP4, edge 로컬 영상 |
| 네트워크 장치 | 다른 컴퓨터와 데이터를 주고받는 통로 | Wi-Fi, Ethernet |

#### 프로그램과 프로세스

- **프로그램(program)**: 디스크에 저장된 실행 방법이다. Java JAR, `mosquitto.exe`, Docker image 같은 것이 여기에 가깝다.
- **프로세스(process)**: 프로그램을 실제로 실행한 상태다. RAM과 CPU를 사용하며 운영체제가 관리한다.

레시피 파일이 프로그램이라면, 주방에서 실제로 요리 중인 요리사가 프로세스다. 같은 프로그램을 여러 번 실행하면 프로세스도 여러 개 생길 수 있다.

#### 서버라는 말의 두 가지 뜻

`서버`는 문맥에 따라 두 가지를 뜻한다.

1. **서버 컴퓨터**: 서비스를 실행하는 물리·가상 컴퓨터. 예: EC2.
2. **서버 프로그램**: 다른 프로그램의 요청을 기다렸다가 응답하는 프로세스. 예: Spring Boot, PostgreSQL, Mosquitto.

“서버가 죽었다”는 말도 EC2 전체가 꺼졌다는 뜻일 수 있고, 그 안의 Spring 프로세스만 멈췄다는 뜻일 수 있다. 반드시 구분해서 물어봐야 한다.

#### 서비스(service)

서비스는 사용자에게 제공하는 전체 기능을 뜻하기도 하고, 운영체제에서 백그라운드로 계속 실행되는 프로그램을 뜻하기도 한다.

- 제품 의미: 윌리엄 제임스 홈캠 서비스
- 운영 의미: `william-james.service`라는 systemd 백그라운드 프로세스

#### 백엔드

백엔드는 사용자가 직접 보는 화면 뒤에서 동작하는 부분이다.

- 요청을 받는다.
- 사용자를 인증한다.
- 권한을 검사한다.
- 비즈니스 규칙을 실행한다.
- DB와 저장소를 읽고 쓴다.
- 다른 서비스와 통신한다.
- 결과나 오류를 프론트엔드에 돌려준다.

백엔드는 곧 DB가 아니다. Spring Boot 백엔드 **프로그램**이 PostgreSQL **DB 서버**에 질의하는 관계다.

### 0.3 클라이언트와 서버

#### 클라이언트

클라이언트는 먼저 요청하는 쪽이다. 이 프로젝트에는 클라이언트가 하나만 있는 것이 아니다.

- Flutter 앱은 Spring API의 클라이언트다.
- 홈캠은 Spring IoT API의 클라이언트다.
- Spring은 PostgreSQL에 질의할 때 PostgreSQL의 클라이언트다.
- Spring은 Mosquitto에 연결할 때 MQTT 클라이언트다.
- Nginx는 Spring에 요청을 넘길 때 Spring의 클라이언트처럼 동작한다.

클라이언트와 서버는 제품의 고정 신분이 아니라 **특정 통신에서 누가 요청하고 누가 받는가**로 정해진다.

#### 요청과 응답

가장 기본적인 통신은 다음과 같다.

```text
클라이언트: "내가 접근할 수 있는 기기 목록을 줘"
    ↓ 요청(request)
서버: 인증 → DB 조회 → 응답 생성
    ↓ 응답(response)
클라이언트: 받은 JSON으로 화면을 그림
```

요청에는 보통 다음이 들어간다.

- 어디로 보낼지: URL
- 무엇을 할지: HTTP method
- 부가 정보: header
- 실제 입력 데이터: body

응답에는 보통 다음이 들어간다.

- 성공·실패 종류: status code
- 부가 정보: header
- 결과 데이터: body

### 0.4 네트워크의 출발점: IP, 도메인, 포트

#### 네트워크

네트워크는 여러 컴퓨터가 데이터를 주고받도록 연결한 것이다. 인터넷은 전 세계의 수많은 네트워크가 서로 연결된 거대한 네트워크다.

데이터는 보통 작은 **패킷(packet)** 단위로 나뉘어 이동한다. 영상 파일 하나가 물리적으로 통째로 순간 이동하는 것이 아니다. 여러 패킷이 네트워크를 지나 상대 컴퓨터에서 다시 조립된다.

#### IP 주소

IP 주소는 네트워크에서 컴퓨터나 네트워크 인터페이스를 찾기 위한 주소다.

예:

```text
127.0.0.1
192.168.0.10
13.125.xxx.xxx
```

- `127.0.0.1`, `localhost`: 지금 이 컴퓨터 자기 자신
- 사설 IP: 집·회사·Docker 내부에서 쓰는 주소
- 공인 IP: 인터넷에서 찾아올 수 있는 주소

IP 주소는 사람에게 외우기 불편하고 바뀔 수 있다.

#### 도메인과 DNS

도메인은 `i15e201.p.ssafy.io`처럼 사람이 읽기 쉬운 이름이다. DNS는 도메인을 IP 주소로 찾아주는 시스템이다.

전화번호부에 비유하면:

- 도메인: 사람 이름
- IP 주소: 전화번호
- DNS: 이름으로 번호를 찾는 전화번호부

DNS가 통신 내용을 전달하는 것은 아니다. 먼저 목적지 IP를 찾게 도와준다.

#### 포트

IP가 건물 주소라면 포트는 그 건물의 창구 번호다. 한 컴퓨터에서 Spring, PostgreSQL, MinIO 같은 여러 서버 프로그램이 동시에 실행되기 때문에 어느 프로그램으로 보낼지 포트로 구분한다.

```text
localhost:8080
│         └─ 포트 8080의 Spring Boot
└─ 현재 컴퓨터
```

이 프로젝트의 대표 포트:

| 포트 | 프로그램 | 용도 |
|---:|---|---|
| 443 | Nginx | 외부 HTTPS 정문 |
| 8080 | Spring Boot | 내부 API |
| 5432 | PostgreSQL | DB 연결 |
| 8883 | Mosquitto | TLS를 적용한 MQTT |
| 9000 | MinIO | S3 호환 API |
| 9001 | MinIO | 관리자 웹 화면 |
| 8554 | MediaMTX | RTSP ingest |
| 8888 | MediaMTX | HLS 제공 |

포트 번호 자체가 보안 기능은 아니다. 포트를 안다고 접속 권한이 생겨서는 안 된다. 방화벽, 인증, TLS, ACL이 따로 필요하다.

#### 소켓과 연결

소켓은 프로그램이 네트워크 통신에 사용하는 운영체제의 창구다. 보통 IP, port, protocol의 조합으로 연결 상대를 식별한다.

백엔드 초반에는 소켓 API를 직접 구현할 필요는 없다. Spring, Paho, PostgreSQL driver 같은 라이브러리가 대신 다룬다. 다만 “한 포트는 보통 한 프로세스가 listen한다”, “연결이 열려 있어야 데이터를 주고받는다” 정도는 알아야 한다.

#### 공유기, 라우터, NAT

라우터는 서로 다른 네트워크 사이에서 패킷이 갈 길을 정하는 장비·기능이다. 가정용 공유기도 라우터 역할을 한다.

집 안의 노트북, 휴대폰, 홈캠은 보통 각각 사설 IP를 갖지만 인터넷에서는 공유기의 공인 IP 하나를 함께 사용한다. NAT는 내부 사설 주소와 외부 공인 주소·포트를 변환한다.

```text
홈캠 192.168.0.20 ─┐
휴대폰 192.168.0.21 ├─ 공유기/NAT ─ 공인 IP ─ 인터넷
노트북 192.168.0.22 ┘
```

외부 서버가 집 안 홈캠으로 갑자기 새 연결을 시작하기는 어렵다. 공유기가 어느 내부 기기로 보내야 하는지 모르고 차단하기 때문이다. 반대로 홈캠이 먼저 외부 Mosquitto나 Spring에 연결하면 NAT가 연결 대응 정보를 만들므로 응답을 받을 수 있다. IoT 기기가 서버로 **outbound 연결을 먼저 여는 구조**가 흔한 이유다.

#### 방화벽

방화벽은 어떤 IP·port·protocol의 통신을 허용하거나 차단하는 규칙이다.

- 443 HTTPS는 사용자에게 허용
- 5432 PostgreSQL은 인터넷에서 차단
- 9001 MinIO 관리자 화면은 내부에서만 허용
- 8883 MQTTS는 필요한 기기에서만 접근하도록 제한

프로그램이 5432에서 실행 중이어도 방화벽이 막으면 외부에서 접속할 수 없다. 반대로 방화벽을 열었다고 인증이 생기는 것도 아니다. 방화벽은 여러 보안 층 중 하나다.

#### 대역폭과 지연시간

- 대역폭(bandwidth): 일정 시간에 얼마나 많은 데이터를 보낼 수 있는지. 수도관의 굵기.
- 지연시간(latency): 데이터가 상대에게 도착하기까지 걸리는 시간. 수도관의 길이.

큰 MP4 업로드는 대역폭 영향을 크게 받고, 라이브 조작 반응은 지연시간 영향을 크게 받는다. 대역폭이 높아도 왕복 거리가 멀면 지연시간은 클 수 있다.

#### 동기, 비동기, polling, push

- 동기적 요청-응답: 요청한 쪽이 결과를 기다린다. 일반 REST 호출.
- 비동기: 요청한 작업의 완료가 나중에 오거나 별도 경로로 전달된다. 객체 삭제 job, MQTT event.
- polling: 클라이언트가 일정 간격으로 “됐나요?”라고 반복 조회한다.
- push: 상태가 생긴 쪽에서 메시지를 보내 알린다. MQTT publish.

이 프로젝트의 라이브는 두 방식을 섞는다. 기기는 MQTT로 `STREAM_READY`를 서버에 push하고, 앱은 REST로 session 상태를 polling한다.

### 0.5 TCP와 UDP

인터넷에서 데이터를 보내는 대표 전송 방식이다.

#### TCP

TCP는 상대와 연결을 만들고 데이터가 순서대로 빠짐없이 도착하도록 확인한다.

택배 비유:

- 송장 번호가 있다.
- 빠진 상자가 있으면 다시 보낸다.
- 순서가 뒤섞이면 정렬한다.
- 상대가 받았는지 확인한다.

장점:

- 신뢰성
- 순서 보장
- 재전송

단점:

- 확인과 재전송 때문에 overhead와 지연이 생긴다.

HTTP, HTTPS, MQTT, PostgreSQL 연결은 일반적으로 TCP 위에서 동작한다.

#### UDP

UDP는 연결과 수신 확인을 최소화하고 데이터를 보낸다.

방송 비유:

- 일단 송출한다.
- 일부가 빠져도 기본 UDP가 다시 보내주지 않는다.
- 순서 보장을 기본 제공하지 않는다.

장점:

- 단순하고 빠르다.
- 약간의 유실보다 지연이 더 중요한 실시간 통신에 유리할 수 있다.

단점:

- 신뢰성 처리를 애플리케이션이나 상위 프로토콜이 해야 한다.

“영상은 무조건 UDP”도 틀린 말이다. RTSP/RTP 설정, 방화벽, 네트워크 환경에 따라 TCP 또는 UDP를 사용할 수 있다.

### 0.6 프로토콜, HTTP, API, REST, JSON

#### 프로토콜

프로토콜은 컴퓨터끼리 대화하기로 약속한 규칙이다.

사람이 대화할 때도 언어, 문법, 질문·대답 순서가 필요하다. 컴퓨터도 다음을 약속해야 한다.

- 메시지 형식
- 누가 먼저 말하는지
- 주소 표현 방법
- 성공과 실패 표현
- 연결 유지·종료 방법

HTTP, MQTT, RTSP, TLS가 각각 다른 목적의 프로토콜이다.

#### HTTP

HTTP는 클라이언트가 요청하고 서버가 응답하는 데 널리 쓰는 프로토콜이다.

요청 예:

```http
GET /api/devices HTTP/1.1
Host: i15e201.p.ssafy.io
Authorization: Bearer eyJ...
Accept: application/json
```

응답 예:

```http
HTTP/1.1 200 OK
Content-Type: application/json

[
  {"id": "...", "name": "거실 홈캠", "status": "ONLINE"}
]
```

#### HTTP method

| method | 보통 의미 | 프로젝트 예 |
|---|---|---|
| GET | 조회 | 기기·영상 목록 |
| POST | 생성 또는 명령 | 로그인, stream session 생성 |
| PATCH | 일부 수정 | 기기 이름 수정 |
| PUT | 전체 설정 또는 정해진 대상 쓰기 | 구독 상태, MinIO 객체 업로드 |
| DELETE | 삭제·종료 | 영상 삭제, stream session 종료 |

method 이름만으로 보안이나 멱등성이 자동 보장되는 것은 아니다. 서버 구현과 API 계약이 의미를 지켜야 한다.

#### URL

```text
https://i15e201.p.ssafy.io/api/videos?deviceId=123&size=20
└─scheme └──── host ────┘└── path ──┘└── query ────────┘
```

- scheme: 어떤 방식으로 통신하는지, `https`
- host: 어느 컴퓨터인지, 도메인
- port: 생략 시 HTTPS 기본 443
- path: 어느 기능·자원인지
- query: 조회 조건

#### header와 body

- header: 메시지에 대한 부가 정보. 인증 token, content type, idempotency key 등.
- body: 실제 전달 데이터. 회원가입 JSON, 영상 metadata 등.

#### API

API는 한 프로그램이 다른 프로그램의 기능을 사용하도록 공개한 사용 규칙이다. 버튼 화면이 아니라 프로그램끼리 쓰는 창구라고 보면 된다.

API 명세에는 다음이 있어야 한다.

- URL과 method
- 필요한 인증
- 요청 header/body
- 응답 body
- 오류 code

이 프로젝트의 REST API 계약은 `자료/api/openapi.yaml`에 있다.

#### REST

REST는 HTTP API를 자원 중심으로 설계하는 방식이다.

```text
/api/devices
/api/videos/{videoId}
/api/stream-sessions/{sessionId}
```

명사를 URL로 표현하고 HTTP method로 동작을 구분하는 경향이 있다. 모든 HTTP API가 자동으로 REST인 것은 아니고, REST도 하나의 설계 방식이다.

#### JSON

JSON은 데이터를 문자열로 표현하는 형식이다.

```json
{
  "deviceId": "11111111-1111-4111-8111-111111111111",
  "status": "ONLINE",
  "recording": true,
  "uploadQueueDepth": 0
}
```

기본 형태:

- object: `{}` 안의 key-value
- array: `[]` 안의 목록
- string: `"문자열"`
- number: `123`, `0.92`
- boolean: `true`, `false`
- null: 값 없음

JSON key는 데이터 필드 이름이다. 암호 키와 아무 관계가 없다.

### 0.7 HTTP와 HTTPS, TLS

#### 평문 HTTP의 문제

HTTP 내용을 암호화하지 않으면 같은 네트워크의 공격자나 중간 장비가 token, 비밀번호, 영상 URL을 훔쳐보거나 바꿀 수 있다.

#### HTTPS

HTTPS는 HTTP를 TLS로 보호한 것이다.

TLS가 제공하는 핵심:

1. **기밀성**: 중간에서 내용을 읽기 어렵게 암호화
2. **무결성**: 전송 중 변경됐는지 확인
3. **서버 인증**: 접속한 서버가 해당 도메인의 진짜 서버인지 인증서로 확인

#### 인증서

인증서는 “이 공개 키는 이 도메인의 서버 것”이라는 보증서다. CA라는 신뢰 기관이 서명한다.

서버에는 인증서와 쌍을 이루는 private key가 있다. private key는 절대 Git이나 앱에 넣지 않는다.

#### TLS와 JWT의 차이

- TLS: 네트워크 **연결 전체**를 보호
- JWT: API 요청자가 누구인지 증명하는 **응용 데이터**

HTTPS를 쓴다고 사용자가 자동 로그인되는 것이 아니고, JWT를 쓴다고 통신 내용이 자동 암호화되는 것도 아니다. 둘 다 필요하다.

#### MQTTS와 RTSPS

- MQTTS: MQTT 연결을 TLS로 보호
- RTSPS: RTSP 연결을 TLS로 보호

뒤의 `S`는 보통 secure/TLS 적용을 뜻한다.

### 0.8 Java, Spring Boot, Gradle은 각각 무엇인가

#### Java

Java는 백엔드 코드를 작성한 프로그래밍 언어다. `.java` 파일을 compile하면 JVM이 실행할 bytecode가 된다.

#### JVM과 JDK

- JVM: Java 프로그램을 실행하는 가상 실행 환경
- JDK: Java 코드 compile, 실행, 개발에 필요한 도구 묶음

이 프로젝트는 Java 17 JDK가 필요하다.

#### Spring Framework

Spring은 Java 백엔드 개발에서 반복되는 일을 도와주는 framework다.

- HTTP 요청을 Controller method에 연결
- 객체 생성과 의존성 연결
- DB transaction 관리
- validation
- 인증·인가
- 설정 파일과 환경변수 처리

framework는 라이브러리보다 애플리케이션의 전체 실행 구조를 더 많이 정해 준다.

#### Spring Boot

Spring Boot는 Spring 애플리케이션을 빠르게 구성·실행하도록 기본 설정과 내장 서버를 제공한다. 이 프로젝트의 `ServerApplication.java`를 실행하면 내장 web server와 Spring 구성 요소가 올라온다.

`Controller`, `Service`, `Mapper`는 물리 서버가 세 개라는 뜻이 아니다. 같은 Spring 프로세스 안에서 책임을 나눈 코드 계층이다.

#### 의존성

의존성은 우리 코드가 가져다 쓰는 외부 코드 묶음이다.

예:

- Spring Security
- PostgreSQL driver
- MinIO SDK
- Eclipse Paho MQTT client

직접 전부 구현하지 않고 검증된 기능을 가져다 쓴다.

#### Gradle

Gradle은 Java 프로젝트의 build 도구다.

- 어떤 의존성을 받을지 관리
- Java compile
- test 실행
- 실행 가능한 JAR 생성

`build.gradle`은 build 방법을 적은 파일이고, `gradlew.bat`는 PC에 Gradle을 따로 설치하지 않아도 정해진 버전을 실행하는 wrapper다.

### 0.9 Nginx란 무엇인가

#### 한 줄 정의

> **Nginx는 인터넷에서 들어오는 요청을 가장 먼저 받아 적절한 내부 프로그램으로 전달하는 웹 서버이자 리버스 프록시다.**

발음은 보통 “엔진엑스”다.

#### 왜 필요한가

우리 서버 컴퓨터 안에는 여러 프로그램이 있다.

```text
Spring Boot :8080
MediaMTX HLS :8888
MinIO :9000
```

이 포트를 모두 인터넷에 공개하면 사용자는 주소를 여러 개 알아야 하고, 각 서비스가 TLS와 접근 제어를 따로 처리해야 하며 공격 표면도 커진다.

Nginx를 정문으로 두면:

```text
인터넷 사용자는 https://서비스도메인:443 하나만 접속
                    ↓
                  Nginx
             ┌──────┴──────┐
          /api 요청      /live 요청
             ↓              ↓
       Spring :8080    MediaMTX :8888
```

#### 프록시와 리버스 프록시

- forward proxy: 클라이언트를 대신해 외부 서버에 접근
- reverse proxy: 서버들을 대신해 외부 클라이언트 요청을 받음

Nginx는 이 프로젝트에서 reverse proxy다. 사용자는 뒤에 Spring과 MediaMTX가 따로 있다는 사실을 몰라도 된다.

#### 이 프로젝트에서 Nginx가 하는 일

- 443에서 HTTPS 요청 수신
- TLS 인증서와 private key 사용
- `/api/**`를 Spring Boot로 전달
- HLS playlist/segment 요청 전에 live token 검사
- 허용되면 MediaMTX로 전달
- PostgreSQL, MinIO, Spring 내부 포트를 외부에서 숨김
- 실제 client IP와 원래 HTTPS 정보를 header로 전달

#### Nginx가 하지 않는 일

- 비즈니스 규칙 판단
- 사용자·영상 metadata를 DB에 저장
- MQTT 메시지 중계
- AI 추론
- MP4 영구 보관

Nginx는 Spring을 대체하지 않는다. 정문과 교통정리 역할이다.

### 0.10 Docker와 Docker Compose란 무엇인가

#### “내 컴퓨터에서는 되는데요” 문제

개발자마다 다음이 다르면 프로그램이 다르게 동작한다.

- PostgreSQL 버전
- 설치 경로
- 설정 파일
- 환경변수
- 필요한 library

#### Docker image

Docker image는 프로그램과 실행 환경을 묶은 읽기 전용 template다. 설치 설명서와 재료를 합쳐 포장한 실행 상자 설계도에 가깝다.

#### container

container는 image를 실제로 실행한 instance다.

- `postgres:16-alpine` image
- 그것을 실행한 `wj-postgres` container

image와 container는 class와 object처럼 “설계도와 실행 개체” 관계로 생각해도 된다.

#### volume

container를 삭제하면 container 내부 변경도 사라질 수 있다. DB와 영상은 그러면 안 되므로 volume에 영속 저장한다.

- `wj-pgdata`: PostgreSQL 데이터
- `wj-minio`: MinIO 객체
- `wj-mosquitto`: broker 설정·상태

container 삭제와 volume 삭제는 영향이 다르다. 운영에서 volume을 지우는 명령은 데이터 삭제다.

#### Docker network

같은 Compose 안의 container는 서비스 이름으로 서로 찾을 수 있다.

```text
Spring 또는 init container → http://minio:9000
```

여기서 `minio`는 인터넷 DNS 이름이 아니라 Compose 내부 서비스 이름이다. 휴대폰은 이 이름을 알 수 없다.

#### Docker Compose

Compose는 여러 container, port, volume, environment, healthcheck를 한 YAML 파일로 정의하고 함께 실행하는 도구다.

이 프로젝트에서는 PostgreSQL, MinIO, Mosquitto, MediaMTX를 한꺼번에 로컬에서 올린다.

### 0.11 PostgreSQL, SQL, MyBatis, Flyway란 무엇인가

#### 데이터베이스

데이터베이스는 데이터를 저장하고 검색·수정하도록 전문화된 프로그램이다. 단순 파일 폴더보다 동시 접근, 검색, 관계, 무결성을 체계적으로 관리한다.

#### 관계형 데이터베이스

관계형 DB는 데이터를 table과 관계로 표현한다.

`users` 예:

| id | email | display_name |
|---|---|---|
| UUID-1 | a@example.com | 찬형 |

- table: 같은 종류 데이터의 표
- row: 한 개체의 한 줄
- column: 속성
- primary key: row를 유일하게 식별
- foreign key: 다른 table row와 관계
- index: 검색을 빠르게 하는 별도 자료구조
- constraint: 허용되지 않는 데이터를 막는 규칙

#### PostgreSQL

PostgreSQL은 관계형 DB 제품 이름이다. “DB”가 일반 종류라면 “PostgreSQL”은 우리가 선택한 구체적인 프로그램이다.

Spring은 PostgreSQL의 5432 포트에 연결해 SQL을 보낸다.

#### SQL

SQL은 관계형 DB에 명령하는 언어다.

```sql
SELECT *
FROM videos
WHERE device_id = ?
  AND status = 'READY';
```

- `SELECT`: 조회
- `INSERT`: 생성
- `UPDATE`: 수정
- `DELETE`: 삭제
- `CREATE TABLE`: 구조 생성

#### MyBatis

Java method와 SQL을 연결해 주는 도구다.

```text
Java Service
  → VideoMapper.findAccessibleVideos(...)
  → MyBatis가 SQL 실행
  → PostgreSQL row
  → Java 객체로 변환
```

MyBatis는 DB가 아니고, DB를 편하게 사용하는 Java library다.

#### schema와 migration

schema는 DB의 구조다. table, column, index, constraint 정의가 포함된다.

기능이 늘면 구조도 변한다.

```text
V1: users, auth_sessions
V2: devices, memberships
V4: videos
V10: stream sessions
V18: device events
```

migration은 구조 변경을 순서대로 기록한 SQL이다.

#### Flyway

Flyway는 어떤 migration이 이미 적용됐는지 기록하고, 서버 시작 때 아직 적용하지 않은 다음 버전을 순서대로 실행하는 도구다.

Flyway는 DB 그 자체가 아니다. DB schema의 버전 관리자다.

### 0.12 MinIO와 객체 저장소란 무엇인가

#### 파일을 PostgreSQL에 다 넣지 않는 이유

MP4는 수십~수백 MB가 될 수 있다. 큰 파일을 DB row에 넣으면:

- DB 크기와 backup이 급격히 커진다.
- 영상 전송 중 DB connection을 오래 쓴다.
- API 서버가 파일 중계 병목이 된다.

그래서 metadata와 실제 파일을 나눈다.

```text
PostgreSQL videos row
  - 제목
  - 촬영 시각
  - 상태
  - storage_key
  - checksum

MinIO object
  - 실제 MP4 bytes
```

#### 객체 저장소

객체 저장소는 큰 파일을 `key → object` 형태로 저장하는 시스템이다.

- bucket: 객체를 담는 큰 보관 단위
- object: 파일 bytes와 metadata
- object key: 객체 이름

```text
bucket: wj-videos
key: private/{deviceId}/events/{videoId}.mp4
```

object key의 `key`는 암호 키가 아니다. 창고 안의 물건 이름표다.

#### S3

S3는 Amazon의 객체 저장 서비스이며, 그 API 방식이 사실상 널리 쓰이는 표준처럼 되었다. “S3 호환”은 Amazon S3와 비슷한 API로 bucket과 object를 다룰 수 있다는 뜻이다.

#### MinIO

> **MinIO는 우리가 직접 실행할 수 있는 S3 호환 객체 저장소 프로그램이다.**

로컬 개발과 현재 배포에서 실제 MP4를 저장한다.

MinIO가 하는 일:

- MP4 object 저장
- object metadata 보관
- 특정 object 조회·삭제
- presigned URL 검증
- 운영 환경의 저장 시 암호화

MinIO가 하지 않는 일:

- 사용자가 어느 기기의 멤버인지 판단
- 로그인
- 영상 목록 검색 규칙
- 웃음 통계 계산

이 판단은 Spring과 PostgreSQL이 한다.

#### presigned URL

MinIO의 master access key를 앱과 기기에 주면 모든 객체에 위험한 권한을 줄 수 있다. 대신 Spring이 특정 작업만 잠깐 허용하는 서명 URL을 만든다.

```text
특정 bucket + 특정 object + PUT + 15분
특정 bucket + 특정 object + GET + 5분
```

쉽게 말해 창고 마스터키가 아니라 “3번 사물함을 5분 동안 열 수 있는 출입증”이다.

### 0.13 MQTT와 Mosquitto란 무엇인가

#### HTTP만으로 기기 상태를 받으면

서버가 홈캠 상태를 알고 싶을 때 HTTP polling만 사용한다면:

```text
서버: 상태 바뀌었어?
기기: 아니
서버: 상태 바뀌었어?
기기: 아니
서버: 상태 바뀌었어?
기기: 응
```

변화가 없어도 계속 요청해야 한다. 기기가 서버의 요청을 받으려면 가정용 NAT와 방화벽 문제도 생긴다.

#### publish / subscribe

MQTT는 발행/구독 방식의 가벼운 메시지 프로토콜이다.

- publisher: 메시지를 발행하는 프로그램
- subscriber: 특정 topic을 구독하는 프로그램
- topic: 메시지 분류·주소 문자열
- broker: publisher에게 받아 subscriber에게 전달하는 중간 서버

```text
홈캠 publisher
  → topic: prod/wj/v2/devices/D/heartbeat
  → MQTT broker
  → 이 topic을 구독한 Spring backend
```

publisher와 subscriber는 서로 직접 주소를 몰라도 broker와 연결하면 된다.

#### MQTT

MQTT는 **대화 규칙인 프로토콜 이름**이다. 프로그램 제품 이름이 아니다.

HTTP가 규칙인 것처럼 MQTT도:

- 연결
- 구독
- 발행
- QoS
- retain
- keep alive

같은 규칙을 정의한다.

#### broker

broker는 MQTT 메시지 중개 프로그램이다.

우체국 비유:

- topic: 우편함 분류 주소
- publisher: 편지를 맡기는 사람
- broker: 우체국
- subscriber: 해당 주소 편지를 받겠다고 신청한 사람

broker는 topic과 구독 관계를 보고 전달한다.

#### Mosquitto

> **Mosquitto는 MQTT 규칙을 실제로 구현한 broker 프로그램의 제품 이름이다.**

정리하면:

```text
MQTT      = 통신 규칙
Mosquitto = 그 규칙으로 메시지를 중개하는 실제 프로그램
Paho      = Java/Spring이 MQTT에 연결할 때 쓰는 client library
```

웹으로 비유하면:

```text
HTTP      = 통신 규칙
Nginx     = HTTP를 처리하는 실제 서버 프로그램 중 하나
브라우저   = HTTP client
```

#### 이 프로젝트에서 Mosquitto가 전달하는 것

- 기기 → 서버: online/offline, heartbeat
- 기기 → 서버: 등록 모드
- 기기 → 서버: 웃음 등 감지 이벤트
- 기기 → 서버: 라이브 준비·종료 이벤트
- 서버 → 기기: 라이브 START/EXTEND/STOP 명령
- 기기 → 서버: 명령 ACK

전달하지 않는 것:

- MP4 파일
- 라이브 H.264/AAC 전체
- 사용자 JWT
- 등록 코드 평문
- presigned URL

#### 왜 Mosquitto에 MP4를 안 보내나

MQTT broker는 작은 상태·명령 메시지를 빠르게 중개하는 역할에 적합하다. 수백 MB MP4를 보내면 broker memory, 저장, 재전송, 느린 subscriber 때문에 작은 heartbeat와 명령까지 지연될 수 있다.

#### topic은 채널 이름이다

```text
prod/wj/v2/devices/{deviceId}/heartbeat
prod/wj/v2/devices/{deviceId}/commands
```

topic을 안다고 메시지를 보낼 권한이 생기는 것은 아니다. Mosquitto가 client 인증과 ACL로 자기 기기 topic만 허용해야 한다.

#### QoS, retain, LWT 미리 보기

- QoS: 전달을 어느 정도 확인할지
- retain: broker가 topic의 마지막 값 하나를 기억할지
- LWT: 기기가 비정상 종료되면 broker가 대신 OFFLINE을 알릴지

자세한 동작은 뒤의 13장에서 다시 다룬다.

### 0.14 MediaMTX, RTSP, HLS, 코덱이란 무엇인가

#### 영상 파일과 라이브 스트림

- 영상 파일: 시작과 끝이 있는 완성된 MP4
- 라이브 스트림: 지금도 계속 만들어지는 영상·음성 데이터

MinIO는 완성된 파일 보관에 적합하고, MediaMTX는 계속 흐르는 라이브 전달에 적합하다.

#### 원본 영상이 사실 무엇인가

카메라 센서가 만드는 원시 영상은 매우 크다. 그대로 네트워크로 보내기 어렵기 때문에 압축한다.

#### 코덱

코덱은 영상·음성을 압축하고 다시 푸는 규칙/기술이다.

- H.264: 영상 코덱
- AAC: 음성 코덱

코덱은 파일 확장자와 다르다.

#### 컨테이너

컨테이너는 압축된 영상·음성, 시간 정보 등을 한 파일이나 전달 구조에 담는 형식이다.

- MP4: 저장 파일 컨테이너
- MPEG-TS/fMP4 segment: HLS에서 사용할 수 있는 조각 형식

Docker container와 영상 container는 이름만 같고 전혀 다른 개념이다.

#### RTSP

RTSP는 라이브 미디어 session을 제어하는 프로토콜이다. 이 프로젝트에서는 홈캠이 MediaMTX에 H.264/AAC stream을 publish하는 ingest 쪽에서 사용한다.

#### HLS

HLS는 라이브 영상을 짧은 파일 조각으로 나누고 HTTP로 재생하는 방식이다.

```text
index.m3u8 playlist
  ├─ segment001
  ├─ segment002
  └─ segment003
```

앱 player는 playlist를 반복해서 읽고 새 segment를 이어 재생한다.

#### ingest와 playback

- ingest: 기기 영상이 미디어 서버로 들어오는 것
- playback: 사용자가 미디어 서버의 영상을 재생하는 것

이 프로젝트:

```text
홈캠 --RTSP(S) ingest--> MediaMTX --HLS playback--> 앱
```

#### MediaMTX

> **MediaMTX는 여러 미디어 프로토콜 사이에서 라이브 스트림을 받아 전달하는 미디어 서버 프로그램이다.**

이 프로젝트에서:

- 홈캠의 RTSP(S) publish를 받음
- H.264/AAC를 가능하면 다시 인코딩하지 않음
- HLS playlist/segment로 제공
- 한 입력을 여러 시청자에게 전달

MediaMTX가 하지 않는 일:

- 사용자 회원가입
- 기기 membership 검사
- MQTT 명령 전달
- MP4 영구 저장
- 통계

#### remux와 transcode

- transcode: 압축을 풀고 다른 설정/코덱으로 다시 압축. 비용이 큼.
- remux: 압축된 H.264/AAC는 유지하고 포장·전달 형식만 변경. 비용이 작음.

MediaMTX를 쓴 핵심 이유 중 하나는 가능한 경로에서 remux와 fan-out을 전문 프로그램에 맡기는 것이다.

### 0.15 주요 이름을 “종류”별로 다시 정리

| 이름 | 이것의 정체 | 한 줄 역할 |
|---|---|---|
| EC2 | 빌린 가상 컴퓨터 | 운영 프로그램들이 실행되는 기계 |
| Linux | 운영체제 | 프로세스·파일·네트워크 관리 |
| systemd | Linux 서비스 관리자 | Spring 등을 백그라운드 실행·재시작 |
| Java | 프로그래밍 언어 | 백엔드 코드 작성 |
| JVM | Java 실행 환경 | compiled Java 실행 |
| Spring Boot | Java backend framework | REST API와 비즈니스 로직 실행 |
| Gradle | build 도구 | 의존성·compile·test·JAR |
| Nginx | web server/reverse proxy | HTTPS 정문과 내부 routing |
| PostgreSQL | 관계형 DB 프로그램 | 계정·권한·metadata·상태 저장 |
| SQL | DB 명령 언어 | PostgreSQL 조회·수정 |
| MyBatis | Java DB mapping library | Java method와 SQL 연결 |
| Flyway | DB migration 도구 | schema version 순서 적용 |
| MinIO | S3 호환 객체 저장소 | MP4 파일 보관 |
| MQTT | pub/sub 통신 프로토콜 | 작은 기기 메시지 규칙 |
| Mosquitto | MQTT broker 프로그램 | MQTT 메시지 중개 |
| Paho | MQTT client library | Spring이 Mosquitto와 연결 |
| MediaMTX | 미디어 서버 | RTSP ingest를 HLS로 전달 |
| Docker | container 실행 도구 | 의존 프로그램 환경 격리 |
| Docker Compose | 다중 container 정의 도구 | 인프라를 함께 실행 |
| Flutter | 앱 framework | Android 사용자 화면과 API 호출 |
| Jetson | edge 컴퓨터 | AI 감지·영상 처리 |
| YAMNet | 오디오 분류 AI 모델 | 웃음 후보 감지 |
| Banuba | 모바일 영상 편집 SDK | Android 로컬 편집 |

이 표에서 가장 중요한 구분은 **규칙과 구현 제품을 섞지 않는 것**이다.

```text
HTTP/MQTT/RTSP/HLS = 통신 규칙 또는 전달 방식
Nginx/Mosquitto/MediaMTX = 그 일을 실제로 수행하는 프로그램
PostgreSQL/MinIO = 서로 다른 종류의 저장 프로그램
Spring Boot = 우리 비즈니스 로직을 실행하는 프로그램 기반
```

### 0.16 이제야 읽는 전체 한 문장

앞의 정의를 바탕으로 처음 문장을 다시 풀면 다음과 같다.

> Flutter 앱은 HTTP라는 요청·응답 규칙으로 Nginx라는 외부 정문에 요청한다. Nginx는 API 요청을 Spring Boot 프로그램에 넘긴다. Spring은 사용자와 권한을 확인하고 PostgreSQL에 metadata를 저장한다. 홈캠과 Spring 사이의 작은 비동기 상태·명령은 MQTT 규칙을 사용하고 Mosquitto가 중개한다. 완성된 MP4는 파일 전문 저장소인 MinIO에 보관한다. 라이브 H.264/AAC stream은 홈캠에서 MediaMTX로 들어가고, MediaMTX가 앱이 재생하기 쉬운 HLS로 내보낸다.

이 문장을 자기 말로 설명할 수 있으면 뒤의 MVP 흐름을 읽을 준비가 된 것이다.

### 0.17 MVP의 정확한 범위

서비스 기획서 8절이 확정한 시연 MVP는 다음 7개다.

| 번호 | MVP | 백엔드 관점 핵심 |
|---:|---|---|
| 1 | 회원가입 / 로그인 | 사용자 인증, JWT access token, refresh token 회전 |
| 2 | 기기 등록 | 기기 인증, 8자리 일회용 코드, claim, 멤버십 |
| 3 | 홈 라이브 스트리밍 | REST 세션 + MQTT 제어 + MediaMTX 영상 전달 |
| 4 | 이벤트 감지 영상 확인 | YAMNet 감지 + 멱등 이벤트 + presigned 업로드 + 목록·재생 |
| 5 | 감지 영상 편집 | Android Banuba 로컬 편집, 서버 편집은 MVP 밖 |
| 6 | 편집 영상 다운로드 | 편집본 로컬 저장, 원본은 단기 다운로드 URL |
| 7 | 이벤트 기반 통계 / 리포트 | READY 영상 집계, 원시 이벤트 집계, 시간대 처리 |

MVP 동선에 필요한 전제 기능은 다음 3개다.

- 세션 유지: REQ-F-03
- 기기 목록·상태: REQ-F-12
- 앱 탭 셸: REQ-F-41

초대, 구성원 관리, 구독, 소유권 이전, 기기 해제, 접근 기록, 알림, 팬틸트 등은 코드가 있더라도 **시연 MVP 밖의 확장 기능**이다.

---

# 1. 전체 시스템을 먼저 한 장으로 보기

## 1.1 구성 요소

```text
[Flutter Android 앱]
  ├─ HTTPS REST + 사용자 JWT ───────────────┐
  ├─ presigned GET으로 영상 재생/다운로드 ─┼──> [Nginx]
  └─ HLS playlist/segment 요청 ─────────────┘       │
                                                    ├─> [Spring Boot API]
                                                    └─> [MediaMTX HLS]

[Jetson / Raspberry Pi 홈캠]
  ├─ HTTPS REST + 기기 credential ───────────────> [Spring Boot API]
  ├─ MQTTS publish/subscribe ────────────────────> [Mosquitto]
  ├─ presigned PUT ──────────────────────────────> [MinIO]
  └─ H.264/AAC RTSP(S) publish ──────────────────> [MediaMTX]

[Spring Boot API]
  ├─ 메타데이터·권한·세션·상태 ────────────────> [PostgreSQL]
  ├─ 서명 URL 발급·객체 검사·삭제 ─────────────> [MinIO]
  ├─ START/EXTEND/STOP 명령, 상태 구독 ─────────> [Mosquitto]
  └─ 라이브 시청 토큰 검증 <─────────────────── [Nginx]
```

## 1.2 왜 서버 하나로 다 하지 않았나

| 통신 경로 | 잘하는 일 | 이 프로젝트에서 맡은 일 | 다른 경로로 하면 생기는 문제 |
|---|---|---|---|
| REST/HTTP | 명확한 요청-응답, 오류 코드 | 로그인, 기기 claim, 목록, URL 발급, 통계 | 기기 상태를 계속 물으면 polling 낭비 |
| MQTT | 작은 비동기 메시지, pub/sub | heartbeat, 감지 이벤트, 라이브 명령 | 큰 MP4를 보내면 브로커 메모리·재전송 부담 |
| MinIO/S3 | 큰 객체 저장·전송 | MP4 업로드, 재생, 다운로드 | API 서버를 거치면 네트워크·메모리 병목 |
| RTSP(S) | 카메라의 연속 스트림 ingest | 홈캠 → MediaMTX | REST 요청 하나로 끝나지 않는 장시간 연결 |
| HLS | 앱·웹 친화적 재생 | MediaMTX → 앱 | RTSP를 앱이 직접 재생하면 호환성과 보안이 어려움 |

### 핵심 구분

- **저장 영상**: 완성된 MP4 파일이다. MinIO에 객체로 보관한다.
- **라이브 영상**: 계속 들어오는 H.264/AAC 패킷이다. MediaMTX가 HLS로 내보낸다.
- **이벤트**: “웃음이 발생했다”는 작은 JSON 사실이다. MQTT와 PostgreSQL이 다룬다.
- **명령**: “라이브를 시작하라”는 작은 JSON이다. MQTT가 다룬다.

이 네 가지를 같은 것으로 보면 설계가 이해되지 않는다.

## 1.3 사용 기술과 선택 이유

| 기술 | 현재 역할 | 선택 이유 | 대표 대안과 차이 |
|---|---|---|---|
| Java 17 | 서버 언어 | LTS, 팀 프로젝트에서 안정적, Spring 생태계 | Kotlin은 간결하지만 팀 숙련도 필요 |
| Spring Boot 3.5.6 | API 애플리케이션 | 보안·검증·트랜잭션·설정 생태계 | Node/NestJS도 가능하나 현재 Java 코드 자산 활용 |
| Spring Security | 인증 필터 체인 | 사용자/기기/관리 API를 경로별로 분리 | 직접 필터 구현은 누락 위험이 큼 |
| OAuth2 Resource Server | JWT 검증 | Bearer JWT 표준 검증을 재사용 | 자체 파싱은 서명·만료 검증 실수 위험 |
| BCrypt | 사용자 비밀번호 해시 | salt 내장, 느리게 만들어 무차별 대입 방어 | SHA-256 단독은 너무 빨라 비밀번호 저장에 부적합 |
| PostgreSQL 16 | 관계형 메타데이터 | 트랜잭션, FK, UNIQUE, 집계, 시간대 기능 | MongoDB는 관계·제약을 앱에서 더 많이 관리 |
| MyBatis | SQL 매핑 | 복잡한 권한 조회·집계 SQL을 직접 통제 | JPA는 객체 중심이지만 복잡한 SQL 튜닝이 간접적 |
| Flyway | DB 마이그레이션 | 코드와 DB 스키마 버전을 함께 관리 | 수동 SQL은 환경별 스키마 불일치 발생 |
| MinIO | S3 호환 객체 저장소 | 로컬/EC2에서도 S3 방식 사용, presigned URL | DB BLOB은 백업·전송·용량 부담 |
| Mosquitto | MQTT broker | 가볍고 IoT pub/sub와 ACL 지원 | Kafka는 이 규모의 기기 제어에 지나치게 무거움 |
| Eclipse Paho | Java MQTT client | Mosquitto와 연결·구독·QoS 발행 | 직접 프로토콜 구현 불필요 |
| MediaMTX | RTSP ingest, HLS fan-out | 트랜스코딩 없이 remux 가능, 구성이 단순 | 서버 직접 FFmpeg는 프로세스·부하 관리가 복잡 |
| Nginx | 외부 정문·리버스 프록시 | TLS 종료, 내부 포트 은닉, HLS 인증 연계 | 각 서비스를 직접 공개하면 공격 면적 증가 |
| Docker Compose | 로컬/운영 의존 서비스 | PostgreSQL·MinIO·Mosquitto·MediaMTX 재현 | PC에 직접 설치하면 버전과 설정이 달라짐 |
| Gradle | 빌드·테스트 | 의존성 관리, bootJar 생성 | Maven도 가능하나 현재 Gradle로 통일 |

---

# 2. MVP 1 — 회원가입 / 로그인

## 2.1 사용자가 보는 기능

- 이메일, 비밀번호, 표시 이름으로 회원가입한다.
- 이메일, 비밀번호로 로그인한다.
- 앱을 껐다 켜도 refresh token으로 세션을 복구한다.
- 로그인 실패가 10분 안에 5회 누적되면 일시 제한한다.
- 로그인 상태에서는 현재 비밀번호를 확인한 뒤 비밀번호를 바꾼다.
- 비밀번호를 잊으면 이메일로 받은 재설정 링크로 새 비밀번호를 정한다.

관련 API:

| API | 인증 필요 | 역할 |
|---|---:|---|
| `POST /api/auth/signup` | 아니오 | 사용자 생성 후 토큰 발급 |
| `POST /api/auth/login` | 아니오 | 비밀번호 확인 후 토큰 발급 |
| `POST /api/auth/refresh` | 아니오 | refresh token 회전 |
| `POST /api/auth/logout` | 사용자 JWT | 현재 세션 폐기 |
| `POST /api/auth/password/change` | 사용자 JWT | 현재 비밀번호 확인 후 변경 |
| `POST /api/auth/password/forgot` | 아니오 | 재설정 링크(토큰) 발급 요청 |
| `POST /api/auth/password/reset` | 아니오 | 토큰으로 비밀번호 재설정 |
| `DELETE /api/auth/me` | 사용자 JWT | 계정 탈퇴 |

## 2.2 아주 기초: 인증과 인가

- **인증(Authentication)**: “너 누구야?”를 확인한다. 로그인, JWT 검증이 여기다.
- **인가(Authorization)**: “네가 이 작업을 해도 돼?”를 확인한다. 특정 기기 멤버인지 검사하는 것이 여기다.

로그인했다고 남의 영상까지 볼 수 있는 것은 아니다. 로그인은 사용자 ID를 알아낸 것뿐이고, 영상 조회 때 `device_memberships` 관계를 다시 확인해야 한다.

## 2.3 회원가입 흐름

```text
앱
  → POST /api/auth/signup
  → SignUpRequest 형식 검증
  → 이메일 소문자·공백 정규화
  → BCrypt로 비밀번호 해시
  → users INSERT
  → auth_sessions에 refresh token의 SHA-256 해시 저장
  → access token + refresh token 반환
```

### 비밀번호를 왜 그대로 저장하지 않나

DB가 유출될 수 있기 때문이다. 평문 비밀번호를 저장하면 다른 서비스에서 같은 비밀번호를 쓰는 사용자까지 피해를 본다.

BCrypt는 다음 특징이 있다.

- 원문으로 되돌리는 복호화 함수가 없다.
- 같은 비밀번호도 매번 다른 salt 때문에 다른 해시가 나온다.
- 일부러 계산을 느리게 만들어 대량 추측 공격 비용을 높인다.

`SHA-256(password)`만 저장하면 안 된다. SHA-256은 파일 무결성이나 토큰 해시에는 좋지만 매우 빨라서 비밀번호 대입 공격에도 빠르다.

## 2.4 로그인 흐름

```text
앱
  → POST /api/auth/login
  → 이메일·IP 기준 최근 실패 횟수 확인
  → users에서 활성 사용자 조회
  → BCrypt.matches(입력 비밀번호, 저장 해시)
  ├─ 실패: 실패 이력 기록, 항상 동일한 INVALID_CREDENTIALS 응답
  └─ 성공: 실패 이력 정리, last_login 갱신, 토큰 발급
```

사용자가 없는 경우와 비밀번호가 틀린 경우에 같은 메시지를 주는 이유는 공격자에게 “이 이메일은 가입되어 있다”는 정보를 주지 않기 위해서다.

## 2.5 access token과 refresh token

### access token

- 형식: JWT
- 기본 수명: 15분
- 용도: 일반 API 호출의 `Authorization: Bearer ...`
- 현재 서명 방식: HS256
- 주요 claim:
  - `sub`: 사용자 UUID
  - `sid`: 인증 세션 UUID
  - `tv`: token version
  - `iss`: `wj-server`
  - `iat`, `exp`: 발급·만료 시각

JWT는 `header.payload.signature` 구조다. payload는 암호화가 아니라 Base64URL 인코딩이므로 비밀번호 같은 비밀을 넣으면 안 된다. 서명은 “서버가 만들었고 내용이 변조되지 않았다”는 것을 검증한다.

### refresh token

- 기본 수명: 14일
- 예측할 수 없는 32바이트 난수
- DB에는 원문이 아니라 SHA-256 해시만 저장
- 갱신할 때 기존 세션을 폐기하고 새 refresh token을 발급하는 **rotation** 적용

access token만 14일로 만들면 탈취 후 14일 동안 막기 어렵다. access token을 짧게 두고 refresh token을 서버 DB에서 폐기할 수 있게 하면 편의성과 통제력을 나눌 수 있다.

## 2.6 Spring Security의 세 필터 체인

`SecurityConfig`는 인증 종류를 경로별로 분리한다.

1. `/internal/admin/**`: provisioning 관리자 키
2. `/api/iot/**`: 기기 credential
3. 나머지 `/api/**`: 사용자 JWT

모두 `STATELESS`다. 즉 전통적인 서버 HTTP session에 로그인 상태를 저장하지 않는다. 요청마다 credential을 제시한다.

CSRF를 끈 이유도 쿠키 기반 서버 세션이 아니라 Authorization header 기반의 stateless API이기 때문이다. 단, refresh token을 브라우저 쿠키로 옮긴다면 SameSite, HttpOnly, CSRF 정책을 다시 설계해야 한다.

## 2.7 DB에서 보는 인증

핵심 테이블:

- `users`: 이메일, 비밀번호 해시, 표시 이름, 상태, token version
- `auth_sessions`: refresh token 해시, 사용자, 만료, 폐기 시각, client 정보
- `auth_login_attempts`: 이메일·IP 해시 기반 실패 기록

왜 로그인 시도 테이블에 이메일과 IP 원문 대신 해시를 저장하나? 공격 방어에는 같은 값인지 비교할 수 있으면 되고, 불필요한 개인정보 원문 보관은 줄이는 편이 낫기 때문이다.

## 2.8 코드 위치

- `auth/api/AuthController.java`
- `auth/application/AuthService.java`
- `auth/application/JwtTokenService.java`
- `auth/application/LoginAttemptService.java`
- `auth/application/PasswordResetSender.java` / `ConfiguredPasswordResetSender.java`
- `auth/persistence/AuthMapper.java`
- `config/SecurityConfig.java`
- `config/JwtConfig.java`
- `db/migration/V1__auth.sql`
- `db/migration/V14__login_rate_limit.sql`
- `db/migration/V25__member_password_reset_notifications.sql` (password_reset_tokens 테이블)

## 2.9 다른 파트가 물을 만한 질문

**Q. JWT는 암호화됐나요?**  
A. 아니다. 현재 access token은 HS256으로 **서명**됐다. 내용은 읽을 수 있지만 비밀 키 없이 위조·변조할 수 없다. 민감정보를 payload에 넣지 않는다.

**Q. `JWT_SIGNING_KEY`를 앱에도 넣어야 하나요?**  
A. 절대 아니다. HS256은 같은 키로 서명과 검증을 하므로 서버만 가져야 한다. 앱은 완성된 token만 보관한다.

**Q. 401과 403의 차이는?**  
A. 401은 로그인 정보가 없거나 유효하지 않음, 403은 누구인지는 알지만 권한이 부족함이다. 이 프로젝트는 리소스 존재 자체를 숨기기 위해 일부 권한 실패를 404로 응답하기도 한다.

**Q. 로그아웃하면 이미 발급된 access token이 즉시 무효인가요?**  
A. refresh 세션은 폐기된다. 짧은 access token은 설계에 따라 만료까지 살아 있을 수 있으므로 15분으로 짧게 둔다. `sid`, `tv`를 활용한 추가 즉시 폐기 검증 여부는 실제 필터 구성을 확인해 설명해야 한다.

**Q. 프론트가 access token을 영구 저장해도 되나요?**  
A. access token은 짧게 쓰고, 민감 저장소에는 refresh token을 두며, 401 시 한 번만 refresh 후 원 요청을 재시도하는 흐름이 일반적이다. 동시 refresh 중복도 막아야 한다.

## 2.10 비밀번호 변경과 재설정

비밀번호를 바꾸는 길은 두 갈래다. **현재 비밀번호를 아는 사람**이 바꾸는 변경과, **비밀번호를 잊은 사람**이 이메일로 되찾는 재설정이다. 둘의 신뢰 근거가 다르므로 흐름도 다르다.

### 변경 — 로그인한 사람이 바꾼다

로그인 상태에서 `POST /api/auth/password/change`를 부른다. 이미 JWT로 “누구인지”는 확인됐지만, 비밀번호를 바꾸는 민감한 동작이라 **현재 비밀번호를 한 번 더 확인**한다(토큰만 탈취한 공격자가 비밀번호까지 바꾸지 못하게).

```text
앱 (로그인 상태)
  → POST /api/auth/password/change { currentPassword, newPassword }
  → BCrypt.matches(currentPassword, 저장 해시)  ── 틀리면 401
  → newPassword가 현재와 같으면 422 (그대로 두는 변경 거부)
  → 새 비밀번호 BCrypt 해시로 교체
  → 이 사용자의 재설정 토큰 전부 만료
  → 지금 세션만 남기고 다른 세션 전부 폐기
```

마지막 줄이 중요하다. 비밀번호를 바꾸면 예전 비밀번호로 로그인해 둔 **다른 기기 세션은 끊는다**(`revokeOtherSessionsForUser`). 지금 조작 중인 세션 하나만 살린다.

### 재설정 — 비밀번호를 잊은 사람이 되찾는다

비밀번호를 모르니 현재 비밀번호로 증명할 수 없다. 대신 **이메일 수신함 접근**을 신원 증거로 삼는다. 두 단계로 나뉜다.

**1단계 — 요청** `POST /api/auth/password/forgot { email }`

```text
→ 이메일 정규화 후 활성 사용자 조회
├─ 없으면: 아무 일도 안 하고 그냥 202 응답   (가입 여부를 숨김)
└─ 있으면:
     → 32바이트 난수 토큰 생성
     → 그 사용자의 기존 재설정 토큰 만료
     → 토큰의 SHA-256 해시 + 만료(30분)를 password_reset_tokens에 저장
     → 이메일로 재설정 링크 발송 (원문 토큰은 메일에만 담김)
```

응답은 계정 존재 여부와 무관하게 항상 `202 Accepted`다. “이 이메일은 가입돼 있다”는 정보를 주지 않으려는 것으로, 2.4 로그인의 동일 메시지 원칙과 같은 이유다.

**2단계 — 실행** `POST /api/auth/password/reset { token, newPassword }`

```text
→ 받은 token을 SHA-256 해시로 바꿔 DB 행을 잠그고 조회
→ 이미 썼거나 / 만료됐거나 / 소비 실패면 401
→ 토큰을 사용됨으로 표시 (원자적 1회 소비)
→ 새 비밀번호 BCrypt 해시로 교체
→ 남은 재설정 토큰 전부 만료
→ 이 사용자의 모든 세션 폐기
```

변경과 달리 재설정은 **모든 세션을 폐기**한다. 비밀번호를 잊었다는 것은 계정이 위험한 상황일 수 있으므로, 어디서 로그인돼 있든 전부 끊고 새로 로그인하게 만든다.

### 토큰을 왜 원문으로 저장하지 않나

refresh token과 같은 사고방식이다. DB에는 토큰의 **SHA-256 해시만** 저장한다. DB가 유출돼도 그 값으로는 재설정 링크를 만들 수 없다. 검증할 때는 들어온 토큰을 같은 방식으로 해시해서 비교한다. 비밀번호에 BCrypt를 쓰고 토큰에 SHA-256을 쓰는 이유는 2.3에 정리돼 있다. 토큰은 원래 예측 불가능한 난수라 느린 해시가 필요 없다.

### 만료 30분이 지나면

30분 제한은 “비밀번호”가 아니라 **재설정 링크(토큰)**의 수명이다. 링크가 만료되면 재설정이 무산될 뿐, 비밀번호는 바뀌지 않았으므로 사용자는 **원래 비밀번호로 그대로 로그인**하면 된다. 정말 잊어서 요청했다면 forgot을 다시 눌러 새 링크를 받는다. 새 요청은 이전 토큰을 먼저 만료시키므로 항상 가장 최근 링크 하나만 유효하다.

### 메일 발송이 설정 안 된 환경

메일 서버(`spring.mail.host`)가 비어 있으면 발송을 건너뛰고 경고 로그만 남긴다(`ConfiguredPasswordResetSender`). 개발 환경에서 메일 인프라 없이도 forgot 흐름이 500으로 죽지 않게 한 것이다.

### 정리: 변경 vs 재설정

| 구분 | 변경(change) | 재설정(reset) |
|---|---|---|
| 신원 증거 | 로그인 JWT + 현재 비밀번호 | 이메일로 받은 1회용 토큰 |
| 로그인 필요 | 필요 | 불필요 |
| 세션 처리 | 현재 세션만 유지, 나머지 폐기 | 전 세션 폐기 |
| 계정 노출 방지 | 해당 없음 | 없는 계정도 202로 동일 응답 |

---

# 3. MVP 2 — 기기 등록

## 3.1 “기기 등록”에는 사실 두 단계가 있다

1. **provisioning**: 운영자가 출고 기기를 서버에 만들고 기기 자격증명을 넣어 준다.
2. **claim**: 최종 사용자가 실제 기기를 자기 계정에 귀속한다.

둘을 섞으면 안 된다. claim 전에 기기는 이미 서버가 아는 `deviceId`와 기기 전용 credential을 가져야 한다.

## 3.2 왜 사람 JWT를 기기에 쓰지 않나

홈캠은 사람처럼 이메일과 비밀번호를 입력하지 않는다. 또한 사용자 로그아웃과 무관하게 heartbeat와 업로드를 계속해야 한다. 그래서 기기에는 별도의 정체성과 수명주기가 필요하다.

현재 기기 credential은 두 목적을 분리한다.

- `BOOTSTRAP`: 최초 등록용, 기본 15분
- `OPERATING`: 정상 운용용, 기본 30일

기기는 bootstrap credential로 `/api/iot/enrollment`에 접근해 operating credential로 교환한다. 이후 등록 코드 발급, 영상 업로드 등 `/api/iot/**` API는 operating 역할이 필요하다.

## 3.3 사용자 claim 전체 흐름

```text
운영자
  → loopback 전용 /internal/admin/devices
  → deviceId + BOOTSTRAP credential 생성

기기
  → bootstrap credential로 enrollment
  → OPERATING credential 발급
  → 물리 버튼 길게 누름
  → MQTT /registration 에 ENABLED 발행
  → POST /api/iot/registration-codes
  → 서버가 8자리 코드 평문 반환
  → 기기 LCD에만 표시

사용자 앱
  → QR 스캔 또는 8자리 직접 입력
  → POST /api/devices/claim
  → 서버가 코드 해시로 기기를 역조회하고 행 잠금
  → TTL·미사용·UNCLAIMED·rate limit 확인
  → device를 CLAIMED로 변경
  → OWNER membership 생성
  → 코드를 사용 처리
```

## 3.4 등록 코드 보안

- 표시: 8자리, 사람이 헷갈리기 쉬운 문자를 줄인 alphabet
- 유효시간: 120초
- DB 저장: 평문이 아니라 SHA-256 해시
- 1회용: `used_at`과 `used_by` 기록
- 경쟁 조건 방지: `findByHashForUpdate`로 행 잠금
- 실패 제한: 계정·IP 기준 10분에 5회
- 응답: 실패 원인을 세세히 구분하지 않고 `DEVICE_CLAIM_REJECTED`

짧은 코드에 SHA-256만 쓰면 DB 유출 시 모든 조합을 대입할 수 있다. 이 설계는 해시 하나만 믿는 것이 아니라 **120초 TTL + 1회용 + 등록 모드 + rate limit + 행 잠금**을 겹쳐서 방어한다.

QR 코드는 별도 권한 체계가 아니다. 사람이 입력할 등록 코드 또는 딥링크를 카메라로 편하게 읽는 표현 방식일 뿐이다.

## 3.5 claim이 트랜잭션이어야 하는 이유

기기를 `CLAIMED`로 바꿨는데 OWNER membership 생성이 실패하면 “소유자는 없는데 이미 등록된 기기”가 된다. 반대로 membership만 생기고 코드가 미사용이면 재사용 공격이 가능하다.

따라서 아래가 한 트랜잭션으로 모두 성공하거나 모두 롤백되어야 한다.

- 코드 검증과 잠금
- device claim 상태 변경
- registration code 사용 처리
- OWNER membership 생성

DB의 UNIQUE와 CHECK 제약은 애플리케이션 검사를 놓쳤을 때의 마지막 방어선이다.

## 3.6 MQTT에서 등록 코드를 보내지 않는 이유

MQTT retained 메시지는 새 구독자에게 남아 있는 마지막 값을 전달할 수 있다. 여기에 등록 코드나 토큰을 넣으면 브로커 보존·로그·잘못된 ACL을 통해 노출될 가능성이 커진다.

MQTT에는 “등록 모드가 켜졌다”는 상태만 보내고, 코드 평문은 인증된 HTTPS 응답으로 기기에 한 번 전달해 LCD에 표시한다.

## 3.7 “MQTT key가 뭐예요?” 정확한 답

`MQTT key`는 MQTT 표준의 정확한 단일 용어가 아니다. 질문한 사람이 무엇을 뜻하는지 먼저 구분해야 한다.

| 상대가 말한 key 후보 | 실제 의미 | 이 프로젝트 예 |
|---|---|---|
| topic key | 메시지 라우팅 주소 | `prod/wj/v2/devices/{deviceId}/heartbeat` |
| MQTT username/password | broker 접속 credential | backend service 계정, 기기별 동적 계정 |
| TLS private key | MQTTS 연결에서 인증서 소유를 증명하는 개인 키 | 기기 보안 저장소에만 보관 |
| device credential | `/api/iot/**` REST 인증 토큰 | BOOTSTRAP, OPERATING |
| `deviceId` | 기기 식별 UUID | 토픽과 payload의 기기 ID |
| `requestId` / `eventId` | 중복 실행을 막는 멱등 키 | 명령 ACK, 감지 이벤트 |

즉, MQTT 토픽에 들어가는 `deviceId`는 비밀 키가 아니다. ACL은 인증된 기기가 자기 `deviceId` 토픽만 publish/subscribe하도록 막아야 한다. UUID를 안다고 권한을 얻어서는 안 된다.

## 3.8 MQTT ACL

기기 D는 최소한 아래만 허용한다.

- publish: 자기 D의 `status`, `heartbeat`, `registration`, `events`, `stream/events`, `commands/ack`
- subscribe: 자기 D의 `commands`
- 금지: 다른 기기 토픽, 임의 와일드카드

백엔드만 여러 기기의 inbound 토픽을 구독하고 command 토픽에 발행한다. Mosquitto Dynamic Security로 기기별 client/role/ACL을 만든다.

## 3.9 코드 위치

- `provisioning/api/ProvisioningController.java`
- `provisioning/application/ProvisioningService.java`
- `iot/auth/DeviceAuthenticationFilter.java`
- `iot/auth/DeviceCredentialAuthenticator.java`
- `iot/auth/DeviceCredentialController.java`
- `device/api/IotRegistrationController.java`
- `device/application/RegistrationCodeService.java`
- `device/application/RegistrationCodeHasher.java`
- `device/application/ClaimAttemptService.java`
- `device/application/DeviceService.java`
- `iot/mqtt/DeviceMqttIdentityManager.java`
- `db/migration/V2__devices_and_memberships.sql`
- `db/migration/V3__claim_security_and_device_credentials.sql`
- `db/migration/V11__registration_codes_and_transfer.sql`
- `db/migration/V16__device_credential_lifecycle.sql`

## 3.10 예상 질문

**Q. serial number로 바로 claim하면 안 되나요?**  
A. serial number는 오래 유지되는 식별자라 노출되면 반복 공격이 가능하다. 120초 일회용 코드는 사용자가 물리적 기기 앞에 있다는 신호를 추가한다.

**Q. MQTT가 끊기면 기기 등록을 못 하나요?**  
A. 현재 등록 모드 상태는 MQTT로 서버에 전달되므로 통합 흐름에 영향이 있다. 코드 발급 자체는 기기 credential을 사용한 HTTPS다. 시연 전에 두 연결을 모두 확인해야 한다.

**Q. 한 기기에 OWNER가 여러 명일 수 있나요?**  
A. 활성 OWNER는 하나여야 한다. 다른 사용자는 EDITOR/VIEWER 멤버십으로 접근하고, 소유권 이전은 별도 트랜잭션이다.

**Q. 코드가 동시에 두 앱에서 제출되면요?**  
A. 해시 조회 시 DB 행을 잠그고 1회용 상태를 변경하므로 하나만 성공해야 한다.

---

# 4. MVP 3 — 홈에서 라이브 스트리밍 시청

## 4.1 가장 많이 헷갈리는 지점

Spring Boot가 영상을 직접 중계하지 않는다.

- Spring Boot: 시청 권한, 세션, 단기 token, 시작·연장·종료 판단
- Mosquitto: 서버의 제어 명령과 기기의 상태 이벤트 운반
- 홈캠: H.264/AAC 인코딩과 RTSP(S) publish
- MediaMTX: RTSP ingest를 HLS로 remux하고 여러 시청자에게 fan-out
- Nginx: 외부 HTTPS 정문과 HLS token introspection

## 4.2 프로토콜 기초

### RTSP

카메라·미디어 서버 사이에서 라이브 스트림을 제어하는 데 흔히 쓴다. 이 프로젝트에서는 홈캠이 MediaMTX에 publish하는 ingest 경로다.

### HLS

앱이 `.m3u8` playlist를 받고 짧은 segment 파일을 이어 재생한다. HTTP 기반이라 프록시, CDN, 모바일 플레이어와 잘 맞는다. 대신 segment가 준비되어야 하므로 초저지연 프로토콜보다 지연이 조금 있다.

### remux와 transcode

- **transcode**: 코덱을 풀고 다시 인코딩한다. CPU/GPU 비용이 크다.
- **remux**: H.264/AAC 압축 내용은 유지하고 컨테이너·전달 형식만 바꾼다.

홈캠이 이미 H.264/AAC로 보내므로 MediaMTX는 가능하면 HLS로 remux한다. 이것이 서버 비용을 크게 줄이는 핵심이다.

## 4.3 세션 생성부터 재생까지

```text
1. 앱 → POST /api/devices/{deviceId}/stream-sessions
2. 서버 → 활성 membership 확인
3. 서버 → DB에 viewer session 생성
4-A. 이미 같은 기기의 READY stream이 있음
     → 기존 streamId 공유, MQTT START 생략
4-B. 송출 없음
     → device_stream 생성
     → MQTT commands에 START_STREAM 발행
5. 기기 → MediaMTX에 live/{streamId} RTSP(S) publish
6. 기기 → MQTT stream/events에 STREAM_READY
7. 서버 → 세션을 READY로 전환
8. 앱 → GET /api/stream-sessions/{sessionId} polling
9. 앱 → 받은 HLS URL로 playlist와 segment 요청
10. Nginx → /api/live/introspect로 token과 streamId 검증
11. 통과하면 Nginx → MediaMTX HLS 전달
```

앱은 세션 생성 직후 영상이 바로 나온다고 가정하면 안 된다. 기기 인코더와 첫 HLS segment가 준비될 시간이 필요해 `PENDING → READY` 상태를 polling한다.

## 4.4 다중 시청자

같은 기기를 가족 두 명이 동시에 보면:

- edge publisher는 하나
- `device_streams`의 stream 하나
- `stream_sessions`의 viewer session은 두 개
- MediaMTX가 같은 입력을 여러 HLS 시청자에게 fan-out

새 시청자마다 홈캠이 별도 인코딩하면 기기 자원과 업로드 대역폭이 배로 든다. 공유 stream 설계가 이를 막는다.

## 4.5 heartbeat, idle timeout, hard lease

| 시간 | 기본값 | 의미 |
|---|---:|---|
| 앱 heartbeat 간격 | 15초 | “아직 보고 있다” |
| viewer TTL | 45초 | 이 시간 동안 heartbeat가 없으면 viewer 만료 |
| idle timeout | 60초 | 마지막 시청 활동 후 송출 중지 판단 |
| edge hard lease | 120초 | 서버가 사라져도 기기가 스스로 끄는 최종 안전장치 |
| live token TTL | 30초 | HLS 접근 token 수명 |

앱이 강제 종료되면 정상 `DELETE`가 오지 않는다. 그래서 heartbeat TTL이 필요하다. 서버나 MQTT가 죽어 `STOP_STREAM`을 못 보내도 hard lease가 지나면 기기가 스스로 종료해야 카메라가 무기한 송출되지 않는다.

활성 시청자가 있으면 서버는 `EXTEND_STREAM`으로 hard expiry를 연장한다. 마지막 시청자가 나가면 즉시 끄지 않고 짧은 idle 시간을 두어 화면 회전·잠깐 이동 시 재시작 비용을 줄인다.

## 4.6 MQTT 명령의 핵심 필드

- `schemaVersion`: payload 계약 버전
- `requestId`: 명령 멱등 키
- `deviceId`: 대상 기기
- `type`: `START_STREAM`, `EXTEND_STREAM`, `STOP_STREAM`
- `issuedAt`, `expiresAt`: 명령 발행·실행 기한
- `payload.sessionId`: 최초 viewer
- `payload.streamId`: 공유 송출
- `payload.hardExpiresAt`: edge 자체 종료 시각

QoS 1은 “최소 한 번(at least once)” 전달이다. 중복 전달될 수 있으므로 기기는 같은 `requestId` 명령을 두 번 실행하면 안 되고, 저장한 ACK를 다시 보내야 한다.

QoS 1은 정확히 한 번 실행을 보장하지 않는다. **전송 품질과 비즈니스 멱등성은 다른 문제**다.

## 4.7 live token이 필요한 이유

MediaMTX의 HLS 포트를 공개하고 URL만 알면 재생되게 하면 접근 제어를 우회할 수 있다. 서버가 짧은 token에 stream ID를 서명하고, Nginx가 playlist/segment 요청 전에 introspection을 호출한다.

검증해야 할 것:

- token 서명이 유효한가
- 만료되지 않았는가
- token 안의 stream ID와 URL path의 stream ID가 같은가

토큰을 다른 stream path에 붙이는 공격을 막으려면 마지막 비교가 중요하다.

## 4.8 MQTT와 영상 스트림의 관계

MQTT가 영상을 운반하는 것이 아니다.

```text
MQTT: "streamId 123으로 송출 시작해"
RTSP(S): 실제 H.264/AAC 바이트
MQTT: "streamId 123 준비됐어"
HLS: 앱이 실제 영상 재생
```

## 4.9 코드 위치

- `stream/api/StreamController.java`
- `stream/api/LiveIntrospectionController.java`
- `stream/application/StreamService.java`
- `stream/application/StreamCommandPublisher.java`
- `stream/application/StreamEventService.java`
- `stream/application/StreamLifecycleWorker.java`
- `stream/application/LiveTokenService.java`
- `stream/persistence/StreamMapper.java`
- `iot/mqtt/PahoMqttGateway.java`
- `iot/telemetry/MqttInboundHandler.java`
- `db/migration/V10__stream_sessions.sql`
- `backend/infra/mediamtx/mediamtx.yml`
- `backend/deploy/nginx-william-james.conf`
- `ai/device_agent/wj_device_agent/stream.py`

## 4.10 예상 질문

**Q. 왜 WebSocket으로 영상을 안 보내나요?**  
A. WebSocket도 바이트를 보낼 수 있지만 미디어 playlist, segment, 재접속, player 호환, fan-out을 직접 구현해야 한다. 검증된 미디어 서버와 HLS를 쓰는 편이 단순하다.

**Q. MQTT만으로 라이브 시작과 영상을 다 처리하면 안 되나요?**  
A. MQTT는 작은 상태·명령에 적합하다. 연속 고대역폭 영상은 브로커 메모리, QoS 재전송, subscriber 처리 지연에 부적합하다.

**Q. MediaMTX는 DB인가요?**  
A. 아니다. 미디어 라우터/서버다. 영구 보관은 MinIO, 메타데이터는 PostgreSQL이다.

**Q. HLS URL을 DB에 저장하나요?**  
A. 영구 공개 URL로 저장하는 구조가 아니다. streamId와 세션 상태를 저장하고 짧은 token이 붙은 URL을 동적으로 만든다.

**Q. 앱 heartbeat와 기기 heartbeat는 같은 건가요?**  
A. 아니다. 앱 heartbeat는 viewer가 시청 중인지, 기기 heartbeat는 홈캠이 온라인이고 어떤 상태인지 나타낸다.

---

# 5. MVP 4 — 이벤트 감지 영상 확인

이 기능은 프로젝트의 핵심이며 다음 다섯 단계를 한 흐름으로 이해해야 한다.

1. edge에서 웃음 감지
2. 로컬 버퍼에서 클립 생성
3. MQTT로 원시 이벤트 기록
4. HTTPS presigned URL로 MinIO 업로드
5. 앱에서 목록 조회와 재생

## 5.1 왜 감지를 서버가 아니라 edge에서 하나

- 카메라·마이크 원본을 계속 클라우드로 보내지 않아도 된다.
- 네트워크가 끊겨도 로컬 순환 버퍼에서 영상을 살릴 수 있다.
- 지연이 짧다.
- 개인정보가 포함된 원본 전송을 줄인다.
- 서버 GPU 비용을 줄인다.

YAMNet은 오디오 이벤트 분류 모델이다. 현재 문서상 웃음 판정 임계값은 0.25, 연속 2개 window 조건이다. 임계값이 낮으면 recall은 늘지만 오탐도 늘 수 있고, 높으면 precision은 늘지만 웃음을 놓칠 수 있다.

## 5.2 MQTT 이벤트는 영상 생성 명령이 아니다

반드시 기억할 문장:

> 기기는 MQTT 성공 여부와 무관하게 먼저 로컬 세그먼트를 보호하고 클립을 만든다.

권장 순서:

```text
웃음 감지
  → 로컬 순환 버퍼 세그먼트 잠금
  → MP4 생성
  → 로컬 업로드 큐에 영속 기록
  → MQTT events 발행
  → 네트워크 가능할 때 REST + MinIO 업로드
```

MQTT가 끊겼다고 클립 생성까지 멈추면 사용자의 추억을 잃는다. 로컬 보존은 클라우드 관측보다 우선한다.

## 5.3 원시 이벤트 JSON

핵심 필드:

- `eventId`: 기기가 만든 UUID, 기기 범위 멱등 키
- `deviceId`: 토픽의 기기와 같아야 함
- `type`: `LAUGHTER`, `WAKE_WORD`, `TOUCH`, `MANUAL`
- `occurredAt`: 실제 감지 시각
- `confidence`: AI 이벤트는 0~1, TOUCH/MANUAL은 없어야 함
- `localClip.state`: `SEGMENTS_LOCKED`, `GENERATING`, `QUEUED`, `FAILED`
- `beforeMs`, `afterMs`, `mergeWindowMs`
- `source.nodeId`, `source.component`, `source.modelVersion`

서버의 `MqttInboundHandler`는:

- topic 구조와 `deviceId` 일치 검사
- `schemaVersion == 2.0`
- 허용 enum 검사
- 미래 시각 제한
- confidence 조건 검사
- 길이·범위 검사
- `eventId` 기준 멱등 저장

원시 이벤트와 영상 행을 분리한 이유는 업로드 실패도 통계와 장애 분석에 남기기 위해서다. “감지는 100번 됐지만 영상은 92개 READY”라는 차이를 볼 수 있다.

## 5.4 presigned 업로드 2단계

### 1단계: 업로드 권한 요청

기기가 `POST /api/iot/videos/upload-url`을 호출한다.

- 인증: OPERATING device credential
- header: `Idempotency-Key`
- `Idempotency-Key == sourceEventId`
- 파일 크기 최대 500 MiB
- 시작·종료 시각 검증
- claimed device인지 검증
- 같은 `(deviceId, sourceEventId)` 업로드가 있는지 확인
- 없으면 `videos`에 `UPLOADING` 행 생성
- MinIO presigned PUT URL과 필수 header 반환

기기가 서버가 아니라 MinIO로 직접 `PUT`한다. 현재 필수 header에는 `Content-Type`과 `x-amz-meta-sha256`이 포함된다.

### 2단계: 완료 통지

기기가 `POST /api/iot/videos/complete`를 호출한다.

서버는 클라이언트의 “끝났어요”만 믿지 않는다.

- MinIO `statObject`
- 실제 객체 크기와 DB의 `sizeBytes` 비교
- 객체 metadata의 SHA-256과 요청 checksum 비교
- 일치하면 `READY`
- 불일치하면 `UPLOAD_INTEGRITY_MISMATCH`

이 2단계가 필요한 이유는 presigned PUT 성공과 DB 상태 변경이 하나의 DB 트랜잭션으로 묶일 수 없기 때문이다. 객체 저장소와 PostgreSQL은 서로 다른 시스템이다.

## 5.5 멱등성

모바일·IoT 네트워크에서는 응답이 유실되어 같은 요청을 다시 보낼 수 있다. 재시도할 때 영상 행이 계속 늘어나면 안 된다.

이 프로젝트는 다음을 연결한다.

- MQTT `eventId`
- REST `sourceEventId`
- HTTP `Idempotency-Key`
- DB `(device_id, source_event_id)` unique

같은 이벤트와 같은 내용이면 기존 결과를 재사용하고, 같은 이벤트 ID인데 파일 정보가 다르면 `IDEMPOTENCY_CONFLICT`를 반환한다.

**멱등성은 요청을 여러 번 보내도 최종 효과가 한 번 보낸 것과 같은 성질**이다.

## 5.6 `UPLOADING`, `READY`, `FAILED`, `DELETING`, `DELETED`

상태를 두는 이유는 파일과 DB가 동시에 완벽히 변하지 않기 때문이다.

- `UPLOADING`: 행은 만들었지만 객체 완료 검증 전
- `READY`: 재생·다운로드 가능한 정상 객체
- `FAILED`: 일정 시간 완료되지 않거나 업로드 실패
- `DELETING`: 목록에서는 숨겼고 비동기 삭제 대기
- `DELETED`: 객체 삭제 완료

`UploadStateSweepWorker`는 오래 멈춘 `UPLOADING`을 `FAILED`로 바꾼다. 같은 이벤트는 재시도할 수 있다.

## 5.7 영상 목록

`GET /api/videos`는 다음을 받는다.

- `deviceId`
- `triggerType`
- `from`, `to`
- `cursor`
- `size` 1~100

먼저 활성 membership을 확인한다. 조회 가능한 영상은 삭제되지 않은 정상 범위로 제한된다.

### 왜 offset 대신 cursor pagination인가

`OFFSET 10000`은 앞 행을 많이 건너뛰어야 하고, 조회 중 새 영상이 들어오면 중복·누락이 생기기 쉽다. 이 구현은 마지막 `(createdAt, id)`를 cursor로 인코딩해 그 뒤를 조회한다. 같은 생성 시각에도 UUID를 tie-breaker로 써서 순서를 안정화한다.

## 5.8 재생

`POST /api/videos/{videoId}/play-url`

- 사용자 JWT 확인
- 영상이 속한 기기의 활성 membership 확인
- 상태가 `READY`인지 확인
- MinIO presigned GET URL 발급
- 기본 TTL 5분
- 접근 감사 로그 기록

버킷을 public으로 열지 않고 짧은 URL을 쓰는 이유는 URL이 유출돼도 노출 시간을 줄이고, 발급 순간에 권한을 검사하기 위해서다.

주의: presigned URL이 발급된 뒤 사용자의 membership이 즉시 회수되어도 URL 자체는 TTL까지 유효할 수 있다. 그래서 TTL을 짧게 둔다.

## 5.9 PostgreSQL과 MinIO의 역할 분담

PostgreSQL:

- 누가 소유·접근하는가
- 제목, 감지 종류, 촬영 시각, 상태
- 객체의 `storage_key`
- 크기, checksum
- 이벤트와 영상 관계
- 목록·통계용 index

MinIO:

- 실제 MP4 바이트

DB에 MP4 BLOB을 넣지 않는 이유:

- DB 백업이 매우 커진다.
- API/DB 연결이 대용량 전송에 묶인다.
- 객체 저장소의 range request, presigned URL, 수명주기를 활용하기 어렵다.

MinIO의 object key는 암호 키가 아니라 버킷 안의 경로형 식별자다.

```text
private/{deviceId}/events/{videoId}.mp4
```

UUID와 경로를 안다고 읽을 수 있어서는 안 된다. 버킷은 private이고 서명 URL이 필요하다.

## 5.10 삭제와 보존

사용자 삭제 요청에서 DB 행과 객체를 한 요청 안에 억지로 모두 지우지 않는다.

1. DB 상태를 `DELETING`으로 바꿔 목록에서 즉시 숨김
2. deletion job 생성
3. worker가 MinIO 객체 삭제
4. 성공하면 `DELETED`
5. 실패하면 재시도

기본 보존 기간은 30일이다. 구독 확장 코드에는 365일과 해지 유예 30일도 있으나 MVP 핵심은 아니다. `RetentionSweepWorker`가 만료 대상을 비동기 삭제 흐름으로 넘긴다.

## 5.11 알림 생성 — 웃음 영상 준비 완료

이벤트 영상이 그냥 저장만 되면 가족은 새 영상이 생긴 줄 모른다. 그래서 영상이 재생 가능한 상태로 확정되는 순간 **인앱 알림**을 만든다. 여기서 알림은 푸시 메시지나 이메일이 아니라, 서버 DB(`notifications` 테이블)에 쌓아 두고 앱의 알림함에서 조회하는 방식이다.

### 언제 만들어지나

5.4의 완료 통지(2단계)에서 서버가 업로드 무결성을 확인하고 영상을 `READY`로 확정한 **바로 그 트랜잭션 안**에서 만든다.

```text
IotVideoService.completeUpload
  → 크기·체크섬 검증
  → videos 상태 READY로 확정 (markReady)
  → device_events에 업로드 연결
  → triggerType이 LAUGHTER면
       notificationService.laughterVideoReady(deviceId, videoId, title)
```

`triggerType`이 `LAUGHTER`일 때만 알림을 만든다. 즉 “웃음으로 판정된 영상이 실제로 재생 가능해진 순간”에만 알린다. 업로드가 실패하거나 무결성 검사에서 막히면 `READY`가 되지 않으므로 알림도 생기지 않는다. 알림 생성이 완료 트랜잭션 안에 있는 이유도 이것이다. 영상 확정과 알림이 함께 커밋되거나 함께 무산된다.

### 누구에게 만들어지나 — 팬아웃

알림은 영상을 올린 한 사람이 아니라 그 기기를 **함께 보는 가족 전원**에게 필요하다. 그래서 한 건을 넣는 게 아니라, `device_memberships`에서 그 기기의 활성 구성원을 조회해 사람마다 한 행씩 INSERT한다.

```sql
INSERT INTO notifications (...)
SELECT gen_random_uuid(), m.user_id, 'LAUGHTER_VIDEO_READY', ...
  FROM device_memberships m
  JOIN users u ON u.id = m.user_id
 WHERE m.device_id = #{deviceId} AND m.status = 'ACTIVE'
   AND u.status = 'ACTIVE' AND u.deleted_at IS NULL
ON CONFLICT (user_id, dedupe_key) DO NOTHING
```

애플리케이션에서 for 문으로 사람 수만큼 INSERT를 반복하지 않고, `SELECT ... INSERT` 한 문장으로 DB가 팬아웃을 처리한다. 탈퇴했거나 비활성인 구성원은 `WHERE` 조건에서 걸러진다.

### 두 번 눌러도 한 번만 — 멱등성

완료 통지는 네트워크 재시도 등으로 두 번 도착할 수 있다. 그때 같은 영상에 대한 알림이 두 번 쌓이면 안 된다. 이를 막는 장치가 **`dedupe_key`**다.

- 웃음 영상 알림: `dedupe_key = 'laughter-video:{videoId}'`
- `notifications` 테이블에 `UNIQUE (user_id, dedupe_key)` 제약이 있다.
- INSERT에 `ON CONFLICT (user_id, dedupe_key) DO NOTHING`을 붙였다.

그래서 같은 영상 완료가 여러 번 들어와도, 사용자별로 알림은 정확히 한 개만 남는다. 5.5의 영상 멱등성과 같은 사고방식을 알림에도 적용한 것이다.

### 같은 알림함을 쓰는 다른 트리거 — 초대

`notifications` 테이블은 웃음 영상 전용이 아니다. 기기 **초대**를 받으면 `INVITATION_RECEIVED` 타입 알림도 같은 테이블에 만들어진다(`dedupe_key = 'invitation:{invitationId}'`). 초대 자체는 시연 MVP 밖의 확장 기능(0.17 참고)이지만, 알림 “생성 방식”은 웃음 영상과 완전히 동일하다. 대상 사용자를 조회해 INSERT하고, `dedupe_key`로 중복을 막는다. 다른 점은 팬아웃 대상뿐이다. 초대는 초대받은 이메일의 사용자 1명에게, 웃음 영상은 기기 구성원 전원에게 간다.

### 만든 알림을 읽는 쪽

생성과 짝을 이루는 조회·읽음 처리 API가 있다. 모두 **자기 것만** 다룰 수 있게 `user_id`로 범위를 제한한다(11.6의 IDOR 방지와 같은 원칙).

| API | 역할 |
|---|---|
| `GET /api/notifications?limit=` | 최신순 목록(기본 30, 최대 100) |
| `GET /api/notifications/unread-count` | 안 읽은 개수 배지용 |
| `PATCH /api/notifications/{id}/read` | 한 건 읽음 처리 |
| `PATCH /api/notifications/read-all` | 전부 읽음 처리 |

읽음 처리(`read_at`)는 알림을 지우는 게 아니라 시각을 찍는 방식이다. 한 건 읽음은 `COALESCE(read_at, now())`로 이미 읽은 것을 덮어쓰지 않고, 남의 알림 id를 넣어도 `user_id` 조건에 걸려 아무것도 바뀌지 않으며 “찾을 수 없음”으로 응답한다.

## 5.12 코드 위치

- edge:
  - `ai/yamnet/yamnet_laughter_detect_jetson.py`
  - `ai/yamnet/mqtt_event_publisher.py`
  - `ai/yolo/laughter_clip_uploader.py`
  - `ai/yolo/segment_clip_uploader.py`
- backend:
  - `iot/telemetry/MqttInboundHandler.java`
  - `iot/event/DeviceEventService.java`
  - `video/api/IotVideoController.java`
  - `video/application/IotVideoService.java`
  - `storage/ObjectStorageService.java`
  - `video/application/VideoQueryService.java`
  - `video/application/UploadStateSweepWorker.java`
  - `video/application/VideoDeletionWorker.java`
  - `video/application/RetentionSweepWorker.java`
  - `video/persistence/VideoMapper.java`
- 알림:
  - `notification/application/NotificationService.java`
  - `notification/persistence/NotificationMapper.java`
  - `notification/api/NotificationController.java`
- DB:
  - `V4__videos.sql`
  - `V5__video_deletion_jobs.sql`
  - `V18__device_events.sql`
  - `V19__stale_upload_indexes.sql`
  - `V25__member_password_reset_notifications.sql` (notifications 테이블)

## 5.13 예상 질문

**Q. ETag가 있으면 SHA-256은 필요 없나요?**  
A. S3 계열 ETag가 항상 파일 MD5라는 보장은 없다. multipart와 서버 설정에 따라 의미가 달라질 수 있어 프로젝트가 정한 SHA-256 metadata를 별도로 검증한다.

**Q. 왜 URL을 받아 두 번 API를 호출하나요?**  
A. 첫 호출은 제한된 업로드 권한 발급, 실제 PUT은 MinIO, 두 번째 호출은 서버가 객체 무결성을 확인하고 DB를 READY로 확정하는 단계다.

**Q. MQTT 이벤트가 먼저 와야 업로드할 수 있나요?**  
A. 꼭 그렇지는 않다. HTTP 업로드가 먼저 오면 같은 `sourceEventId`로 최소 이벤트 행을 복구·연결하도록 설계되어 있다.

**Q. checksum도 암호화인가요?**  
A. 아니다. checksum은 내용이 같은지 확인하는 지문이다. 기밀성을 제공하지 않는다. 전송 기밀성은 TLS, 저장 기밀성은 SSE/KMS가 담당한다.

**Q. 네트워크가 끊기면 영상은 사라지나요?**  
A. 설계 원칙상 로컬 큐에 남아 재연결 후 같은 eventId로 재시도한다. 실제 시연 장비의 디스크 큐와 재시도 worker가 정상 동작하는지는 별도 통합 점검이 필요하다.

**Q. 알림은 휴대폰 푸시(FCM)인가요?**  
A. 현재 MVP의 알림은 서버 DB에 쌓아 두는 **인앱 알림**이다. 앱이 목록·안 읽은 개수 API를 호출해서 보여 준다. FCM/APNs 같은 실시간 푸시 발송은 확장 지점이고, 그 경우에도 지금의 `notifications` 테이블과 `dedupe_key` 멱등성이 발송 원장 역할을 그대로 할 수 있다.

**Q. 완료 통지가 두 번 오면 알림도 두 번 오나요?**  
A. 아니다. `dedupe_key = 'laughter-video:{videoId}'`와 `UNIQUE (user_id, dedupe_key)` + `ON CONFLICT DO NOTHING` 덕분에 사용자별로 한 번만 남는다.

---

# 6. MVP 5 — 이벤트 영상 편집

## 6.1 현재 MVP 판정

현재 편집은 Android 앱의 Banuba 편집기에서 **로컬로 수행**한다. 서버가 영상을 트랜스코딩하거나 편집 결과를 다시 업로드하지 않아도 MVP 충족으로 확정됐다.

따라서 백엔드가 하는 일은 주로:

1. 사용자가 원본을 볼 권한이 있는지 확인
2. `READY` 원본의 단기 GET URL 발급
3. 앱이 원본을 내려받아 Banuba로 편집하도록 지원

서버의 과거 `video_edits` 스키마나 편집 관련 흔적을 보고 “서버 편집이 현재 동작한다”고 말하면 안 된다. `V13__disable_server_video_edits.sql`과 최신 문서의 경계를 함께 봐야 한다.

## 6.2 왜 로컬 편집을 선택했나

- MVP 일정 안에 서버 FFmpeg worker, queue, 결과 저장, 실패 재처리를 만들 필요가 없다.
- 모바일 기기의 편집 SDK UI와 효과를 바로 활용한다.
- 서버 CPU/GPU 비용을 줄인다.
- 편집 결과를 클라우드에 다시 올리지 않아 개인정보와 저장 용량을 줄인다.

대신 단점도 있다.

- Android 전용
- Banuba 라이선스 token 필요
- 기기 성능과 저장 공간에 영향
- 편집 결과가 서버 통계·가족 공유 목록에 자동 반영되지 않음
- 앱 삭제나 단말 분실 시 로컬 편집본을 서버가 복구하지 못함

## 6.3 백엔드가 알아야 할 경계

- 원본: 서버가 관리하는 `videos` 행 + MinIO 객체
- 편집 작업: 앱/Banuba 로컬 책임
- 편집 결과: 단말 갤러리/로컬 파일
- 서버 재업로드: MVP 불요, 현재 보장하지 않음

이 경계를 API 계약과 발표에서 동일하게 말해야 한다.

## 6.4 예상 질문

**Q. DB에 `video_edits`가 있는데 서버 편집 되는 거 아닌가요?**  
A. 스키마 존재와 현재 제품 경로는 다르다. 최신 MVP는 로컬 편집이며 서버 재업로드를 사용하지 않는다. 과거 확장 설계가 마이그레이션에 남아 있을 수 있다.

**Q. Banuba token을 백엔드 JWT처럼 쓰나요?**  
A. 아니다. Banuba SDK 사용권을 증명하는 라이선스 성격의 token과 우리 사용자 인증 JWT는 목적·발급자·검증 주체가 완전히 다르다.

**Q. 편집 결과를 가족이 다른 폰에서 볼 수 있나요?**  
A. 현재 로컬 저장만으로는 자동 공유되지 않는다. 서버 재업로드와 새 영상 메타데이터 생성은 확장 기능이다.

---

# 7. MVP 6 — 편집 영상 다운로드

## 7.1 요구사항을 두 갈래로 구분

- 편집본: Banuba가 단말에 저장하여 MVP 충족
- 서버 원본: `POST /api/videos/{videoId}/download-url`로 다운로드

“편집 영상을 다운로드 API가 서버에 있다”라고 뭉뚱그리면 틀릴 수 있다. API-32는 서버에 있는 원본/READY 영상에 대한 다운로드 URL이고, 로컬 편집 결과 저장은 앱의 책임이다.

## 7.2 재생 URL과 다운로드 URL의 차이

둘 다 MinIO presigned GET이지만 다운로드 URL은 다음 query를 추가한다.

```text
response-content-disposition=attachment
```

브라우저나 클라이언트에게 inline 재생보다 첨부 파일 다운로드로 취급하라는 힌트다.

공통 검증:

- 사용자 JWT
- 영상 접근 membership
- `READY` 상태
- 짧은 TTL(기본 5분)
- 감사 로그

## 7.3 왜 앱에 S3 access key를 주지 않나

S3 access key/secret key는 버킷에 광범위한 권한을 줄 수 있는 장기 credential이다. 앱에 넣으면 APK 분석이나 로그로 유출될 수 있다.

서버가 다음이 제한된 presigned URL만 준다.

- 특정 bucket
- 특정 object key
- 특정 HTTP method
- 짧은 만료시간
- 업로드라면 특정 header

이를 “창고 마스터키를 주지 않고, 특정 사물함을 5분 동안 여는 일회용 출입증을 준다”고 이해하면 쉽다.

## 7.4 예상 질문

**Q. presigned URL은 한 번만 쓸 수 있나요?**  
A. 기본적으로 만료 전까지 여러 번 사용될 수 있다. “짧은 수명과 제한된 권한”이지 자동 1회용은 아니다.

**Q. URL을 받은 뒤 서버가 파일 바이트를 전달하나요?**  
A. 아니다. 앱이 MinIO/Nginx 쪽으로 직접 GET한다. 백엔드는 URL 발급만 한다.

**Q. 다운로드 중 URL이 만료되면요?**  
A. 객체 저장소의 서명 검증 시점과 연결 동작에 따라 달라질 수 있다. 실패하면 앱이 권한을 다시 확인받아 새 URL을 요청하는 흐름이 안전하다.

---

# 8. MVP 7 — 이벤트 기반 통계 / 리포트

## 8.1 현재 구현 상태를 정확히 말하기

- REQ-F-19 캘린더 영상 집계: 구현
- REQ-F-36 웃음/영상 통계: 구현
- API-33 `VideoStatsService`: 프론트가 실제 사용
- API-46 `EventStatsService`: 백엔드 구현은 있으나 현재 클라이언트 사용 경로는 사실상 없음
- REQ-F-42 이벤트 전용 신규 리포트 화면: 미구현, 개발 예정

따라서 시연은 현행 캘린더와 웃음 통계로 충족하고, 신규 전용 리포트를 이미 완성된 것처럼 말하지 않는다.

## 8.2 영상 통계와 이벤트 통계 차이

| 구분 | 영상 통계 | 원시 이벤트 통계 |
|---|---|---|
| 기준 | `READY` videos | device_events |
| 의미 | 실제 재생 가능한 추억 수 | 감지 자체가 발생한 수 |
| 업로드 실패 | 제외 | 남길 수 있음 |
| 현재 앱 사용 | 사용 | 사실상 미사용 |

예:

```text
LAUGHTER 감지 10회
  ├─ 8개 업로드 READY
  ├─ 1개 클립 생성 실패
  └─ 1개 네트워크 재시도 중

영상 통계: 8
이벤트 통계: 10
```

두 숫자가 다른 것이 버그가 아니라 관측 목적이 다르다.

## 8.3 `VideoStatsService`

입력:

- `deviceId`
- `from`, `to` 날짜
- `timeZone`, 기본 `Asia/Seoul`

검증:

- 활성 membership
- 올바른 ZoneId
- 시작일 ≤ 종료일
- 최대 366일

출력:

- 전체 READY 영상 수
- trigger type별 수
- 날짜별 수
- 최다 요일
- 최다 시간대

## 8.4 시간대가 왜 중요한가

DB는 `timestamptz`로 절대 시각을 저장한다. 사용자가 서울에서 “7월 27일”을 조회하면 서울 자정부터 다음 자정까지를 UTC instant 범위로 바꿔야 한다.

```text
사용자 날짜: 2026-07-27 Asia/Seoul
범위: 2026-07-27T00:00+09:00
   ~ 2026-07-28T00:00+09:00 (exclusive)
```

서버는 `[from, toExclusive)` 반열린 구간을 쓴다. 이렇게 하면 23:59:59.999 같은 끝값을 억지로 만들 필요가 없고, 인접 날짜 경계가 겹치지 않는다.

서버 OS 시간대에 기대면 배포 서버가 UTC일 때 날짜가 어긋날 수 있다. 조회 timeZone을 명시적으로 SQL에 전달하는 이유다.

## 8.5 집계를 PostgreSQL에서 하는 이유

영상 행을 전부 Java로 가져와 날짜별로 세면:

- 네트워크 전송량 증가
- 서버 메모리 사용 증가
- DB index와 집계 최적화 미활용

PostgreSQL의 `COUNT`, `GROUP BY`, 날짜 변환을 사용하면 필요한 작은 결과만 받는다. MyBatis는 이 SQL을 명시적으로 작성하고 결과 row에 매핑한다.

## 8.6 캘린더 목록과 통계 API의 관계

캘린더는 `GET /api/videos?from=...&to=...`의 기간 필터 결과를 날짜별로 보여줄 수 있다. 통계 API는 기간 집계 결과를 더 직접적으로 제공한다.

목록 API는 개별 영상 카드가 필요하고, 통계 API는 count만 필요하다. 같은 데이터를 보여줘도 응답 목적이 다르다.

## 8.7 코드 위치

- `video/api/VideoStatsController.java`
- `video/application/VideoStatsService.java`
- `video/persistence/VideoMapper.java`
- `iot/event/EventStatsController.java`
- `iot/event/EventStatsService.java`
- `iot/event/DeviceEventMapper.java`
- `frontend/lib/core/api_client.dart`

## 8.8 예상 질문

**Q. 통계가 실시간인가요?**  
A. 요청 시 PostgreSQL의 현재 READY 영상/이벤트를 집계한다. 별도 OLAP이나 캐시를 쓰는 구조는 아니다.

**Q. 업로드 중인 영상도 통계에 포함되나요?**  
A. 영상 통계는 READY 기준이다. 원시 event 통계에는 감지 사실이 남을 수 있다.

**Q. 왜 최대 366일인가요?**  
A. 무제한 집계 쿼리로 DB 부하가 커지는 것을 막고, 연간 히트맵까지 지원하기 위한 실용적 제한이다.

**Q. REQ-F-42가 끝났나요?**  
A. 아니다. 전용 화면은 신규 개발 항목이다. 현재 시연은 기존 캘린더·웃음 통계로 충족한다.

---

# 9. MVP 전제 1 — 세션 유지

앱이 access token 만료 때 refresh를 호출하고 새 token을 저장해야 한다. 백엔드는 refresh token을 rotation하고 이전 DB 세션을 폐기한다.

백엔드가 프론트와 합의할 사항:

- 401 발생 시 refresh는 한 번만
- 여러 API가 동시에 401이어도 refresh 요청을 하나로 합치기
- refresh 실패 시 로그인 화면으로 이동
- logout 시 로컬 token 삭제
- access와 refresh를 로그에 출력하지 않기
- 운영 HTTPS 없이 token을 전송하지 않기

---

# 10. MVP 전제 2 — 기기 목록과 상태

## 10.1 상태 데이터 출처

기기는 MQTT로 다음을 보낸다.

- `status`: ONLINE/OFFLINE 상태 전이, retained
- `heartbeat`: 주기적인 자원과 녹화 상태, non-retained

heartbeat 예:

- `recording`
- `uploadQueueDepth`
- `bufferSeconds`
- `personCount`
- `firmwareVersion`
- CPU, 메모리, 디스크 등 계약 필드

서버는 전체 원문을 모두 저장하기보다 UI와 운영에 필요한 최소 상태와 `last_seen_at`을 갱신한다. 90초 이상 heartbeat가 없으면 offline 판정하는 계약이 있다.

현재 최신 요구사항 문서는 실제 기기 경로에서 `recording=false`, `uploadQueueDepth=0` 스텁 가능성을 지적한다. API 필드가 존재한다고 실제 센서 값이 연결됐다고 단정하면 안 된다.

## 10.2 retained와 LWT

- **retained**: broker가 토픽의 마지막 메시지 하나를 기억해 새 subscriber에게 즉시 전달
- **LWT(Last Will and Testament)**: 기기 연결이 비정상 종료되면 broker가 대신 OFFLINE 메시지를 발행

status는 retained가 유용하지만 heartbeat는 오래된 자원 상태를 새 값처럼 보이면 안 되어 retain하지 않는다.

---

# 11. 모든 MVP를 받치는 백엔드 공통 지식

## 11.1 Controller → Service → Mapper

```text
Controller
  - HTTP path, method, header, body를 받음
  - 인증 principal에서 userId/deviceId 추출
  - DTO validation

Service
  - 비즈니스 규칙
  - 권한 검사
  - 상태 전이
  - 트랜잭션 경계

Mapper (MyBatis)
  - SQL 실행
  - row ↔ Java record 매핑

PostgreSQL
  - 데이터 영속화
  - FK/UNIQUE/CHECK로 무결성 방어
```

DTO는 API 계약용이고 DB row는 영속 모델용이다. 둘을 분리하면 DB 컬럼을 그대로 외부에 노출하지 않고, 응답 필드를 독립적으로 바꿀 수 있다.

## 11.2 `@Transactional`

- 기본: 성공 시 commit, runtime exception 시 rollback
- `readOnly = true`: 조회 의도를 명확히 하고 일부 최적화 가능
- 여러 UPDATE/INSERT가 하나의 비즈니스 동작이면 같은 트랜잭션에 둔다.

주의: MinIO PUT, MQTT publish 같은 외부 시스템 작업은 PostgreSQL 트랜잭션과 원자적으로 묶이지 않는다. 그래서 상태 머신, 멱등 키, worker 재시도로 **결과적 일관성(eventual consistency)**을 만든다.

## 11.3 validation의 층

1. API DTO: 형식, null, 길이
2. Service: 현재 상태와 비즈니스 규칙
3. DB: UNIQUE, FK, CHECK
4. 외부 저장소 확인: 객체 크기/checksum

한 층만 믿지 않는다.

## 11.4 HTTP 상태 코드

| 코드 | 의미 | 프로젝트 예 |
|---:|---|---|
| 200/201 | 성공 | 조회, 생성 |
| 204 | 본문 없는 성공 | 삭제, introspection 허용 |
| 400 | 문법적으로 잘못된 요청 | JSON 파싱 등 |
| 401 | 인증 실패 | JWT/기기 credential 불일치 |
| 403 | 인증됐지만 권한 없음 | OWNER 전용 작업 |
| 404 | 없거나 존재를 숨김 | 남의 영상/기기 |
| 409 | 현재 상태와 충돌 | 이미 claim, idempotency 충돌 |
| 413 | 너무 큰 payload | 500 MiB 초과 영상 |
| 422 | 값 형식은 읽었으나 규칙 위반 | 날짜 범위, enum |
| 429 | 요청 제한 | 로그인/claim 반복 실패 |
| 503 | 외부 의존성 사용 불가 | MinIO/MQTT 관리 실패 |

## 11.5 request ID

`RequestIdFilter`는 요청을 추적할 ID를 붙이고 오류 응답에도 담는다. 사용자가 오류 화면의 request ID를 알려주면 서버 로그에서 같은 요청을 찾을 수 있다.

request ID와 idempotency key는 다르다.

- request ID: 관측·로그 추적
- idempotency key: 중복 비즈니스 효과 방지

## 11.6 인가와 IDOR

나쁜 구현:

```text
GET /api/videos/{videoId}
→ videoId만 있으면 반환
```

공격자는 UUID를 얻거나 추측해 남의 영상을 볼 수 있다. 이것이 IDOR 계열 문제다.

현재 서비스는 `findAccessibleVideo(userId, videoId)` 또는 membership 확인을 통해 관계를 같이 검사한다. 리소스 ID가 UUID라고 안전한 것이 아니다.

## 11.7 해시, 암호화, 서명

| 개념 | 되돌릴 수 있나 | 목적 | 프로젝트 예 |
|---|---:|---|---|
| 인코딩 | 예 | 표현 형식 | Base64URL |
| 해시 | 아니오 | 지문·비교 | SHA-256 checksum, token hash |
| 비밀번호 해시 | 아니오 | 느린 비밀번호 검증 | BCrypt |
| 대칭 암호화 | 키로 가능 | 기밀성 | 저장소 SSE/KMS 내부 |
| 디지털 서명/MAC | 원문은 보이지만 위조 방지 | 무결성·발급자 확인 | HS256 JWT, presigned URL |
| TLS | 연결 중 암호화 | 도청·변조 방지 | HTTPS, MQTTS, RTSPS |

## 11.8 주요 “키”를 한 번에 구분

| 이름 | 누가 보관 | 어디에 사용 | 유출 시 |
|---|---|---|---|
| `JWT_SIGNING_KEY` | Spring 서버만 | 사용자 access JWT 서명 | 사용자 token 위조 가능 |
| S3 access/secret key | Spring/MinIO 운영 환경 | presigned URL 생성, 객체 관리 | 버킷 접근 위험 |
| MQTT backend password | Spring/Mosquitto 운영 환경 | broker service 계정 | 명령 위조·상태 구독 위험 |
| 기기 MQTT credential | 해당 기기 | 자기 토픽 연결 | 해당 기기 사칭 위험 |
| TLS private key | 해당 서버/기기 | TLS 신원 증명 | 통신 사칭 위험 |
| device REST credential | 해당 기기 | `/api/iot/**` | 업로드·등록 API 사칭 위험 |
| `Idempotency-Key` | 요청마다 전달 | 중복 업로드 방지 | 비밀 키는 아니지만 계약상 중요 |
| MinIO object key | DB | 객체 경로 식별 | 비밀 credential이 아님 |

환경변수 이름에 `KEY`, JSON의 `eventId`, 객체의 `storageKey`가 모두 나오지만 보안 성질은 전혀 다르다.

---

# 12. PostgreSQL, MyBatis, Flyway

## 12.1 왜 관계형 DB인가

이 도메인은 관계와 제약이 강하다.

```text
user
  └─ device_membership
       └─ device
            ├─ videos
            ├─ device_events
            ├─ stream_sessions
            └─ access_logs
```

“활성 멤버만 영상 조회”, “기기 하나에 활성 OWNER 하나”, “같은 eventId 영상 하나” 같은 규칙은 JOIN, UNIQUE, FK, 트랜잭션이 잘 맞는다.

## 12.2 Flyway

`V1__...sql`부터 `V23__...sql`까지 순서대로 실행한다. 서버 시작 시 아직 적용되지 않은 버전만 적용하고 이력을 남긴다.

원칙:

- 이미 공유 환경에 적용된 migration을 몰래 수정하지 않는다.
- 변경은 더 높은 새 V번호 파일로 추가한다.
- 앱 코드가 기대하는 스키마와 migration을 같은 commit으로 관리한다.
- 운영 DB 수동 ALTER는 다음 배포에서 불일치를 만든다.

## 12.3 MyBatis

MyBatis는 SQL을 직접 작성하고 Java method와 연결한다.

장점:

- 복잡한 권한 JOIN과 통계 SQL이 눈에 보인다.
- PostgreSQL 기능을 직접 활용한다.
- 예상 쿼리를 통제하기 쉽다.

주의:

- 동적 SQL에서 사용자 문자열을 `${}`로 붙이면 SQL injection 위험
- 일반 값은 parameter binding을 사용
- N+1 조회를 직접 피해야 함
- schema 변경 시 mapper와 row mapping을 함께 수정

## 12.4 핵심 테이블

| 테이블 | 역할 |
|---|---|
| `users` | 사용자 계정 |
| `auth_sessions` | refresh 세션 |
| `auth_login_attempts` | 로그인 제한 |
| `devices` | 기기 상태·설정 |
| `device_memberships` | 사용자-기기 권한 관계 |
| `device_credentials` | 기기 REST credential |
| `registration_codes` | 일회용 claim 코드 해시 |
| `device_events` | 원시 감지 이벤트 |
| `videos` | 영상 메타데이터와 객체 상태 |
| `video_deletion_jobs` | 비동기 객체 삭제 queue |
| `device_streams` | 기기당 공유 라이브 송출 |
| `stream_sessions` | 사용자별 viewer 세션 |
| `access_logs` | 접근·변경 감사 |

---

# 13. MQTT를 백엔드 면접 수준으로 설명하기

## 13.1 publish / subscribe

HTTP는 보통 요청자가 상대 주소를 알고 응답을 기다린다. MQTT는 publisher가 topic에 메시지를 발행하고 broker가 subscriber에게 전달한다. 기기와 서버가 직접 서로의 연결을 관리하는 대신 둘 다 Mosquitto와 연결한다.

## 13.2 topic

```text
{env}/wj/v2/devices/{deviceId}/{suffix}
```

- `env`: dev/prod 격리
- `wj`: 서비스 namespace
- `v2`: 계약 major version
- `deviceId`: 권한 단위
- suffix: heartbeat, events, commands 등

topic은 routing 주소이지 암호화 키가 아니다.

## 13.3 QoS

- QoS 0: 최대 한 번. 빠르지만 유실 가능. heartbeat처럼 다음 값이 곧 오는 데이터.
- QoS 1: 최소 한 번. 도착 가능성을 높이지만 중복 가능. 이벤트·명령.
- QoS 2: 정확히 한 번 전달 절차. overhead가 크고 그래도 애플리케이션 부작용 설계는 신중해야 함.

이 프로젝트는 heartbeat 0, 상태·이벤트·명령·ACK 1을 기본으로 한다.

## 13.4 retain

broker가 topic 마지막 메시지 하나를 저장한다. 새 구독자가 즉시 현재 ONLINE/OFFLINE 상태를 알 수 있어 status에 적합하다. 계속 변하는 heartbeat 원문을 retain하면 오래된 값이 현재값처럼 보일 수 있다.

## 13.5 Last Will

기기가 정상 DISCONNECT를 못 하고 끊기면 broker가 미리 등록된 OFFLINE 메시지를 대신 발행한다. 전원 단절을 빠르게 알리는 장치다.

## 13.6 keep alive와 재연결

- keep alive 권장 30초
- 1, 2, 4, 8... 최대 60초 지수 백오프
- 여러 기기가 동시에 재연결하지 않도록 jitter
- 기기 시간은 NTP 동기화

고정 1초 재시도는 장애 중 broker를 더 공격하는 thundering herd를 만든다.

## 13.7 MQTT 보안 세 겹

1. TLS: 통신 도청·변조 방지
2. 인증: 어떤 client인지 확인
3. ACL: 그 client가 어느 topic에 무엇을 할 수 있는지 제한

TLS만 켰다고 다른 기기 topic 접근이 자동으로 막히는 것은 아니다.

---

# 14. MinIO/S3를 백엔드 면접 수준으로 설명하기

## 14.1 bucket, object, key

- bucket: 객체 묶음, 현재 `wj-videos`
- object: MP4 바이트 + metadata
- key: bucket 안의 객체 이름/경로

폴더처럼 보이지만 객체 저장소의 key는 문자열 namespace다.

## 14.2 endpoint와 public endpoint

- `S3_ENDPOINT`: Spring 서버가 MinIO에 내부적으로 접근하는 주소
- `S3_PUBLIC_ENDPOINT`: 앱/기기가 presigned URL로 실제 접근 가능한 외부 주소

Docker 내부 주소 `http://minio:9000`으로 서명된 URL을 휴대폰에 주면 휴대폰은 `minio`라는 hostname을 찾지 못한다. 내부 endpoint와 외부 endpoint를 구분해야 하는 이유다.

## 14.3 저장 시 암호화

운영 compose는 MinIO SSE-KMS와 KES 설정을 요구한다. TLS는 이동 중 암호화, SSE는 디스크에 저장된 객체 암호화다.

- TLS가 있어도 디스크가 유출되면 저장 데이터 보호는 별도 문제
- SSE key 수명주기와 백업이 중요
- key를 잃으면 데이터도 복구하지 못할 수 있음

## 14.4 DB 백업과 객체 백업

PostgreSQL만 백업하면 영상 metadata만 있고 MP4가 없다. MinIO만 백업하면 파일은 있지만 누구의 어떤 영상인지 연결하기 어렵다. 복구 시점과 절차를 함께 설계해야 한다.

---

# 15. 배포와 네트워크

## 15.1 공개 포트 원칙

일반 사용자에게는 443을 정문으로 공개한다.

외부 공개 금지 또는 제한:

- PostgreSQL 5432
- MinIO API 9000 / console 9001
- Spring 8080
- MediaMTX HLS 8888
- 평문 MQTT 1883

MQTT 기기 연결이 필요하면 TLS 8883을 공개하되 기기별 인증·ACL을 적용한다. 운영 MediaMTX RTSPS publish 포트는 인증과 방화벽 정책을 함께 확인한다.

## 15.2 Nginx

- HTTPS TLS 종료
- `/api`를 Spring으로 reverse proxy
- HLS 요청을 인증 후 MediaMTX로 proxy
- 내부 서비스 포트 은닉
- 외부 hostname 통일

`X-Forwarded-For`, `X-Forwarded-Proto`를 올바르게 전달하고 Spring의 forward header 설정을 맞춰야 실제 client IP와 HTTPS scheme을 알 수 있다. 로그인 rate limit이 proxy IP 하나로 뭉치지 않게 신뢰 프록시 범위를 제한해야 한다.

## 15.3 Docker

컨테이너는 VM보다 가볍게 프로세스와 파일시스템·네트워크를 격리한다. Compose는 여러 서비스를 함께 정의한다.

중요한 구분:

- image: 실행 환경의 불변 template
- container: image의 실행 instance
- volume: container를 지워도 남겨야 하는 DB/객체 데이터
- network: container 사이 통신 공간
- healthcheck: 프로세스가 준비됐는지 확인

## 15.4 secret

다음은 Git에 넣지 않는다.

- `.env`
- JWT signing key
- DB 운영 password
- MinIO secret key
- MQTT password
- TLS private key
- PEM SSH key
- Banuba license token

개발 기본값은 운영에 쓰지 않는다. 로그, 스택 트레이스, CI 출력에도 원문을 남기지 않는다.

---

# 16. 장애 상황별로 설명하기

| 장애 | 기대 동작 | 확인할 곳 |
|---|---|---|
| Spring 중단 | 앱 REST 불가, edge 로컬 클립 보존은 계속 | systemd, actuator, edge queue |
| Mosquitto 중단 | 상태·명령 유실/지연, 로컬 클립 생성은 계속 | broker, 재연결 backoff |
| MinIO 중단 | presigned/stat 실패, 업로드 queue 재시도 | 503, MinIO health |
| PostgreSQL 중단 | 권한·상태 판단 불가, API 실패 | DB health, connection |
| MediaMTX 중단 | 로그인·목록은 되지만 라이브 불가 | HLS/RTSP health |
| 앱 강제 종료 | viewer heartbeat 만료 후 stream 정리 | lifecycle worker |
| 서버+MQTT 동시 중단 | edge hard lease 후 라이브 자체 종료 | device stream agent |
| PUT 성공, complete 유실 | DB는 UPLOADING, 같은 eventId complete 재시도 | idempotency |
| DB READY 전환 실패 | 객체는 존재할 수 있음, 재시도/정리 필요 | 상태 worker, object audit |
| object 삭제 실패 | DELETING job 재시도 | deletion worker |

---

# 17. 현재 구현의 주의점과 발표 시 정직하게 말할 것

1. Banuba 편집은 Android 전용이며 라이선스 token이 필요하다.
2. 편집 결과 서버 재업로드는 MVP 요구가 아니고 현재 제품 흐름에 없다.
3. REQ-F-42 전용 이벤트 리포트 화면은 미구현이다.
4. API-46 원시 이벤트 통계는 백엔드 구현이 있지만 프론트가 현재 실사용하지 않는다.
5. 기기 status 응답의 `recording`, `uploadQueueDepth`는 실제 edge 연동에서 스텁 값일 수 있다.
6. 과거 문서와 migration에 서버 편집·확장 기능 흔적이 있어도 최신 MVP와 구분한다.
7. 라이브 준비는 기기 `STREAM_READY`뿐 아니라 실제 HLS playlist/segment 준비와 함께 봐야 한다.
8. presigned URL은 권한을 영구 위임하는 것이 아니지만 만료 전 유출 위험은 있다.
9. MQTT QoS 1은 중복 가능하므로 eventId/requestId 멱등 처리가 필수다.
10. DB와 MinIO/MQTT 사이에는 단일 ACID 트랜잭션이 없으므로 worker와 상태 머신이 필요하다.

---

# 18. 파트 간 예상 질문 40선

## 인증

1. **JWT payload는 숨겨지나?** 아니오. 서명될 뿐이다.
2. **왜 access token이 15분인가?** 탈취 피해 시간을 줄이기 위해서다.
3. **refresh token은 왜 DB에 저장하나?** 폐기·회전·기기별 세션 통제를 위해서다.
4. **왜 refresh 원문 대신 해시인가?** DB 유출 시 바로 재사용되는 것을 줄이기 위해서다.
5. **BCrypt와 SHA-256 차이?** BCrypt는 비밀번호 대입을 느리게 하고 salt를 내장한다.
6. **401/403/404를 어떻게 나누나?** 인증 실패/권한 부족/존재 숨김을 구분한다.
7. **JWT key를 프론트가 알아야 하나?** 절대 아니다.

## 기기 등록과 MQTT

8. **기기와 사용자 인증이 왜 다른가?** 수명주기와 주체가 다르다.
9. **BOOTSTRAP과 OPERATING을 왜 나누나?** 출고·최초 등록 권한을 장기 운영 권한과 분리한다.
10. **MQTT key가 뭔가?** 표준 단일 용어가 아니며 topic/credential/TLS key를 구분해야 한다.
11. **deviceId가 비밀인가?** 아니다. 권한은 인증과 ACL이 보장해야 한다.
12. **등록 코드를 MQTT로 왜 안 보내나?** retained·로그·ACL 오설정 노출 위험 때문이다.
13. **QoS 1이면 정확히 한 번인가?** 아니다. 최소 한 번이라 중복 가능하다.
14. **retain과 DB 저장은 같은가?** 아니다. retain은 broker가 마지막 메시지 하나를 기억한다.
15. **LWT는 누가 보내나?** 비정상 연결 종료 시 broker가 기기 대신 보낸다.
16. **왜 8자리 코드가 120초인가?** 물리적 근접성을 확인하면서 공격 창을 줄이는 절충이다.

## 영상 저장

17. **왜 MP4를 MQTT로 안 보내나?** 큰 지속 payload에 부적합하다.
18. **왜 API 서버로 업로드하지 않나?** 서버 네트워크·메모리 병목을 피한다.
19. **presigned URL은 무엇에 서명하나?** method, bucket, object, 만료, 일부 header/query 조건이다.
20. **object key는 secret key인가?** 아니다. 객체 식별 문자열이다.
21. **왜 complete API가 필요한가?** 실제 객체 무결성을 확인한 뒤 READY로 확정하기 위해서다.
22. **왜 ETag만 안 믿나?** multipart 등에서 파일 MD5와 다를 수 있다.
23. **멱등 키가 왜 eventId와 같나?** 감지 하나와 업로드 하나를 끝까지 추적하기 위해서다.
24. **PostgreSQL과 MinIO 중 누가 원본인가?** 권한·상태는 DB, 파일 바이트는 MinIO라 둘의 일관성이 필요하다.
25. **삭제를 즉시 안 하나?** 외부 객체 삭제 실패를 재시도하면서 UI에서는 먼저 숨기기 위해서다.

## 라이브

26. **Spring이 스트리밍하나?** 제어만 하고 실제 영상은 MediaMTX가 전달한다.
27. **RTSP와 HLS 차이?** RTSP는 기기 ingest, HLS는 앱 재생에 사용한다.
28. **remux가 뭔가?** 재인코딩 없이 포장/전달 형식만 바꾸는 것이다.
29. **왜 START 후 polling하나?** 인코더와 첫 HLS segment 준비 시간이 필요하다.
30. **시청자가 두 명이면 stream도 두 개인가?** viewer session은 둘, 공유 edge stream은 하나다.
31. **앱이 죽으면 stream은?** heartbeat TTL과 lifecycle worker가 회수한다.
32. **서버가 죽으면 카메라가 계속 송출하나?** hard lease에서 자체 종료해야 한다.
33. **HLS URL만 알면 볼 수 있나?** Nginx introspection과 짧은 token으로 막아야 한다.

## DB·통계·인프라

34. **왜 JPA 대신 MyBatis인가?** 복잡한 권한·통계 SQL을 명시적으로 통제하려는 선택이다.
35. **왜 Flyway가 필요한가?** 환경별 DB schema를 코드 버전과 맞추기 위해서다.
36. **cursor가 offset보다 좋은 점?** 큰 offset 비용과 새 데이터에 의한 중복·누락을 줄인다.
37. **왜 timeZone을 받나?** UTC instant를 사용자 로컬 날짜로 정확히 집계하기 위해서다.
38. **영상 수와 이벤트 수가 왜 다르나?** 감지는 됐지만 업로드 실패한 이벤트가 있기 때문이다.
39. **왜 DB/MinIO/MQTT 포트를 공개하지 않나?** Nginx 정문 뒤로 공격 면적을 줄이기 위해서다.
40. **Docker volume을 지우면?** PostgreSQL/MinIO/Mosquitto 영속 데이터가 사라질 수 있으므로 운영에서 매우 조심해야 한다.

---

# 19. 코드 읽기 추천 순서

## 1일차: HTTP와 Spring 구조

1. `backend/server/build.gradle`
2. `application.yml`
3. `AuthController`
4. `AuthService`
5. `AuthMapper`
6. `V1__auth.sql`

목표: 요청이 Controller → Service → Mapper → DB로 흐르는 것을 설명한다.

## 2일차: 인증과 권한

1. `SecurityConfig`
2. `JwtConfig`
3. `JwtTokenService`
4. `DeviceAuthenticationFilter`
5. `DeviceCredentialAuthenticator`

목표: 사용자 JWT, 기기 credential, 관리자 키를 구분한다.

## 3일차: 기기 claim

1. `RegistrationCodeService`
2. `RegistrationCodeHasher`
3. `ClaimAttemptService`
4. `DeviceService.claim`
5. `V11__registration_codes_and_transfer.sql`

목표: TTL, hash, rate limit, row lock, transaction을 설명한다.

## 4일차: MQTT

1. `자료/api/mqtt-contract.md`
2. `PahoMqttGateway`
3. `MqttInboundHandler`
4. `DeviceMqttIdentityManager`
5. Mosquitto config

목표: topic, QoS, retain, LWT, ACL, 멱등 키를 설명한다.

## 5일차: 이벤트 영상

1. `IotVideoController`
2. `IotVideoService`
3. `ObjectStorageService`
4. `VideoQueryService`
5. `V4__videos.sql`, `V18__device_events.sql`

목표: presigned PUT → stat → READY 흐름을 그림 없이 말한다.

## 6일차: 라이브

1. `StreamController`
2. `StreamService`
3. `StreamLifecycleWorker`
4. `LiveTokenService`
5. MediaMTX와 Nginx 설정
6. edge `stream.py`

목표: 제어 평면과 영상 데이터 평면을 구분한다.

## 7일차: 통계와 장애

1. `VideoStatsService`
2. `EventStatsService`
3. 관련 mapper SQL
4. upload/deletion/retention worker
5. `backend/BACKEND_STATUS.md`

목표: READY 영상 통계와 원시 event 통계, 결과적 일관성을 설명한다.

---

# 20. 로컬 실행과 확인

```powershell
cd backend
docker compose up -d

cd server
.\gradlew.bat test
.\gradlew.bat bootRun
```

기본 확인:

- API: `http://localhost:8080`
- health: `GET http://localhost:8080/actuator/health`
- PostgreSQL: 5432
- MinIO API: 9000
- MinIO console: 9001
- MQTTS: 8883
- MediaMTX RTSP: 8554
- MediaMTX HLS: 8888

로컬 포트가 열려 있다는 것과 운영에서 인터넷에 공개해도 된다는 것은 전혀 다르다.

테스트:

```powershell
.\gradlew.bat test
.\gradlew.bat bootJar
```

통합 시연 전에 최소한 다음을 확인한다.

- 회원가입 → 로그인 → refresh
- 기기 등록 코드 TTL과 재사용 거절
- 기기 목록 online/offline 변화
- stream session `PENDING → READY`
- 앱 heartbeat 중 송출 유지
- 앱 종료 후 송출 정리
- 웃음 감지 eventId와 업로드 sourceEventId 일치
- presigned PUT 필수 header
- complete 후 `READY`
- 목록 → play URL → 실제 재생
- download URL의 attachment 동작
- 서울 날짜 기준 통계 수

---

# 21. 최종 암기용 한 장 요약

```text
[1 회원가입/로그인]
비밀번호 BCrypt
access JWT 15분
refresh 난수 14일 + DB에는 SHA-256 + rotation

[2 기기 등록]
기기 REST credential은 사용자 JWT와 별개
BOOTSTRAP → OPERATING
물리 버튼 → 등록 모드 → 8자리/120초/1회용 코드
claim 성공 → OWNER membership

[3 라이브]
REST: viewer session
MQTT: START/EXTEND/STOP + STREAM_READY
RTSP(S): 기기 → MediaMTX
HLS: MediaMTX → 앱
Spring은 제어 평면

[4 이벤트 영상]
YAMNet edge 감지
로컬 클립 우선
MQTT eventId 관측
REST로 presigned PUT 발급
MinIO 직접 업로드
complete에서 size + SHA-256 확인
READY만 재생

[5 편집]
Banuba Android 로컬 편집
서버 트랜스코딩/재업로드는 MVP 아님

[6 다운로드]
편집본은 단말 저장
서버 원본은 5분 presigned GET + attachment

[7 통계]
영상 통계 = READY videos
이벤트 통계 = raw device_events
Asia/Seoul 날짜를 UTC instant 범위로 변환
REQ-F-42 전용 화면은 아직 미구현

[공통]
PostgreSQL = 관계·권한·상태·통계
MinIO = MP4 바이트
Mosquitto = 작은 상태·명령
MediaMTX = 라이브 미디어
Nginx = 외부 정문
Flyway = DB 버전
MyBatis = 명시적 SQL
Docker = 실행 환경 재현
```

---

# 22. 원문·코드 찾아보기

- MVP 기준: `자료/docs/사람이 읽을 문서/01-서비스기획.md`
- 요구사항 상태: `자료/docs/사람이 읽을 문서/02-요구사항명세서.md`
- 기능별 구현: `자료/docs/사람이 읽을 문서/03-기능명세서.md`
- REST API: `자료/docs/사람이 읽을 문서/04-API명세서.md`
- 기계 판독 REST 계약: `자료/api/openapi.yaml`
- MQTT 계약: `자료/api/mqtt-contract.md`
- 현재 백엔드 상태: `backend/BACKEND_STATUS.md`
- 백엔드 시작: `backend/server/README.md`
- 보안 운영: `backend/IOT_SECURITY_RUNBOOK.md`
- Spring 코드: `backend/server/src/main/java/com/wj/server`
- DB migration: `backend/server/src/main/resources/db/migration`
- 앱 API 호출: `frontend/lib/core/api_client.dart`
- edge 코드: `ai/device_agent`, `ai/yamnet`, `ai/yolo`
- 로컬 인프라: `backend/docker-compose.yml`
- 운영 인프라: `backend/deploy`

이 문서에서 이해가 안 되는 용어가 나오면 첨부 자료 `배경지식_통신_인증_저장소.md`의 네트워크, 인증, 저장소, 인프라, mTLS 장을 먼저 읽고 해당 MVP 절로 돌아오면 된다.
