#!/bin/bash
# Levanta la plataforma juan-in-one desde cero en OrbStack.
#
# Automatiza lo que es de verdad automatizable (activar Kubernetes en
# OrbStack, instalar ArgoCD, aplicar el app-of-apps) — a partir de ahí,
# GitOps hace el resto solo. Lo que NO automatiza a propósito son los
# secretos reales (token de GHCR, token de GitHub para los repos privados,
# inicialización de Vault): eso necesita credenciales tuyas, y no tiene
# sentido dejarlas escritas en un script de un repo público. Ver
# docs/BOOTSTRAP.md para esa parte, paso a paso.
set -euo pipefail

echo "== 1/4 — Kubernetes en OrbStack =="
if [ "$(orbctl config get k8s.enable 2>/dev/null)" != "true" ]; then
  echo "Activando Kubernetes en OrbStack..."
  orbctl config set k8s.enable true
  echo "OrbStack necesita reiniciarse para aplicar el cambio."
  echo "Reinícialo tú (icono de la barra de menú, o 'orbctl stop' y vuelve a abrir la app) y ejecuta este script otra vez."
  exit 0
fi

echo "Esperando a que el nodo esté listo..."
until kubectl get nodes 2>/dev/null | grep -q " Ready "; do
  sleep 2
done
echo "Nodo listo."

echo
echo "== 2/4 — Instalar ArgoCD (si no está ya) =="
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
# --server-side: el CRD de ApplicationSet es demasiado grande para el apply
# de cliente normal (desborda el límite de 262144 bytes de la anotación
# donde guarda la configuración anterior) — mismo problema que ya tuvimos
# con los CRDs de Kyverno, comprobado en real al ejecutar este script
# contra un clúster limpio.
kubectl apply --server-side -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "Esperando a que argocd-server esté listo (puede tardar unos minutos: pull de varias imágenes a la vez en un nodo recién arrancado)..."
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

echo
echo "== 3/4 — Aplicar el app-of-apps =="
kubectl apply -f "$(dirname "$0")/../apps-root.yaml"

echo
echo "== 4/4 — Esperando a que ArgoCD sincronice todo (unos minutos) =="
sleep 10
kubectl get applications -n argocd 2>/dev/null || true

# El manifiesto crudo de ArgoCD (paso 2/4) crea argocd-server con la config
# por defecto (server.insecure=false). La Application "argocd-core" parchea
# después el ConfigMap argocd-cmd-params-cm a server.insecure=true (para
# que ingress-nginx pueda hablarle en HTTP sin bucle de redirección a
# HTTPS) — pero argocd-server solo lee ese ConfigMap al arrancar, no en
# caliente. Sin este reinicio, la UI queda en un bucle infinito de
# redirección a HTTPS (comprobado en real: hasta "curl" con -L lo sufre).
# Se espera a que argocd-core esté Synced antes de reiniciar, para no
# reiniciar con el ConfigMap todavía sin parchear.
echo "Esperando a que argocd-core (el ConfigMap de ArgoCD) esté sincronizado..."
for i in $(seq 1 60); do
  sync=$(kubectl get application argocd-core -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "")
  [ "$sync" = "Synced" ] && break
  sleep 5
done
if [ "$sync" = "Synced" ]; then
  echo "Reiniciando argocd-server para que recoja server.insecure=true..."
  kubectl rollout restart deployment/argocd-server -n argocd
  kubectl rollout status deployment/argocd-server -n argocd --timeout=120s
else
  echo "argocd-core no llegó a Synced a tiempo — reinicia argocd-server a mano cuando sincronice:" >&2
  echo "  kubectl rollout restart deployment/argocd-server -n argocd" >&2
fi

cat <<'EOF'

────────────────────────────────────────────────────────────────────
GitOps ya está desplegando el resto solo. Pero ANTES de que las apps
puedan arrancar de verdad, faltan los secretos que no viven en Git:

  1. ghcr-pull (imagePullSecret) en cada namespace: car-api, sport-api,
     academy-api, web.
  2. repo-<nombre> (credenciales de Git) en el namespace argocd, uno
     por cada uno de los 6 repos privados.
  3. Inicializar/desellar Vault, y configurar el auth de Kubernetes +
     la política para External Secrets Operator.
  4. Crear las bases de datos y usuarios en Postgres (una por servicio)
     y escribir sus contraseñas reales en Vault.

Todo esto, paso a paso con los comandos exactos, está en
gitops/docs/BOOTSTRAP.md — a propósito NO está en este script.

Comprueba el progreso con:
  kubectl get applications -n argocd
  kubectl get pods -A | grep -v Running
────────────────────────────────────────────────────────────────────
EOF
