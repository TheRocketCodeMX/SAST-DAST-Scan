# PR-DSO-001 · Proceso de escaneo DevSecOps en CI/CD

> **Uso interno de rocket code.** No distribuir fuera de la organización.
> Versión 1.0 · 23 de septiembre de 2026 · Dueño del proceso: [__] · Aprobó: [__]

## 1. Objetivo, alcance y roles

**Objetivo.** Detectar vulnerabilidades de código, dependencias, secretos, configuración de infraestructura y de la aplicación en ejecución en cada cambio, y centralizar los hallazgos en DefectDojo.

**Alcance.** Repositorios de aplicaciones con CI/CD en Azure, AWS o GCP (también GitHub Actions, GitLab CI, Jenkins o Bitbucket). Se dispara con push a `main` y `develop` y con PRs hacia `main`.

| Rol | Responsabilidad |
|---|---|
| DevOps del proyecto | Ejecuta la configuración (F3 y F4) y mantiene el pipeline |
| AppSec / Seguridad | Administra SonarQube y DefectDojo, emite tokens, valida la primera ejecución y hace el triage |
| Líder técnico | Asigna y corrige hallazgos, aprueba activar `FAIL_ON_HIGH` |
| PO | Informado del estado de hallazgos y riesgos aceptados |

| Herramienta | Tipo | Qué revisa |
|---|---|---|
| Opengrep | SAST | Patrones inseguros en el código |
| SonarQube Community | SAST / calidad | Calidad, deuda técnica y security hotspots (rama `main`) |
| Trivy 0.69.3 | SCA | Dependencias vulnerables, secretos, IaC |
| ZAP | DAST | La app desplegada en staging (no corre en PRs) |
| DefectDojo | Gestión | Consolida hallazgos por repo y rama |

## 2. Flujo

| Fase | Entrada | Salida | Responsable |
|---|---|---|---|
| F1 Prerrequisitos | Solicitud del proyecto | URLs, token de SonarQube, API key de DefectDojo, staging autorizado | AppSec |
| F2 Elegir nube | Dónde corre el CI/CD | Azure, AWS o GCP | DevOps |
| F3 Configurar | Valores de F1 | Secretos cargados, pipeline y disparadores | DevOps |
| F4 Integrar al repo | Este repositorio | Pipeline y `devsecops/devsecops-scan.sh` en `main` | DevOps |
| F5 Validar | Primera ejecución | Criterios de aceptación cumplidos | DevOps + AppSec |
| F6 Operar | Hallazgos en DefectDojo | Hallazgos atendidos, riesgos documentados | Líder técnico + AppSec |

**Cómo se ejecuta desde cualquier país.** El dev abre la consola web de su nube (ya autenticada con su cuenta) y pega una línea. No instala nada ni depende de ningún equipo.

## 3. F1 y F2 · Prerrequisitos y selección de nube

- SonarQube y DefectDojo publicados con HTTPS (una sola instancia de cada uno para las tres nubes).
- Token de SonarQube (My Account → Security → Global Analysis) y API v2 key de DefectDojo.
- URL de staging autorizada para ZAP.
- Permisos de admin en la cuenta, suscripción o proyecto de la nube.

| Valor | Tipo |
|---|---|
| `SONAR_HOST_URL` | normal |
| `SONAR_TOKEN` | secreto |
| `DOJO_URL` | normal |
| `DOJO_API_KEY` | secreto |
| `DAST_TARGET_URL` | normal |

Regla: el escaneo se configura en la misma nube donde ya se construye y despliega la app.

| | Azure | AWS | GCP |
|---|---|---|---|
| Servicio | Azure Pipelines | CodeBuild | Cloud Build |
| Archivo | `azure-pipelines.yml` | `buildspec.yml` | `cloudbuild.yaml` |
| Secretos | Variable group `devsecops-oss` | Secrets Manager `devsecops-oss` | Secret Manager (2 secretos) |
| Docker | Incluido | Privileged mode | Incluido (red `cloudbuild`) |

## 4. F3 y F4 · Procedimiento por nube

### 4.1 Azure

1. Abrir [Azure Cloud Shell](https://shell.azure.com/bash).
2. Pegar:
   ```bash
   bash <(curl -fsSL https://raw.githubusercontent.com/diegofernandez-dotcom/SAST-DAST-Scan/main/azure/setup-azure.sh)
   ```
3. El script crea el variable group con secretos, instala SARIF Scans Tab, agrega el pipeline a tu repo (clásico o portable) y crea el pipeline.

### 4.2 AWS

1. Abrir [AWS CloudShell](https://console.aws.amazon.com/cloudshell/home).
2. Pegar:
   ```bash
   bash <(curl -fsSL https://raw.githubusercontent.com/diegofernandez-dotcom/SAST-DAST-Scan/main/aws/setup-aws.sh)
   ```
3. El script crea el secreto en Secrets Manager, el rol IAM, el proyecto CodeBuild (privileged) y el webhook de push y PR. Con Bitbucket o GitLab, conectar el repo antes en CodeBuild → Settings → Connections.

### 4.3 GCP

1. Conectar el repo de la app en [Cloud Build → Triggers → Connect repository](https://console.cloud.google.com/cloud-build/triggers/connect).
2. Abrir [Google Cloud Shell](https://shell.cloud.google.com/cloudshell/editor?cloudshell_git_repo=https%3A%2F%2Fgithub.com%2Fdiegofernandez-dotcom%2FSAST-DAST-Scan&cloudshell_git_branch=main&cloudshell_tutorial=gcp%2FTUTORIAL.md&show=terminal).
3. Pegar:
   ```bash
   bash <(curl -fsSL https://raw.githubusercontent.com/diegofernandez-dotcom/SAST-DAST-Scan/main/gcp/setup-gcp.sh)
   ```
4. El script habilita APIs, crea los secretos, da acceso a la cuenta de servicio y crea los triggers (o lanza un build manual).

## 5. F5 y F6 · Validación y operación

**Criterios de aceptación de la primera ejecución**

- [ ] El pipeline corre completo al hacer push a `main`.
- [ ] El resumen del log muestra Opengrep, Trivy, SonarQube y ZAP sin “ERROR”.
- [ ] DefectDojo tiene el producto (nombre del repo), engagement `CI-CD main` y un test por herramienta.
- [ ] SonarQube muestra el proyecto.
- [ ] Un PR hacia `main` dispara el pipeline y omite ZAP.
- [ ] `devsecops-reports/` queda como artefacto.

**Operación continua**

1. Triage de hallazgos nuevos en DefectDojo (AppSec).
2. Corrección por severidad. Plazo objetivo: Critical [__] días, High [__] días, Medium [__] días (Líder técnico).
3. Sin Critical/High abiertos → `FAIL_ON_HIGH=true` (Líder técnico).
4. Revisión periódica [__] de riesgos aceptados, versiones y reglas (AppSec).

| Variable | Default | Cuándo cambiarla |
|---|---|---|
| `FAIL_ON_HIGH` | `false` | `true` para bloquear merges con Critical/High |
| `ZAP_MODE` | `baseline` | `full` (solo staging) o `api` con `ZAP_API_SPEC` |
| `SONAR_BRANCHES` | `main` | Si la rama principal tiene otro nombre |
| `DAST_ON_PR` | `false` | Solo si cada PR despliega su ambiente |
| `TRIVY_IMAGE` | `0.69.3` | No usar 0.69.4 a 0.69.6 (GHSA-69fq-xp46-6x23) |

## 6. Otras plataformas

Copiar el archivo de `otros/` y la carpeta `devsecops/` a la raíz del repo y dar de alta los 5 valores.

| Plataforma | Archivo | Secretos |
|---|---|---|
| GitHub Actions | `otros/github-actions-devsecops.yml` → `.github/workflows/` | Settings → Secrets and variables → Actions |
| GitLab CI | `otros/.gitlab-ci.yml` | Settings → CI/CD → Variables (masked) |
| Jenkins | `otros/Jenkinsfile` | Credentials `sonar-token`, `dojo-api-key` |
| Bitbucket | `otros/bitbucket-pipelines.yml` | Repository variables (secured) |

## 7. Solución de problemas

| Síntoma | Nube | Acción |
|---|---|---|
| “Cannot connect to the Docker daemon” | AWS | Activar privileged mode en CodeBuild |
| `AccessDeniedException` al leer el secreto | AWS | El rol necesita `secretsmanager:GetSecretValue` |
| “Permission denied on secret” | GCP | `roles/secretmanager.secretAccessor` a la cuenta de servicio |
| “Variable group could not be found” | Azure | Nombre exacto `devsecops-oss`; autorizar el pipeline |
| “No hosted parallelism has been purchased or granted” | Azure | Pedir el grant gratuito o usar agente self-hosted |
| SonarQube o DefectDojo: timeout | Todas | El servicio no es accesible desde el agente |
| ZAP rc=3 | Todas | Staging caído; en modo `api` definir `ZAP_API_SPEC` |
| GitHub pide usuario y contraseña al hacer push | Todas | Usar un token personal como contraseña |
| “Falta az / aws / gcloud” | Todas | Correr el comando en la consola web de la nube |
