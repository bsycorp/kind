#!/bin/bash
sleep 2

# by default kind will set capacity to be the capacity of the host, and not honour any limits that have been imposed on it
# this tries to reserve an amount inverse to the limit on kind to fix that
if [ ! -z "$ENFORCE_CAPACITY" ]; then
	MEMORY_TOTAL=$(cat /proc/meminfo | grep MemTotal | awk '{print $2}')
	MEMORY_LIMIT=$(($(cat /sys/fs/cgroup/memory/memory.limit_in_bytes) / 1024))
	MEMORY_OUTSIDE_LIMIT=$(($MEMORY_TOTAL - $MEMORY_LIMIT))
	echo "Memory to reserve to ensure correct node capacity: $MEMORY_OUTSIDE_LIMIT"

	CPU_TOTAL=$(grep -c processor /proc/cpuinfo)
	CPU_LIMIT=$(($(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us) / $(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us)))
	CPU_OUTSIDE_LIMIT=$(($CPU_TOTAL - $CPU_LIMIT))
	echo "CPU to reserve to ensure correct node capacity: $CPU_OUTSIDE_LIMIT"

	SYSTEM_RESERVED="--system-reserved=cpu=$CPU_OUTSIDE_LIMIT,memory=${MEMORY_OUTSIDE_LIMIT}Ki"
	echo "Using arguments: $SYSTEM_RESERVED"
fi
/usr/bin/kubelet --hostname-override=minikube \
                 $SYSTEM_RESERVED \
				 --cluster-domain=cluster.local \
				 --bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf \
				 --pod-manifest-path=/etc/kubernetes/manifests \
				 --cluster-dns=10.96.0.10 \
				 --authorization-mode=Webhook \
				 --client-ca-file=/var/lib/localkube/certs/ca.crt \
				 --fail-swap-on=false \
				 --kubeconfig=/etc/kubernetes/kubelet.conf \
				 --cgroup-driver=cgroupfs