# K3S in Alpine-VM with Traefik 2.x and ArgoCD

## Install vagrant

`dnf install libvirt vagrant vagrant-libvirt vagrant-sshfs`

## Clone this Repo

```lang=bash
git clone https://github.com/der-mac/k3s.git
cd k3s
```

## Customize the cluster if needed

Edit the `config`-file to your requirements.

## Create VM

`vagrant up`

## Test Cluster-Access

`kubectl --kubeconfig kubeconfig/k3s.yaml cluster-info`

## Access tools from local mashine

Add the following line to your local host-file (/etc/hosts).
Change it, if you set custom-hostnames.

`127.0.0.1 traefik.example.com argocd.example.com`

Open Traefik-Dashboard in Browser [https://traefik.example.com:8443/dashboard/](https://traefik.example.com:8443/dashboard/)

Open ArgoCD in Browser [https://argocd.example.com:8443/dashboard/](https://argocd.example.com:8443/)
