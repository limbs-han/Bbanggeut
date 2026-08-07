# Jenkins 보안 운영

## 관리자 로그인

Jenkins는 자체 사용자 DB와 Matrix Authorization을 사용합니다.
전체 관리자 권한은 `admin` 계정에만 부여되며 익명 사용자는 Jenkins API와 작업에 접근할 수 없습니다.

초기 설정 때 생성한 새 관리자 비밀번호는 채팅이나 저장소에 기록하지 않습니다.
EC2의 `ubuntu` 사용자만 읽을 수 있는 다음 파일에서 한 번 확인할 수 있습니다.

```bash
ssh -i I15E201T.pem ubuntu@i15e201.p.ssafy.io
cat /home/ubuntu/jenkins-admin-password
```

처음 로그인한 뒤 Jenkins에서 비밀번호를 변경하고 비밀번호 관리자에 보관합니다.
변경을 확인한 다음 평문 전달 파일을 삭제합니다.

```bash
rm /home/ubuntu/jenkins-admin-password
```

## 자동 보안 설정

`10-security-bootstrap.groovy`는 Controller가 시작될 때 다음 상태를 보장합니다.

- Jenkins 초기 설정 완료 상태
- 자체 사용자 DB 사용
- 사용자 직접 가입 차단
- `admin` 계정에만 전체 관리자 권한 부여
- CSRF 보호 활성화

최초 비밀번호 전달 파일이 없더라도 기존 `admin` 계정이 있으면 비밀번호를 변경하지 않고
권한 설정만 다시 확인합니다.

## 비밀정보 원칙

- 비밀번호, SSH 개인키, Agent Secret은 Git에 커밋하지 않습니다.
- Jenkins Pipeline 로그에 비밀값을 출력하지 않습니다.
- 운영 SSH 키는 Production 폴더 범위 Credential로만 관리합니다.
- 일반 브랜치의 Jenkinsfile에서는 운영 Credential에 접근할 수 없습니다.
- 배포 Agent에는 Docker Socket을 연결하지 않습니다.

## 복구

7단계 보안 변경 전 Jenkins 설정은 EC2의 다음 위치에 백업돼 있습니다.

```text
/home/ubuntu/backups/jenkins/stage7-before-security
```

백업에는 Jenkins 설정과 사용자 데이터가 포함되므로 외부로 복사하거나 저장소에 올리지 않습니다.
