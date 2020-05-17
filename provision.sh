#!/bin/bash
set -ve

#
# only during vagrant provisioning
#
if [ ! -f /etc/vagrant_box_build_time ]; then
  exit 1
fi

#
# Load config if exists
#
if [ -f /tmp/config ]; then
  . /tmp/config
fi

#
# Change vagrant user to root per default
#
cat <<EOF >/etc/profile.d/root.sh
[ $EUID -ne 0 ] && exec sudo -i
EOF

#
# Color Prompt
# From https://github.com/rancher/k3s
#
sed -i 's|:/bin/ash$|:/bin/bash|g' /etc/passwd
cat <<\EOF >/etc/profile.d/color.sh
alias ls='ls --color=auto'
export PS1='\033[31m[ \033[90m\D{%F 🐮 %T}\033[31m ]\n\[\033[36m\]\u\[\033[m\]@\[\033[32m\]\h\[\033[35m\]:\[\033[33;1m\]\w\[\033[m\]\$ '
EOF

#
# Message of the day
# From https://github.com/rancher/k3s
#
cat <<\EOF >/etc/motd
               ,        ,
   ,-----------|'------'| |\    ____
  /.           '-'@  o|-' | |  /___ \
 |/|             | .. |   | | __ __) | ____
   |   .________.'----'   | |/ /|__ < / __/
   |  ||        |  ||     |   < ___) |\__ \
   \__|'        \__|'     |_|\_\_____/____/

EOF

#
# Install additional packages
#
apk add -q -f curl libc6-compat tzdata git wait4ports bash-completion jq apache2-utils

#
# Install k3s without traefik 1.x
#
curl -sfL https://get.k3s.io | sh -s - --no-deploy traefik --write-kubeconfig-mode 644

#
# Wait for kubeconfig to use kubectl
#
while [ ! -f /etc/rancher/k3s/k3s.yaml ]; do
  echo "Wait for kubeconfig..."
  sleep 2
done

#
# Wait for kubeapi-port to ensure the cluster is up and running
#
/usr/bin/wait4ports tcp://127.0.0.1:6443 && echo "Kubernetes up!"

#
# Copy config to use it outside the virtual mashine
#
mkdir -p /root/kubeconfig
cp /etc/rancher/k3s/* /root/kubeconfig/

#
# Enable bash-completion for kubectl
#
echo 'source <(kubectl completion bash)' >>~/.profile
source <(kubectl completion bash)

#
# Install helm
#
curl -f -o helm.tgz https://get.helm.sh/helm-v3.1.2-linux-amd64.tar.gz
tar -xzf helm.tgz
mv linux-amd64/helm /usr/local/bin/helm
rm -f helm.tgz
rm -rf linux-amd64/

#
# Install traefik 2.x
#
kubectl create namespace traefik

helm repo add traefik https://containous.github.io/traefik-helm-chart
helm repo update
helm --kubeconfig /etc/rancher/k3s/k3s.yaml install -n traefik traefik traefik/traefik

#
# Fetch default certificate for traefik, if set
#
curl -so tls.crt $K3S_DEFAULT_CERTFILE_URL 2>/dev/null || echo "curl-cert-error" > tls.crt
curl -so tls.key $K3S_DEFAULT_CERTKEY_URL 2>/dev/null || echo "curl-key-error" > tls.key

#
# Check if key and certificate matches
#
CERT_MD5=$(openssl x509 -noout -modulus -in tls.crt 2>/dev/null | openssl md5)
KEY_MD5=$(openssl rsa -noout -modulus -in tls.key 2>/dev/null | openssl md5)

#
# Default tlsstore 
#
cat <<EOF > tlsstore.yaml
apiVersion: traefik.containo.us/v1alpha1
kind: TLSStore
metadata:
  name: default
  namespace: traefik

spec:
  defaultCertificate:
    secretName: traefik-default-cert
EOF

#
# Replace traefik certificates if key and cert are ok
#
if [ ! -z $K3S_DEFAULT_CERTFILE_URL ] &&
   [ ! -z $K3S_DEFAULT_CERTKEY_URL ] &&
   [ ! "$(cat tls.crt)" == "curl-cert-error" ] &&
   [ ! "$(cat tls.key)" == "curl-key-error" ] &&
   [ "$CERT_MD5" == "$KEY_MD5" ]; then
  echo "Custom default-certifikate and key matches."
  echo "Replacing default-traefik-certificate..."
  kubectl create secret generic traefik-default-cert --from-file=./tls.crt --from-file=./tls.key -n traefik
  kubectl -n traefik apply -f tlsstore.yaml
fi

rm -f tls.key tls.crt tlsstore.yaml

#
# Configure traefik options
#
kubectl -n traefik get deployments.apps traefik -o json | \
  jq '(
    .spec.template.spec.containers[] |
    select(.name == "traefik") |
    .args 
  ) = [
    "--global.checknewversion=false",
    "--global.sendanonymoususage=false",
    "--log.level=INFO",
    "--entryPoints.traefik.address=:9000",
    "--entryPoints.web.address=:8000",
    "--entryPoints.websecure.address=:8443",
    "--api.dashboard=true",
    "--api.insecure=true",
    "--ping=true",
    "--providers.kubernetescrd"
  ]' | \
  kubectl -n traefik apply -f -

#
# Create ingressroute for traefik
#
cat <<EOF > ingressroute.yml
apiVersion: traefik.containo.us/v1alpha1
kind: IngressRoute
metadata:
  labels:
    app: traefik
  name: traefik-dashboard-ingressroute
  namespace: traefik
spec:
  entryPoints:
  - websecure
  routes:
  - kind: Rule
    match: Host(\`${K3S_TREAFIK_HOSTNAME:-traefik.example.com}\`)
    services:
    - name: api@internal
      kind: TraefikService
  tls: {}
EOF
kubectl -n traefik apply -f ingressroute.yml && rm -f ingressroute.yml

#
# Install argocd
#
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

#
# Create ingressroute for argocd
#
cat <<EOF > ingressroute.yml
apiVersion: traefik.containo.us/v1alpha1
kind: IngressRoute
metadata:
  labels:
    app: argocd-server
  name: argocd-server-ingressroute
  namespace: argocd
spec:
  entryPoints:
  - websecure
  routes:
  - kind: Rule
    match: Host(\`${K3S_ARGOCD_HOSTNAME:-argocd.example.com}\`)
    services:
    - name: argocd-server
      port: 80
  tls: {}
EOF
kubectl -n argocd apply -f ingressroute.yml && rm -f ingressroute.yml

#
# Add '--insecure' to argocd-server command
#
kubectl -n argocd get deployments.apps argocd-server -o json | \
  jq '(
    .spec.template.spec.containers[] |
    select(
      .name == "argocd-server"
    ) |
    .command[.command| length]
  ) |= . + "--insecure"' | \
  kubectl -n argocd apply -f -

#
# Set admin password for argocd (password)
#
PASSWORD=$(htpasswd -bnBC 10 "" "${K3S_ARGOCD_PASSWORD:-password}" | tr -d ':\n' | sed 's/$2y/$2a/')

kubectl -n argocd patch secret argocd-secret \
  -p '{"stringData": {
    "admin.password": "'$PASSWORD'",
    "admin.passwordMtime": "'$(date +%FT%T%Z)'"
  }}'

