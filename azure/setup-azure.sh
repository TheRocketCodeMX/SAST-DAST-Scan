#!/usr/bin/env bash
# =============================================================================
# setup-azure.sh · rocket code
# Configura en Azure DevOps todo lo que necesita azure-pipelines.yml (DevSecOps OSS)
#   1. Verifica herramientas (az, jq, git) e instala la extension azure-devops
#   2. Crea/actualiza el variable group "devsecops-oss" (con secretos)
#   3. Instala la extension "SARIF SAST Scans Tab" en la organizacion
#   4. (Opcional) Agrega azure-pipelines.yml a tu repo (clona, commit y push)
#   5. Crea el pipeline y (opcional) lo ejecuta
# Ejecutar desde la consola web de la nube (sin instalar nada):
#   bash <(curl -fsSL https://raw.githubusercontent.com/diegofernandez-dotcom/SAST-DAST-Scan/main/azure/setup-azure.sh)
# Se puede correr de nuevo sin romper nada (idempotente).
# =============================================================================
set -uo pipefail
# Permite ejecutarlo tanto con "bash <(curl ...)" como con "curl ... | bash"
[ -t 0 ] || exec </dev/tty
RAW="${DEVSECOPS_RAW:-https://raw.githubusercontent.com/diegofernandez-dotcom/SAST-DAST-Scan/main}"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
APP_DIR=""
GROUP="devsecops-oss"

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
azul "  rocket code · setup DevSecOps para Azure Pipelines"
azul "=============================================================="
echo

# ---------------------------------------------------------------- 1. herramientas
azul "1/5  Verificando herramientas"
need_tools az git curl
ensure_jq
az extension show --name azure-devops >/dev/null 2>&1 || az extension add --name azure-devops --only-show-errors \
  || fail "No se pudo instalar la extension azure-devops de az"
ok "extension azure-devops lista"

if ! az account show >/dev/null 2>&1; then
  warn "No hay sesion de Azure. Sigue las instrucciones para iniciar sesion."
  az login --use-device-code --allow-no-subscriptions --only-show-errors >/dev/null || fail "az login fallo"
fi
ok "sesion de Azure activa"
echo

# ---------------------------------------------------------------- datos
azul "Datos de tu organizacion y servicios"
ORG=$(ask "URL de la organizacion (https://dev.azure.com/ORG)")
PROJECT=$(ask "Proyecto de Azure DevOps")
REPO=$(ask "Repositorio (Azure Repos) donde vive el codigo")
BRANCH=$(ask "Rama principal" "main")
[ -n "$ORG" ] && [ -n "$PROJECT" ] && [ -n "$REPO" ] || fail "Organizacion, proyecto y repo son obligatorios"
az devops configure --defaults organization="$ORG" project="$PROJECT" >/dev/null || fail "No se pudo configurar org/proyecto"

echo
SONAR_HOST_URL=$(ask "SONAR_HOST_URL (p. ej. https://sonar.tuempresa.com)")
SONAR_TOKEN=$(secret "SONAR_TOKEN")
DOJO_URL=$(ask "DOJO_URL (p. ej. https://defectdojo.tuempresa.com)")
DOJO_API_KEY=$(secret "DOJO_API_KEY")
DAST_TARGET_URL=$(ask "DAST_TARGET_URL (staging, p. ej. https://staging.tuapp.com)")
echo

# ---------------------------------------------------------------- 2. variable group
azul "2/5  Variable group '$GROUP'"
GID=$(az pipelines variable-group list --group-name "$GROUP" --query "[0].id" -o tsv 2>/dev/null)
if [ -z "$GID" ]; then
  GID=$(az pipelines variable-group create --name "$GROUP" --authorize true \
        --variables SONAR_HOST_URL="$SONAR_HOST_URL" DOJO_URL="$DOJO_URL" DAST_TARGET_URL="$DAST_TARGET_URL" \
        --query id -o tsv) || fail "No se pudo crear el variable group"
  ok "creado (id $GID)"
else
  ok "ya existia (id $GID), se actualizan valores"
fi

setvar() {  # $1 nombre  $2 valor  $3 secret(true/false)
  [ -z "$2" ] && { warn "$1 vacio, se omite"; return; }
  if az pipelines variable-group variable list --group-id "$GID" --query "keys(@)" -o tsv | tr '\t' '\n' | grep -qx "$1"; then
    az pipelines variable-group variable update --group-id "$GID" --name "$1" --value "$2" --secret "$3" -o none
  else
    az pipelines variable-group variable create --group-id "$GID" --name "$1" --value "$2" --secret "$3" -o none
  fi && ok "$1" || warn "no se pudo guardar $1"
}
setvar SONAR_HOST_URL  "$SONAR_HOST_URL"  false
setvar DOJO_URL        "$DOJO_URL"        false
setvar DAST_TARGET_URL "$DAST_TARGET_URL" false
setvar SONAR_TOKEN     "$SONAR_TOKEN"     true
setvar DOJO_API_KEY    "$DOJO_API_KEY"    true
echo

# ---------------------------------------------------------------- 3. extension SARIF
azul "3/5  Extension 'SARIF SAST Scans Tab'"
if az devops extension show --publisher-id sariftools --extension-id scans -o none 2>/dev/null; then
  ok "ya instalada"
elif az devops extension install --publisher-id sariftools --extension-id scans -o none 2>/dev/null; then
  ok "instalada"
else
  warn "No se pudo instalar (requiere permisos de admin de la organizacion)."
  warn "Instalala manualmente: https://marketplace.visualstudio.com/items?itemName=sariftools.scans"
fi
echo

# ---------------------------------------------------------------- 4. yml al repo
azul "4/5  azure-pipelines.yml en el repositorio"
if yesno "¿Agregar el pipeline a tu repo ahora (clona, commit y push)?"; then
  echo "  Version: 1) clasica, jobs en paralelo  2) portable, mismo script que AWS/GCP"
  VER=$(ask "Opcion" "1")
  if [ "$VER" = 2 ]; then
    push_to_repo "ci: pipeline DevSecOps OSS" azure/azure-pipelines-portable.yml:azure-pipelines.yml devsecops/devsecops-scan.sh:devsecops/devsecops-scan.sh
  else
    push_to_repo "ci: pipeline DevSecOps OSS" azure/azure-pipelines.yml:azure-pipelines.yml
  fi
else
  warn "Asegurate de que azure-pipelines.yml ya este en la raiz de '$REPO' (rama $BRANCH)."
fi
echo

# ---------------------------------------------------------------- 5. pipeline
azul "5/5  Pipeline"
PIPE="devsecops-$REPO"
if az pipelines show --name "$PIPE" -o none 2>/dev/null; then
  ok "el pipeline '$PIPE' ya existe"
else
  az pipelines create --name "$PIPE" --repository "$REPO" --repository-type tfsgit \
     --branch "$BRANCH" --yml-path azure-pipelines.yml --skip-first-run true -o none \
     || fail "No se pudo crear el pipeline (¿el yml esta en la rama $BRANCH?)"
  ok "pipeline '$PIPE' creado"
fi

if yesno "¿Ejecutar el pipeline ahora?"; then
  RUN=$(az pipelines run --name "$PIPE" --branch "$BRANCH" --query id -o tsv) || fail "No se pudo lanzar"
  URL="$ORG/$PROJECT/_build/results?buildId=$RUN"
  ok "ejecucion $RUN lanzada"
  echo "  $URL"
  command -v open >/dev/null && open "$URL" 2>/dev/null || true
fi

echo
azul "Listo. Hallazgos en: $DOJO_URL/product   ·   Calidad: $SONAR_HOST_URL"
echo
