#!/usr/bin/env bash
# =============================================================================
# install.sh · rocket code · Servidor DevSecOps 100% open source (costo $0 en licencias)
#
# Instala en UN servidor Linux propio (EC2, VM de Azure/GCP u on-prem):
#   - SonarQube Community Build (+ PostgreSQL)        LGPL
#   - DefectDojo (compose oficial)                     BSD-3
#   - Jenkins LTS como CI (JCasC + Job DSL)            MIT
#   - Caddy como proxy HTTPS con Let's Encrypt         Apache-2.0
#   - Docker Engine                                    Apache-2.0
# y deja listo el escaneo (Opengrep, Trivy, ZAP) que corre en Jenkins.
# No usa servicios de pago de ninguna nube.
#
# Uso (en el servidor, Ubuntu 22.04/24.04):
#   sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/TheRocketCodeMX/SAST-DAST-Scan/main/server/install.sh)"
# Idempotente: se puede volver a correr.
# =============================================================================
set -uo pipefail

KIT_RAW="${KIT_RAW:-https://raw.githubusercontent.com/TheRocketCodeMX/SAST-DAST-Scan/main}"
BASE=/opt/devsecops
ENVF="$BASE/.env"

azul()  { printf '\033[1;34m%s\033[0m\n' "$*"; }
ok()    { printf '\033[1;32m  OK  \033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m  !!  \033[0m %s\n' "$*"; }
fail()  { printf '\033[1;31m  XX  \033[0m %s\n' "$*"; exit 1; }
ask()   { local v; read -r -p "  $1${2:+ [$2]}: " v; printf '%s' "${v:-${2:-}}"; }
rnd()   { openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c "${1:-24}"; }
setenv(){ # setenv CLAVE valor  -> guarda/actualiza en .env
  touch "$ENVF"; chmod 600 "$ENVF"
  if grep -q "^$1=" "$ENVF"; then sed -i "s|^$1=.*|$1=$2|" "$ENVF"; else echo "$1=$2" >> "$ENVF"; fi
}
getenv(){ grep -s "^$1=" "$ENVF" | head -1 | cut -d= -f2-; }

[ "$(id -u)" = 0 ] || fail 'Ejecuta como root: sudo bash -c "$(curl -fsSL .../server/install.sh)"'
[ -t 0 ] || fail 'Este instalador es interactivo. Usa: sudo bash -c "$(curl -fsSL .../server/install.sh)"'
. /etc/os-release 2>/dev/null
case "${ID:-}" in ubuntu|debian) ;; *) warn "Probado en Ubuntu/Debian; detectado '${ID:-?}'. Continuo bajo tu riesgo." ;; esac

clear
azul "=============================================================="
azul "  rocket code · servidor DevSecOps open source"
azul "=============================================================="
echo

# ---------------------------------------------------------------- 0. datos
azul "0/7  Datos"
mkdir -p "$BASE"
DOMAIN_DEF="$(getenv DOMAIN)"
if [ -z "$DOMAIN_DEF" ]; then
  IP="$(curl -fsS -4 --max-time 10 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]')"
  [ -n "$IP" ] && DOMAIN_DEF="$(echo "$IP" | tr . -).sslip.io"
fi
echo "  Se publicaran sonar.<dominio>, dojo.<dominio> y ci.<dominio>."
echo "  Si no tienes dominio, deja el valor sugerido (sslip.io, gratis)."
DOMAIN=$(ask "Dominio base" "$DOMAIN_DEF")
[ -n "$DOMAIN" ] || fail "El dominio es obligatorio"
EMAIL=$(ask "Correo para el certificado HTTPS (Let's Encrypt)" "$(getenv ACME_EMAIL)")
[ -n "$EMAIL" ] || fail "El correo es obligatorio"
setenv DOMAIN "$DOMAIN"; setenv ACME_EMAIL "$EMAIL"; setenv KIT_RAW "$KIT_RAW"
[ -n "$(getenv SONAR_ADMIN_PASSWORD)" ]  || setenv SONAR_ADMIN_PASSWORD "$(rnd 20)Aa1!"
[ -n "$(getenv JENKINS_ADMIN_PASSWORD)" ] || setenv JENKINS_ADMIN_PASSWORD "$(rnd 20)"
[ -n "$(getenv SONAR_DB_PASSWORD)" ]      || setenv SONAR_DB_PASSWORD "$(rnd 24)"
[ -n "$(getenv DOJO_ADMIN_PASSWORD)" ]    || setenv DOJO_ADMIN_PASSWORD "$(rnd 22)"
[ -n "$(getenv DD_SECRET_KEY)" ]          || setenv DD_SECRET_KEY "$(rnd 50)"
[ -n "$(getenv DD_CREDENTIAL_AES_256_KEY)" ] || setenv DD_CREDENTIAL_AES_256_KEY "$(rnd 32)"
[ -n "$(getenv FAIL_ON_HIGH)" ]           || setenv FAIL_ON_HIGH false
[ -n "$(getenv ZAP_MODE)" ]               || setenv ZAP_MODE baseline
echo

# ---------------------------------------------------------------- 1. sistema
azul "1/7  Sistema y Docker"
apt-get update -qq >/dev/null && apt-get install -y -qq curl git jq openssl ca-certificates >/dev/null || fail "apt-get fallo"
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh >/dev/null 2>&1 || fail "No se pudo instalar Docker"
fi
systemctl enable --now docker >/dev/null 2>&1
docker compose version >/dev/null 2>&1 || fail "Falta el plugin docker compose"
ok "$(docker --version)"
# SonarQube (Elasticsearch) necesita estos limites
cat > /etc/sysctl.d/99-sonarqube.conf <<'EOF'
vm.max_map_count=524288
fs.file-max=131072
EOF
sysctl -q --system >/dev/null 2>&1
ok "sysctl para SonarQube"
docker network inspect devsecops >/dev/null 2>&1 || docker network create devsecops >/dev/null
ok "red docker 'devsecops'"
echo

# ---------------------------------------------------------------- 2. archivos
azul "2/7  Archivos en $BASE"
mkdir -p "$BASE/jenkins" "$BASE/secrets"
touch "$BASE/repos.txt"

cat > "$BASE/docker-compose.yml" <<'EOF'
# rocket code · DevSecOps OSS · generado por install.sh
services:
  caddy:
    image: caddy:2
    restart: unless-stopped
    ports: ["80:80", "443:443"]
    environment:
      DOMAIN: ${DOMAIN}
      ACME_EMAIL: ${ACME_EMAIL}
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config

  sonar-db:
    image: postgres:16
    restart: unless-stopped
    environment:
      POSTGRES_USER: sonar
      POSTGRES_PASSWORD: ${SONAR_DB_PASSWORD}
      POSTGRES_DB: sonar
    volumes: [sonar_db:/var/lib/postgresql/data]

  sonarqube:
    image: sonarqube:community
    restart: unless-stopped
    depends_on: [sonar-db]
    environment:
      SONAR_JDBC_URL: jdbc:postgresql://sonar-db:5432/sonar
      SONAR_JDBC_USERNAME: sonar
      SONAR_JDBC_PASSWORD: ${SONAR_DB_PASSWORD}
    ulimits:
      nofile: {soft: 131072, hard: 131072}
    volumes:
      - sonar_data:/opt/sonarqube/data
      - sonar_ext:/opt/sonarqube/extensions
      - sonar_logs:/opt/sonarqube/logs

  jenkins:
    build: ./jenkins
    image: rocketcode/devsecops-jenkins:lts
    restart: unless-stopped
    user: root
    environment:
      CASC_JENKINS_CONFIG: /var/jenkins_home/devsecops/casc.yaml
      JAVA_OPTS: -Djenkins.install.runSetupWizard=false
    volumes:
      - jenkins_home:/var/jenkins_home
      - ./jenkins:/var/jenkins_home/devsecops:ro
      - ./secrets:/run/secrets:ro
      - /var/run/docker.sock:/var/run/docker.sock

volumes:
  caddy_data: {}
  caddy_config: {}
  sonar_db: {}
  sonar_data: {}
  sonar_ext: {}
  sonar_logs: {}
  jenkins_home: {}

networks:
  default:
    name: devsecops
    external: true
EOF

cat > "$BASE/Caddyfile" <<'EOF'
{
	email {$ACME_EMAIL}
}
sonar.{$DOMAIN} {
	reverse_proxy sonarqube:9000
}
dojo.{$DOMAIN} {
	reverse_proxy defectdojo:8080
}
ci.{$DOMAIN} {
	reverse_proxy jenkins:8080
}
EOF

cat > "$BASE/jenkins/Dockerfile" <<'EOF'
FROM docker:27-cli AS dockercli
FROM jenkins/jenkins:lts-jdk21
USER root
COPY --from=dockercli /usr/local/bin/docker /usr/local/bin/docker
RUN apt-get update && apt-get install -y --no-install-recommends jq curl git && rm -rf /var/lib/apt/lists/*
RUN jenkins-plugin-cli --plugins configuration-as-code job-dsl workflow-aggregator git credentials-binding timestamper
EOF

ok "docker-compose.yml, Caddyfile y Dockerfile de Jenkins"
echo

# ---------------------------------------------------------------- 3. DefectDojo
azul "3/7  DefectDojo"
if [ ! -d "$BASE/defectdojo/.git" ]; then
  git clone -q --depth 1 https://github.com/DefectDojo/django-DefectDojo.git "$BASE/defectdojo" || fail "No se pudo clonar DefectDojo"
fi
cat > "$BASE/defectdojo/.env" <<EOF
DD_SECRET_KEY=$(getenv DD_SECRET_KEY)
DD_CREDENTIAL_AES_256_KEY=$(getenv DD_CREDENTIAL_AES_256_KEY)
EOF
cat > "$BASE/defectdojo/docker-compose.override.yml" <<EOF
# rocket code · solo local + red devsecops (Caddy publica HTTPS)
services:
  nginx:
    ports: !override
      - "127.0.0.1:8080:8080"
    networks:
      default: {}
      devsecops:
        aliases: [defectdojo]
  uwsgi:
    environment:
      DD_ALLOWED_HOSTS: "*"
      DD_CSRF_TRUSTED_ORIGINS: "https://dojo.$DOMAIN"
      DD_SECURE_PROXY_SSL_HEADER: "True"
  initializer:
    environment:
      DD_ADMIN_PASSWORD: "$(getenv DOJO_ADMIN_PASSWORD)"
networks:
  devsecops:
    external: true
EOF
chmod 600 "$BASE/defectdojo/.env" "$BASE/defectdojo/docker-compose.override.yml"
(cd "$BASE/defectdojo" && docker compose pull -q >/dev/null 2>&1 && docker compose up -d --no-build >/dev/null 2>&1) || fail "DefectDojo no arranco (revisa: cd $BASE/defectdojo && docker compose logs)"
ok "DefectDojo arrancando (la primera vez tarda varios minutos)"
echo

# ---------------------------------------------------------------- 4. SonarQube + Caddy
azul "4/7  SonarQube y HTTPS"
cd "$BASE" || exit 1
docker compose up -d caddy sonar-db sonarqube >/dev/null 2>&1 || fail "No arrancaron SonarQube/Caddy (docker compose logs)"
SQ="docker run --rm --network devsecops curlimages/curl:latest -fsS"
printf '  esperando a SonarQube'
for _ in $(seq 1 90); do
  st=$($SQ http://sonarqube:9000/api/system/status 2>/dev/null | jq -r .status 2>/dev/null)
  [ "$st" = "UP" ] && break; printf '.'; sleep 10
done; echo
[ "$st" = "UP" ] || fail "SonarQube no respondio (docker compose logs sonarqube)"
SQPASS="$(getenv SONAR_ADMIN_PASSWORD)"
if $SQ -u admin:admin -X POST "http://sonarqube:9000/api/users/change_password" \
     --data-urlencode login=admin --data-urlencode previousPassword=admin --data-urlencode "password=$SQPASS" >/dev/null 2>&1; then
  ok "contrasena de admin de SonarQube cambiada"
fi
if [ -z "$(getenv SONAR_TOKEN)" ]; then
  TK=$($SQ -u "admin:$SQPASS" -X POST "http://sonarqube:9000/api/user_tokens/generate" \
        --data-urlencode "name=jenkins-$(date +%s)" --data-urlencode type=GLOBAL_ANALYSIS_TOKEN | jq -r .token)
  [ -n "$TK" ] && [ "$TK" != null ] || fail "No se pudo generar el token de SonarQube"
  setenv SONAR_TOKEN "$TK"
fi
ok "token de analisis de SonarQube"
echo

# ---------------------------------------------------------------- 5. token DefectDojo
azul "5/7  Token de DefectDojo"
if [ -z "$(getenv DOJO_API_KEY)" ]; then
  printf '  esperando a DefectDojo'
  for _ in $(seq 1 60); do
    K=$(curl -fsS -X POST http://127.0.0.1:8080/api/v2/api-token-auth/ \
        -d "username=admin" --data-urlencode "password=$(getenv DOJO_ADMIN_PASSWORD)" 2>/dev/null | jq -r .token 2>/dev/null)
    [ -n "$K" ] && [ "$K" != null ] && break; printf '.'; sleep 10
  done; echo
  [ -n "${K:-}" ] && [ "$K" != null ] || fail "No se pudo obtener la API key de DefectDojo"
  setenv DOJO_API_KEY "$K"
fi
ok "API key de DefectDojo"
echo

# ---------------------------------------------------------------- 6. Jenkins
azul "6/7  Jenkins (CI)"
curl -fsSL "$KIT_RAW/server/devsecops" -o /usr/local/bin/devsecops && chmod +x /usr/local/bin/devsecops \
  || fail "No se pudo descargar el comando devsecops"
/usr/local/bin/devsecops apply || fail "No se pudo configurar Jenkins"
echo

# ---------------------------------------------------------------- 7. primer repo
azul "7/7  Repositorios a escanear"
if [ ! -s "$BASE/repos.txt" ] || ! grep -qv '^#' "$BASE/repos.txt"; then
  read -r -p "  ¿Agregar ahora el primer repositorio? [s/N]: " v
  [[ "$v" =~ ^[sSyY] ]] && /usr/local/bin/devsecops add-repo
fi
echo
/usr/local/bin/devsecops status
