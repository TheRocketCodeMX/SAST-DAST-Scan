# PR-DSO-001 · Proceso de escaneo DevSecOps en CI/CD

> **Uso interno de rocket code.** No distribuir fuera de la organización.
> Versión 2.0 · 23 de septiembre de 2026 · Dueño del proceso: [__] · Aprobó: [__]

## 1. Objetivo, alcance y roles

**Objetivo.** Detectar vulnerabilidades de código, dependencias, secretos, IaC y de la aplicación en ejecución en cada cambio, y centralizar los hallazgos en DefectDojo, **con herramientas 100% open source y sin costo de licencias ni servicios de pago**.

**Alcance.** Todos los repositorios de aplicaciones, alojados en cualquier git (GitHub, Azure Repos, GitLab, Bitbucket, CodeCommit, Gitea). Se escanean las ramas configuradas (por defecto `main` y `develop`) en cada commit nuevo.

| Rol | Responsabilidad |
|---|---|
| DevOps / Infra | Prepara el servidor (F1), instala (F2), da de alta repos (F3) |
| AppSec / Seguridad | Valida la primera ejecución (F4) y hace el triage de hallazgos (F5) |
| Líder técnico | Corrige hallazgos y aprueba `FAIL_ON_HIGH=true` (F6) |
| PO | Informado del estado de hallazgos y riesgos aceptados |

| Herramienta | Tipo | Licencia |
|---|---|---|
| Opengrep | SAST | LGPL-2.1 |
| SonarQube Community Build | Calidad / hotspots | LGPL-3.0 |
| Trivy | SCA, secretos, IaC | Apache-2.0 |
| ZAP | DAST | Apache-2.0 |
| DefectDojo | Gestión de hallazgos | BSD-3-Clause |
| Jenkins | CI | MIT |
| Caddy + Let's Encrypt | HTTPS | Apache-2.0 |
| Docker Engine | Contenedores | Apache-2.0 |

## 2. Flujo

| Fase | Qué se hace | Responsable |
|---|---|---|
| F1 Servidor | Instancia Linux con puertos 22/80/443 e IP fija | DevOps |
| F2 Instalar | Un comando instala todo en el servidor | DevOps |
| F3 Alta de repos | `sudo devsecops add-repo` por cada repositorio | DevOps |
| F4 Validar | Primera ejecución y criterios de aceptación | DevOps + AppSec |
| F5 Operar | Triage y corrección en DefectDojo | AppSec + Líder técnico |
| F6 Endurecer | `FAIL_ON_HIGH=true` cuando no haya Critical/High | Líder técnico |

Arquitectura: un solo servidor con Docker. Jenkins revisa los repos cada 5 minutos (no necesita webhooks), descarga el código, corre Opengrep, SonarQube, Trivy y ZAP en contenedores y sube los resultados a DefectDojo. Caddy publica las tres interfaces con HTTPS gratuito.

## 3. F1 · Servidor (AWS)

- **EC2 Ubuntu 22.04/24.04**, mínimo **4 vCPU / 16 GB RAM / 100 GB** (p. ej. t3.xlarge o m6i.xlarge).
- **Security Group**: 22 solo desde tu IP; 80 y 443 desde 0.0.0.0/0.
- **Elastic IP** asociada.
- **DNS opcional**: registros A `sonar.`, `dojo.` y `ci.` apuntando a la IP. Sin dominio se usa `<ip-con-guiones>.sslip.io`.

Comandos equivalentes con AWS CLI (operaciones sin costo):

```bash
SG=sg-xxxxxxxx; MIIP=$(curl -s https://checkip.amazonaws.com)
aws ec2 authorize-security-group-ingress --group-id $SG --protocol tcp --port 22  --cidr $MIIP/32
aws ec2 authorize-security-group-ingress --group-id $SG --protocol tcp --port 80  --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id $SG --protocol tcp --port 443 --cidr 0.0.0.0/0
```

En Azure (NSG) o GCP (regla de firewall) aplica lo mismo: abrir 80 y 443, y 22 solo desde tu IP.

## 4. F2 · Instalación

1. Conectarse al servidor por SSH o con **EC2 Instance Connect** (consola de AWS → instancia → *Connect*).
2. Pegar:
   ```bash
   sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/TheRocketCodeMX/SAST-DAST-Scan/main/server/install.sh)"
   ```
3. Responder dominio (o dejar el sugerido) y correo para el certificado.
4. El instalador: instala Docker, ajusta el sistema para SonarQube, levanta SonarQube + PostgreSQL, DefectDojo, Jenkins y Caddy; cambia la contraseña de admin de SonarQube, genera los tokens y configura Jenkins.
5. Ver credenciales: `sudo devsecops credentials` (quedan en `/opt/devsecops/.env`, solo root).

## 5. F3 · Alta de repositorios

```bash
sudo devsecops add-repo
```

Pide URL HTTPS, ramas, URL de staging (para ZAP) y, si el repo es privado, un **token de solo lectura**:

| Git | Token de solo lectura |
|---|---|
| GitHub | Fine-grained token con *Contents: Read* sobre el repo |
| Azure Repos | PAT con *Code (Read)* |
| GitLab | Token con `read_repository` |
| Bitbucket | Access token con *Repositories: Read* |
| CodeCommit | Credenciales HTTPS de Git de un usuario IAM con `codecommit:GitPull` |

No se modifica ningún repo de aplicación.

## 6. F4 · Criterios de aceptación

- [ ] `https://sonar.`, `https://dojo.` y `https://ci.` abren con certificado válido.
- [ ] En Jenkins aparece el job `scan-<repo>` y termina en verde.
- [ ] El log muestra el resumen de Opengrep, Trivy, SonarQube y ZAP sin “ERROR”.
- [ ] DefectDojo tiene el producto (nombre del repo) con un test por herramienta.
- [ ] Un commit nuevo en `main` dispara un escaneo en menos de 10 minutos.

## 7. F5 y F6 · Operación

1. Triage de hallazgos nuevos en DefectDojo (AppSec).
2. Corrección por severidad. Plazo objetivo: Critical [__] días, High [__] días, Medium [__] días.
3. Sin Critical/High abiertos: `sudo devsecops set FAIL_ON_HIGH true`.
4. Revisión periódica [__]: riesgos aceptados, `sudo devsecops update`, usuarios.
5. Crear usuarios individuales en SonarQube, DefectDojo y Jenkins para cada dev; no compartir las cuentas admin.

## 8. Costos

| Concepto | Costo |
|---|---|
| Licencias de todas las herramientas | $0 (open source) |
| Certificados HTTPS | $0 (Let's Encrypt) |
| DNS | $0 con sslip.io, o el dominio que ya tengan |
| Servicios de CI/secretos de la nube | No se usan |
| Servidor | El que ya tienen; si se crea uno nuevo, se paga la instancia |

## 9. Solución de problemas

| Síntoma | Acción |
|---|---|
| No abre `https://...` | Revisar Security Group (80/443) y que el DNS apunte a la IP; `sudo devsecops logs caddy` |
| SonarQube no arranca | Falta memoria (16 GB); `sudo devsecops logs sonarqube` |
| Job falla en *Checkout* | URL o token del repo; `sudo devsecops add-repo` de nuevo con el mismo nombre |
| “Opengrep no genero reporte” | El servidor no llega a github.com o hubo rate limit |
| ZAP rc=3 | Staging caído o inaccesible desde el servidor |
| Límite de descargas de Docker Hub | Esperar unas horas o iniciar sesión con `docker login` (cuenta gratuita) |
