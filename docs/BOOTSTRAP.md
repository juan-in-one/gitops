# Levantar la plataforma desde cero

`scripts/bootstrap.sh` automatiza lo que GitOps puede hacer solo. Esto de
aquí es lo que **no** puede — porque necesita credenciales reales tuyas —
y por eso no está en ningún script versionado en un repo público.

```bash
bash gitops/scripts/bootstrap.sh
```

Cuando termine, ArgoCD ya está desplegando todo lo demás (Postgres, Vault,
observabilidad, Kyverno, las 4 apps...) pero varias piezas se quedarán en
`Degraded`/`Progressing` hasta hacer lo siguiente.

## 1. Credenciales de GHCR (para tirar de las imágenes)

Un `imagePullSecret` por cada namespace de aplicación:

```bash
for ns in car-api sport-api academy-api web; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
  kubectl create secret docker-registry ghcr-pull \
    -n "$ns" \
    --docker-server=ghcr.io \
    --docker-username=<tu-usuario-de-github> \
    --docker-password=<un-token-con-read:packages>
done
```

## 2. Credenciales de Git (para que ArgoCD lea los repos privados)

Un `Secret` por cada uno de los 6 repos — **no se comparte uno solo para
todos**, cada repo necesita el suyo:

```bash
for repo in gitops .github car-api sport-api academy-api web; do
  kubectl create secret generic "repo-$repo" -n argocd \
    --from-literal=type=git \
    --from-literal=url="https://github.com/juan-in-one/$repo.git" \
    --from-literal=username=<tu-usuario-de-github> \
    --from-literal=password=<un-token-con-repo>
  kubectl label secret "repo-$repo" -n argocd argocd.argoproj.io/secret-type=repository
done
```

## 3. Vault — hazlo tú, con tu propio token

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

# Dentro de una sesión ya autenticada con el root token:
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
  car-api-password=<nueva-contraseña> \
  sport-api-password=<nueva-contraseña> \
  academy-api-password=<nueva-contraseña> \
  grafana-password=<nueva-contraseña>
```

## 4. Bases de datos en Postgres

El chart de Postgres solo crea usuarios/bases en el primer arranque con el
volumen vacío — si el volumen ya existía (ver más abajo), esto no hace
falta.

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

## 5. Restaurar tus datos reales (opcional)

Si tienes una copia de `pg_dump` de antes de desmontar el clúster
(ver `scripts/teardown.sh`):

```bash
kubectl exec -i -n platform postgres-postgresql-0 -- sh -c \
  "PGPASSWORD=\$(cat /opt/bitnami/postgresql/secrets/postgres-password) \
   psql -U postgres -d car_api" < car_api_backup.sql
```

## Nota sobre si hace falta todo esto

El 2026-09-15 se comprobó que desactivar `k8s.enable` en OrbStack y
volver a activarlo **no borró el volumen** — Postgres y Vault seguían con
sus datos tal cual, sin necesidad de repetir ningún paso de este
documento. Si eso se mantiene así, la mayoría de esto solo hace falta la
primera vez, o si algún día se destruye la VM de OrbStack de verdad (no
solo se desactiva Kubernetes).
