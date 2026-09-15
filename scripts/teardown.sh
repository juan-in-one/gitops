#!/bin/bash
# Apaga Kubernetes en OrbStack para liberar recursos, sin borrar nada del
# repo (GitOps es la fuente de verdad, así que la vuelta atrás es solo
# volver a correr bootstrap.sh).
#
# OJO con los datos reales: los datos de Postgres (car-api/sport-api/
# academy-api) y de Vault viven en el disco de la VM de OrbStack. En la
# práctica, desactivar y reactivar k8s.enable NO los ha borrado (probado
# el 2026-09-15) — pero no está garantizado que siga siendo así en el
# futuro. Si quieres estar tranquilo, haz antes un volcado real:
#
#   kubectl exec -n platform postgres-postgresql-0 -- sh -c \
#     'PGPASSWORD=$(cat /opt/bitnami/postgresql/secrets/postgres-password) \
#      pg_dump -U postgres -d car_api' > car_api_backup.sql
#
#   (repetir para sport_api y academy_api)
set -euo pipefail

echo "Esto apaga Kubernetes en OrbStack. Los pods dejan de correr."
read -p "¿Seguro? (escribe 'si' para continuar) " confirm
if [ "$confirm" != "si" ]; then
  echo "Cancelado."
  exit 0
fi

orbctl config set k8s.enable false
echo "Hecho. Reinicia OrbStack para que se aplique del todo."
echo "Para volver a levantarlo: bash gitops/scripts/bootstrap.sh"
