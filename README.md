# rocket code · DevSecOps 100% open source (SAST · SCA · DAST)

> Uso interno de rocket code. Proceso completo: [PR-DSO-001](docs/PROCESO.md).

Escaneo de seguridad para todos los repositorios, **sin licencias ni servicios de pago**. Todo corre en **un servidor propio** (por ejemplo, una EC2 que ya tengan en AWS):

| Componente | Para qué | Licencia |
|---|---|---|
| Opengrep | SAST: patrones inseguros en el código | LGPL-2.1 |
| SonarQube Community Build | Calidad y security hotspots | LGPL-3.0 |
| Trivy | SCA: dependencias, secretos, IaC | Apache-2.0 |
| ZAP | DAST contra staging | Apache-2.0 |
| DefectDojo | Tablero único de hallazgos | BSD-3-Clause |
| Jenkins | CI que dispara los escaneos | MIT |
| Caddy + Let's Encrypt | HTTPS gratuito | Apache-2.0 |
| Docker Engine | Contenedores | Apache-2.0 |

No usa CodeBuild, Cloud Build, Azure Pipelines de pago, Secrets Manager ni ningún otro servicio facturable.

## 1. Preparar el servidor (una vez)

- Ubuntu 22.04 o 24.04, **4 vCPU, 16 GB RAM, 100 GB de disco**, con salida a internet.
- Puertos de entrada: **22** (solo tu IP), **80** y **443** (abiertos).
- IP fija (en AWS, una Elastic IP). Dominio opcional: si no hay, se usa `sslip.io`.

## 2. Instalar (un comando, en el servidor)

Conéctate por SSH o con **EC2 Instance Connect** (botón *Connect* en la consola de AWS) y pega:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/TheRocketCodeMX/SAST-DAST-Scan/main/server/install.sh)"
```

Pide el dominio (o usa el sugerido) y un correo. Al terminar muestra las URLs:

- `https://sonar.<dominio>` · SonarQube
- `https://dojo.<dominio>` · DefectDojo
- `https://ci.<dominio>` · Jenkins

## 3. Agregar repositorios

```bash
sudo devsecops add-repo
```

Funciona con cualquier git por HTTPS: **GitHub, Azure Repos, GitLab, Bitbucket, CodeCommit, Gitea**. Para repos privados pide un token de **solo lectura**. Jenkins revisa cada 5 minutos las ramas configuradas; cuando hay un commit nuevo corre el escaneo y sube los hallazgos a DefectDojo. No hay que cambiar nada en los repos de las apps.

## Comandos

```
sudo devsecops add-repo              agrega un repo
sudo devsecops list                  lista los repos
sudo devsecops remove-repo NOMBRE    quita un repo
sudo devsecops status                estado y URLs
sudo devsecops credentials           usuarios admin
sudo devsecops set FAIL_ON_HIGH true bloquear builds con Critical/High
sudo devsecops set ZAP_MODE full     DAST activo (solo staging)
sudo devsecops update                actualiza las imágenes
sudo devsecops logs jenkins          logs
```

## Contenido

```
server/install.sh             instalador del servidor
server/devsecops              comando de administración
devsecops/devsecops-scan.sh   escaneo (Opengrep, SonarQube, Trivy, ZAP → DefectDojo)
docs/PROCESO.md               proceso PR-DSO-001
```
