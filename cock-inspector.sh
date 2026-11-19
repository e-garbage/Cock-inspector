#!/usr/bin/env bash
#
# cock-inspector.sh - read-only inventory of a Linux server's configuration,
# written to a single Markdown document.
#
#   sudo bash cock-inspector.sh [-o report.md] [--redact]
#
# The script never changes the system: it only reads files and runs
# status/list commands. Run it as root for complete results.

VERSION="1.0"
OUT=""
REDACT=0
MAX_BYTES=200000   # max bytes printed per file
MAX_LINES=3000     # max lines printed per command / file

usage() {
  cat <<'EOF'
Usage: sudo bash cock-inspector.sh [options]

  -o, --output FILE   Write the report to FILE
                      (default: ./server-config-<hostname>-<timestamp>.md)
      --redact        Mask passwords, tokens and keys found in configs/env
  -h, --help          Show this help

Read-only. Run as root for full coverage; as a normal user, anything that
could not be read is listed under "Could not collect" at the end.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -o|--output) OUT="$2"; shift 2 ;;
    --redact)    REDACT=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

HOST=$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo unknown)
TS=$(date +%Y%m%d-%H%M%S)
[ -z "$OUT" ] && OUT="./server-config-${HOST}-${TS}.md"

umask 077
BODY=$(mktemp) || { echo "mktemp failed" >&2; exit 1; }
trap 'rm -f "$BODY"' EXIT

IS_ROOT=0; [ "$(id -u)" -eq 0 ] && IS_ROOT=1
WARN=()
DETECTED=()
SHOWN=""

if [ "$IS_ROOT" -ne 1 ]; then
  echo "WARNING: not running as root - many sections will be incomplete." >&2
  echo "         Recommended: sudo bash $0" >&2
fi

# ---------------------------------------------------------------- helpers --

has()  { command -v "$1" >/dev/null 2>&1; }
t()    { if has timeout; then timeout "$@"; else shift; "$@"; fi; }   # t SECS cmd...
w()    { printf '%s\n' "$*" >>"$BODY"; }
section() { w ""; w "## $*"; w ""; echo "[*] $*" >&2; }
sub()  { w ""; w "### $*"; w ""; }
note() { WARN+=("$*"); }
para() { w "$*"; w ""; }

redact() {
  if [ "$REDACT" = 1 ]; then
    sed -E \
      -e 's#(://[^:/@[:space:]]+:)[^@[:space:]]+@#\1***@#g' \
      -e 's/^([^=:#]*(pass|secret|token|api_?key|apikey|access_?key|private_?key|credential|auth_?key|salt|psk)[^=:]*[=:][[:space:]]*).+/\1***REDACTED***/I' \
      -e 's/^([[:space:]]*(requirepass|masterauth|psk|password)[[:space:]]+).+/\1***REDACTED***/I' \
      -e 's/^(PrivateKey|PresharedKey)([[:space:]]*=[[:space:]]*).+/\1\2***REDACTED***/I'
  else
    cat
  fi
}

perm_check() {   # label text
  if printf '%s' "$2" | grep -qiE 'permission denied|operation not permitted|must be root|are you root|access denied|requires root|need to be root|not have permission|superuser'; then
    note "$1 - permission problem (re-run as root)"
  fi
}

block() {        # stdin -> fenced code block
  local data n
  data=$(cat)
  [ -z "$data" ] && data="(empty)"
  n=$(printf '%s\n' "$data" | wc -l)
  w '~~~~'
  printf '%s\n' "$data" | head -n "$MAX_LINES" | redact >>"$BODY"
  [ "$n" -gt "$MAX_LINES" ] && w "... (truncated: $n lines total)"
  w '~~~~'
  w ""
}

run() {          # run "Label" "shell command or function"
  local label="$1" cmd="$2" out rc
  out=$( (eval "$cmd") </dev/null 2>&1 ); rc=$?
  [ -z "$out" ] && out="(no output, exit code $rc)"
  perm_check "$label" "$out"
  if [ -n "$label" ]; then
    if [ "$(type -t "${cmd%% *}")" = function ]; then
      w "**$label**"
    else
      w "**$label** - \`$cmd\`"
    fi
    w ""
  fi
  printf '%s\n' "$out" | block
}

show_file() {    # show_file PATH [nc]   (nc = strip comments/blank lines)
  local f="$1" mode="${2:-full}"
  { [ -e "$f" ] && [ ! -d "$f" ]; } || return 0
  case "$SHOWN" in *"|$f|"*) return 0 ;; esac
  SHOWN="$SHOWN|$f|"
  if [ ! -r "$f" ]; then
    w "**\`$f\`** - _not readable_"; w ""
    note "Cannot read $f"
    return 0
  fi
  if [ "$mode" = nc ]; then
    w "**\`$f\`** _(comments and blank lines removed)_"; w ""
    head -c "$MAX_BYTES" "$f" | grep -vE '^[[:space:]]*([#;]|//|$)' | block
  else
    w "**\`$f\`**"; w ""
    head -c "$MAX_BYTES" "$f" | block
  fi
}

show_files() {   # show_files [--nc] PATH_OR_GLOB...
  local mode=full f
  if [ "$1" = --nc ]; then mode=nc; shift; fi
  for f in "$@"; do [ -f "$f" ] && show_file "$f" "$mode"; done
  return 0
}

PROCS=$(ps -eo comm= 2>/dev/null | sort -u)
proc_running() { printf '%s\n' "$PROCS" | grep -qxE "$1"; }

# login-capable users: "name:home"
USER_HOMES=$(awk -F: '($3==0||$3>=1000) && $3!=65534 && $6!="" {print $1":"$6}' /etc/passwd)

# directories where applications usually live
ROOTS=()
for d in /opt /srv /var/www /home /root /usr/local/src /data /app /apps; do
  [ -d "$d" ] && ROOTS+=("$d")
done
PRUNE=( \( -name node_modules -o -name .git -o -name venv -o -name .venv -o -name vendor
        -o -name .cache -o -name site-packages -o -name .npm -o -name snap -o -name .local
        -o -name __pycache__ -o -name .cargo -o -name .rustup -o -name go \) -prune -o )
find_apps() {    # find_apps MAXDEPTH <find expression>
  [ ${#ROOTS[@]} -eq 0 ] && return 0
  local depth="$1"; shift
  find "${ROOTS[@]}" -maxdepth "$depth" "${PRUNE[@]}" "$@" -print 2>/dev/null
}

# ============================================================ 1. System ====
section "1. System"
run "Host / OS"        'hostnamectl 2>/dev/null || cat /etc/hostname'
show_file /etc/os-release
run "Kernel"           'uname -a'
run "Uptime / load"    'uptime'
run "Virtualization"   'systemd-detect-virt 2>/dev/null || echo "unknown (systemd-detect-virt not available)"'
run "CPU"              'lscpu 2>/dev/null | grep -E "^(Architecture|CPU\(s\)|Model name|Thread|Core|Socket|Hypervisor|Virtualization)" || grep -m1 "model name" /proc/cpuinfo'
run "Memory"           'free -h'
run "Time / NTP"       'timedatectl 2>/dev/null || date'
show_files --nc /etc/chrony/chrony.conf /etc/chrony.conf /etc/systemd/timesyncd.conf /etc/ntp.conf

# =========================================================== 2. Storage ====
section "2. Storage"
run "Block devices"    'lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,UUID,MODEL 2>/dev/null || cat /proc/partitions'
run "Filesystem usage" 'df -hT -x tmpfs -x devtmpfs -x overlay -x squashfs 2>/dev/null || df -h'
run "Inode usage"      'df -i -x tmpfs -x devtmpfs -x overlay -x squashfs 2>/dev/null || df -i'
show_file /etc/fstab
show_file /etc/crypttab
run "Swap"             'swapon --show 2>/dev/null || cat /proc/swaps'
has pvs && run "LVM" 'pvs; echo; vgs; echo; lvs'
grep -q '^md' /proc/mdstat 2>/dev/null && show_file /proc/mdstat
has zpool && run "ZFS" 'zpool status; echo; zfs list'
run "Network mounts"   'mount | grep -E " type (nfs|nfs4|cifs|smb3|fuse.sshfs|glusterfs|ceph|fuse.rclone) " || echo none'
show_files --nc /etc/exports /etc/samba/smb.conf

# =========================================================== 3. Network ====
section "3. Network"
run "Interfaces"       'ip -br addr 2>/dev/null || ifconfig -a'
run "Interfaces (detail)" 'ip addr'
run "Routes"           'ip route; echo; ip -6 route'
has resolvectl && run "DNS (systemd-resolved)" 'resolvectl status | head -60'
show_file /etc/resolv.conf
show_file /etc/hosts
show_files /etc/netplan/*.yaml /etc/netplan/*.yml \
           /etc/network/interfaces /etc/network/interfaces.d/* \
           /etc/sysconfig/network-scripts/ifcfg-* \
           /etc/NetworkManager/system-connections/* \
           /etc/systemd/network/*
has wg && run "WireGuard" 'wg show'
show_files /etc/wireguard/*.conf
has tailscale && run "Tailscale" 'tailscale status'

# =================================================== 4. Listening ports ====
section "4. Listening ports"
run "TCP/UDP listeners" 'ss -tulpn 2>/dev/null || netstat -tulpn'
run "Socket summary"    'ss -s'

# ========================================================== 5. Firewall ====
section "5. Firewall"
fw_found=0
has ufw          && { fw_found=1; run "UFW" 'ufw status verbose'; show_files --nc /etc/ufw/ufw.conf /etc/default/ufw; }
has firewall-cmd && { fw_found=1; run "firewalld" 'firewall-cmd --state; firewall-cmd --list-all-zones'; }
has nft          && { fw_found=1; run "nftables ruleset" 'nft list ruleset'; }
has iptables     && { fw_found=1; run "iptables (filter + nat)" 'iptables -S; echo; iptables -t nat -S'; }
has ip6tables    && run "ip6tables" 'ip6tables -S'
[ "$fw_found" = 0 ] && para "_No firewall tooling found._"
show_files --nc /etc/nftables.conf /etc/iptables/rules.v4 /etc/iptables/rules.v6 /etc/sysconfig/iptables
has fail2ban-client && run "fail2ban" 'fail2ban-client status'
show_files --nc /etc/fail2ban/jail.local /etc/fail2ban/jail.d/*
show_files --nc /etc/hosts.allow /etc/hosts.deny

# =================================================== 6. Users & access ====
section "6. Users & access"
list_users() {
  awk -F: '($3==0||$3>=1000) && $3!=65534 {printf "%-18s uid=%-6s home=%-26s shell=%s\n",$1,$3,$6,$7}' /etc/passwd
}
run "Users (root + uid >= 1000)" list_users
run "Privileged groups" 'for g in sudo wheel admin docker adm lxd libvirt; do getent group "$g"; done'
show_files --nc /etc/sudoers /etc/sudoers.d/*

ssh_keys() {
  local u h f
  while IFS=: read -r u h; do
    [ -z "$u" ] && continue
    for f in "$h/.ssh/authorized_keys" "$h/.ssh/authorized_keys2"; do
      [ -e "$f" ] || continue
      echo "== $u: $f"
      if [ -r "$f" ]; then
        ssh-keygen -lf "$f" 2>/dev/null || echo "  (could not fingerprint)"
        grep -vE '^[[:space:]]*(#|$)' "$f" | grep -vE '^(ssh-|ecdsa-|sk-)' | sed 's/ \(ssh-\|ecdsa-\|sk-\).*/ <key>/; s/^/  restricted: /'
      else
        echo "  not readable"
      fi
    done
  done <<<"$USER_HOMES"
}
run "Authorized SSH keys (fingerprints)" ssh_keys

SSHD=$(command -v sshd || echo /usr/sbin/sshd)
[ -x "$SSHD" ] && run "sshd effective settings" "$SSHD -T 2>&1 | grep -E '^(port|listenaddress|permitrootlogin|passwordauthentication|pubkeyauthentication|kbdinteractiveauthentication|challengeresponseauthentication|usepam|allowusers|allowgroups|denyusers|denygroups|x11forwarding|allowtcpforwarding|gatewayports|maxauthtries|clientaliveinterval|authorizedkeysfile|subsystem|permitemptypasswords) '"
show_files --nc /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf

outgoing_ssh() {
  local u h
  while IFS=: read -r u h; do
    [ -d "$h/.ssh" ] || continue
    echo "== $u ($h/.ssh)"
    ls -l "$h/.ssh" 2>&1 | sed 's/^/  /'
  done <<<"$USER_HOMES"
}
run "Per-user ~/.ssh contents (keys this server uses to reach others)" outgoing_ssh
while IFS=: read -r u h; do show_file "$h/.ssh/config"; done <<<"$USER_HOMES"
show_files --nc /etc/ssh/ssh_config.d/*.conf
run "Recent logins"  'last -a -n 25 2>/dev/null || echo "last not available"'
has lastlog && run "Last login per user" 'lastlog 2>/dev/null | grep -v "Never logged in"'

# =========================================================== 7. Services ====
section "7. Services"
if has systemctl; then
  run "Running services" 'systemctl list-units --type=service --state=running --no-pager --no-legend'
  run "Enabled unit files" 'systemctl list-unit-files --state=enabled --no-pager --no-legend'
  run "Failed units" 'systemctl --failed --no-pager --no-legend'
  sub "Custom / locally defined systemd units"
  custom=0
  for f in /etc/systemd/system/*.service /etc/systemd/system/*.timer \
           /etc/systemd/system/*.socket /etc/systemd/system/*.path \
           /etc/systemd/system/*.mount /etc/systemd/system/*.d/*.conf; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    custom=1; show_file "$f"
  done
  while IFS=: read -r u h; do
    for f in "$h"/.config/systemd/user/*.service "$h"/.config/systemd/user/*.timer; do
      [ -f "$f" ] && [ ! -L "$f" ] && { custom=1; show_file "$f"; }
    done
  done <<<"$USER_HOMES"
  [ "$custom" = 0 ] && para "_None found._"
else
  has service    && run "Services (SysV)" 'service --status-all'
  has rc-status  && run "Services (OpenRC)" 'rc-status -a'
fi

# ===================================================== 8. Web / proxy ====
section "8. Web servers & reverse proxies"
web=0
if has nginx || [ -d /etc/nginx ]; then
  web=1; DETECTED+=("Web server: nginx")
  run "nginx version" 'nginx -v'
  if nginx -T >/dev/null 2>&1; then
    run "nginx full effective config" 'nginx -T'
  else
    show_files /etc/nginx/nginx.conf /etc/nginx/conf.d/*.conf /etc/nginx/sites-enabled/* /etc/nginx/streams-enabled/*
  fi
fi
if has apache2ctl || has apachectl || has httpd || [ -d /etc/apache2 ] || [ -d /etc/httpd ]; then
  web=1; DETECTED+=("Web server: Apache")
  ACTL=$(command -v apache2ctl || command -v apachectl || echo "")
  [ -n "$ACTL" ] && run "Apache vhosts" "$ACTL -S" && run "Apache modules" "$ACTL -M"
  show_files --nc /etc/apache2/apache2.conf /etc/apache2/ports.conf /etc/apache2/sites-enabled/* \
                  /etc/apache2/conf-enabled/*.conf /etc/httpd/conf/httpd.conf /etc/httpd/conf.d/*.conf
fi
if has caddy || [ -d /etc/caddy ]; then
  web=1; DETECTED+=("Web server: Caddy")
  has caddy && run "Caddy version" 'caddy version'
  show_files /etc/caddy/Caddyfile /etc/caddy/*.json
fi
if has haproxy || [ -f /etc/haproxy/haproxy.cfg ]; then
  web=1; DETECTED+=("Proxy: HAProxy")
  show_file /etc/haproxy/haproxy.cfg nc
fi
if has traefik || [ -d /etc/traefik ]; then
  web=1; DETECTED+=("Proxy: Traefik")
  show_files /etc/traefik/*.yml /etc/traefik/*.yaml /etc/traefik/*.toml
fi
show_files --nc /etc/php/*/fpm/pool.d/*.conf /etc/php-fpm.d/*.conf
[ "$web" = 0 ] && para "_No host-installed web server found (check the Docker section for containerised ones)._"

cert_paths() {
  {
    ls /etc/letsencrypt/live/*/cert.pem 2>/dev/null
    has nginx && nginx -T 2>/dev/null | awk '$1=="ssl_certificate"{gsub(";","",$2); print $2}'
    grep -rhiE '^[[:space:]]*SSLCertificateFile' /etc/apache2 /etc/httpd 2>/dev/null | awk '{print $2}'
  } | grep -v '\$' | sort -u
}
cert_info() {
  local c
  cert_paths | while read -r c; do
    [ -z "$c" ] && continue
    echo "== $c"
    if [ -r "$c" ]; then
      openssl x509 -in "$c" -noout -subject -issuer -enddate 2>&1 | sed 's/^/  /'
      openssl x509 -in "$c" -noout -ext subjectAltName 2>/dev/null | tail -n +2 | sed 's/^ */  SAN: /'
    else
      echo "  not readable"
    fi
  done
}
if has openssl && [ -n "$(cert_paths)" ]; then
  sub "TLS certificates"
  run "Certificates in use (subject, issuer, expiry)" cert_info
  show_files /etc/letsencrypt/renewal/*.conf
fi

# ============================================================ 9. Docker ====
section "9. Containers & virtualization"
DOCKER_TPL='Image:          {{.Config.Image}}
State:          {{.State.Status}} (started {{.State.StartedAt}}, restart count {{.RestartCount}})
Restart policy: {{.HostConfig.RestartPolicy.Name}}
Ports:          {{range $p, $b := .NetworkSettings.Ports}}{{$p}}{{if $b}} -> {{range $b}}{{.HostIp}}:{{.HostPort}} {{end}}{{end}}; {{end}}
Networks:       {{range $n, $v := .NetworkSettings.Networks}}{{$n}} ({{$v.IPAddress}}) {{end}}
Entrypoint:     {{json .Config.Entrypoint}}
Command:        {{json .Config.Cmd}}
Compose:        project={{index .Config.Labels "com.docker.compose.project"}} service={{index .Config.Labels "com.docker.compose.service"}}
Mounts:{{range .Mounts}}
  - {{.Type}} {{if .Name}}{{.Name}} {{end}}{{.Source}} -> {{.Destination}} {{if .RW}}(rw){{else}}(ro){{end}}{{end}}
Environment:{{range .Config.Env}}
  {{.}}{{end}}'
docker_detail() { docker inspect --format "$DOCKER_TPL" "$1"; }

if has docker; then
  if t 15 docker info >/dev/null 2>&1; then
    run "Docker version" 'docker version --format "client {{.Client.Version}} / server {{.Server.Version}}"'
    run "Docker daemon" 'docker info 2>/dev/null | grep -E "^ ?(Server Version|Storage Driver|Logging Driver|Cgroup Driver|Docker Root Dir|Containers|Running|Paused|Stopped|Images|Swarm|Live Restore Enabled|Registry Mirrors)"'
    show_file /etc/docker/daemon.json
    run "Containers" 'docker ps -a --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"'
    run "Compose projects" 'docker compose ls -a 2>/dev/null || echo "docker compose plugin not available"'
    n_run=$(docker ps -q 2>/dev/null | wc -l); n_all=$(docker ps -aq 2>/dev/null | wc -l)
    DETECTED+=("Docker: $n_run running / $n_all total containers")

    while read -r c; do
      [ -z "$c" ] && continue
      sub "Container: $c"
      run "" "docker_detail $(printf %q "$c")"
    done <<<"$(docker ps -a --format '{{.Names}}' 2>/dev/null)"

    while IFS='|' read -r proj wd files; do
      [ -z "$proj" ] && continue
      sub "Compose project: $proj"
      para "Working directory: \`$wd\`"
      IFS=, read -ra flist <<<"$files"
      for f in "${flist[@]}"; do show_file "$f"; done
      show_files "$wd/.env" "$wd"/*.env
    done <<<"$(docker ps -a --format '{{.Label "com.docker.compose.project"}}|{{.Label "com.docker.compose.project.working_dir"}}|{{.Label "com.docker.compose.project.config_files"}}' 2>/dev/null | sort -u)"

    run "Networks" 'docker network ls'
    run "Volumes"  'docker volume ls'
    run "Images"   'docker images --format "table {{.Repository}}:{{.Tag}}\t{{.ID}}\t{{.Size}}\t{{.CreatedSince}}"'
    run "Disk usage" 'docker system df'
  else
    para "_Docker is installed but the daemon is not reachable (not running, or no permission)._"
    note "Docker daemon not accessible - re-run as root or as a member of the docker group"
  fi
fi

sub "Compose files found on disk"
compose_on_disk=$(find_apps 5 -type f \( -name docker-compose.yml -o -name docker-compose.yaml -o -name compose.yml -o -name compose.yaml \))
if [ -n "$compose_on_disk" ]; then
  while read -r f; do
    show_file "$f"
    show_files "$(dirname "$f")/.env"
  done <<<"$compose_on_disk"
else
  para "_None found._"
fi

has podman  && run "Podman containers" 'podman ps -a'
has kubectl && run "Kubernetes" 'timeout 20 kubectl get nodes -o wide; timeout 20 kubectl get pods -A -o wide'
has virsh   && run "libvirt VMs" 'virsh list --all'
has lxc     && run "LXD/LXC" 'lxc list'

# ========================================================= 10. Databases ====
section "10. Databases"
db=0
if proc_running 'postgres|postmaster' || has psql; then
  db=1; DETECTED+=("Database: PostgreSQL")
  has psql && run "psql version" 'psql --version'
  if [ "$IS_ROOT" = 1 ] && id postgres >/dev/null 2>&1; then
    pg() { (cd /tmp && if has runuser; then runuser -u postgres -- psql -X -At "$@"; else su -s /bin/sh postgres -c "psql -X -At $(printf '%q ' "$@")"; fi); }
    pg_server() { for s in data_directory config_file hba_file listen_addresses port max_connections shared_buffers; do printf '%-18s %s\n' "$s" "$(t 10 pg -c "show $s" 2>&1)"; done; t 10 pg -c "select version()"; }
    pg_dbs()   { t 10 pg -c "select datname, pg_size_pretty(pg_database_size(datname)) from pg_database where not datistemplate"; }
    pg_roles() { t 10 pg -c "select rolname, rolsuper, rolcanlogin from pg_roles where rolname !~ '^pg_'"; }
    run "PostgreSQL server settings" pg_server
    run "PostgreSQL databases (name|size)" pg_dbs
    run "PostgreSQL roles (name|superuser|login)" pg_roles
    show_file "$(t 10 pg -c 'show config_file' 2>/dev/null)" nc
    show_file "$(t 10 pg -c 'show hba_file' 2>/dev/null)" nc
  fi
  show_files --nc /etc/postgresql/*/*/postgresql.conf /etc/postgresql/*/*/pg_hba.conf /etc/postgresql/*/*/conf.d/*.conf
fi
if proc_running 'mysqld|mariadbd' || has mysql; then
  db=1; DETECTED+=("Database: MySQL/MariaDB")
  run "MySQL/MariaDB client version" 'mysql --version'
  if [ "$IS_ROOT" = 1 ]; then
    mysql_info() { t 15 mysql --connect-timeout=5 -e "SELECT VERSION(); SHOW DATABASES; SELECT user, host FROM mysql.user;"; }
    run "Databases and users" mysql_info
  fi
  show_files --nc /etc/mysql/my.cnf /etc/mysql/*.cnf /etc/mysql/conf.d/*.cnf /etc/mysql/mysql.conf.d/*.cnf \
                  /etc/mysql/mariadb.conf.d/*.cnf /etc/my.cnf /etc/my.cnf.d/*.cnf /root/.my.cnf
fi
if proc_running 'redis-server' || has redis-server; then
  db=1; DETECTED+=("Database: Redis")
  has redis-server && run "Redis version" 'redis-server --version'
  has redis-cli && run "Redis info" 'timeout 5 redis-cli INFO server | grep -E "redis_version|tcp_port|config_file|uptime_in_days"; timeout 5 redis-cli INFO keyspace'
  show_files --nc /etc/redis/redis.conf /etc/redis.conf /etc/redis/*.conf
fi
if proc_running 'mongod' || has mongod; then
  db=1; DETECTED+=("Database: MongoDB")
  has mongod && run "MongoDB version" 'mongod --version | head -3'
  show_file /etc/mongod.conf nc
fi
run "Other data / messaging services (processes)" \
  'ps -eo user,pid,args | grep -Ei "elasticsearch|opensearch|rabbitmq|memcached|influxd|clickhouse|etcd|minio|mosquitto|kafka|zookeeper|cassandra|nats-server|meilisearch|qdrant" | grep -v grep | cut -c1-250 || echo none'
[ "$db" = 0 ] && para "_No host-installed database found (check the Docker section for containerised ones)._"

# ======================================================= 11. Applications ====
section "11. Applications"
run "Top processes by memory" 'ps -eo user,pid,ppid,%cpu,%mem,etime,args --sort=-%mem | head -40 | cut -c1-250'
runtimes() {
  local c
  for c in python3 python node npm java go php ruby dotnet; do
    has "$c" || continue
    printf '%-8s ' "$c"
    case "$c" in
      java)   java -version 2>&1 | head -1 ;;
      go)     go version ;;
      dotnet) dotnet --version ;;
      *)      "$c" --version 2>&1 | head -1 ;;
    esac
  done
}
run "Language runtimes" runtimes
if has supervisorctl; then
  run "Supervisor programs" 'supervisorctl status'
fi
show_files --nc /etc/supervisor/supervisord.conf /etc/supervisor/conf.d/* /etc/supervisord.conf /etc/supervisord.d/*
run "PM2 daemons" 'ps -eo user,pid,args | grep -E "PM2 v[0-9]" | grep -v grep || echo none'
while IFS=: read -r u h; do show_files "$h/ecosystem.config.js"; done <<<"$USER_HOMES"
has uwsgi && show_files --nc /etc/uwsgi/apps-enabled/*

app_dirs() {
  local d
  for d in /opt /srv /var/www /usr/local/src /data /app /apps; do [ -d "$d" ] && { echo "== $d"; ls -la "$d"; }; done
  while IFS=: read -r u h; do [ -d "$h" ] && { echo "== $h ($u)"; ls -la "$h"; }; done <<<"$USER_HOMES"
}
run "Application / home directories" app_dirs

git_repos() {
  [ ${#ROOTS[@]} -eq 0 ] && return 0
  local g d
  find "${ROOTS[@]}" -maxdepth 5 \( -name node_modules -o -name .cache \) -prune -o -type d -name .git -print -prune 2>/dev/null |
  while read -r g; do
    d=${g%/.git}
    echo "== $d"
    git -c safe.directory='*' --no-optional-locks -C "$d" remote -v 2>&1 | sed 's/^/  remote: /'
    echo "  branch: $(git -c safe.directory='*' --no-optional-locks -C "$d" rev-parse --abbrev-ref HEAD 2>&1)"
    echo "  commit: $(git -c safe.directory='*' --no-optional-locks -C "$d" log -1 --format='%h %ci %an: %s' 2>&1)"
    echo "  uncommitted changes: $(git -c safe.directory='*' --no-optional-locks -C "$d" status --porcelain 2>/dev/null | wc -l) file(s)"
  done
}
has git && run "Git checkouts (deployed code)" git_repos

sub "Environment files (.env)"
env_files=$(find_apps 5 -type f \( -name '.env' -o -name '.env.*' -o -name '*.env' \) | head -60)
if [ -n "$env_files" ]; then
  while read -r f; do show_file "$f"; done <<<"$env_files"
else
  para "_None found._"
fi
run "Other likely app config files (paths only)" \
  "find_apps 5 -type f \\( -name 'settings.py' -o -name 'application*.yml' -o -name 'application*.properties' -o -name 'appsettings*.json' -o -name 'config.json' -o -name 'config.yml' -o -name 'config.yaml' -o -name 'ecosystem.config.js' -o -name 'wp-config.php' \\) | head -100"

# ==================================================== 12. Scheduled jobs ====
section "12. Scheduled jobs"
show_file /etc/crontab nc
show_files --nc /etc/cron.d/*
run "cron.hourly / daily / weekly / monthly" 'ls -l /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly 2>/dev/null'
user_crontabs() {
  local u c
  if [ "$IS_ROOT" = 1 ]; then
    for u in $(cut -d: -f1 /etc/passwd); do
      c=$(crontab -l -u "$u" 2>/dev/null | grep -vE '^[[:space:]]*(#|$)')
      [ -n "$c" ] && { echo "== $u"; echo "$c"; echo; }
    done
  else
    echo "== $(id -un) (only own crontab visible without root)"
    crontab -l 2>&1
  fi
}
run "User crontabs" user_crontabs
has systemctl && run "systemd timers" 'systemctl list-timers --all --no-pager'
show_file /etc/anacrontab nc
has atq && run "at jobs" 'atq'

# ================================================= 13. Backups & logging ====
section "13. Backups & logging"
backup_tools() {
  local c
  for c in restic borg borgmatic rsnapshot duplicity duplicati rclone kopia pgbackrest barman autorestic rdiff-backup bacula-fd urbackupclientctl rsync; do
    has "$c" && echo "$c: $(command -v "$c")"
  done
}
run "Backup tools installed" backup_tools
show_files --nc /etc/borgmatic/config.yaml /etc/borgmatic.d/*.yaml /etc/rsnapshot.conf /etc/restic/* \
                /etc/autorestic.yml /etc/pgbackrest.conf /etc/pgbackrest/pgbackrest.conf
while IFS=: read -r u h; do show_files "$h/.config/rclone/rclone.conf" "$h/.autorestic.yml"; done <<<"$USER_HOMES"
run "Cron/systemd files mentioning backups or dumps" \
  'grep -rliE "backup|restic|borg|rclone|pg_dump|pg_basebackup|mysqldump|mariadb-dump|mongodump|rsnapshot|duplicity" /etc/crontab /etc/cron.d /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly /var/spool/cron /etc/systemd/system 2>/dev/null || echo none'
sub "Backup scripts"
bk_scripts=$(for d in /usr/local/bin /usr/local/sbin /opt /root /home /srv /etc/cron.daily /etc/cron.weekly; do
  [ -d "$d" ] && find "$d" -maxdepth 3 -type f \( -iname '*backup*' -o -iname '*dump*' -o -iname '*snapshot*' \) -size -200k 2>/dev/null
done | head -30)
if [ -n "$bk_scripts" ]; then
  while read -r f; do show_file "$f"; done <<<"$bk_scripts"
else
  para "_None found by name._"
fi

sub "Logging"
show_files --nc /etc/systemd/journald.conf /etc/systemd/journald.conf.d/*.conf
has journalctl && run "Journal disk usage" 'journalctl --disk-usage'
show_files --nc /etc/rsyslog.conf /etc/rsyslog.d/*.conf
show_file /etc/logrotate.conf nc
run "logrotate.d entries" 'ls -l /etc/logrotate.d'
show_files --nc /etc/logrotate.d/*
run "/var/log size (largest items)" 'du -sh /var/log 2>/dev/null; du -ah /var/log 2>/dev/null | sort -rh | head -15'
run "Monitoring / log shipping agents (processes)" \
  'ps -eo user,pid,args | grep -Ei "promtail|alloy|fluent|filebeat|vector|telegraf|node_exporter|zabbix|netdata|datadog|newrelic|prometheus|grafana|uptime-kuma|wazuh|crowdsec" | grep -v grep | cut -c1-250 || echo none'

# ========================================================== 14. Packages ====
section "14. Packages"
if has apt-mark; then
  run "Manually installed packages (apt)" 'apt-mark showmanual'
  run "Held packages" 'apt-mark showhold'
  show_files /etc/apt/sources.list /etc/apt/sources.list.d/*
  show_files --nc /etc/apt/apt.conf.d/20auto-upgrades /etc/apt/apt.conf.d/50unattended-upgrades
  run "Pending upgrades (from local cache)" 'apt list --upgradable 2>/dev/null | head -80'
fi
if has dnf; then
  run "User-installed packages (dnf)" 'dnf -C -q repoquery --userinstalled 2>/dev/null || dnf history userinstalled'
  show_files --nc /etc/yum.repos.d/*.repo
elif has yum; then
  run "Installed packages (yum)" 'yum -C list installed'
  show_files --nc /etc/yum.repos.d/*.repo
fi
has apk    && show_files /etc/apk/world /etc/apk/repositories
has pacman && run "Explicitly installed (pacman)" 'pacman -Qe'
has snap    && run "Snaps" 'snap list'
has flatpak && run "Flatpaks" 'flatpak list'
has pip3    && run "System-wide Python packages" 'pip3 list 2>/dev/null | head -150'
has npm     && run "Global npm packages" 'npm -g ls --depth=0 2>/dev/null'
run "Binaries in /usr/local" 'ls -l /usr/local/bin /usr/local/sbin 2>/dev/null'
run "Reboot required?" 'if [ -f /var/run/reboot-required ]; then cat /var/run/reboot-required /var/run/reboot-required.pkgs 2>/dev/null; else echo no; fi'

# ===================================================== 15. Kernel tuning ====
section "15. Kernel & security tuning"
run "Kernel command line" 'cat /proc/cmdline'
show_file /etc/default/grub nc
show_files --nc /etc/sysctl.conf /etc/sysctl.d/*.conf
run "Key sysctl values" 'sysctl net.ipv4.ip_forward net.ipv6.conf.all.forwarding vm.swappiness vm.overcommit_memory vm.max_map_count fs.file-max fs.inotify.max_user_watches net.core.somaxconn net.ipv4.tcp_syncookies kernel.panic 2>/dev/null'
show_files --nc /etc/modules /etc/modules-load.d/*.conf /etc/modprobe.d/*.conf
show_files --nc /etc/security/limits.conf /etc/security/limits.d/*.conf
run "Transparent huge pages" 'cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo n/a'
has getenforce && run "SELinux" 'getenforce; sestatus 2>/dev/null'
has aa-status  && run "AppArmor" 'aa-status 2>&1 | head -15'

# ============================================================== assemble ====
echo "[*] Writing report" >&2

port_rows() {
  ss -tulpn 2>/dev/null | awk 'NR>1 {n="?"; if (match($7, /"[^"]+"/)) n=substr($7, RSTART+1, RLENGTH-2); print "| " $1 " | " $5 " | " n " |"}' | sort -u
}

OS_NAME=$( (. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME") || uname -s)
IPS=$(hostname -I 2>/dev/null || ip -4 -br addr 2>/dev/null | awk '{print $3}' | tr '\n' ' ')
MEM=$(free -h 2>/dev/null | awk '/^Mem:/{print $2}')
ROOTFS=$(df -h / 2>/dev/null | awk 'NR==2{print $3 " used of " $2 " (" $5 ")"}')

{
  echo "# Server configuration: $HOST"
  echo
  echo "_Generated $(date '+%Y-%m-%d %H:%M:%S %Z') by cock-inspector.sh v$VERSION, run as \`$(id -un)\`$([ "$IS_ROOT" = 1 ] && echo ' (root)' || echo ' (NOT root - incomplete)')._"
  echo
  if [ "$REDACT" = 1 ]; then
    echo "> Secrets matching common patterns were redacted. Review before sharing anyway."
  else
    echo "> **WARNING: this document contains secrets** (passwords, tokens, keys) copied from"
    echo "> configuration and .env files. Store it encrypted; do not commit or share it."
  fi
  echo
  echo "## Summary"
  echo
  echo "| Item | Value |"
  echo "|---|---|"
  echo "| Hostname | $HOST |"
  echo "| OS | $OS_NAME |"
  echo "| Kernel | $(uname -r) |"
  echo "| IP addresses | $IPS |"
  echo "| CPUs / RAM | $(nproc 2>/dev/null) / $MEM |"
  echo "| Root filesystem | $ROOTFS |"
  for d in "${DETECTED[@]}"; do
    echo "| ${d%%:*} | ${d#*: } |"
  done
  echo
  echo "### Listening ports"
  echo
  echo "| Proto | Local address | Process |"
  echo "|---|---|---|"
  port_rows
  echo
  echo "_\"docker-proxy\" ports belong to containers - see section 9. \"?\" = process not visible (run as root)._"
  cat "$BODY"
  echo
  echo "## Could not collect"
  echo
  if [ ${#WARN[@]} -eq 0 ]; then
    echo "_Nothing - all checks ran._"
  else
    printf '%s\n' "${WARN[@]}" | sort -u | sed 's/^/- /'
  fi
} >"$OUT"

chmod 600 "$OUT" 2>/dev/null
echo "Done: $OUT ($(wc -c <"$OUT" | tr -d ' ') bytes, ${#WARN[@]} item(s) could not be collected)" >&2
