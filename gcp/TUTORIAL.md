# DevSecOps en Cloud Build · rocket code

## Ejecutar el setup

Corre el script en la terminal de Cloud Shell:

```bash
bash gcp/setup-gcp.sh
```

Te pedirá el proyecto de GCP, las URLs de SonarQube, DefectDojo y staging, y los tokens.
Crea los secretos, da permisos a la cuenta de servicio de Cloud Build y crea los
triggers de push y PR (o lanza un build manual).

## Antes de crear triggers

Conecta el repo de la app una vez en
[Cloud Build → Triggers → Connect repository](https://console.cloud.google.com/cloud-build/triggers/connect).
