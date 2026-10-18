# 리눅스 서버 관제 자동화 미션 수행 내역서

> 컴퓨터가 알아서 자기 상태를 점검하게 만들기

SSH/방화벽 보안 설정, 역할 기반 계정·그룹·권한, 앱 실행 환경, `monitor.sh` 관제 스크립트, cron 자동 실행, 로그 용량 관리까지 직접 구성한 기록이다.

## 0. 실습 환경

| 항목 | 내용 |
| --- | --- |
| 호스트 | macOS (Apple Silicon) |
| 리눅스 환경 | OrbStack Ubuntu 머신 `clean-env` (코드명 `resolute`) |
| 아키텍처 | `x86_64` (amd64) → 앱은 `agent-app-linux-x86` 사용 |
| 방화벽 | UFW |
| 앱 실행 계정 | `agent-admin` (루트 실행 안 함) |

---

## 1. 기본 보안 및 네트워크 설정

### 1-1. SSH 포트 20022 변경 + Root 원격 로그인 차단

```bash
sudo apt update && sudo apt install -y openssh-server
sudo sed -i 's/^#\?Port .*/Port 20022/' /etc/ssh/sshd_config
sudo sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config
sudo systemctl disable --now ssh.socket
sudo systemctl enable --now ssh
sudo sshd -t && echo "설정 문법 OK"
```

**확인 (설정 파일)**

```
$ grep -E '^(Port|PermitRootLogin)' /etc/ssh/sshd_config
Port 20022
PermitRootLogin no
```

**확인 (리슨 상태)**

```
$ sudo ss -tulnp | grep sshd
tcp   LISTEN 0   128   0.0.0.0:20022   0.0.0.0:*   users:(("sshd",pid=4160,fd=6))
tcp   LISTEN 0   128      [::]:20022      [::]:*   users:(("sshd",pid=4160,fd=7))
```

- 22번 포트는 리슨하지 않고 20022만 열려 있다.
- `ssh.socket`이 22번 포트를 먼저 잡을 수 있어 소켓은 비활성화하고 `ssh` 서비스만 사용했다.

**왜 기본 보안인가**
- 22번은 자동화된 무차별 대입 공격의 1순위 대상이라 포트를 바꾸면 노이즈성 공격을 줄일 수 있다.
- Root는 계정명이 알려져 있고 권한이 최대라서, 원격 로그인을 막고 일반 계정 + `sudo`로만 권한 상승하게 해야 추적과 최소 권한이 가능하다.

### 1-2. 방화벽 (UFW)

```bash
sudo apt install -y ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 20022/tcp
sudo ufw allow 15034/tcp
sudo ufw --force enable
```

**확인**

```
$ sudo ufw status
Status: active

To                         Action      From
--                         ------      ----
20022/tcp                  ALLOW       Anywhere
15034/tcp                  ALLOW       Anywhere
20022/tcp (v6)             ALLOW       Anywhere (v6)
15034/tcp (v6)             ALLOW       Anywhere (v6)
```

- 인바운드는 기본 차단, `20022/tcp`(SSH)와 `15034/tcp`(APP)만 허용했다.
- `(v6)` 줄은 같은 규칙이 IPv6용으로 자동 추가된 것이다.
- 규칙을 먼저 넣고 나서 활성화해서, 활성화 시점에 원격 접속이 끊기지 않게 했다.

---

## 2. 계정 / 그룹 / 권한 체계

### 2-1. 그룹과 계정 생성

```bash
sudo groupadd agent-common
sudo groupadd agent-core
sudo useradd -m -s /bin/bash agent-admin
sudo useradd -m -s /bin/bash agent-dev
sudo useradd -m -s /bin/bash agent-test

sudo usermod -aG agent-common,agent-core agent-admin
sudo usermod -aG agent-common,agent-core agent-dev
sudo usermod -aG agent-common agent-test
```

**확인**

```
$ id agent-admin
uid=1000(agent-admin) gid=1002(agent-admin) groups=1002(agent-admin),1000(agent-common),1001(agent-core)
$ id agent-dev
uid=1001(agent-dev) gid=1003(agent-dev) groups=1003(agent-dev),1000(agent-common),1001(agent-core)
$ id agent-test
uid=1002(agent-test) gid=1004(agent-test) groups=1004(agent-test),1000(agent-common)
```

| 그룹 | 구성원 |
| --- | --- |
| agent-common | admin, dev, test |
| agent-core | admin, dev |

### 2-2. 디렉토리 구조와 권한

`AGENT_HOME=/home/agent-admin/agent-app`

```bash
sudo mkdir -p /home/agent-admin/agent-app/{upload_files,api_keys,bin}
sudo mkdir -p /var/log/agent-app

sudo chown agent-admin:agent-admin /home/agent-admin/agent-app
sudo chown agent-admin:agent-common /home/agent-admin/agent-app/upload_files
sudo chown agent-admin:agent-core   /home/agent-admin/agent-app/api_keys
sudo chown agent-admin:agent-core   /var/log/agent-app
sudo chown agent-dev:agent-core     /home/agent-admin/agent-app/bin

sudo chmod 770 /home/agent-admin/agent-app/upload_files
sudo chmod 770 /home/agent-admin/agent-app/api_keys
sudo chmod 770 /var/log/agent-app
sudo chmod 750 /home/agent-admin/agent-app/bin
sudo chmod 755 /home/agent-admin /home/agent-admin/agent-app
```

**확인**

```
$ sudo ls -ld /home/agent-admin/agent-app /home/agent-admin/agent-app/* /var/log/agent-app
drwxr-xr-x 1 agent-admin agent-common      84 Oct 18 07:42 /home/agent-admin/agent-app
-rwxr-xr-x 1 agent-admin agent-admin  6498144 Oct 18 07:42 /home/agent-admin/agent-app/agent-app-linux-x86
drwxrwx--- 1 agent-admin agent-core        44 Oct 18 07:56 /home/agent-admin/agent-app/api_keys
drwxr-x--- 1 agent-dev   agent-core        20 Oct 18 08:27 /home/agent-admin/agent-app/bin
drwxrwx--- 1 agent-admin agent-common       0 Oct 18 00:59 /home/agent-admin/agent-app/upload_files
drwxrwx--- 1 agent-admin agent-core        48 Oct 18 08:28 /var/log/agent-app
```

| 경로 | 소유자:그룹 | 권한 | 의도 |
| --- | --- | --- | --- |
| upload_files | agent-admin:agent-common | 770 | 공유 디렉토리 (admin/dev/test R/W) |
| api_keys | agent-admin:agent-core | 770 | 보안 디렉토리 (admin/dev만) |
| /var/log/agent-app | agent-admin:agent-core | 770 | 로그 디렉토리 (admin/dev만) |
| bin | agent-dev:agent-core | 750 | monitor.sh 보관 |

**공유/보안 디렉토리를 분리하는 이유**
- 테스트 계정(`agent-test`)은 업로드 파일은 다뤄야 하지만, API 키와 운영 로그는 볼 필요가 없다. 그룹을 `common`/`core`로 나눠 필요한 만큼만 권한을 주는 최소 권한 구조다.

**참고 (권한 수정 기록)**
- 처음에 `agent-app` 디렉토리를 775 + 그룹 `agent-common`으로 열어서 `agent-test`가 쓰기 가능해졌다. 최소 권한 원칙에 어긋나 755로 되돌렸다.

---

## 3. 애플리케이션 실행 환경

### 3-1. 환경 변수

| 변수 | 값 |
| --- | --- |
| AGENT_HOME | /home/agent-admin/agent-app |
| AGENT_PORT | 15034 |
| AGENT_UPLOAD_DIR | /home/agent-admin/agent-app/upload_files |
| AGENT_KEY_PATH | /home/agent-admin/agent-app/api_keys |
| AGENT_LOG_DIR | /var/log/agent-app |

환경 변수로 실행 경로·포트·키 위치를 고정하면 실행 계정이나 현재 디렉토리와 상관없이 같은 환경에서 동작하고, 앱이 기대하는 값과 다르면 부팅 단계에서 바로 걸러낼 수 있다.

### 3-2. 키 파일

```bash
echo "agent_api_key_test" | sudo tee /home/agent-admin/agent-app/api_keys/t_secret.key
sudo chown agent-admin:agent-core /home/agent-admin/agent-app/api_keys/t_secret.key
sudo chmod 660 /home/agent-admin/agent-app/api_keys/t_secret.key
# 앱이 요구한 파일명(secret.key)으로 복사본 추가 (4-1 트러블슈팅 참고)
sudo cp /home/agent-admin/agent-app/api_keys/t_secret.key /home/agent-admin/agent-app/api_keys/secret.key
sudo chown agent-admin:agent-core /home/agent-admin/agent-app/api_keys/secret.key
sudo chmod 660 /home/agent-admin/agent-app/api_keys/secret.key
```

### 3-3. 앱 실행

앱 실행 파일은 `AGENT_HOME`에 복사하고(`agent-app-linux-x86`, 755), 일반 계정(`agent-admin`)으로 실행했다.

```bash
sudo -u agent-admin \
  AGENT_HOME=/home/agent-admin/agent-app \
  AGENT_PORT=15034 \
  AGENT_UPLOAD_DIR=/home/agent-admin/agent-app/upload_files \
  AGENT_KEY_PATH=/home/agent-admin/agent-app/api_keys \
  AGENT_LOG_DIR=/var/log/agent-app \
  /home/agent-admin/agent-app/agent-app-linux-x86
```

**Boot Sequence 결과**

```
>>> Starting Agent Boot Sequence...
[1/5] Checking User Account               [OK]
   ... Running as service user 'agent-admin' (uid=1000)
[2/5] Verifying Environment Variables     [OK]
   ... All required Envs correct
[3/5] Checking Required Files             [OK]
   ... Verified 'secret.key' with correct key string.
[4/5] Checking Port Availability          [OK]
   ... Port 15034 is available.
[5/5] Verifying Log Permission            [OK]
   ... Log directory is writable: /var/log/agent-app
------------------------------------------------------------
All Boot Checks Passed!
Agent READY
```

**포트 LISTEN 확인**

```
$ ss -tulnp | grep 15034
tcp   LISTEN 0      1                   0.0.0.0:15034      0.0.0.0:*
```

---

## 4. 트러블슈팅 기록

### 4-1. Boot Sequence 2~3단계 실패

| 시도 | 증상 | 원인 | 조치 |
| --- | --- | --- | --- |
| 1차 | `[2/5] Verifying Environment Variables [FAIL]` `Key Path Mismatch. Expected: /home/agent-admin/agent-app/api_keys` | `AGENT_KEY_PATH`를 문서대로 파일 경로(`.../api_keys/t_secret.key`)로 줬는데, 앱은 **디렉토리 경로**를 기대함 | `AGENT_KEY_PATH=/home/agent-admin/agent-app/api_keys`로 변경 |
| 2차 | `[3/5] Checking Required Files [FAIL]` `Missing File: secret.key` | 앱이 찾는 파일명은 `secret.key`인데 문서 기준 `t_secret.key`로 만들어 둠 | 같은 내용의 `secret.key`를 추가 (기존 `t_secret.key`는 그대로 둠) |
| 3차 | 5단계 모두 `[OK]`, `Agent READY` | - | - |

### 4-2. 앱 재시작 시 포트 충돌

- 증상: 재실행했더니 `[4/5] Checking Port Availability [FAIL] Port 15034 is already in use.`
- 원인: 이전에 띄운 앱이 다른 터미널 탭에서 계속 실행 중이었다.
- 조치: `pgrep -a -f agent-app-linux-x86`로 프로세스를 확인하고 `sudo pkill -f agent-app-linux-x86`로 종료한 뒤, 프로세스와 포트(`ss -tln | grep 15034`)가 비어 있는 것을 확인하고 재실행했다.

### 4-3. 방화벽 점검 오판 (monitor.sh)

- 증상: UFW는 active인데 `monitor.sh` 실행 시 `[WARNING] Firewall is not active` 출력
- 원인: cron 실행 계정 `agent-admin`에는 sudo 권한이 없어 `sudo -n ufw status`가 실패했고, 이를 "비활성"으로 판단함
- 조치: sudo 없이 읽을 수 있는 `/etc/ufw/ufw.conf`의 `ENABLED=yes` 값을 확인하는 방식으로 변경
- 한계: `ENABLED`는 "부팅 시 시작 여부" 설정값이라, 실시간 활성 상태와 완전히 같지는 않다. 이 점을 알고 쓴다.

### 4-4. logrotate 보안 경고

- 증상: `logrotate -d` 시 `skipping ... because parent directory has insecure permissions`
- 원인: 로그 디렉토리가 root가 아닌 그룹(`agent-core`)이 쓸 수 있는 권한(770)이라 logrotate가 안전하지 않다고 판단
- 조치: 설정에 `su agent-admin agent-core` 지시어를 추가해 회전 작업을 해당 계정/그룹 권한으로 수행하게 함

### 4-5. 명령 실행 위치 혼동

- 증상: 리눅스 명령을 맥 터미널(`zukrass3800@c5r6s7 ~ %`)에서 실행해 맥의 sudo 비밀번호를 묻는 상황
- 조치: 프롬프트로 현재 위치를 구분하고 `orb -m clean-env`로 리눅스 머신에 들어가 실행

---

## 5. monitor.sh

- 소스: [`monitor.sh`](./monitor.sh)
- 배치 경로: `/home/agent-admin/agent-app/bin/monitor.sh`
- 소유자/그룹/권한: `agent-dev:agent-core` / `750` (`-rwxr-x---`)
- 실행 계정: cron에서 `agent-admin`이 실행 (agent-core 그룹 소속이라 실행 가능)

### 동작 요약

| 구분 | 내용 | 실패 시 |
| --- | --- | --- |
| 프로세스 점검 | 실행 파일 경로로 시작하는 `agent-app-linux-x86` 프로세스 확인 (`sudo` 래퍼 줄은 제외) | `exit 1` |
| 포트 점검 | TCP 15034 LISTEN 확인 (`ss -tln`) | `exit 1` |
| 방화벽 점검 | `/etc/ufw/ufw.conf`의 `ENABLED=yes` 확인 | `[WARNING]`만 출력, 종료 안 함 |
| 자원 수집 | CPU(`top`), MEM(`free`), DISK(`df /`) 사용률 | - |
| 임계값 경고 | CPU > 20%, MEM > 10%, DISK > 80% | `[WARNING]`만 출력 |
| 로그 기록 | `/var/log/agent-app/monitor.log`에 한 줄 추가 | - |

방화벽 점검 블록 (최종):

```bash
# 3) 방화벽 점검 (경고만)
if grep -qs '^ENABLED=yes' /etc/ufw/ufw.conf; then
  :
else
  echo "[WARNING] Firewall is not active"
fi
```

### 실행 결과

```
$ sudo -u agent-admin /home/agent-admin/agent-app/bin/monitor.sh
====== SYSTEM MONITOR RESULT ======

[HEALTH CHECK]
Checking process 'agent-app-linux-x86'... [OK] (PID: 5053)
Checking port 15034... [OK]

[RESOURCE MONITORING]
CPU Usage : 6.6%
MEM Usage : 5.8%
DISK Used : 1%


[INFO] Log appended: /var/log/agent-app/monitor.log
```

### 임계값 경고 동작 검증

실제 값이 임계값 아래라 경고가 뜨지 않아서, 임계값을 1%로 낮춘 **복사본**으로 테스트했다 (원본은 수정하지 않았고 복사본은 삭제함).

```
[WARNING] CPU threshold exceeded (4.9% > 1%)
[WARNING] MEM threshold exceeded (5.9% > 1%)
```

DISK 경고는 CPU/MEM과 같은 구조의 비교문이지만 별도로 발생시켜 보지는 않았다.

---

## 6. cron 자동 실행 및 로그 관리

### 6-1. crontab 등록 (agent-admin, 매분)

```bash
echo "* * * * * /home/agent-admin/agent-app/bin/monitor.sh >> /dev/null 2>&1" | sudo -u agent-admin crontab -
```

```
$ sudo -u agent-admin crontab -l
* * * * * /home/agent-admin/agent-app/bin/monitor.sh >> /dev/null 2>&1
```

### 6-2. 자동 누적 확인

등록 직후와 약 15분 뒤의 `monitor.log` 줄 수와 최근 라인이다.

```
$ sudo wc -l /var/log/agent-app/monitor.log
4 /var/log/agent-app/monitor.log          # 등록 직후
18 /var/log/agent-app/monitor.log         # 약 15분 후

$ sudo tail -n 5 /var/log/agent-app/monitor.log
[2026-10-18 08:44:01] PID:5053 CPU:4.8% MEM:5.7% DISK_USED:1%
[2026-10-18 08:45:02] PID:5053 CPU:4.9% MEM:5.7% DISK_USED:1%
[2026-10-18 08:46:01] PID:5053 CPU:3.3% MEM:5.8% DISK_USED:1%
[2026-10-18 08:47:01] PID:5053 CPU:3.4% MEM:5.8% DISK_USED:1%
[2026-10-18 08:48:01] PID:5053 CPU:3.3% MEM:5.6% DISK_USED:1%
```

- 매분 01~02초에 기록되어 cron이 자동 실행하고 있음을 확인했다.
- 로그 포맷: `[YYYY-MM-DD HH:MM:SS] PID:... CPU:..% MEM:..% DISK_USED:..%`
- 참고: 초기 기록 중 한 번 `CPU:100.0%`가 찍힌 적이 있다. `top -bn1`은 한 번 샘플링한 값이라 순간적으로 튈 수 있다고 보고, 이후 값은 3~5%대로 안정적이었다. 다만 원인을 정확히 분석하지는 못했다.

### 6-3. 로그 용량 관리 (logrotate)

`/etc/logrotate.d/agent-app`

```
/var/log/agent-app/monitor.log {
    su agent-admin agent-core
    size 10M
    rotate 10
    missingok
    notifempty
    compress
    delaycompress
    create 660 agent-admin agent-core
}
```

- 10MB를 넘으면 회전하고 최대 10개를 보관한다.
- `logrotate -d`(시뮬레이션)에서 에러 없이 통과했고, 현재 로그가 10MB 미만이라 `log does not need rotating`으로 표시되었다.
- logrotate는 보통 하루 한 번 실행되므로, 10MB를 넘는 즉시 회전되지는 않는다.

**로그 보존 정책이 필요한 이유**
- 로그가 무한히 쌓이면 디스크가 차서 서비스 자체가 멈출 수 있다. 크기/개수 제한과 압축으로 최근 기록은 유지하면서 디스크 사용을 일정하게 막는다.

---

## 7. 증거 체크리스트

| 항목 | 위치 | 상태 |
| --- | --- | --- |
| SSH 20022 + Root 차단 | 1-1 | 완료 |
| UFW 20022/15034만 허용 | 1-2 | 완료 |
| 계정/그룹 생성 | 2-1 | 완료 |
| 디렉토리 구조/권한 | 2-2 | 완료 |
| Boot Sequence 5단계 [OK] + Agent READY | 3-3 | 완료 |
| monitor.sh 실행 결과 | 5 | 완료 |
| monitor.log 누적 | 6-2 | 완료 |
| crontab 매분 실행 + 로그 증가 | 6-1, 6-2 | 완료 |

보너스 과제(report.sh, 시간 기반 로그 보존)는 수행하지 않았다.
