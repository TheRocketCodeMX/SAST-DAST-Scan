#!/usr/bin/env bash
# =============================================================================
# setup-aws.sh · rocket code · DevSecOps OSS en AWS CodeBuild
#   1. Verifica aws CLI, jq, git y la sesion de AWS
#   2. Crea/actualiza el secreto "devsecops-oss" en Secrets Manager
#   3. Crea el rol IAM de CodeBuild con permisos minimos
#   4. (Opcional) Agrega buildspec.yml + devsecops/ a tu repo (clona, commit y push)
#   5. Crea el proyecto CodeBuild (privileged) y el webhook, y (opcional) lo corre
# Ejecutar desde la consola web de la nube (sin instalar nada):
#   bash <(curl -fsSL https://raw.githubusercontent.com/diegofernandez-dotcom/SAST-DAST-Scan/main/aws/setup-aws.sh)
# Idempotente.
# =============================================================================
set -uo pipefail
# Permite ejecutarlo tanto con "bash <(curl ...)" como con "curl ... | bash"
[ -t 0 ] || exec </dev/tty
RAW="${DEVSECOPS_RAW:-https://raw.githubusercontent.com/diegofernandez-dotcom/SAST-DAST-Scan/main}"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
APP_DIR=""
SECRET="devsecops-oss"

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
azul "  rocket code · setup DevSecOps en AWS CodeBuild"
azul "=============================================================="
echo

# ---------------------------------------------------------------- 1
azul "1/5  Herramientas y sesion"
need_tools aws git curl
ensure_jq
PROFILE="${AWS_PROFILE:-}"   # en AWS CloudShell no hace falta perfil
[ -n "$PROFILE" ] && export AWS_PROFILE="$PROFILE"
if ! ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null); then
  fail "Sin credenciales de AWS. Abre AWS CloudShell desde la consola de AWS y vuelve a ejecutar."
fi
REGION=$(ask "Region" "${AWS_REGION:-$(aws configure get region 2>/dev/null || echo us-east-1)}")
export AWS_DEFAULT_REGION="$REGION"
ok "cuenta $ACCOUNT · region $REGION"
echo

azul "Datos del repositorio y servicios"
echo "  Origen del codigo: 1) GitHub  2) CodeCommit  3) Bitbucket  4) GitLab"
SRC=$(ask "Opcion" "1")
case "$SRC" in
  2) STYPE=CODECOMMIT ;; 3) STYPE=BITBUCKET ;; 4) STYPE=GITLAB ;; *) STYPE=GITHUB ;;
esac
REPO_URL=$(ask "URL HTTPS del repo (p. ej. https://github.com/org/app.git)")
[ -n "$REPO_URL" ] || fail "La URL del repo es obligatoria"
REPO=$(basename "${REPO_URL%.git}")
BRANCH=$(ask "Rama principal" "main")
PROJECT=$(ask "Nombre del proyecto CodeBuild" "devsecops-$REPO")
echo
SONAR_HOST_URL=$(ask "SONAR_HOST_URL")
SONAR_TOKEN=$(secret "SONAR_TOKEN")
DOJO_URL=$(ask "DOJO_URL")
DOJO_API_KEY=$(secret "DOJO_API_KEY")
DAST_TARGET_URL=$(ask "DAST_TARGET_URL (staging)")
echo

# ---------------------------------------------------------------- 2
azul "2/5  Secreto '$SECRET' en Secrets Manager"
JSON=$(jq -n --arg a "$SONAR_HOST_URL" --arg b "$SONAR_TOKEN" --arg c "$DOJO_URL" --arg d "$DOJO_API_KEY" --arg e "$DAST_TARGET_URL" \
  '{SONAR_HOST_URL:$a,SONAR_TOKEN:$b,DOJO_URL:$c,DOJO_API_KEY:$d,DAST_TARGET_URL:$e}')
if SECRET_ARN=$(aws secretsmanager describe-secret --secret-id "$SECRET" --query ARN --output text 2>/dev/null); then
  aws secretsmanager put-secret-value --secret-id "$SECRET" --secret-string "$JSON" >/dev/null || fail "No se pudo actualizar el secreto"
  ok "actualizado"
else
  SECRET_ARN=$(aws secretsmanager create-secret --name "$SECRET" --secret-string "$JSON" --query ARN --output text) \
    || fail "No se pudo crear el secreto"
  ok "creado"
fi
unset JSON SONAR_TOKEN DOJO_API_KEY
echo

# ---------------------------------------------------------------- 3
azul "3/5  Rol IAM para CodeBuild"
ROLE="codebuild-$PROJECT-role"
TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"codebuild.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
if ! ROLE_ARN=$(aws iam get-role --role-name "$ROLE" --query Role.Arn --output text 2>/dev/null); then
  ROLE_ARN=$(aws iam create-role --role-name "$ROLE" --assume-role-policy-document "$TRUST" --query Role.Arn --output text) \
    || fail "No se pudo crear el rol (¿permisos IAM?)"
  NEW_ROLE=1
fi
POLICY=$(jq -n --arg s "$SECRET_ARN" --arg r "arn:aws:codecommit:$REGION:$ACCOUNT:$REPO" '{
  Version:"2012-10-17", Statement:[
   {Effect:"Allow",Action:["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents"],Resource:"*"},
   {Effect:"Allow",Action:["secretsmanager:GetSecretValue"],Resource:$s},
   {Effect:"Allow",Action:["codecommit:GitPull"],Resource:$r}]}')
aws iam put-role-policy --role-name "$ROLE" --policy-name devsecops --policy-document "$POLICY" || fail "No se pudo asignar la politica"
ok "$ROLE"
[ "${NEW_ROLE:-0}" = 1 ] && { echo "  esperando propagacion de IAM..."; sleep 12; }
echo

# ---------------------------------------------------------------- 4
azul "4/5  Archivos en el repositorio"
if yesno "¿Agregar buildspec.yml y devsecops/ a tu repo ahora (clona, commit y push)?"; then
  push_to_repo "ci: DevSecOps OSS en AWS CodeBuild" aws/buildspec.yml:buildspec.yml devsecops/devsecops-scan.sh:devsecops/devsecops-scan.sh
else
  warn "Asegurate de tener buildspec.yml y devsecops/devsecops-scan.sh en la raiz del repo."
fi
echo

# ---------------------------------------------------------------- 5
azul "5/5  Proyecto CodeBuild"
if [ "$STYPE" != "CODECOMMIT" ]; then
  if ! aws codebuild list-source-credentials --query "sourceCredentialsInfos[?serverType=='$STYPE']" --output text | grep -q .; then
    if [ "$STYPE" = "GITHUB" ]; then
      warn "CodeBuild necesita acceso a GitHub."
      TOKEN=$(secret "Token de GitHub (scopes repo y admin:repo_hook)")
      aws codebuild import-source-credentials --server-type GITHUB --auth-type PERSONAL_ACCESS_TOKEN --token "$TOKEN" >/dev/null \
        || fail "No se pudieron importar las credenciales"
      unset TOKEN; ok "credenciales de GitHub importadas"
    else
      warn "Conecta $STYPE a CodeBuild una vez desde la consola (CodeBuild > Settings > Connections)"
      warn "o crea el proyecto desde la consola: https://$REGION.console.aws.amazon.com/codesuite/settings/connections"
      yesno "¿Ya lo conectaste y quieres continuar?" || fail "Conecta $STYPE y vuelve a correr el script"
    fi
  fi
fi
SOURCE=$(jq -n --arg t "$STYPE" --arg l "$REPO_URL" '{type:$t,location:$l,buildspec:"buildspec.yml",gitCloneDepth:0}')
ENVJ='{"type":"LINUX_CONTAINER","image":"aws/codebuild/amazonlinux-x86_64-standard:5.0","computeType":"BUILD_GENERAL1_MEDIUM","privilegedMode":true}'
if aws codebuild batch-get-projects --names "$PROJECT" --query "projects[0].name" --output text 2>/dev/null | grep -qx "$PROJECT"; then
  aws codebuild update-project --name "$PROJECT" --source "$SOURCE" --environment "$ENVJ" --service-role "$ROLE_ARN" \
    --source-version "$BRANCH" --timeout-in-minutes 120 >/dev/null || fail "No se pudo actualizar el proyecto"
  ok "proyecto '$PROJECT' actualizado"
else
  aws codebuild create-project --name "$PROJECT" --source "$SOURCE" --environment "$ENVJ" --service-role "$ROLE_ARN" \
    --source-version "$BRANCH" --artifacts type=NO_ARTIFACTS --timeout-in-minutes 120 >/dev/null || fail "No se pudo crear el proyecto"
  ok "proyecto '$PROJECT' creado"
fi

if [ "$STYPE" = "CODECOMMIT" ]; then
  warn "CodeCommit no usa webhooks: para disparos automaticos agrega una regla de EventBridge o CodePipeline (ver runbook)."
else
  FILTERS='[[{"type":"EVENT","pattern":"PUSH"},{"type":"HEAD_REF","pattern":"^refs/heads/(main|develop)$"}],[{"type":"EVENT","pattern":"PULL_REQUEST_CREATED,PULL_REQUEST_UPDATED,PULL_REQUEST_REOPENED"},{"type":"BASE_REF","pattern":"^refs/heads/main$"}]]'
  if aws codebuild create-webhook --project-name "$PROJECT" --filter-groups "$FILTERS" >/dev/null 2>&1; then ok "webhook creado"
  else aws codebuild update-webhook --project-name "$PROJECT" --filter-groups "$FILTERS" >/dev/null 2>&1 && ok "webhook actualizado" || warn "No se pudo crear el webhook"; fi
fi

if yesno "¿Ejecutar un build ahora?"; then
  BID=$(aws codebuild start-build --project-name "$PROJECT" --query build.id --output text) || fail "No se pudo lanzar"
  URL="https://$REGION.console.aws.amazon.com/codesuite/codebuild/$ACCOUNT/projects/$PROJECT/build/${BID//:/%3A}/log?region=$REGION"
  ok "build $BID"; echo "  $URL" 2>/dev/null || true
fi
echo
azul "Listo. Hallazgos en: $DOJO_URL/product"
