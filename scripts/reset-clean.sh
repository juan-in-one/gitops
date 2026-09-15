#!/bin/bash
# Borra TODO lo que gestiona OrbStack (Docker + el clúster de Kubernetes
# entero) y lo deja como recién instalado. Distinto de teardown.sh, que
# solo desactiva Kubernetes sin borrar nada (comprobado el 2026-09-15: no
# borra el volumen).
#
# Úsalo después de una prueba, un experimento, o cuando quieras el
# clúster limpio para meter otra cosa. Para volver a tener juan-in-one
# desplegado: 'juan-in-one' (scripts/deploy-all.sh).
set -euo pipefail

echo "Esto borra TODO en OrbStack: Docker (imágenes, contenedores) y el"
echo "clúster de Kubernetes entero. No es reversible."
read -p "¿Seguro? (escribe 'si' para continuar) " confirm
if [ "$confirm" != "si" ]; then
  echo "Cancelado."
  exit 0
fi

orbctl reset -y
echo "Hecho. Para volver a desplegar juan-in-one: juan-in-one"
