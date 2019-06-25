#!/bin/bash
sleep 2
/usr/bin/kubelet --hostname-override=minikube \
				 --cluster-domain=cluster.local \
				 --bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf \
				 --pod-manifest-path=/etc/kubernetes/manifests \
				 --cluster-dns=10.96.0.10 \
				 --authorization-mode=Webhook \
				 --client-ca-file=/var/lib/localkube/certs/ca.crt \
				 --fail-swap-on=false \
				 --kubeconfig=/etc/kubernetes/kubelet.conf \
				 --cgroup-driver=cgroupfs