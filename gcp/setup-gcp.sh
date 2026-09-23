#!/usr/bin/env bash
# =============================================================================
# setup-gcp.sh · rocket code · DevSecOps OSS en GCP Cloud Build
#   1. Verifica gcloud, git y la sesion de Google Cloud
#   2. Habilita APIs y crea/actualiza los secretos en Secret Manager
#   3. Da acceso a los secretos a la cuenta de servicio de Cloud Build
#   4. (Opcional) Agrega cloudbuild.yaml + devsecops/ a tu repo (clona, commit y push)
#   5. Crea los triggers (push y PR) o lanza un build manual
# Ejecutar desde la consola web de la nube (sin instalar nada):
#   bash <(curl -fsSL https://raw.githubusercontent.com/diegofernandez-dotcom/SAST-DAST-Scan/main/gcp/setup-gcp.sh)
# Idempotente.
# =============================================================================
set -uo pipefail
# Permite ejecutarlo tanto con "bash <(curl ...)" como con "curl ... | bash"
[ -t 0 ] || exec </dev/tty
RAW="${DEVSECOPS_RAW:-https://raw.githubusercontent.com/diegofernandez-dotcom/SAST-DAST-Scan/main}"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
APP_DIR=""

azul()  { printf '\033[1;34m%s\033[0m\n' "$*"; }
ok()    { printf '\033[1;32m  OK  \033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m  !!  \033[0m %s\n' "$*"; }
fail()  { printf '\033[1;31m  XX  \033[0m %s\n' "$*"; exit 1; }
ask()   { local v; read -r -p "  $1${2:+ [$2]}: " v; printf '%s' "${v:-${2:-}}"; }
secret(){ local v; read -r -s -p "  $1 (oculto): " v; echo >&2; printf '%s' "$v"; }
yesno() { local v; read -r -p "  $1 [s/N]: " v; [[ "$v" =~ ^[sSyY] ]]; }

# Descarga un archivo del kit publicado en GitHub
fetch() { mkdir -p "$(dirname "$2")"; curl -fsSL "$RAW/$1" -o "$2" || fail "No se pudo descargar $RAW/$1"; }

need_tools() {
  local t
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 && { ok "$t"; continue; }
    fail "Falta '$t'. Ejecuta este script desde la consola web de tu nube (Azure Cloud Shell, AWS CloudShell o Google Cloud Shell), que ya lo trae instalado."
  done
}
ensure_jq() {
  command -v jq >/dev/null 2>&1 && { ok "jq"; return; }
  mkdir -p "$HOME/bin"
  curl -fsSL -o "$HOME/bin/jq" https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64 \
    && chmod +x "$HOME/bin/jq" && export PATH="$HOME/bin:$PATH" && ok "jq (descargado)" || fail "No se pudo instalar jq"
}

# Clona el repo de la app, agrega archivos del kit, hace commit y push.
#   push_to_repo "mensaje" "ruta/en/kit:ruta/en/repo" ...
push_to_repo() {
  local msg="$1"; shift
  local url br p e
  url=$(ask "URL git HTTPS del repo de la app (p. ej. https://github.com/org/app.git)")
  [ -n "$url" ] || fail "La URL del repo es obligatoria"
  br=$(ask "Rama" "main")
  APP_DIR="$WORK/app"
  git_auth "$url"
  git clone -q --branch "$br" "$url" "$APP_DIR" || fail "No se pudo clonar $url (revisa la URL y tus credenciales de git)"
  for p in "$@"; do fetch "${p%%:*}" "$APP_DIR/${p#*:}"; git -C "$APP_DIR" add "${p#*:}"; done
  if ! git -C "$APP_DIR" config user.email >/dev/null; then
    e=$(ask "Tu correo para el commit")
    git -C "$APP_DIR" config user.email "$e"; git -C "$APP_DIR" config user.name "${e%@*}"
  fi
  if git -C "$APP_DIR" diff --cached --quiet; then ok "el repo ya tenia estos archivos"
  elif git -C "$APP_DIR" commit -qm "$msg" && git -C "$APP_DIR" push -q origin "$br"; then ok "commit y push a $br"
  else fail "commit/push fallo (¿permiso de escritura en el repo?)"; fi
}
# Credenciales de git sin configurar nada a mano cuando la consola lo permite
git_auth() {
  case "$1" in
    *dev.azure.com*|*visualstudio.com*)
      local tk; tk=$(az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 --query accessToken -o tsv 2>/dev/null) \
        && git config --global http.https://dev.azure.com/.extraheader "AUTHORIZATION: bearer $tk" ;;
    *git-codecommit*)
      git config --global credential.helper '!aws codecommit credential-helper $@'
      git config --global credential.UseHttpPath true ;;
    *github.com*)
      warn "GitHub pedira usuario y un token personal (Settings > Developer settings > Tokens) como contrasena." ;;
  esac
}

clear
azul "=============================================================="
azul "  rocket code · setup DevSecOps en GCP Cloud Build"
azul "=============================================================="
echo

# ---------------------------------------------------------------- 1
azul "1/5  Herramientas y sesion"
need_tools gcloud git curl
if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | grep -q .; then
  gcloud auth login --no-launch-browser || fail "gcloud auth login fallo"
fi
PROJECT_ID=$(ask "ID del proyecto de GCP" "$(gcloud config get-value project 2>/dev/null)")
[ -n "$PROJECT_ID" ] || fail "El proyecto es obligatorio"
gcloud config set project "$PROJECT_ID" >/dev/null 2>&1 || fail "Proyecto invalido o sin acceso"
PNUM=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)") || fail "No se pudo leer el proyecto"
ok "proyecto $PROJECT_ID ($PNUM)"
echo

azul "Datos del repositorio y servicios"
SONAR_HOST_URL=$(ask "SONAR_HOST_URL")
SONAR_TOKEN=$(secret "SONAR_TOKEN")
DOJO_URL=$(ask "DOJO_URL")
DOJO_API_KEY=$(secret "DOJO_API_KEY")
DAST_TARGET_URL=$(ask "DAST_TARGET_URL (staging)")
echo

# ---------------------------------------------------------------- 2
azul "2/5  APIs y secretos"
gcloud services enable cloudbuild.googleapis.com secretmanager.googleapis.com --quiet || fail "No se pudieron habilitar las APIs"
ok "APIs cloudbuild y secretmanager habilitadas"
putsecret() {  # $1 nombre  $2 valor
  [ -z "$2" ] && { warn "$1 vacio, se omite"; return; }
  if ! gcloud secrets describe "$1" >/dev/null 2>&1; then
    gcloud secrets create "$1" --replication-policy=automatic --quiet >/dev/null || { warn "no se pudo crear $1"; return; }
  fi
  printf '%s' "$2" | gcloud secrets versions add "$1" --data-file=- --quiet >/dev/null && ok "$1" || warn "no se pudo guardar $1"
}
putsecret devsecops-sonar-token  "$SONAR_TOKEN"
putsecret devsecops-dojo-api-key "$DOJO_API_KEY"
unset SONAR_TOKEN DOJO_API_KEY
echo

# ---------------------------------------------------------------- 3
azul "3/5  Permisos de la cuenta de servicio de Cloud Build"
SA=$(gcloud builds get-default-service-account --format="value(serviceAccountEmail)" 2>/dev/null)
SA="${SA##*/}"
[ -n "$SA" ] || SA="$PNUM-compute@developer.gserviceaccount.com"
for s in devsecops-sonar-token devsecops-dojo-api-key; do
  gcloud secrets add-iam-policy-binding "$s" --member="serviceAccount:$SA" \
    --role=roles/secretmanager.secretAccessor --quiet >/dev/null 2>&1 && ok "$SA puede leer $s" || warn "no se pudo dar acceso a $s"
done
gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="serviceAccount:$SA" \
  --role=roles/logging.logWriter --condition=None --quiet >/dev/null 2>&1 && ok "logs habilitados" || warn "no se pudo dar logging.logWriter"
echo

# ---------------------------------------------------------------- 4
azul "4/5  Archivos en el repositorio"
if yesno "¿Agregar cloudbuild.yaml y devsecops/ a tu repo ahora (clona, commit y push)?"; then
  push_to_repo "ci: DevSecOps OSS en GCP Cloud Build" gcp/cloudbuild.yaml:cloudbuild.yaml devsecops/devsecops-scan.sh:devsecops/devsecops-scan.sh
else
  warn "Asegurate de tener cloudbuild.yaml y devsecops/devsecops-scan.sh en la raiz del repo."
fi
echo

# ---------------------------------------------------------------- 5
azul "5/5  Triggers"
SUBS="_SONAR_HOST_URL=$SONAR_HOST_URL,_DOJO_URL=$DOJO_URL,_DAST_TARGET_URL=$DAST_TARGET_URL"
SA_FULL="projects/$PROJECT_ID/serviceAccounts/$SA"
if yesno "¿Crear triggers para un repo de GitHub ya conectado a Cloud Build?"; then
  echo "  (Si no esta conectado: https://console.cloud.google.com/cloud-build/triggers/connect?project=$PROJECT_ID)"
  OWNER=$(ask "Dueno u organizacion en GitHub")
  REPO=$(ask "Nombre del repo")
  SUBS_R="$SUBS,_APP_NAME=$REPO"
  gcloud builds triggers create github --name="devsecops-$REPO-push" --repo-owner="$OWNER" --repo-name="$REPO" \
    --branch-pattern='^(main|develop)$' --build-config=cloudbuild.yaml --substitutions="$SUBS_R" \
    --service-account="$SA_FULL" --quiet >/dev/null 2>&1 && ok "trigger push creado" || warn "trigger push no creado (¿ya existe o repo sin conectar?)"
  gcloud builds triggers create github --name="devsecops-$REPO-pr" --repo-owner="$OWNER" --repo-name="$REPO" \
    --pull-request-pattern='^main$' --build-config=cloudbuild.yaml --substitutions="$SUBS_R" \
    --service-account="$SA_FULL" --quiet >/dev/null 2>&1 && ok "trigger PR creado" || warn "trigger PR no creado (¿ya existe o repo sin conectar?)"
fi

if yesno "¿Lanzar un build manual ahora?"; then
  if [ -z "$APP_DIR" ]; then
    url=$(ask "URL git HTTPS del repo de la app"); br=$(ask "Rama" "main")
    APP_DIR="$WORK/app"; git clone -q --branch "$br" "$url" "$APP_DIR" || fail "No se pudo clonar $url"
  fi
  [ -f "$APP_DIR/cloudbuild.yaml" ] || fetch gcp/cloudbuild.yaml "$APP_DIR/cloudbuild.yaml"
  [ -f "$APP_DIR/devsecops/devsecops-scan.sh" ] || fetch devsecops/devsecops-scan.sh "$APP_DIR/devsecops/devsecops-scan.sh"
  BR=$(git -C "$APP_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)
  NAME=$(basename "$(git -C "$APP_DIR" config --get remote.origin.url)" .git)
  gcloud builds submit "$APP_DIR" --config="$APP_DIR/cloudbuild.yaml" \
    --substitutions="$SUBS,_APP_NAME=$NAME,_MANUAL_BRANCH=$BR" \
    --service-account="$SA_FULL" --async || warn "No se pudo lanzar el build"
  echo "  https://console.cloud.google.com/cloud-build/builds?project=$PROJECT_ID"
fi
echo
azul "Listo. Hallazgos en: $DOJO_URL/product"
