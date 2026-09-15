#!/bin/bash
# Despliegue completo de juan-in-one desde un clúster de OrbStack vacío.
#
# A diferencia de bootstrap.sh (que solo hace la parte 100% GitOps), este
# script hace TODO, incluidos los secretos que no viven en Git: GHCR,
# credenciales de los 6 repos, e inicializar/configurar Vault por
# completo. El token root y las claves de unseal de Vault se generan aquí
# mismo, se usan internamente, y NUNCA se imprimen — ni en este script ni
# en su salida. Con el flujo de trabajo de este proyecto (clúster
# desechable, reset completo cada vez), no hace falta guardarlos: la
# próxima vez que se ejecute este script, generará unos nuevos.
#
# Requisitos: `gh auth login` ya hecho (se usa su token para GHCR y para
# los repos privados de GitHub).
set -euo pipefail
cd "$(dirname "$0")/.."

echo "════════════════════════════════════════"
echo " 1/6 — Kubernetes + ArgoCD + app-of-apps"
echo "════════════════════════════════════════"
bash scripts/bootstrap.sh

echo
echo "════════════════════════════════════════"
echo " 2/6 — Credenciales de GHCR"
echo "════════════════════════════════════════"
GH_USER=$(gh api user --jq .login)
GH_TOKEN=$(gh auth token)

for ns in car-api sport-api academy-api web kyverno; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl create secret docker-registry ghcr-pull -n "$ns" \
    --docker-server=ghcr.io \
    --docker-username="$GH_USER" \
    --docker-password="$GH_TOKEN" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  echo "  ghcr-pull en $ns: OK"
done

echo
echo "════════════════════════════════════════"
echo " 3/6 — Credenciales de los repos privados"
echo "════════════════════════════════════════"
# ".github" no es un nombre válido de Secret de Kubernetes (el punto
# pegado al guion rompe la validación) — se usa "github-org" en su lugar.
# A ArgoCD no le importa el nombre del Secret, solo el campo "url" de
# dentro, así que esto es seguro.
# (Arrays asociativos no valen: el bash 3.2 de serie en macOS no los
# soporta — se usan dos arrays normales en paralelo.)
SECRET_NAMES=(gitops github-org car-api sport-api academy-api web)
REPO_NAMES=(gitops .github car-api sport-api academy-api web)
i=0
while [ $i -lt ${#SECRET_NAMES[@]} ]; do
  key="${SECRET_NAMES[$i]}"
  repo="${REPO_NAMES[$i]}"
  kubectl create secret generic "repo-$key" -n argocd \
    --from-literal=type=git \
    --from-literal=url="https://github.com/juan-in-one/$repo.git" \
    --from-literal=username="$GH_USER" \
    --from-literal=password="$GH_TOKEN" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl label secret "repo-$key" -n argocd argocd.argoproj.io/secret-type=repository --overwrite >/dev/null
  echo "  repo-$key -> $repo: OK"
  i=$((i + 1))
done

echo
echo "════════════════════════════════════════"
echo " 4/6 — Vault: inicializar, desellar, configurar"
echo "════════════════════════════════════════"
# En un clúster recién reseteado, ArgoCD puede seguir programando el pod
# de vault-0 cuando llegamos aquí ("pod vault-0 does not have a host
# assigned" al hacer exec). No vale esperar a "condition=ready": un Vault
# sellado nunca pasa el readiness probe, así que "kubectl wait
# --for=condition=ready" se quedaría colgado para siempre en un volumen
# nuevo. Se espera a que la fase sea Running (contenedor arrancado y con
# nodo asignado), que es lo único que hace falta para poder hacer exec.
echo "  Esperando a que vault-0 tenga contenedor arrancado..."
for i in $(seq 1 60); do
  phase=$(kubectl get pod vault-0 -n vault -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  [ "$phase" = "Running" ] && break
  sleep 2
done
if [ "$phase" != "Running" ]; then
  echo "  vault-0 no llegó a Running a tiempo (fase: $phase). Revisa 'kubectl get pods -n vault'." >&2
  exit 1
fi

# "vault status" devuelve exit code 2 cuando está sellado (aunque ya esté
# inicializado) — con pipefail eso rompía la comprobación de antes y
# metía el script por la rama equivocada. Aquí no se usa en un pipe ni
# bajo pipefail: se guarda a fichero aparte y se lee después.
kubectl exec -n vault vault-0 -- vault status -format=json > /tmp/.jio-vault-status.json 2>/dev/null || true
ALREADY_INIT=$(python3 -c 'import json; print(json.load(open("/tmp/.jio-vault-status.json")).get("initialized", False))' 2>/dev/null || echo False)

if [ "$ALREADY_INIT" = "True" ]; then
  echo "  Vault ya estaba inicializado, no se toca (ni se desella otra vez si ya está desellado)."
else
  kubectl exec -n vault vault-0 -- vault operator init -key-shares=5 -key-threshold=3 -format=json > /tmp/.jio-vault-init.json

  python3 - <<'PYEOF'
import json, subprocess
d = json.load(open("/tmp/.jio-vault-init.json"))
for k in d["unseal_keys_b64"][:3]:
    subprocess.run(["kubectl", "exec", "-n", "vault", "vault-0", "--", "vault", "operator", "unseal", k], capture_output=True)
subprocess.run(["kubectl", "exec", "-i", "-n", "vault", "vault-0", "--", "vault", "login", "-"], input=d["root_token"], text=True, capture_output=True)
print("  Vault inicializado, desellado y autenticado (token no mostrado).")
PYEOF

  kubectl exec -n vault vault-0 -- vault secrets enable -path=secret kv-v2 >/dev/null 2>&1 || true
  kubectl exec -n vault vault-0 -- vault auth enable kubernetes >/dev/null 2>&1 || true
  kubectl exec -n vault vault-0 -- vault write auth/kubernetes/config kubernetes_host=https://kubernetes.default.svc >/dev/null

  kubectl exec -i -n vault vault-0 -- vault policy write eso-policy - >/dev/null <<'POLICY'
path "secret/data/*" {
  capabilities = ["read"]
}
POLICY

  kubectl exec -n vault vault-0 -- vault write auth/kubernetes/role/eso-role \
    bound_service_account_names=external-secrets \
    bound_service_account_namespaces=external-secrets \
    policies=eso-policy ttl=1h >/dev/null

  python3 - <<'PYEOF'
import json, subprocess, secrets, string

def genpw():
    alphabet = string.ascii_letters + string.digits
    return "".join(secrets.choice(alphabet) for _ in range(24))

pw = {k: genpw() for k in ["postgres", "car_api", "sport_api", "academy_api", "grafana"]}

subprocess.run(["kubectl", "exec", "-n", "vault", "vault-0", "--", "vault", "kv", "put", "secret/postgres",
    f"postgres-password={pw['postgres']}",
    f"car-api-password={pw['car_api']}",
    f"sport-api-password={pw['sport_api']}",
    f"academy-api-password={pw['academy_api']}"], capture_output=True, check=True)

subprocess.run(["kubectl", "exec", "-n", "vault", "vault-0", "--", "vault", "kv", "put", "secret/grafana",
    f"admin-password={pw['grafana']}"], capture_output=True, check=True)

print("  secret/postgres y secret/grafana escritos (contraseñas nuevas, no mostradas).")
PYEOF
fi

kubectl rollout restart deployment/external-secrets -n external-secrets >/dev/null
kubectl rollout status deployment/external-secrets -n external-secrets --timeout=60s >/dev/null

echo
echo "════════════════════════════════════════"
echo " 5/6 — Bases de datos por servicio en Postgres"
echo "════════════════════════════════════════"
kubectl wait --for=condition=ready pod/postgres-postgresql-0 -n platform --timeout=180s

python3 - <<'PYEOF'
import json, subprocess

# Las contraseñas se leen de Vault directamente (la fuente de verdad),
# no de un fichero temporal entre pasos — así el script es idempotente de
# verdad, tanto si Vault se acaba de configurar en este mismo run como si
# ya lo estaba de antes.
kv = subprocess.run(
    ["kubectl", "exec", "-n", "vault", "vault-0", "--", "vault", "kv", "get", "-format=json", "secret/postgres"],
    capture_output=True, text=True, check=True,
)
data = json.loads(kv.stdout)["data"]["data"]
pw = {
    "car_api": data["car-api-password"],
    "sport_api": data["sport-api-password"],
    "academy_api": data["academy-api-password"],
}

admin_pw = subprocess.run(
    ["kubectl", "exec", "-n", "platform", "postgres-postgresql-0", "--", "sh", "-c",
     "cat /opt/bitnami/postgresql/secrets/postgres-password"],
    capture_output=True, text=True,
).stdout.strip()

def psql(sql):
    return subprocess.run(
        ["kubectl", "exec", "-n", "platform", "postgres-postgresql-0", "--",
         "env", f"PGPASSWORD={admin_pw}", "psql", "-U", "postgres", "-c", sql],
        capture_output=True, text=True,
    )

for svc in ["car_api", "sport_api", "academy_api"]:
    p = pw[svc]
    r1 = psql(f"CREATE USER {svc} WITH PASSWORD '{p}';")
    if "already exists" in r1.stderr:
        psql(f"ALTER USER {svc} WITH PASSWORD '{p}';")
    r2 = psql(f"CREATE DATABASE {svc} OWNER {svc};")
    print(f"  {svc}: OK" if ("already exists" in r1.stderr or r1.returncode == 0) else f"  {svc}: revisar -> {r1.stderr[:100]}")
PYEOF

echo
echo "════════════════════════════════════════"
echo " 6/6 — Forzar el primer sync de las 4 apps"
echo "════════════════════════════════════════"
for app in car-api sport-api academy-api web; do
  kubectl patch application "$app" -n argocd --type merge \
    -p '{"operation":{"initiatedBy":{"username":"bootstrap"},"sync":{"revision":"HEAD"}}}' >/dev/null
done
sleep 15
kubectl get applications -n argocd

# Limpieza: el root token de Vault no hace falta guardarlo (la próxima vez
# que se corra este script, se genera uno nuevo) — se borra del disco en
# vez de dejarlo tirado en /tmp indefinidamente.
rm -f /tmp/.jio-vault-init.json /tmp/.jio-vault-status.json

echo
echo "Listo. Prueba: curl http://juan-in-one.local/api/car-api/health"
echo "Si tienes una copia de pg_dump de antes, restáurala con:"
echo '  kubectl exec -i -n platform postgres-postgresql-0 -- env PGPASSWORD=... psql -U postgres -d car_api < backup.sql'
