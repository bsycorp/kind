#!/bin/bash
docker pull nginx:1.13 # used by config-serve

# Add images here for them to be available at runtime
# for example:
# docker pull quay.io/kubernetes-ingress-controller/nginx-ingress-controller:0.9.0

kubectl config set-context --current --namespace=kube-system
git clone https://github.com/kubernetes-csi/external-snapshotter
kubectl create -f external-snapshotter/config/crd
sed -i -e 's/default/kube-system/g' external-snapshotter/deploy/kubernetes/csi-snapshotter/rbac-csi-snapshotter.yaml
sed -i -e 's/default/kube-system/g' external-snapshotter/deploy/kubernetes/csi-snapshotter/rbac-external-provisioner.yaml
sed -i -e 's/default/kube-system/g' external-snapshotter/deploy/kubernetes/csi-snapshotter/setup-csi-snapshotter.yaml
kubectl create -f external-snapshotter/deploy/kubernetes/csi-snapshotter
# Needed because of this todo: https://github.com/kubernetes-csi/external-snapshotter/blob/master/deploy/kubernetes/snapshot-controller/setup-snapshot-controller.yaml#L13
sed -i -e 's/default/kube-system/g' external-snapshotter/deploy/kubernetes/snapshot-controller/setup-snapshot-controller.yaml
sed -i -e 's/default/kube-system/g' external-snapshotter/deploy/kubernetes/snapshot-controller/rbac-snapshot-controller.yaml
kubectl create -f external-snapshotter/deploy/kubernetes/snapshot-controller
kubectl config set-context --current --namespace=default
