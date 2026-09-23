# rocket code · DevSecOps multinube (SAST · SCA · DAST)

Escaneo de seguridad open source para los pipelines de Azure, AWS y GCP:
**Opengrep** y **SonarQube Community** (SAST), **Trivy** (SCA, secretos, IaC),
**ZAP** (DAST contra staging) y **DefectDojo** (gestión de hallazgos).

> Uso interno de rocket code. Proceso: PR-DSO-001.

## Ejecutar el setup (desde cualquier equipo o país, sin instalar nada)

Abre la consola web de tu nube y pega el comando. Ya tiene tu sesión y las herramientas (`az`, `aws`, `gcloud`, `git`, `jq`).

| Nube | 1. Abrir consola | 2. Pegar |
|---|---|---|
| Azure | [Azure Cloud Shell](https://shell.azure.com/bash) | `bash <(curl -fsSL https://raw.githubusercontent.com/diegofernandez-dotcom/SAST-DAST-Scan/main/azure/setup-azure.sh)` |
| AWS | [AWS CloudShell](https://console.aws.amazon.com/cloudshell/home) | `bash <(curl -fsSL https://raw.githubusercontent.com/diegofernandez-dotcom/SAST-DAST-Scan/main/aws/setup-aws.sh)` |
| GCP | [![Open in Cloud Shell](https://gstatic.com/cloudssh/images/open-btn.svg)](https://shell.cloud.google.com/cloudshell/editor?cloudshell_git_repo=https%3A%2F%2Fgithub.com%2Fdiegofernandez-dotcom%2FSAST-DAST-Scan&cloudshell_git_branch=main&cloudshell_tutorial=gcp%2FTUTORIAL.md&show=terminal) | `bash <(curl -fsSL https://raw.githubusercontent.com/diegofernandez-dotcom/SAST-DAST-Scan/main/gcp/setup-gcp.sh)` |

El script pide los datos del proyecto (URLs de SonarQube, DefectDojo y staging, tokens),
guarda los secretos en el gestor de secretos de la nube, crea el pipeline y los
disparadores, y opcionalmente agrega los archivos a tu repo con commit y push.

## Contenido

```
devsecops/devsecops-scan.sh   núcleo común (va en la raíz de cada repo de app)
azure/  azure-pipelines.yml · azure-pipelines-portable.yml · setup-azure.sh
aws/    buildspec.yml · setup-aws.sh
gcp/    cloudbuild.yaml · setup-gcp.sh · TUTORIAL.md
otros/  github-actions-devsecops.yml · .gitlab-ci.yml · Jenkinsfile · bitbucket-pipelines.yml
```

## Seguridad

- Los scripts no contienen secretos. Cada dev captura los suyos al ejecutarlos y quedan en el gestor de secretos de su nube.
- Revisa el script antes de ejecutarlo: está completo en este repositorio.
