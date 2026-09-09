# gitops

La fuente de verdad del clúster de [juan-in-one](https://github.com/juan-in-one). Todo lo que corre —
microservicios propios y plataforma compartida— está declarado aquí. Un `git push` a este repo es el único
mecanismo de despliegue: nunca hay un `kubectl apply` manual salvo el arranque en frío inicial.

## Patrón: App of Apps

```
apps-root.yaml          ← la única Application aplicada a mano, una vez
  └── apps/*.yaml        ← una Application por cada pieza (microservicio o plataforma)
        └── platform/*   ← wrapper de Helm para las piezas de plataforma (chart de terceros + values propios)
```

`apps-root` vigila la carpeta `apps/` de este mismo repo. Añadir un microservicio nuevo, o una pieza de
plataforma nueva, es añadir un archivo a `apps/` y hacer `git push` — ArgoCD detecta el cambio solo y crea
la `Application` correspondiente, sin tocar nada más.

## Qué hay en `apps/`

| Application | Qué despliega |
|---|---|
| `car-api`, `sport-api`, `academy-api`, `web` | Los microservicios propios — cada uno apunta al `chart/` de su propio repo. |
| `postgres`, `vault`, `external-secrets` | Gestión de secretos: Postgres compartido (una base de datos por servicio), Vault, y el operador que sincroniza los secretos de Vault a Kubernetes. |
| `monitoring`, `loki`, `alloy`, `tempo` | Observabilidad: Prometheus + Grafana + Alertmanager, logs, el agente que los recolecta, y trazas distribuidas. |
| `kyverno` | Admission controller — verifica la firma de Cosign de cada imagen y restringe qué registros de origen se admiten (ver `platform/kyverno/templates/`). |
| `ingress-nginx`, `metrics-server`, `argocd-core` | Infraestructura base del clúster. |

## `platform/`

Cada pieza de plataforma que no es un microservicio propio (Postgres, Vault, Loki, Kyverno...) es un
**wrapper de Helm**: un `Chart.yaml` que declara una dependencia sobre el chart oficial del proyecto, y un
`values.yaml` con los overrides necesarios para un clúster de un solo nodo. Ver los comentarios de cada
`values.yaml` — casi todos documentan un problema real encontrado al desplegar (memoria insuficiente,
namespacing raro de la clave del chart, un falso `OutOfSync`...) y por qué se resolvió como se resolvió.

## Secretos

Ningún `Secret` de Kubernetes con datos reales vive en este repo. Cada microservicio tiene un
`ExternalSecret` (`platform/secrets/externalsecret-*.yaml`) que le dice a [External Secrets
Operator](https://external-secrets.io/) dónde leer su contraseña real dentro de Vault — el secreto en sí
nunca toca Git.

## Añadir un microservicio nuevo

1. El repo del microservicio necesita su propio `chart/` de Helm (mismo patrón que `car-api`).
2. Un `Secret` `repo-<nombre>` en el namespace `argocd` (credenciales de solo lectura del repo, se crea a
   mano en el clúster — no en Git).
3. Un `ExternalSecret` en `platform/secrets/` si necesita su propia base de datos.
4. Un archivo nuevo en `apps/` apuntando a su `chart/`.

Nada más. `apps-root` se encarga del resto.

---

Para la arquitectura completa de la plataforma (cadena de suministro firmada, observabilidad, decisiones de
ingeniería), ver el [README de la organización](https://github.com/juan-in-one).
