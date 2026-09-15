# Levantar la plataforma desde cero

## La forma rápida

```bash
bash gitops/scripts/deploy-all.sh
```

Hace todo: activa Kubernetes en OrbStack, instala ArgoCD, aplica el
app-of-apps, crea las credenciales de GHCR y de los 6 repos (usa tu
`gh auth token`, tiene que estar autenticado), inicializa/desella/configura
Vault por completo (genera contraseñas nuevas, el token root no se imprime
en ningún momento ni se guarda en ningún sitio), crea las bases de datos
por servicio, y fuerza el primer sync. Probado dos veces seguidas contra
un clúster recién reseteado — de verdad funciona de punta a punta.

Si tienes una copia de `pg_dump` de antes de desmontar el clúster, restáurala
al final (ver `scripts/teardown.sh` para cómo se generó):

```bash
kubectl exec -i -n platform postgres-postgresql-0 -- sh -c \
  'PGPASSWORD=$(cat /opt/bitnami/postgresql/secrets/postgres-password) psql -U postgres -d car_api' \
  < car_api_backup.sql
```

## Paso a paso, si quieres hacerlo a mano (o entender qué hace el script)

`scripts/bootstrap.sh` automatiza solo la parte 100% GitOps (Kubernetes +
ArgoCD + app-of-apps). Lo de aquí abajo es lo que ese script deliberadamente
no hace, porque necesita credenciales reales tuyas — y por eso no está en
ningún script versionado en un repo público sin más.

### 1. Credenciales de GHCR (para tirar de las imágenes)

Un `imagePullSecret` por cada namespace de aplicación — **y también en
`kyverno`**: la política de firma consulta el registro ella misma para
verificar la firma de cada imagen, y necesita sus propias credenciales para
eso, no le sirven las de los namespaces de las apps.

```bash
for ns in car-api sport-api academy-api web kyverno; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
  kubectl create secret docker-registry ghcr-pull \
    -n "$ns" \
    --docker-server=ghcr.io \
    --docker-username=<tu-usuario-de-github> \
    --docker-password=<un-token-con-read:packages>
done
```

### 2. Credenciales de Git (para que ArgoCD lea los repos privados)

Un `Secret` por cada uno de los 6 repos — **no se comparte uno solo para
todos**, cada repo necesita el suyo. Ojo con `.github`: un nombre de Secret
no puede tener un punto pegado a un guion (`repo-.github` es inválido);
usa cualquier nombre válido, a ArgoCD no le importa el nombre del Secret,
solo el campo `url` de dentro.

```bash
for repo in gitops .github car-api sport-api academy-api web; do
  name=$(echo "repo-$repo" | sed 's/repo-\.github/repo-github-org/')
  kubectl create secret generic "$name" -n argocd \
    --from-literal=type=git \
    --from-literal=url="https://github.com/juan-in-one/$repo.git" \
    --from-literal=username=<tu-usuario-de-github> \
    --from-literal=password=<un-token-con-repo>
  kubectl label secret "$name" -n argocd argocd.argoproj.io/secret-type=repository
done
```

### 3. Vault — hazlo tú, con tu propio token

**No pegues el root token ni las claves de unseal en un chat.** Corre esto
tú mismo en tu terminal.

```bash
# Inicializar (solo la primera vez que el volumen está vacío de verdad)
kubectl exec -n vault vault-0 -- vault operator init

# Guarda las 5 claves de unseal y el root token en tu gestor de
# contraseñas, no en ningún fichero de este repo.

# Desellar (necesitas 3 de las 5 claves)
kubectl exec -n vault vault-0 -- vault operator unseal <clave-1>
kubectl exec -n vault vault-0 -- vault operator unseal <clave-2>
kubectl exec -n vault vault-0 -- vault operator unseal <clave-3>

# Autenticado con el root token (ej. "vault login <token>" dentro del pod):
vault secrets enable -path=secret kv-v2

vault auth enable kubernetes
vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc"

vault policy write eso-policy - <<'POLICY'
path "secret/data/*" {
  capabilities = ["read"]
}
POLICY

vault write auth/kubernetes/role/eso-role \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=eso-policy \
  ttl=1h

# Las contraseñas reales que leen los ExternalSecret — genera unas nuevas,
# no reutilices las viejas si el volumen se recreó de cero:
vault kv put secret/postgres \
  postgres-password=<nueva-contraseña> \
  car-api-password=<nueva-contraseña> \
  sport-api-password=<nueva-contraseña> \
  academy-api-password=<nueva-contraseña>

vault kv put secret/grafana admin-password=<nueva-contraseña>
```

Después de escribir en Vault, reinicia External Secrets para que recoja los
valores nuevos ya mismo (si no, espera hasta 1h al `refreshInterval`):

```bash
kubectl rollout restart deployment/external-secrets -n external-secrets
```

### 4. Bases de datos en Postgres

El chart de Postgres solo crea usuarios/bases en el primer arranque con el
volumen vacío (y `car_api` en concreto puede que ya exista de fábrica según
la configuración del chart — usa `ALTER USER` en vez de `CREATE USER` si
falla por ya existir):

```bash
for svc in car_api sport_api academy_api; do
  kubectl exec -n platform postgres-postgresql-0 -- sh -c \
    "PGPASSWORD=\$(cat /opt/bitnami/postgresql/secrets/postgres-password) \
     psql -U postgres -c \"CREATE USER $svc WITH PASSWORD '<misma-contraseña-que-en-vault>';\""
  kubectl exec -n platform postgres-postgresql-0 -- sh -c \
    "PGPASSWORD=\$(cat /opt/bitnami/postgresql/secrets/postgres-password) \
     psql -U postgres -c \"CREATE DATABASE $svc OWNER $svc;\""
done
```

### 5. Forzar el primer sync

`selfHeal` debería encargarse solo, pero la primera vez puede tardar en
reintentar tras arreglar los secretos — para no esperar:

```bash
for app in car-api sport-api academy-api web; do
  kubectl patch application "$app" -n argocd --type merge \
    -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"HEAD"}}}'
done
```

## Nota sobre si hace falta todo esto

El 2026-09-15 se comprobó que desactivar `k8s.enable` en OrbStack y volver
a activarlo **no borró el volumen** — Postgres y Vault seguían con sus
datos tal cual. Un `orbctl reset` sí lo borra todo de verdad (probado el
mismo día) — es la forma de tener un clúster realmente limpio para otros
proyectos, y es justo el escenario para el que está pensado
`deploy-all.sh`.
