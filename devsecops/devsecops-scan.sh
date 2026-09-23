#!/usr/bin/env bash
# =============================================================================
# devsecops-scan.sh · rocket code · DevSecOps 100% open source, portable
#   SAST: Opengrep (seguridad) + SonarQube Community Build (calidad/hotspots)
#   SCA : Trivy (dependencias, secretos, IaC)
#   DAST: ZAP (baseline | full | api) contra staging
#   Gestion: DefectDojo (import automatico de hallazgos)
#
# Corre igual en Azure Pipelines, AWS CodeBuild, GCP Cloud Build, GitHub
# Actions, GitLab CI, Jenkins, Bitbucket Pipelines.
#
# Uso:  bash devsecops/devsecops-scan.sh [opengrep] [sonar] [trivy] [zap] [report]
#       (sin argumentos corre todo, en ese orden)
#
# Requiere en la maquina/agente: bash, docker, git, curl, tar (jq se descarga
# solo si falta en Linux). Las herramientas corren en contenedores con
# "docker create + docker cp", sin montar volumenes, para que funcione tambien
# con docker-in-docker (Cloud Build, GitLab dind, Bitbucket).
#
# Configuracion por variables de entorno (todas opcionales):
#   SONAR_HOST_URL, SONAR_TOKEN        si faltan, se omite SonarQube
#   DOJO_URL, DOJO_API_KEY             si faltan, se omite DefectDojo
#   DAST_TARGET_URL                    si falta, se omite ZAP
#   ZAP_MODE=baseline|full|api   ZAP_API_SPEC=<url openapi>
#   FAIL_ON_HIGH=false|true      SONAR_BRANCHES="main"   DAST_ON_PR=false
#   OPENGREP_VERSION=""  OPENGREP_RULES_DIRS="java javascript ..."
#   TRIVY_IMAGE  ZAP_IMAGE  SONAR_IMAGE  DOCKER_NETWORK (p. ej. cloudbuild)
#   APP_NAME BRANCH COMMIT BUILD_ID IS_PR   (se detectan del CI si no se dan)
#   SRC_DIR=. OUT_DIR=./devsecops-reports
# =============================================================================
set -uo pipefail

# ------------------------------------------------------------------ defaults
SRC_DIR="${SRC_DIR:-.}"
SRC_DIR="$(cd "$SRC_DIR" && pwd)" || { echo "SRC_DIR invalido"; exit 2; }
OUT_DIR="${OUT_DIR:-$SRC_DIR/devsecops-reports}"
FAIL_ON_HIGH="${FAIL_ON_HIGH:-false}"
ZAP_MODE="${ZAP_MODE:-baseline}"
ZAP_API_SPEC="${ZAP_API_SPEC:-}"
DAST_ON_PR="${DAST_ON_PR:-false}"
SONAR_BRANCHES="${SONAR_BRANCHES:-main}"
OPENGREP_VERSION="${OPENGREP_VERSION:-}"
OPENGREP_RULES_DIRS="${OPENGREP_RULES_DIRS:-java javascript typescript python csharp go php generic dockerfile}"
# Trivy: FIJA una version verificada (evita 0.69.4 a 0.69.6, advisory GHSA-69fq-xp46-6x23)
TRIVY_IMAGE="${TRIVY_IMAGE:-aquasec/trivy:0.69.3}"
ZAP_IMAGE="${ZAP_IMAGE:-ghcr.io/zaproxy/zaproxy:stable}"
SONAR_IMAGE="${SONAR_IMAGE:-sonarsource/sonar-scanner-cli}"
DOJO_PRODUCT_TYPE="${DOJO_PRODUCT_TYPE:-Aplicaciones}"
SONAR_HOST_URL="${SONAR_HOST_URL:-}"; SONAR_TOKEN="${SONAR_TOKEN:-}"
DOJO_URL="${DOJO_URL:-}";             DOJO_API_KEY="${DOJO_API_KEY:-}"
DAST_TARGET_URL="${DAST_TARGET_URL:-}"
DOCKER_NETWORK="${DOCKER_NETWORK:-}"
EXCLUDES="node_modules vendor dist build target devsecops-reports"

# ------------------------------------------------------------------ logging
# Emite anotaciones nativas segun la plataforma (Azure, GitHub) o texto plano.
note() { echo "[devsecops] $*"; }
warn() {
  if [ -n "${TF_BUILD:-}" ]; then echo "##vso[task.logissue type=warning]$*"
  elif [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::warning::$*"
  else echo "[devsecops] ADVERTENCIA: $*"; fi
}
err() {
  if [ -n "${TF_BUILD:-}" ]; then echo "##vso[task.logissue type=error]$*"
  elif [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::error::$*"
  else echo "[devsecops] ERROR: $*" >&2; fi
}
section() { echo; echo "================ $* ================"; }

# ------------------------------------------------------------------ metadata CI
first() { for v in "$@"; do if [ -n "$v" ]; then printf '%s' "$v"; return; fi; done; }
git_try() { git -C "$SRC_DIR" "$@" 2>/dev/null || true; }

PLATFORM=local
[ -n "${TF_BUILD:-}" ]            && PLATFORM=azure
[ -n "${CODEBUILD_BUILD_ID:-}" ]  && PLATFORM=aws
[ -n "${CLOUD_BUILD:-}" ]         && PLATFORM=gcp
[ -n "${GITHUB_ACTIONS:-}" ]      && PLATFORM=github
[ -n "${GITLAB_CI:-}" ]           && PLATFORM=gitlab
[ -n "${JENKINS_URL:-}" ]         && PLATFORM=jenkins
[ -n "${BITBUCKET_BUILD_NUMBER:-}" ] && PLATFORM=bitbucket

AWS_REF="${CODEBUILD_WEBHOOK_HEAD_REF:-}"; AWS_REF="${AWS_REF#refs/heads/}"
BRANCH="$(first "${BRANCH:-}" "${BUILD_SOURCEBRANCHNAME:-}" "$AWS_REF" "${BRANCH_NAME:-}" \
  "${GITHUB_HEAD_REF:-}" "${GITHUB_REF_NAME:-}" "${CI_COMMIT_REF_NAME:-}" "${BITBUCKET_BRANCH:-}" \
  "${BRANCH_FALLBACK:-}" "$(git_try rev-parse --abbrev-ref HEAD)" "local")"
COMMIT="$(first "${COMMIT:-}" "${BUILD_SOURCEVERSION:-}" "${CODEBUILD_RESOLVED_SOURCE_VERSION:-}" \
  "${COMMIT_SHA:-}" "${GITHUB_SHA:-}" "${CI_COMMIT_SHA:-}" "${GIT_COMMIT:-}" "${BITBUCKET_COMMIT:-}" \
  "$(git_try rev-parse HEAD)")"
BUILD_ID="$(first "${BUILD_ID:-}" "${BUILD_BUILDNUMBER:-}" "${CODEBUILD_BUILD_NUMBER:-}" \
  "${GITHUB_RUN_NUMBER:-}" "${CI_PIPELINE_IID:-}" "${BUILD_NUMBER:-}" "${BITBUCKET_BUILD_NUMBER:-}" \
  "$(date +%Y%m%d%H%M%S)")"
AWS_REPO="${CODEBUILD_SOURCE_REPO_URL:-}"; AWS_REPO="${AWS_REPO%.git}"; AWS_REPO="${AWS_REPO##*/}"
GH_REPO="${GITHUB_REPOSITORY:-}"; GH_REPO="${GH_REPO##*/}"
APP_NAME="$(first "${APP_NAME:-}" "${BUILD_REPOSITORY_NAME:-}" "$AWS_REPO" "${REPO_NAME:-}" "$GH_REPO" \
  "${CI_PROJECT_NAME:-}" "${BITBUCKET_REPO_SLUG:-}" "$(basename "$SRC_DIR")")"
APP_NAME="${APP_NAME##*/}"
if [ -z "${IS_PR:-}" ]; then
  IS_PR=false
  [ "${BUILD_REASON:-}" = "PullRequest" ] && IS_PR=true
  case "${CODEBUILD_WEBHOOK_EVENT:-}" in PULL_REQUEST_*) IS_PR=true ;; esac
  [ -n "${_PR_NUMBER:-}${PR_NUMBER:-}" ] && IS_PR=true
  [ "${GITHUB_EVENT_NAME:-}" = "pull_request" ] && IS_PR=true
  [ "${CI_PIPELINE_SOURCE:-}" = "merge_request_event" ] && IS_PR=true
  [ -n "${CHANGE_ID:-}${BITBUCKET_PR_ID:-}" ] && IS_PR=true
fi
DOJO_ENGAGEMENT="${DOJO_ENGAGEMENT:-CI-CD $BRANCH}"

# ------------------------------------------------------------------ helpers
TMP_ROOT="$(mktemp -d 2>/dev/null || mktemp -d -t devsecops)"
cleanup() { rm -rf "$TMP_ROOT" 2>/dev/null || true; }
trap cleanup EXIT
GATE_FAILED=0
RESULTS=""
result() { RESULTS="$RESULTS$(printf '  %-10s %s' "$1" "$2")"$'\n'; }

need() { command -v "$1" >/dev/null 2>&1; }

ensure_jq() {
  need jq && return 0
  if [ "$(uname -s)" = "Linux" ]; then
    local arch=amd64; case "$(uname -m)" in aarch64|arm64) arch=arm64 ;; esac
    mkdir -p "$TMP_ROOT/bin"
    curl -fsSL -o "$TMP_ROOT/bin/jq" "https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-$arch" \
      && chmod +x "$TMP_ROOT/bin/jq" && PATH="$TMP_ROOT/bin:$PATH" && need jq && return 0
  fi
  err "Falta jq (macOS: brew install jq · Debian/Ubuntu: apt-get install jq)"; exit 2
}

# Copia del codigo sin carpetas pesadas, lista para "docker cp".
SNAP=""
snapshot() {
  [ -n "$SNAP" ] && return 0
  SNAP="$TMP_ROOT/src"; mkdir -p "$SNAP"
  local ex=() d
  for d in $EXCLUDES; do ex+=("--exclude=$d"); done
  (cd "$SRC_DIR" && tar -cf - "${ex[@]}" .) | tar -C "$SNAP" -xf - \
    || { err "No se pudo preparar la copia del codigo"; return 1; }
}

# crun <dir_salida_host> <dir_salida_contenedor> <args de docker create...>
#   Antes de llamar, llena CRUN_IN=(origen_host destino_contenedor ...)
CRUN_IN=()
crun() {
  local out_h="$1" out_c="$2"; shift 2
  local cid rc i
  local net=(); [ -n "$DOCKER_NETWORK" ] && net=(--network "$DOCKER_NETWORK")
  cid=$(docker create ${net[@]+"${net[@]}"} "$@") || return 125
  i=0
  while [ $i -lt ${#CRUN_IN[@]} ]; do
    docker cp "${CRUN_IN[$i]}" "$cid:${CRUN_IN[$((i+1))]}" >/dev/null \
      || { docker rm -f "$cid" >/dev/null 2>&1; return 125; }
    i=$((i+2))
  done
  docker start -a "$cid"; rc=$?
  mkdir -p "$out_h"
  docker cp "$cid:$out_c/." "$out_h/" >/dev/null 2>&1 || true
  docker rm -f "$cid" >/dev/null 2>&1 || true
  CRUN_IN=()
  return $rc
}

gate() {  # $1 herramienta  $2 cantidad  $3 descripcion
  if [ "$FAIL_ON_HIGH" = "true" ] && [ "$2" -gt 0 ]; then
    err "$1 encontro $2 $3"; GATE_FAILED=1
  fi
}

# ------------------------------------------------------------------ opengrep
run_opengrep() {
  section "Opengrep (SAST seguridad)"
  local out="$OUT_DIR/opengrep" rules="$TMP_ROOT/opengrep-rules" args=() d configs=() rc
  mkdir -p "$out"
  if ! need opengrep; then
    [ -n "$OPENGREP_VERSION" ] && args=(-v "$OPENGREP_VERSION")
    curl -fsSL https://raw.githubusercontent.com/opengrep/opengrep/main/install.sh | bash -s -- ${args[@]+"${args[@]}"} \
      || { err "No se pudo instalar Opengrep"; result opengrep "ERROR instalacion"; GATE_FAILED=1; return; }
    PATH="$HOME/.opengrep/cli/latest:$PATH"
  fi
  git clone -q --depth 1 https://github.com/opengrep/opengrep-rules.git "$rules" \
    || { err "No se pudo clonar opengrep-rules"; result opengrep "ERROR reglas"; GATE_FAILED=1; return; }
  for d in $OPENGREP_RULES_DIRS; do [ -d "$rules/$d" ] && configs+=(--config "$rules/$d"); done
  # Reglas propias del equipo (opcional): carpeta .opengrep/ en la raiz del repo
  [ -d "$SRC_DIR/.opengrep" ] && configs+=(--config "$SRC_DIR/.opengrep")
  local exc=(); for d in $EXCLUDES; do exc+=(--exclude "$d"); done
  (cd "$SRC_DIR" && opengrep scan ${configs[@]+"${configs[@]}"} "${exc[@]}" \
      --sarif-output="$out/opengrep.sarif" --json-output="$out/opengrep.json" .); rc=$?
  [ $rc -ne 0 ] && warn "Opengrep termino con rc=$rc (revisar reglas con error)"
  if [ ! -s "$out/opengrep.json" ]; then
    err "Opengrep no genero reporte"; result opengrep "ERROR sin reporte"; GATE_FAILED=1; return
  fi
  local high total
  high=$(jq '[.results[] | select(.extra.severity=="ERROR")] | length' "$out/opengrep.json")
  total=$(jq '.results | length' "$out/opengrep.json")
  note "Opengrep: $total hallazgos, $high de severidad ERROR"
  result opengrep "$total hallazgos ($high ERROR)"
  gate Opengrep "$high" "hallazgos ERROR"
}

# ------------------------------------------------------------------ sonarqube
run_sonar() {
  section "SonarQube Community (calidad + hotspots)"
  if [ -z "$SONAR_HOST_URL" ] || [ -z "$SONAR_TOKEN" ]; then
    note "SONAR_HOST_URL/SONAR_TOKEN no definidos, se omite"; result sonar "omitido (sin config)"; return
  fi
  # Community Build analiza solo UNA rama
  case " $SONAR_BRANCHES " in *" $BRANCH "*) ;; *)
    note "Rama '$BRANCH' no esta en SONAR_BRANCHES ($SONAR_BRANCHES), se omite"
    result sonar "omitido (rama $BRANCH)"; return ;;
  esac
  [ "$IS_PR" = "true" ] && { note "PR: se omite SonarQube"; result sonar "omitido (PR)"; return; }
  snapshot || { result sonar "ERROR copia"; GATE_FAILED=1; return; }
  local key wait=false
  key=$(printf '%s' "$APP_NAME" | tr -c 'A-Za-z0-9_.:-' '_')
  [ "$FAIL_ON_HIGH" = "true" ] && wait=true
  export SONAR_HOST_URL SONAR_TOKEN
  CRUN_IN=("$SNAP/." /usr/src)
  if crun "$OUT_DIR/sonar" /tmp/none \
      -u 0 -e SONAR_HOST_URL -e SONAR_TOKEN "$SONAR_IMAGE" \
      -Dsonar.projectKey="$key" -Dsonar.projectName="$APP_NAME" -Dsonar.sources=. \
      -Dsonar.working.directory=/tmp/.scannerwork \
      -Dsonar.exclusions="**/node_modules/**,**/vendor/**,**/dist/**,**/build/**,**/target/**" \
      -Dsonar.qualitygate.wait="$wait" -Dsonar.qualitygate.timeout=600; then
    note "Dashboard: $SONAR_HOST_URL/dashboard?id=$key"; result sonar "ok ($SONAR_HOST_URL/dashboard?id=$key)"
  else
    err "SonarQube fallo o quality gate en rojo"; result sonar "FALLO / gate rojo"
    [ "$FAIL_ON_HIGH" = "true" ] && GATE_FAILED=1
  fi
  # NOTA Java/.NET: usa "mvn verify sonar:sonar", "gradle sonar" o "dotnet sonarscanner"
}

# ------------------------------------------------------------------ trivy
run_trivy() {
  section "Trivy (dependencias, secretos, IaC)"
  local out="$OUT_DIR/trivy" empty="$TMP_ROOT/empty"
  mkdir -p "$out" "$empty"
  snapshot || { result trivy "ERROR copia"; GATE_FAILED=1; return; }
  CRUN_IN=("$SNAP/." /src "$empty/." /out)
  crun "$out" /out "$TRIVY_IMAGE" fs --scanners vuln,secret,misconfig \
      --format json --output /out/trivy.json /src
  if [ ! -s "$out/trivy.json" ]; then
    err "Trivy no genero reporte"; result trivy "ERROR sin reporte"; GATE_FAILED=1; return
  fi
  CRUN_IN=("$out/." /out)
  crun "$out" /out "$TRIVY_IMAGE" convert --format sarif --output /out/trivy.sarif /out/trivy.json \
    || warn "No se pudo convertir Trivy a SARIF"
  local high
  high=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="CRITICAL" or .Severity=="HIGH")] | length' "$out/trivy.json")
  note "Trivy: $high vulnerabilidades HIGH/CRITICAL en dependencias"
  result trivy "$high HIGH/CRITICAL"
  gate Trivy "$high" "vulnerabilidades HIGH/CRITICAL"
}

# ------------------------------------------------------------------ zap
run_zap() {
  section "ZAP (DAST, modo $ZAP_MODE)"
  if [ "$IS_PR" = "true" ] && [ "$DAST_ON_PR" != "true" ]; then
    note "PR: staging no tiene el codigo del PR, se omite ZAP"; result zap "omitido (PR)"; return
  fi
  local target="$DAST_TARGET_URL"
  [ "$ZAP_MODE" = "api" ] && target="$ZAP_API_SPEC"
  if [ -z "$target" ]; then
    note "DAST_TARGET_URL (o ZAP_API_SPEC en modo api) no definido, se omite"; result zap "omitido (sin config)"; return
  fi
  local wrk="$TMP_ROOT/zapwrk" out="$OUT_DIR/zap" conf=() cmd rc
  mkdir -p "$wrk" "$out" && chmod 777 "$wrk"
  if [ -f "$SRC_DIR/.zap/rules.tsv" ]; then cp "$SRC_DIR/.zap/rules.tsv" "$wrk/"; chmod 644 "$wrk/rules.tsv"; conf=(-c rules.tsv); fi
  case "$ZAP_MODE" in
    full) cmd=(zap-full-scan.py -t "$target") ;;
    api)  cmd=(zap-api-scan.py -t "$target" -f openapi) ;;
    *)    cmd=(zap-baseline.py -t "$target") ;;
  esac
  CRUN_IN=("$wrk/." /zap/wrk)
  crun "$out" /zap/wrk "$ZAP_IMAGE" "${cmd[@]}" ${conf[@]+"${conf[@]}"} -r zap.html -J zap.json -x zap.xml -I
  rc=$?
  # Codigos ZAP: 0 ok, 1 FAIL, 2 WARN, 3 error de ejecucion
  if [ "$rc" -eq 3 ] || [ "$rc" -eq 125 ] || [ ! -s "$out/zap.json" ]; then
    err "ZAP no pudo completar el escaneo (rc=$rc)"; result zap "ERROR rc=$rc"; GATE_FAILED=1; return
  fi
  local high
  high=$(jq '[.site[]?.alerts[]? | select(.riskcode=="3")] | length' "$out/zap.json")
  note "ZAP: $high alertas de riesgo High"
  result zap "$high alertas High"
  gate ZAP "$high" "alertas High"
}

# ------------------------------------------------------------------ defectdojo + sarif
dojo_upload() {  # $1=scan_type  $2=archivo  $3=titulo del test
  if [ ! -s "$2" ]; then note "No existe $2, se omite"; return 0; fi
  if curl -sS -f -X POST "$DOJO_URL/api/v2/reimport-scan/" \
      -H "Authorization: Token $DOJO_API_KEY" \
      -F "scan_type=$1" -F "file=@$2" -F "test_title=$3" \
      -F "product_type_name=$DOJO_PRODUCT_TYPE" -F "product_name=$APP_NAME" \
      -F "engagement_name=$DOJO_ENGAGEMENT" -F "auto_create_context=true" \
      -F "close_old_findings=true" -F "active=true" -F "verified=false" \
      -F "minimum_severity=Info" -F "build_id=$BUILD_ID" \
      -F "commit_hash=$COMMIT" -F "branch_tag=$BRANCH" > /dev/null; then
    note "Importado a DefectDojo: $3"
  else
    warn "No se pudo importar $3 a DefectDojo"
  fi
}
run_report() {
  section "Reporte (DefectDojo + SARIF)"
  mkdir -p "$OUT_DIR/sarif"
  cp "$OUT_DIR"/opengrep/*.sarif "$OUT_DIR/sarif/" 2>/dev/null || true
  cp "$OUT_DIR"/trivy/*.sarif    "$OUT_DIR/sarif/" 2>/dev/null || true
  if [ -z "$DOJO_URL" ] || [ -z "$DOJO_API_KEY" ]; then
    note "DOJO_URL/DOJO_API_KEY no definidos, se omite DefectDojo"; result dojo "omitido (sin config)"; return
  fi
  dojo_upload "Semgrep JSON Report" "$OUT_DIR/opengrep/opengrep.json" "Opengrep"
  dojo_upload "Trivy Scan"          "$OUT_DIR/trivy/trivy.json"       "Trivy"
  dojo_upload "ZAP Scan"            "$OUT_DIR/zap/zap.xml"            "ZAP"
  note "Ver hallazgos: $DOJO_URL/product"
  result dojo "$DOJO_URL/product"
}

# ------------------------------------------------------------------ main
need docker || { err "Falta docker en este agente"; exit 2; }
need git    || { err "Falta git en este agente"; exit 2; }
need curl   || { err "Falta curl en este agente"; exit 2; }
ensure_jq
mkdir -p "$OUT_DIR"
# limpia reportes de corridas anteriores para no subir resultados viejos
for d in opengrep sonar trivy zap sarif; do rm -rf "${OUT_DIR:?}/$d"; done

STEPS="$*"; [ -z "$STEPS" ] && STEPS="opengrep sonar trivy zap report"
note "plataforma=$PLATFORM app=$APP_NAME rama=$BRANCH build=$BUILD_ID pr=$IS_PR fail_on_high=$FAIL_ON_HIGH"
for s in $STEPS; do
  case "$s" in
    opengrep) run_opengrep ;;
    sonar)    run_sonar ;;
    trivy)    run_trivy ;;
    zap)      run_zap ;;
    report)   run_report ;;
    *) err "Paso desconocido: $s (usa opengrep sonar trivy zap report)"; exit 2 ;;
  esac
done

section "Resumen"
printf '%s' "$RESULTS"
echo "  reportes   $OUT_DIR"
if [ "$GATE_FAILED" -ne 0 ]; then err "El escaneo tiene errores o hallazgos que bloquean (FAIL_ON_HIGH=$FAIL_ON_HIGH)"; exit 1; fi
exit 0
