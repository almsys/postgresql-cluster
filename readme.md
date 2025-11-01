# Отказоустойчивый кластер PostgreSQL для Production

Полная инструкция по развертыванию высокодоступного кластера PostgreSQL с автоматическим failover для 1С и других enterprise-приложений.
<img width="1919" height="1079" alt="image" src="https://github.com/user-attachments/assets/257adda8-404e-4441-852b-a41c760b65af" />

## Содержание

1. [Архитектура решения](#архитектура-решения)
2. [Компоненты системы](#компоненты-системы)
3. [Системные требования](#системные-требования)
4. [Топология кластера](#топология-кластера)
5. [Предварительная подготовка](#предварительная-подготовка)
6. [Установка компонентов](#установка-компонентов)
7. [Конфигурация](#конфигурация)
8. [Резервное копирование](#резервное-копирование)
9. [Настройка для 1С](#настройка-для-1с)
10. [Мониторинг](#мониторинг)
11. [Тестирование](#тестирование)
12. [Обслуживание](#обслуживание)
13. [Безопасность](#безопасность)
14. [Troubleshooting](#troubleshooting)

---

## Архитектура решения

```
                    ┌─────────────┐
                    │  Keepalived │
                    │ VIP: 192.168.100.200 │
                    └──────┬──────┘
                           │
        ┌──────────────────┼──────────────────┐
        │                  │                  │
    ┌───▼───┐          ┌───▼───┐          ┌───▼───┐
    │HAProxy│          │HAProxy│          │HAProxy│
    │ Node1 │          │ Node2 │          │ Node3 │
    └───┬───┘          └───┬───┘          └───┬───┘
        │                  │                  │
        └──────────────────┼──────────────────┘
                           │
        ┌──────────────────┼──────────────────┐
        │                  │                  │
    ┌───▼────┐         ┌───▼────┐         ┌───▼────┐
    │PgBouncer│        │PgBouncer│        │PgBouncer│
    └───┬────┘         └───┬────┘         └───┬────┘
        │                  │                  │
        └──────────────────┼──────────────────┘
                           │
        ┌──────────────────┼──────────────────┐
        │                  │                  │
    ┌───▼────┐         ┌───▼────┐         ┌───▼────┐
    │Patroni │         │Patroni │         │Patroni │
    │PostgreSQL│       │PostgreSQL│       │PostgreSQL│
    │ Master │         │ Replica│         │ Replica│
    └───┬────┘         └───┬────┘         └───┬────┘
        │                  │                  │
        └──────────────────┼──────────────────┘
                           │
        ┌──────────────────┼──────────────────┐
        │                  │                  │
    ┌───▼───┐          ┌───▼───┐          ┌───▼───┐
    │ etcd  │          │ etcd  │          │ etcd  │
    │ Node1 │          │ Node2 │          │ Node3 │
    └───────┘          └───────┘          └───────┘
```

---

## Компоненты системы

- **PostgreSQL 16** - СУБД
- **Patroni 3.x** - управление репликацией и автоматический failover
- **etcd 3.5.x** - распределенное хранилище конфигурации
- **PgBouncer 1.21.x** - connection pooling
- **HAProxy 2.8.x** - балансировка нагрузки
- **Keepalived 2.2.x** - управление виртуальным IP

---

## Системные требования

### Минимальные требования на узел

- **CPU:** 4 cores
- **RAM:** 16 GB
- **Disk:** 500 GB SSD (для данных PostgreSQL)
- **OS:** Ubuntu 22.04 LTS / Rocky Linux 9 / Debian 12
- **Network:** 1 Gbps

### Рекомендуемые требования для 1С (50+ пользователей)

- **CPU:** 8+ cores
- **RAM:** 32+ GB
- **Disk:** 1+ TB NVMe SSD (RAID 10)
- **Network:** 10 Gbps

---

## Топология кластера

Для production рекомендуется минимум 3 узла:

- **node1:** 192.168.100.201 (Primary)
- **node2:** 192.168.100.202 (Replica)
- **node3:** 192.168.100.203 (Replica)
- **VIP:** 192.168.100.200 (управляется Keepalived)

---

## Предварительная подготовка

### 1. Настройка hostname и /etc/hosts

На каждом узле установить соответствующий hostname:

```bash
# На каждом узле установить соответствующий hostname
sudo hostnamectl set-hostname node1  # node2, node3

# Добавить в /etc/hosts на всех узлах
cat <<EOF | sudo tee -a /etc/hosts
192.168.100.201 node1
192.168.100.202 node2
192.168.100.203 node3
192.168.100.200 pg-cluster-vip
EOF
```

### 2. Отключение SELinux (для RHEL/Rocky Linux)

```bash
sudo setenforce 0
sudo sed -i 's/^SELINUX=enforcing/SELINUX=disabled/' /etc/selinux/config
```

### 3. Настройка firewall

**Для Ubuntu/Debian:**

```bash
sudo ufw allow 5432/tcp  # PostgreSQL
sudo ufw allow 6432/tcp  # PgBouncer
sudo ufw allow 5000/tcp  # HAProxy stats
sudo ufw allow 7000/tcp  # HAProxy PostgreSQL
sudo ufw allow 2379/tcp  # etcd client
sudo ufw allow 2380/tcp  # etcd peer
sudo ufw allow 8008/tcp  # Patroni REST API
```

**Для RHEL/Rocky Linux:**

```bash
sudo firewall-cmd --permanent --add-port=5432/tcp
sudo firewall-cmd --permanent --add-port=6432/tcp
sudo firewall-cmd --permanent --add-port=5000/tcp
sudo firewall-cmd --permanent --add-port=7000/tcp
sudo firewall-cmd --permanent --add-port=2379/tcp
sudo firewall-cmd --permanent --add-port=2380/tcp
sudo firewall-cmd --permanent --add-port=8008/tcp
sudo firewall-cmd --reload
```

### 4. Настройка системных параметров

```bash
# Увеличение лимитов
cat <<EOF | sudo tee /etc/security/limits.conf
postgres soft nofile 65536
postgres hard nofile 65536
postgres soft nproc 8192
postgres hard nproc 8192
EOF

# Настройка sysctl для PostgreSQL
cat <<EOF | sudo tee /etc/sysctl.d/99-postgresql.conf
# Shared memory
kernel.shmmax = 17179869184
kernel.shmall = 4194304

# Memory management
vm.swappiness = 1
vm.overcommit_memory = 2
vm.overcommit_ratio = 80
vm.dirty_ratio = 10
vm.dirty_background_ratio = 3

# Network
net.ipv4.ip_local_port_range = 10000 65535
net.core.netdev_max_backlog = 10000
net.ipv4.tcp_max_syn_backlog = 8192
net.core.somaxconn = 65535
net.ipv4.ip_nonlocal_bind = 1
EOF

sudo sysctl -p /etc/sysctl.d/99-postgresql.conf
```

---

## Установка компонентов

### Шаг 1: Установка PostgreSQL 16

**Для Ubuntu 22.04:**

```bash
sudo apt-get install -y wget gnupg2
wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo apt-key add -
echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" | sudo tee /etc/apt/sources.list.d/pgdg.list
sudo apt-get update
sudo apt-get install -y postgresql-16 postgresql-contrib-16
```

**Для Rocky Linux 9:**

```bash
sudo dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-x86_64/pgdg-redhat-repo-latest.noarch.rpm
sudo dnf -qy module disable postgresql
sudo dnf install -y postgresql16-server postgresql16-contrib
```

**Остановить автоматически запущенный PostgreSQL:**

```bash
sudo systemctl stop postgresql
sudo systemctl disable postgresql
```

### Шаг 2: Установка Python и зависимостей

**Ubuntu/Debian:**

```bash
sudo apt-get install -y python3 python3-pip python3-dev python3-venv
sudo apt-get install -y libpq-dev
```

**Rocky Linux:**

```bash
sudo dnf install -y python3 python3-pip python3-devel
sudo dnf install -y postgresql16-devel
```

### Шаг 3: Установка Patroni

```bash
# Создание виртуального окружения
sudo mkdir -p /opt/patroni
sudo python3 -m venv /opt/patroni/venv
sudo /opt/patroni/venv/bin/pip install --upgrade pip
sudo /opt/patroni/venv/bin/pip install patroni[etcd] psycopg2-binary

# Создание симлинка
sudo ln -s /opt/patroni/venv/bin/patroni /usr/local/bin/patroni
sudo ln -s /opt/patroni/venv/bin/patronictl /usr/local/bin/patronictl
```

### Шаг 4: Установка etcd

```bash
ETCD_VER=v3.5.11

# Скачивание и установка
wget https://github.com/etcd-io/etcd/releases/download/${ETCD_VER}/etcd-${ETCD_VER}-linux-amd64.tar.gz
tar xzvf etcd-${ETCD_VER}-linux-amd64.tar.gz
sudo mv etcd-${ETCD_VER}-linux-amd64/etcd* /usr/local/bin/
sudo rm -rf etcd-${ETCD_VER}-linux-amd64*

# Создание пользователя и директорий
sudo useradd -r -s /bin/false etcd
sudo mkdir -p /var/lib/etcd /etc/etcd
sudo chown -R etcd:etcd /var/lib/etcd
sudo chmod 700 /var/lib/etcd
```

### Шаг 5: Установка PgBouncer

**Ubuntu/Debian:**

```bash
sudo apt-get install -y pgbouncer
```

**Rocky Linux:**

```bash
sudo dnf install -y pgbouncer
```

### Шаг 6: Установка HAProxy

**Ubuntu/Debian:**

```bash
sudo apt-get install -y haproxy
```

**Rocky Linux:**

```bash
sudo dnf install -y haproxy
```

### Шаг 7: Установка Keepalived

**Ubuntu/Debian:**

```bash
sudo apt-get install -y keepalived
```

**Rocky Linux:**

```bash
sudo dnf install -y keepalived
```

---

## Конфигурация

### 1. Настройка etcd

Создать файл `/etc/etcd/etcd.conf` на каждом узле.

**На node1:**

```yaml
name: 'node1'
data-dir: /var/lib/etcd
wal-dir: /var/lib/etcd/wal

listen-peer-urls: http://192.168.100.201:2380
listen-client-urls: http://192.168.100.201:2379,http://127.0.0.1:2379

initial-advertise-peer-urls: http://192.168.100.201:2380
advertise-client-urls: http://192.168.100.201:2379

initial-cluster: node1=http://192.168.100.201:2380,node2=http://192.168.100.202:2380,node3=http://192.168.100.203:2380
initial-cluster-token: 'etcd-cluster-pg'
initial-cluster-state: 'new'

enable-v2: true
```

**На node2:** изменить `name`, IP адреса на 192.168.100.202

**На node3:** изменить `name`, IP адреса на 192.168.100.203

**Создать systemd unit для etcd:**

```bash
cat <<EOF | sudo tee /etc/systemd/system/etcd.service
[Unit]
Description=etcd key-value store
Documentation=https://github.com/etcd-io/etcd
After=network.target

[Service]
User=etcd
Type=notify
ExecStart=/usr/local/bin/etcd --config-file=/etc/etcd/etcd.conf
Restart=always
RestartSec=10s
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable etcd
sudo systemctl start etcd
```

**Проверка кластера etcd:**

```bash
etcdctl --endpoints=http://192.168.100.201:2379,http://192.168.100.202:2379,http://192.168.100.203:2379 member list
etcdctl --endpoints=http://192.168.100.201:2379,http://192.168.100.202:2379,http://192.168.100.203:2379 endpoint health
sudo ss -tuln | grep 2379
sudo ss -tuln | grep 2380
curl http://192.168.100.201:2379/health
curl http://192.168.100.202:2379/health
curl http://192.168.100.203:2379/health
sudo lsof -p $(pgrep etcd)
```

### 2. Настройка Patroni

**Создать директории:**

```bash
sudo mkdir -p /etc/patroni /var/lib/postgresql/16/main
sudo chown -R postgres:postgres /var/lib/postgresql

# Или Создаем базовую структуру каталогов
sudo mkdir -p /var/lib/postgresql/16/main
sudo chown -R postgres:postgres /var/lib/postgresql/16
sudo chmod 700 /var/lib/postgresql/16/main

# Активируйте локаль
sudo sed -i "s/# ru_RU.UTF-8 UTF-8/ru_RU.UTF-8 UTF-8/"  /etc/locale.gen
sudo locale-gen
```

**Создать конфигурацию `/etc/patroni/patroni.yml` на node1:**

```yaml
scope: postgres-cluster
namespace: /db/
name: node1

restapi:
  listen: 0.0.0.0:8008    # Если ставить статически 192.168.100.201:8008, то не работает failover Patroni API
  connect_address: 192.168.100.201:8008

etcd:
  hosts:
    - 192.168.100.201:2379
    - 192.168.100.202:2379
    - 192.168.100.203:2379

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        # Основные параметры
        max_connections: 500
        superuser_reserved_connections: 10
        
        # Память (для сервера с 32GB RAM)
        shared_buffers: 2GB
        effective_cache_size: 4GB
        maintenance_work_mem: 1GB
        work_mem: 32MB
        
        # WAL настройки
        wal_level: replica
        wal_log_hints: on
        wal_buffers: 16MB
        min_wal_size: 2GB
        max_wal_size: 8GB
        
        # Checkpoint
        checkpoint_timeout: 15min
        checkpoint_completion_target: 0.9
        
        # Планировщик
        random_page_cost: 1.1
        effective_io_concurrency: 200
        
        # Репликация
        max_wal_senders: 10
        max_replication_slots: 10
        hot_standby: on
        hot_standby_feedback: on
        
        # Логирование
        log_destination: 'stderr'
        logging_collector: on
        log_directory: '/var/log/postgresql'
        log_filename: 'postgresql-%Y-%m-%d.log'
        log_rotation_age: 1d
        log_rotation_size: 100MB
        log_min_duration_statement: 1000
        log_line_prefix: '%t [%p]: [%l-1] user=%u,db=%d,app=%a,client=%h '
        log_checkpoints: on
        log_connections: on
        log_disconnections: on
        log_lock_waits: on
        log_temp_files: 0
        
        # Оптимизации для 1С
        shared_preload_libraries: 'pg_stat_statements'
        track_activities: on
        track_counts: on
        track_io_timing: on
        track_functions: all
        
        # Autovacuum для 1С (агрессивный)
        autovacuum: on
        autovacuum_max_workers: 4
        autovacuum_naptime: 30s
        autovacuum_vacuum_scale_factor: 0.05
        autovacuum_analyze_scale_factor: 0.02
        autovacuum_vacuum_cost_delay: 10ms
        
        # Timezone
        timezone: 'Asia/Almaty'
        
  initdb:
    - encoding: UTF8
    - locale: ru_RU.UTF-8
    - data-checksums

  pg_hba:
    - host replication replicator 192.168.100.0/24 md5
    - host all all 192.168.100.0/24 md5
    - host all all 0.0.0.0/0 md5
    - local all all peer

  users:
    admin:
      password: CHANGE_ADMIN_PASSWORD
      options:
        - createrole
        - createdb
    replicator:
      password: CHANGE_REPLICATOR_PASSWORD
      options:
        - replication

postgresql:
  listen: 192.168.100.201:5432
  connect_address: 192.168.100.201:5432
  data_dir: /var/lib/postgresql/16/main
  bin_dir: /usr/lib/postgresql/16/bin
  pgpass: /tmp/pgpass0
  authentication:
    replication:
      username: replicator
      password: CHANGE_REPLICATOR_PASSWORD
    superuser:
      username: postgres
      password: CHANGE_POSTGRES_PASSWORD
    rewind:
      username: replicator
      password: CHANGE_REPLICATOR_PASSWORD
  parameters:
    unix_socket_directories: '/var/run/postgresql'
    listen_addresses: '192.168.100.201,127.0.0.1'
    port: 5432

tags:
    nofailover: false
    noloadbalance: false
    clonefrom: false
    nosync: false

```

**На node2 и node3:** скопировать конфигурацию и изменить:
- `name:` на node2 / node3
- `restapi.listen` и `restapi.connect_address` на соответствующий IP
- `postgresql.listen` и `postgresql.connect_address` на соответствующий IP

**Создать systemd unit для Patroni:**

```bash
cat <<EOF | sudo tee /etc/systemd/system/patroni.service
[Unit]
Description=Patroni PostgreSQL high-availability manager
After=network.target etcd.service

[Service]
Type=simple
User=postgres
Group=postgres
ExecStart=/usr/local/bin/patroni /etc/patroni/patroni.yml
ExecReload=/bin/kill -HUP \$MAINPID
KillMode=process
TimeoutSec=30
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
```

**ВАЖНО:** Сначала запустить Patroni на node1, подождать инициализации, затем на остальных:

```bash
# На node1
sudo systemctl enable patroni
sudo systemctl start patroni

# Подождать 30 секунд, проверить статус
sudo systemctl status patroni
patronictl -c /etc/patroni/patroni.yml list

# Затем на node2 и node3
sudo systemctl enable patroni
sudo systemctl start patroni
```

**Проверка кластера:**

```bash
patronictl -c /etc/patroni/patroni.yml list
```

### 3. Настройка PgBouncer

Создать конфигурацию `/etc/pgbouncer/pgbouncer.ini`:

```ini
[databases]
* = host=127.0.0.1 port=5432

[pgbouncer]
listen_addr = *
listen_port = 6432
unix_socket_dir = /var/run/postgresql
auth_type = md5
auth_file = /etc/pgbouncer/userlist.txt

# Connection pooling
pool_mode = transaction
max_client_conn = 2000
default_pool_size = 25
min_pool_size = 10
reserve_pool_size = 10
reserve_pool_timeout = 3

# Логирование
log_connections = 1
log_disconnections = 1
log_pooler_errors = 1

# Таймауты
server_idle_timeout = 600
server_lifetime = 3600
server_connect_timeout = 15
query_timeout = 0
query_wait_timeout = 120
client_idle_timeout = 0

# Performance
max_db_connections = 0
max_user_connections = 0

# Maintenance
server_reset_query = DISCARD ALL
server_check_delay = 30
```

**Создать userlist для PgBouncer:**

```bash
# Сгенерировать MD5 хеш для пользователя
# Формат: "md5" + md5(password + username)
echo -n "CHANGE_ADMIN_PASSWORDadmin" | md5sum
# Результат использовать ниже

cat <<EOF | sudo tee /etc/pgbouncer/userlist.txt
"admin" "md5ХЕШ_ИЗ_КОМАНДЫ_ВЫШЕ"
"postgres" "md5ХЕШ_POSTGRES_PASSWORD"
EOF

sudo useradd -r -s /bin/false pgbouncer
sudo chown pgbouncer:pgbouncer /etc/pgbouncer/userlist.txt
sudo chmod 600 /etc/pgbouncer/userlist.txt
```

**Включить и запустить PgBouncer:**

```bash
sudo systemctl enable pgbouncer
sudo systemctl start pgbouncer
sudo systemctl status pgbouncer
```

### 4. Настройка HAProxy

Создать конфигурацию `/etc/haproxy/haproxy.cfg`:

```
sudo tee /etc/haproxy/haproxy.cfg > /dev/null <<'EOF'
global
    maxconn 10000
    log /dev/log local0
    log /dev/log local1 notice
    chroot /var/lib/haproxy
    stats socket /run/haproxy/admin.sock mode 660 level admin
    stats timeout 30s
    user haproxy
    group haproxy
    daemon

defaults
    log global
    mode tcp
    option tcplog
    option dontlognull
    option redispatch
    retries 3
    timeout connect 5s
    timeout client 1h
    timeout server 1h
    timeout check 5s

# Страница статистики
listen stats
    mode http
    bind *:5000
    stats enable
    stats uri /
    stats refresh 10s
    stats admin if TRUE
    stats auth admin:CHANGE_STATS_PASSWORD

# PostgreSQL Master (чтение и запись)
listen postgres_master
    bind *:7000
    mode tcp
    option httpchk
    http-check expect status 200
    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions
    server node1 192.168.100.201:6432 maxconn 500 check port 8008
    server node2 192.168.100.202:6432 maxconn 500 check port 8008 backup
    server node3 192.168.100.203:6432 maxconn 500 check port 8008 backup

# PostgreSQL Replicas (только чтение)
listen postgres_replicas
    bind *:7001
    mode tcp
    balance leastconn
    option httpchk
    http-check expect status 200
    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions
    server node1 192.168.100.201:6432 maxconn 500 check port 8008
    server node2 192.168.100.202:6432 maxconn 500 check port 8008
    server node3 192.168.100.203:6432 maxconn 500 check port 8008
EOF
```

**Запустить HAProxy:**

```bash
sudo systemctl enable haproxy
sudo systemctl restart haproxy
sudo systemctl status haproxy
```

### 5. Настройка Keepalived

**Создать скрипт проверки check_patroni `/etc/keepalived/check_patroni.sh`:**

```bash
sudo tee /etc/keepalived/check_patroni.sh > /dev/null <<'EOF'
#!/bin/bash

# Проверка 1: HAProxy работает
if ! systemctl is-active --quiet haproxy; then
    exit 1
fi

# Проверка 2: Patroni REST API отвечает
if ! curl -sf http://localhost:8008/health >/dev/null 2>&1; then
    exit 1
fi

# Проверка 3: Этот узел является мастером PostgreSQL
# Возвращает HTTP 200 только если узел - мастер
if curl -sf http://localhost:8008/master >/dev/null 2>&1; then
    exit 0
else
    exit 1
fi
EOF

sudo chmod +x /etc/keepalived/check_patroni.sh
```

**На node1 создать `/etc/keepalived/keepalived.conf`:**

```bash
sudo tee /etc/keepalived/keepalived.conf > /dev/null <<'EOF'
global_defs {
    router_id node1  # Измените на node2, node3 для других узлов
    enable_script_security
    script_user root
    vrrp_garp_interval 0.001
    vrrp_gna_interval 0.001
}

vrrp_script check_patroni_master {
    script "/etc/keepalived/check_patroni.sh"
    interval 1
    timeout 2
    weight -200       # Агрессивное снижение priority
    fall 2
    rise 2
}

vrrp_instance VI_1 {
    state BACKUP
    interface eth0
    virtual_router_id 51
    priority 100      # node1: 100, node2: 90, node3: 80
    advert_int 1
    #nopreempt        # Не забирать VIP автоматически у слейва, после востановления мастера
    garp_master_delay 1      # пауза в 1 секунду перед широковещательной рассылкой, сообщает всем устройствам в сети, что MAC-адрес, связанный с VIP, изменился и теперь принадлежит новому узлу-мастеру
    
    unicast_src_ip 192.168.100.201  # Измените для каждого узла (IP текущего узла)
    unicast_peer {
        192.168.100.202
        192.168.100.203
    }
    
    authentication {
        auth_type PASS
        auth_pass YourPassword123
    }
    
    virtual_ipaddress {
        192.168.100.200/24
    }
    
    track_script {
        check_patroni_master   # Вызывается keepalived, определяет здоровье и роль узла, возвращая 0 - здоров, 1 - упал
    }
    # Опционально: уведомления при смене состояния
    notify_master "/usr/local/bin/keepalived_notify.sh MASTER"
    notify_backup "/usr/local/bin/keepalived_notify.sh BACKUP"
    notify_fault "/usr/local/bin/keepalived_notify.sh FAULT"
}
EOF
```

**На node2 создать `/etc/keepalived/keepalived.conf`:**
```bash
sudo tee /etc/keepalived/keepalived.conf > /dev/null <<'EOF'
global_defs {
    router_id node2  # Измените на node2, node3 для других узлов
    enable_script_security
    script_user root
    vrrp_garp_interval 0.001
    vrrp_gna_interval 0.001
}

vrrp_script check_patroni_master {
    script "/etc/keepalived/check_patroni.sh"
}

vrrp_instance VI_1 {
    state BACKUP
    interface eth0
    virtual_router_id 51
    priority 90      # node1: 100, node2: 90, node3: 80
    advert_int 1
    #nopreempt
    garp_master_delay 1

    unicast_src_ip 192.168.100.202  # Измените для каждого узла
    unicast_peer {
        192.168.100.201
        192.168.100.203
    }

    authentication {
        auth_type PASS
        auth_pass YourPassword123
    }

    virtual_ipaddress {
        192.168.100.200/24
    }

    track_script {
        check_patroni_master
    }
    # Опционально: уведомления при смене состояния
    notify_master "/usr/local/bin/keepalived_notify.sh MASTER"
    notify_backup "/usr/local/bin/keepalived_notify.sh BACKUP"
    notify_fault "/usr/local/bin/keepalived_notify.sh FAULT"
}
EOF
```
**На node3 создать `/etc/keepalived/keepalived.conf`:**
```bash
sudo tee /etc/keepalived/keepalived.conf > /dev/null <<'EOF'
global_defs {
    router_id node3  # Измените на node2, node3 для других узлов
    enable_script_security
    script_user root
    vrrp_garp_interval 0.001
    vrrp_gna_interval 0.001
}

vrrp_script check_patroni_master {
    script "/etc/keepalived/check_patroni.sh"
}

vrrp_instance VI_1 {
    state BACKUP
    interface eth0
    virtual_router_id 51
    priority 80      # node1: 100, node2: 90, node3: 80
    advert_int 1
    #nopreempt
    garp_master_delay 1

    unicast_src_ip 192.168.100.203  # Измените для каждого узла
    unicast_peer {
        192.168.100.201
        192.168.100.202
    }

    authentication {
        auth_type PASS
        auth_pass YourPassword123
    }

    virtual_ipaddress {
        192.168.100.200/24
    }

    track_script {
        check_patroni_master
    }
    # Опционально: уведомления при смене состояния
    notify_master "/usr/local/bin/keepalived_notify.sh MASTER"
    notify_backup "/usr/local/bin/keepalived_notify.sh BACKUP"
    notify_fault "/usr/local/bin/keepalived_notify.sh FAULT"
}

EOF
```
**Запустить Keepalived:**

```bash
sudo systemctl enable keepalived
sudo systemctl start keepalived
sudo systemctl status keepalived

# Проверить VIP
ip addr show
```
**Проверка мастера через Patroni API**
```bash
curl -sf http://localhost:8008/master
```
✅ Возвращает 200 **только** на мастере PostgreSQL.

## Как это работает

### Сценарий 1: Нормальная работа
```
node1: PostgreSQL мастер → /master = 200 → priority 100 → VIP на node1
node2: PostgreSQL реплика → /master = 503 → priority 90-100 = -10 → нет VIP
node3: PostgreSQL реплика → /master = 503 → priority 80-100 = -20 → нет VIP
```

### Сценарий 2: Patroni упал на node1
```
1. Patroni на node1 останавливается
2. /master на node1 → 503
3. node1 priority: 100 - 100 = 0
4. Patroni failover: node2 становится мастером
5. /master на node2 → 200
6. node2 priority: 90 (нормальный)
7. node2 (90) > node1 (0) → VIP переезжает на node2
```

### Сценарий 3: node1 перезагружается
```
1. node1 возвращается, но Patroni делает его репликой
2. /master на node1 → 503
3. node1 priority: 0 (т.к. не мастер)
4. node2 всё ещё мастер → priority 90
5. Флаг nopreempt → node1 НЕ забирает VIP
6. VIP остаётся на node2
```

**Скрипт уведомлений (опционально)**
```bash
sudo tee /usr/local/bin/keepalived_notify.sh > /dev/null <<'EOF'
#!/bin/bash

STATE=$1
NODE=$(hostname)
DATE=$(date +"%Y-%m-%d %H:%M:%S")

case $STATE in
    "MASTER")
        echo "[$DATE] $NODE became MASTER" | logger -t keepalived
        # Отправить уведомление в Telegram/email
        ;;
    "BACKUP")
        echo "[$DATE] $NODE became BACKUP" | logger -t keepalived
        ;;
    "FAULT")
        echo "[$DATE] $NODE in FAULT state" | logger -t keepalived
        ;;
esac
EOF
sudo chmod +x /usr/local/bin/keepalived_notify.sh
```


## Резервное копирование

### 1. Установка pgBackRest

**Ubuntu/Debian:**

```bash
sudo apt-get install -y pgbackrest
```

**Rocky Linux:**

```bash
sudo dnf install -y pgbackrest
```

### 2. Конфигурация pgBackRest

Создать `/etc/pgbackrest.conf`:

```ini
[global]
repo1-path=/var/lib/pgbackrest
repo1-retention-full=7
repo1-retention-diff=7

log-level-console=info
log-level-file=debug
start-fast=y
stop-auto=y

# Параллельное выполнение
process-max=4

[postgres-cluster]
pg1-path=/var/lib/postgresql/16/main
pg1-port=5432
pg1-user=postgres
```

**Настроить права:**

```bash
sudo mkdir -p /var/lib/pgbackrest
sudo chown -R postgres:postgres /var/lib/pgbackrest
sudo chmod 750 /var/lib/pgbackrest
```

### 3. Скрипты резервного копирования

**Полное резервное копирование `/usr/local/bin/pg_backup_full.sh`:**

```bash
#!/bin/bash
LOG_FILE="/var/log/postgresql/backup_full.log"
DATE=$(date +%Y-%m-%d_%H-%M-%S)

echo "[$DATE] Starting full backup" | tee -a $LOG_FILE

sudo -u postgres pgbackrest --stanza=postgres-cluster --type=full backup 2>&1 | tee -a $LOG_FILE

if [ ${PIPESTATUS[0]} -eq 0 ]; then
    echo "[$DATE] Full backup completed successfully" | tee -a $LOG_FILE
    exit 0
else
    echo "[$DATE] Full backup failed!" | tee -a $LOG_FILE
    exit 1
fi
```

**Инкрементное резервное копирование `/usr/local/bin/pg_backup_incr.sh`:**

```bash
#!/bin/bash
LOG_FILE="/var/log/postgresql/backup_incr.log"
DATE=$(date +%Y-%m-%d_%H-%M-%S)

echo "[$DATE] Starting incremental backup" | tee -a $LOG_FILE

sudo -u postgres pgbackrest --stanza=postgres-cluster --type=incr backup 2>&1 | tee -a $LOG_FILE

if [ ${PIPESTATUS[0]} -eq 0 ]; then
    echo "[$DATE] Incremental backup completed successfully" | tee -a $LOG_FILE
    exit 0
else
    echo "[$DATE] Incremental backup failed!" | tee -a $LOG_FILE
    exit 1
fi
```

**Сделать скрипты исполняемыми:**

```bash
sudo chmod +x /usr/local/bin/pg_backup_full.sh
sudo chmod +x /usr/local/bin/pg_backup_incr.sh
```

### 4. Инициализация и первое резервное копирование

```bash
# Создать stanza (выполнить на мастере)
sudo -u postgres pgbackrest --stanza=postgres-cluster stanza-create

# Проверить конфигурацию
sudo -u postgres pgbackrest --stanza=postgres-cluster check

# Выполнить первое полное резервное копирование
sudo /usr/local/bin/pg_backup_full.sh
```

### 5. Настройка расписания (cron)

```bash
# Редактировать crontab для postgres
sudo crontab -u postgres -e

# Добавить следующие строки:
# Полное резервное копирование каждое воскресенье в 02:00
0 2 * * 0 /usr/local/bin/pg_backup_full.sh

# Инкрементное резервное копирование каждый день в 02:00 (кроме воскресенья)
0 2 * * 1-6 /usr/local/bin/pg_backup_incr.sh
```

### 6. Восстановление из резервной копии

**Восстановление на момент времени (PITR):**

```bash
# Остановить Patroni на всех узлах
sudo systemctl stop patroni

# На мастере - восстановить на определенный момент времени
sudo -u postgres pgbackrest --stanza=postgres-cluster \
  --type=time "--target=2025-10-22 12:00:00" \
  --target-action=promote restore

# Или восстановить последнюю резервную копию
sudo -u postgres pgbackrest --stanza=postgres-cluster restore

# Запустить Patroni на мастере
sudo systemctl start patroni

# После завершения восстановления - запустить Patroni на репликах
# Они автоматически синхронизируются с мастером
```

---

## Настройка для 1С

### 1. Создание базы данных для 1С

```bash
# Подключиться к PostgreSQL через мастер
psql -h 192.168.100.200 -p 7000 -U postgres

# Создать пользователя для 1С
CREATE USER usr1cv8 WITH PASSWORD 'CHANGE_1C_PASSWORD';

# Создать базу данных
CREATE DATABASE erp_database
  WITH OWNER = usr1cv8
  ENCODING = 'UTF8'
  LC_COLLATE = 'ru_RU.UTF-8'
  LC_CTYPE = 'ru_RU.UTF-8'
  TABLESPACE = pg_default
  CONNECTION LIMIT = -1;

# Подключиться к созданной базе
\c erp_database

# Установить расширения для 1С
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS btree_gin;
CREATE EXTENSION IF NOT EXISTS btree_gist;

# Предоставить права
GRANT ALL PRIVILEGES ON DATABASE erp_database TO usr1cv8;
GRANT ALL ON SCHEMA public TO usr1cv8;

# Настройки специально для 1С
ALTER DATABASE erp_database SET shared_buffers = '8GB';
ALTER DATABASE erp_database SET effective_cache_size = '24GB';
ALTER DATABASE erp_database SET random_page_cost = 1.1;
ALTER DATABASE erp_database SET seq_page_cost = 1.0;
```

### 2. Настройка подключения 1С

**Строка подключения для 1С:**

- **Сервер:** 192.168.100.200
- **Порт:** 7000
- **База данных:** erp_database
- **Пользователь:** usr1cv8
- **Пароль:** CHANGE_1C_PASSWORD

**В параметрах СУБД 1С указать:**

- Тип СУБД: PostgreSQL
- Использовать пул соединений: Да
- Блокировка в таблицах СУБД: Да

### 3. Оптимизация для работы с 1С

```sql
-- Увеличение статистики для планировщика запросов
ALTER DATABASE erp_database SET default_statistics_target = 500;

-- Оптимизация для транзакций 1С
ALTER DATABASE erp_database SET synchronous_commit = off;

-- Для отчетов 1С (если используются тяжелые запросы)
ALTER DATABASE erp_database SET work_mem = '64MB';
ALTER DATABASE erp_database SET temp_buffers = '64MB';

-- Локализация
ALTER DATABASE erp_database SET lc_messages = 'ru_RU.UTF-8';
ALTER DATABASE erp_database SET lc_monetary = 'ru_RU.UTF-8';
ALTER DATABASE erp_database SET lc_numeric = 'ru_RU.UTF-8';
ALTER DATABASE erp_database SET lc_time = 'ru_RU.UTF-8';
```

---

## Мониторинг

### 1. Установка postgres_exporter

```bash
# Скачать и установить postgres_exporter
wget https://github.com/prometheus-community/postgres_exporter/releases/download/v0.15.0/postgres_exporter-0.15.0.linux-amd64.tar.gz
tar xvfz postgres_exporter-0.15.0.linux-amd64.tar.gz
sudo mv postgres_exporter-0.15.0.linux-amd64/postgres_exporter /usr/local/bin/
sudo rm -rf postgres_exporter-0.15.0.linux-amd64*

# Создать пользователя для мониторинга
psql -h localhost -U postgres -c "CREATE USER postgres_exporter WITH PASSWORD 'CHANGE_EXPORTER_PASSWORD';"
psql -h localhost -U postgres -c "ALTER USER postgres_exporter SET SEARCH_PATH TO postgres_exporter,pg_catalog;"
psql -h localhost -U postgres -c "GRANT pg_monitor TO postgres_exporter;"

# Создать systemd service
cat <<EOF | sudo tee /etc/systemd/system/postgres_exporter.service
[Unit]
Description=Prometheus PostgreSQL Exporter
After=network.target

[Service]
Type=simple
User=postgres
Environment="DATA_SOURCE_NAME=postgresql://postgres_exporter:CHANGE_EXPORTER_PASSWORD@localhost:5432/postgres?sslmode=disable"
ExecStart=/usr/local/bin/postgres_exporter
Restart=always

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable postgres_exporter
sudo systemctl start postgres_exporter
```

### 2. Скрипт проверки здоровья кластера

Создать `/usr/local/bin/check_cluster.sh`:

```bash
#!/bin/bash

echo "=== Patroni Cluster Status ==="
patronictl -c /etc/patroni/patroni.yml list

echo -e "\n=== etcd Cluster Health ==="
etcdctl --endpoints=http://192.168.100.201:2379,http://192.168.100.202:2379,http://192.168.100.203:2379 endpoint health

echo -e "\n=== HAProxy Status ==="
systemctl status haproxy --no-pager

echo -e "\n=== Keepalived Status ==="
systemctl status keepalived --no-pager
ip addr show | grep "192.168.100.200"

echo -e "\n=== PgBouncer Status ==="
systemctl status pgbouncer --no-pager

echo -e "\n=== PostgreSQL Connection Test ==="
psql -h 192.168.100.200 -p 7000 -U postgres -c "SELECT version();"

echo -e "\n=== Replication Lag ==="
psql -h 192.168.100.200 -p 7000 -U postgres -c "SELECT client_addr, state, sync_state, replay_lag FROM pg_stat_replication;"
```

```bash
sudo chmod +x /usr/local/bin/check_cluster.sh
```

### 3. Метрики кластера

Создать `/usr/local/bin/cluster_metrics.sh`:

```bash
#!/bin/bash

echo "=== Database Size ==="
psql -h localhost -U postgres -c "SELECT pg_database.datname, pg_size_pretty(pg_database_size(pg_database.datname)) AS size FROM pg_database ORDER BY pg_database_size(pg_database.datname) DESC;"

echo -e "\n=== Connection Stats ==="
psql -h localhost -U postgres -c "SELECT count(*) as connections, usename, state FROM pg_stat_activity GROUP BY usename, state ORDER BY connections DESC;"

echo -e "\n=== Top 10 Largest Tables ==="
psql -h localhost -U postgres -d erp_database -c "SELECT schemaname, tablename, pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS size FROM pg_tables ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC LIMIT 10;"

echo -e "\n=== Long Running Queries ==="
psql -h localhost -U postgres -c "SELECT pid, now() - pg_stat_activity.query_start AS duration, query, state FROM pg_stat_activity WHERE (now() - pg_stat_activity.query_start) > interval '5 minutes' AND state != 'idle';"

echo -e "\n=== Cache Hit Ratio ==="
psql -h localhost -U postgres -c "SELECT sum(heap_blks_read) as heap_read, sum(heap_blks_hit) as heap_hit, sum(heap_blks_hit) / (sum(heap_blks_hit) + sum(heap_blks_read)) * 100 as cache_hit_ratio FROM pg_statio_user_tables;"
```

```bash
sudo chmod +x /usr/local/bin/cluster_metrics.sh
```

---

## Тестирование

### 1. Тест автоматического failover

```bash
# Проверить текущий мастер
patronictl -c /etc/patroni/patroni.yml list

# Остановить мастер (например, node1)
sudo systemctl stop patroni

# Наблюдать за автоматическим переключением (обычно 30 секунд)
watch -n 1 'patronictl -c /etc/patroni/patroni.yml list'

# Наблюдать за автоматическим переключением keepalived и patroni (обычно 30 секунд)
watch 'ip a; patronictl -c /etc/patroni/patroni.yml list'

# Проверить доступность через VIP
psql -h 192.168.100.200 -p 7000 -U postgres -c "SELECT pg_is_in_recovery();"

# Запустить node1 обратно - он станет репликой
sudo systemctl start patroni
```

### 2. Тест отказа HAProxy

```bash
# Остановить HAProxy на текущем держателе VIP
sudo systemctl stop haproxy

# Keepalived должен переместить VIP на другой узел
# Проверить новый держатель VIP
ip addr show | grep "192.168.100.200"

# Подключение через VIP должно продолжать работать
psql -h 192.168.100.200 -p 7000 -U postgres -c "SELECT 1;"
```

### 3. Тест нагрузки (pgbench)

```bash
# Инициализация тестовой базы
pgbench -h 192.168.100.200 -p 7000 -U postgres -i -s 50 postgres

# Тест производительности (10 минут, 50 клиентов)
pgbench -h 192.168.100.200 -p 7000 -U postgres -c 50 -j 4 -T 600 postgres

# Тест с failover во время нагрузки
# В другом терминале остановить мастер:
sudo systemctl stop patroni

# pgbench должен автоматически переподключиться к новому мастеру
```

---

## Обслуживание

### 1. Плановое обновление узла

```bash
# Перевести узел в режим обслуживания (no failover)
patronictl -c /etc/patroni/patroni.yml pause postgres-cluster

# Обновить пакеты
sudo apt-get update && sudo apt-get upgrade -y

# Перезагрузить узел
sudo reboot

# После перезагрузки - снять режим обслуживания
patronictl -c /etc/patroni/patroni.yml resume postgres-cluster
```

### 2. Ручное переключение мастера

```bash
# Переключить мастер на node2
patronictl -c /etc/patroni/patroni.yml switchover postgres-cluster --master node1 --candidate node2

# Или принудительное переключение
patronictl -c /etc/patroni/patroni.yml failover postgres-cluster --candidate node2 --force
```

### 3. Добавление нового узла в кластер

```bash
# На новом узле (node4: 192.168.100.204):
# 1. Установить все компоненты
# 2. Скопировать конфигурации, изменив IP и name
# 3. Добавить node4 в etcd кластер:

# На существующем узле etcd
etcdctl member add node4 --peer-urls=http://192.168.100.204:2380

# На node4 изменить initial-cluster-state на 'existing'
# И запустить сервисы:
sudo systemctl start etcd
sudo systemctl start patroni
sudo systemctl start pgbouncer
sudo systemctl start haproxy

# Patroni автоматически клонирует данные с мастера
```
### 3.1. Повторное включение узла в кластер если он вышел из кластера

На проблемной ноде допустим node3:
```bash
# Останавливаем patroni и postgresql
sudo systemctl stop patroni
sudo systemctl stop postgresql

# Удаляем старую базу данных
sudo rm -rf /var/lib/postgresql/16/main

# Создаём пустую структуру каталогов
sudo mkdir -p /var/lib/postgresql/16/main
sudo chown -R postgres:postgres /var/lib/postgresql/16
sudo chmod 700 /var/lib/postgresql/16/main

# Удалить старую регистрацию ноды из DCS (etcd)
# Выполняется на любой ноде кластера, где установлен etcdctl.
# Если в patroni.yml указан namespace:
# namespace: /db/
# то команда будет:
etcdctl del /db/postgres-cluster/members/node3

# Иначе — без namespace:
etcdctl del /postgres-cluster/members/node3

# Проверить, что запись удалена:
etcdctl get / --prefix --keys-only | grep node3

# Результат должен быть пустой.

# Запустить Patroni на ноде заново
# После очистки и удаления старой записи запусти Patroni:
sudo systemctl restart patroni
sudo journalctl -u patroni -f

# В логах ожидаются строки:
# INFO: Replica has no PGDATA, creating replica using base backup
# INFO: basebackup completed
# INFO: postmaster started
# INFO: Replica is running in streaming replication

# Проверить состояние кластера
# Через 1–2 минуты (когда pg_basebackup завершится):
patronictl -c /etc/patroni/patroni.yml list

# Ожидаемый результат:

# + Cluster: postgres-cluster --------+---------+-----------+----+
# | Member | Host            | Role    | State   | TL | Lag |
# +--------+-----------------+---------+---------+----+-----+
# | node1  | 192.168.100.201 | Replica | running | 16 | 0   |
# | node2  | 192.168.100.202 | Leader  | running | 16 |     |
# | node3  | 192.168.100.203 | Replica | running | 16 | 0   |
# +--------+-----------------+---------+---------+----+-----+
```

Диагностика, если нода снова не стартует
```bash
# Посмотреть последние логи:
sudo journalctl -u patroni -n 50 -e
```

Частые причины:
- Ошибка доступа в pg_hba.conf к лидеру;
- Неверный пароль репликации (replicator);
- Несовпадение scope или namespace в конфиге patroni.yml;
- Проблема с сетевым доступом между нодами (порт 5432 или 8008 закрыт).

### 4. Vacuum и обслуживание для 1С

Создать `/usr/local/bin/pg_maintenance_1c.sh`:

```bash
#!/bin/bash
# Обслуживание БД 1С

DB_NAME="erp_database"
LOG_FILE="/var/log/postgresql/maintenance_1c.log"
DATE=$(date +%Y-%m-%d_%H-%M-%S)

echo "[$DATE] Starting maintenance for $DB_NAME" | tee -a $LOG_FILE

# Vacuum Full для критичных таблиц 1С (выполнять в нерабочее время!)
psql -h localhost -U postgres -d $DB_NAME -c "VACUUM FULL VERBOSE ANALYZE;" 2>&1 | tee -a $LOG_FILE

# Reindex для улучшения производительности
psql -h localhost -U postgres -d $DB_NAME -c "REINDEX DATABASE $DB_NAME;" 2>&1 | tee -a $LOG_FILE

# Обновление статистики
psql -h localhost -U postgres -d $DB_NAME -c "ANALYZE VERBOSE;" 2>&1 | tee -a $LOG_FILE

echo "[$DATE] Maintenance completed for $DB_NAME" | tee -a $LOG_FILE
```

```bash
sudo chmod +x /usr/local/bin/pg_maintenance_1c.sh

# Добавить в crontab (выполнять каждое воскресенье в 04:00)
sudo crontab -u postgres -e
0 4 * * 0 /usr/local/bin/pg_maintenance_1c.sh
```

---

## Безопасность

### 1. Настройка SSL/TLS для PostgreSQL

```bash
# Создать самоподписанный сертификат
sudo -u postgres openssl req -new -x509 -days 365 -nodes -text \
  -out /var/lib/postgresql/16/main/server.crt \
  -keyout /var/lib/postgresql/16/main/server.key \
  -subj "/CN=pg-cluster.example.com"

sudo chmod 600 /var/lib/postgresql/16/main/server.key
sudo chown postgres:postgres /var/lib/postgresql/16/main/server.*

# Обновить patroni.yml для включения SSL
# Добавить в секцию postgresql.parameters:
#   ssl: on
#   ssl_cert_file: '/var/lib/postgresql/16/main/server.crt'
#   ssl_key_file: '/var/lib/postgresql/16/main/server.key'

# Перезапустить Patroni
sudo systemctl restart patroni
```

### 2. Настройка firewall правил

```bash
# Ограничить доступ к PostgreSQL только с определенных сетей
sudo ufw allow from 192.168.100.0/24 to any port 5432
sudo ufw allow from 192.168.1.0/24 to any port 7000  # Сеть 1С серверов

# Закрыть прямой доступ к PostgreSQL извне
sudo ufw deny 5432/tcp

# Разрешить доступ к HAProxy stats только с админской сети
sudo ufw allow from 192.168.100.0/24 to any port 5000
```

### 3. Аудит и логирование

```bash
# Включить расширение pgAudit для детального аудита
psql -h localhost -U postgres -d erp_database -c "CREATE EXTENSION IF NOT EXISTS pgaudit;"

# Настроить в patroni.yml:
# pgaudit.log = 'all'
# pgaudit.log_catalog = off
# pgaudit.log_parameter = on
# pgaudit.log_relation = on

# Ротация логов
cat <<EOF | sudo tee /etc/logrotate.d/postgresql
/var/log/postgresql/*.log {
    daily
    rotate 30
    compress
    delaycompress
    notifempty
    missingok
    su postgres postgres
    postrotate
        /usr/bin/killall -HUP syslogd 2> /dev/null || true
    endscript
}
EOF
```

---

## Troubleshooting

### Проблема: Patroni не может запуститься

```bash
# Проверить логи
sudo journalctl -u patroni -n 100 --no-pager

# Проверить доступность etcd
etcdctl endpoint health

# Проверить права на директории
ls -la /var/lib/postgresql/16/main
sudo chown -R postgres:postgres /var/lib/postgresql

# Удалить lock файлы если нужно
sudo rm -f /var/lib/postgresql/16/main/postmaster.pid
```

### Проблема: Репликация отстает

```bash
# Проверить лаг репликации
psql -h localhost -U postgres -c "SELECT client_addr, state, sync_state, sent_lsn, write_lsn, flush_lsn, replay_lsn, replay_lag FROM pg_stat_replication;"

# Увеличить max_wal_senders если нужно
patronictl -c /etc/patroni/patroni.yml edit-config

# Проверить сетевую связность
ping node2
nc -zv node2 5432
```

### Проблема: Split-brain (два мастера)

```bash
# Проверить статус кластера
patronictl -c /etc/patroni/patroni.yml list

# Если есть два мастера - принудительно переключить:
patronictl -c /etc/patroni/patroni.yml reinit postgres-cluster node2 --force

# Проверить etcd кластер
etcdctl endpoint status --cluster -w table
```

### Проблема: 1С медленно работает

```bash
# Проверить активные запросы
psql -h localhost -U postgres -d erp_database -c "SELECT pid, query_start, state, query FROM pg_stat_activity WHERE state != 'idle' ORDER BY query_start;"

# Проверить блокировки
psql -h localhost -U postgres -d erp_database -c "SELECT pid, usename, pg_blocking_pids(pid) as blocked_by, query FROM pg_stat_activity WHERE cardinality(pg_blocking_pids(pid)) > 0;"

# Убить зависшую транзакцию (осторожно!)
psql -h localhost -U postgres -c "SELECT pg_terminate_backend(PID);"

# Проверить раздутие таблиц
psql -h localhost -U postgres -d erp_database -c "SELECT schemaname, tablename, pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) FROM pg_tables ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC LIMIT 10;"

# Запустить vacuum
psql -h localhost -U postgres -d erp_database -c "VACUUM VERBOSE ANALYZE;"
```

---

## Чек-лист для production deployment

- [ ] Все пароли изменены на безопасные (CHANGE_*)
- [ ] Настроен мониторинг (Prometheus + Grafana)
- [ ] Настроены alerts на критичные метрики
- [ ] Резервное копирование работает и проверено восстановление
- [ ] Настроен off-site backup (S3/NFS)
- [ ] Протестирован failover
- [ ] Настроен SSL/TLS
- [ ] Firewall настроен согласно политике безопасности
- [ ] Логирование и аудит включены
- [ ] Документация обновлена с актуальными IP и паролями
- [ ] Команда обучена процедурам восстановления
- [ ] Создан runbook для типовых инцидентов
- [ ] Настроены контакты для экстренной связи
- [ ] Проведено нагрузочное тестирование
- [ ] Настроена ротация логов
- [ ] Созданы мониторинговые дашборды

---

## Полезные команды

```bash
# Статус кластера
patronictl -c /etc/patroni/patroni.yml list

# Переключение мастера
patronictl -c /etc/patroni/patroni.yml switchover

# Перезагрузка конфигурации Patroni
patronictl -c /etc/patroni/patroni.yml reload postgres-cluster

# Просмотр конфигурации в etcd
patronictl -c /etc/patroni/patroni.yml show-config

# Редактирование конфигурации кластера
patronictl -c /etc/patroni/patroni.yml edit-config

# Проверка резервных копий
sudo -u postgres pgbackrest --stanza=postgres-cluster info

# Подключение к PostgreSQL через VIP
psql -h 192.168.100.200 -p 7000 -U postgres

# Проверка статистики PgBouncer
psql -h localhost -p 6432 -U pgbouncer -d pgbouncer -c "SHOW STATS;"
psql -h localhost -p 6432 -U pgbouncer -d pgbouncer -c "SHOW POOLS;"

# Просмотр статистики HAProxy
curl http://192.168.100.200:5000
```

---

## Дополнительные оптимизации

### 1. Настройка huge pages для PostgreSQL

```bash
# Рассчитать необходимый размер huge pages
# Для shared_buffers = 8GB нужно примерно 4100 huge pages (по 2MB)

# Добавить в /etc/sysctl.conf
echo "vm.nr_hugepages = 4100" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p

# Проверить
cat /proc/meminfo | grep -i huge

# Добавить в patroni.yml в секцию postgresql.parameters:
# huge_pages = try
```

### 2. Настройка I/O scheduler для SSD

```bash
# Для SSD дисков использовать deadline или noop
echo deadline | sudo tee /sys/block/sda/queue/scheduler

# Сделать постоянным через udev
cat <<EOF | sudo tee /etc/udev/rules.d/60-scheduler.rules
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="deadline"
EOF
```

### 3. Отключение transparent huge pages

```bash
cat <<EOF | sudo tee /etc/systemd/system/disable-thp.service
[Unit]
Description=Disable Transparent Huge Pages (THP)
DefaultDependencies=no
After=sysinit.target local-fs.target
Before=postgresql.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled'
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/defrag'

[Install]
WantedBy=basic.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable disable-thp
sudo systemctl start disable-thp
```

---

## Полезные ресурсы

- **Документация PostgreSQL:** https://www.postgresql.org/docs/16/
- **Документация Patroni:** https://patroni.readthedocs.io/
- **Документация etcd:** https://etcd.io/docs/
- **Документация PgBouncer:** https://www.pgbouncer.org/
- **Документация HAProxy:** https://www.haproxy.org/
- **Сообщество 1С + PostgreSQL:** https://infostart.ru/
- **PostgreSQL Wiki:** https://wiki.postgresql.org/
- **pgBackRest:** https://pgbackrest.org/

---

## Заключение

Эта инструкция предоставляет полное руководство по развертыванию отказоустойчивого кластера PostgreSQL для production-окружения. Следуйте всем шагам последовательно и не забудьте:

1. Изменить все пароли (CHANGE_*)
2. Настроить мониторинг и алерты
3. Протестировать failover перед production
4. Настроить и проверить резервное копирование
5. Обучить команду процедурам обслуживания

Удачи в развертывании!
