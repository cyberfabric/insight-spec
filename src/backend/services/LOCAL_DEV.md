# Local Kubernetes Development

Guide for running Insight backend services on a local Kubernetes cluster. Updated as new services are added.

## Prerequisites

- **Docker Desktop** or **OrbStack** (macOS) — container runtime
- **Local K8s** — one of:
  - OrbStack (built-in K8s, recommended for macOS)
  - minikube (`brew install minikube`)
  - kind (`brew install kind`)
  - Docker Desktop Kubernetes (Settings → Kubernetes → Enable)
- **Helm 3** — `brew install helm`
- **kubectl** — `brew install kubectl`
- **Rust 1.92+** — `rustup update stable`
- **protoc** — `brew install protobuf` (required for gRPC code generation)

## Cluster setup

### OrbStack (recommended)

OrbStack includes a single-node K8s cluster. Enable it in OrbStack settings.

```bash
kubectl cluster-info
kubectl get nodes
```

### minikube

```bash
minikube start --memory=4096 --cpus=4
```

### kind

```bash
kind create cluster --name insight
```

## Building images

The Insight backend depends on cyberfabric-core via path dependencies. The Docker build context must include both repos. The expected directory layout:

```
cf/
├── cyberfabric-core/    # cyberfabric-core repo
└── insight/             # this repo
```

### Build API Gateway image

From the `cf/` parent directory:

```bash
cd /path/to/cf

docker build \
  -f insight/src/backend/services/api-gateway/Dockerfile \
  -t insight-api-gateway:dev \
  .
```

### Load image into cluster

```bash
# OrbStack — local images are already available, no extra step.

# minikube:
minikube image load insight-api-gateway:dev

# kind:
kind load docker-image insight-api-gateway:dev --name insight
```

## Services

### API Gateway

The entry point for all backend requests. Validates JWT tokens via OIDC and routes to service modules.

#### Deploy without auth (quickstart)

No OIDC provider needed. All requests get root access.

```bash
cd insight/src/backend

helm install insight-gw services/api-gateway/helm/ \
  --set image.repository=insight-api-gateway \
  --set image.tag=dev \
  --set image.pullPolicy=Never \
  --set authDisabled=true \
  --set ingress.enabled=false
```

Verify and access:

```bash
kubectl get pods -l app.kubernetes.io/name=api-gateway
kubectl logs -l app.kubernetes.io/name=api-gateway -f

# Port-forward to access locally
kubectl port-forward svc/insight-gw-api-gateway 8080:8080
curl http://localhost:8080/api/v1/docs
```

#### Deploy with OIDC (Okta)

Requires an Okta application. See `plugins/oidc-authn-plugin/README.md` for IdP setup.

```bash
helm install insight-gw services/api-gateway/helm/ \
  --set image.repository=insight-api-gateway \
  --set image.tag=dev \
  --set image.pullPolicy=Never \
  --set oidc.issuerUrl=https://dev-12345.okta.com/oauth2/default \
  --set oidc.audience=api://insight \
  --set oidc.clientId=YOUR_FRONTEND_CLIENT_ID \
  --set oidc.redirectUri=http://localhost:3000/callback \
  --set ingress.enabled=false
```

Port-forward and test:

```bash
kubectl port-forward svc/insight-gw-api-gateway 8080:8080

# Public endpoint (no auth):
curl http://localhost:8080/api/v1/auth/config

# Authenticated endpoint:
TOKEN=$(curl -s -X POST https://dev-12345.okta.com/oauth2/default/v1/token \
  -d grant_type=client_credentials \
  -d client_id=YOUR_CLIENT_ID \
  -d client_secret=YOUR_CLIENT_SECRET \
  -d scope=openid | jq -r .access_token)

curl -H "Authorization: Bearer $TOKEN" http://localhost:8080/api/v1/docs
```

#### Uninstall

```bash
helm uninstall insight-gw
```

## Running without Kubernetes

For fast iteration, run the binary directly. No Docker or K8s needed.

```bash
cd insight/src/backend

# No auth (dev mode)
cargo run --bin insight-api-gateway -- run -c services/api-gateway/config/no-auth.yaml

# With OIDC
OIDC_ISSUER_URL=https://dev-12345.okta.com/oauth2/default \
OIDC_AUDIENCE=api://insight \
OIDC_CLIENT_ID=your-frontend-client-id \
OIDC_REDIRECT_URI=http://localhost:3000/callback \
cargo run --bin insight-api-gateway -- run -c services/api-gateway/config/insight.yaml
```

## Troubleshooting

### Build fails with "Could not find protoc"

```bash
brew install protobuf
```

### Pod stuck in CrashLoopBackOff

```bash
kubectl logs -l app.kubernetes.io/name=api-gateway --previous
```

Common causes:
- Missing OIDC env vars when `authDisabled=false`
- JWKS endpoint unreachable from inside cluster (DNS/firewall)
- Port conflict on 8080

### Cannot reach service from host

```bash
kubectl get svc
kubectl port-forward svc/insight-gw-api-gateway 8080:8080
```

### OIDC token rejected

- Check issuer URL matches token's `iss` claim exactly (trailing slash matters)
- Check audience matches token's `aud` claim
- Check clock skew (`leeway_seconds` default is 60s)
- Check JWKS keys loaded: look for "OIDC authn plugin initialized" in logs
