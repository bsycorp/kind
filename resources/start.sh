#!/bin/bash
set -ex
KUBERNETES_VERSION=$(cat /var/kube-config/kubernetes-version)
STATIC_IP=$(cat /var/kube-config/static-ip)

echo "Clean up.." # cleanup stuff that might be left over from build-phase, sometimes throws Resource busy errors on build phase cleanup so needs to be done here.
rm -rf /var/run/docker*
rm -rf /var/lib/kubelet

echo "Setting up networking.." # use hard-coded IP to make kube happy (all the things are configured against it, otherwise we need to bootstrap kube everytime)
ip addr add $STATIC_IP/32 dev eth0

echo "Extracting cache.." # extract the tarred up docker images from build phase, we do this so when dind starts again in run phase we have all our stuff still, and its fast.
(mkdir -p /var/lib/docker; cd /var/lib/docker; tar -xf /docker-cache.tar)

supervisorctl -c /etc/supervisord.conf start dockerd
sleep 2
docker info
echo "Docker ready"
touch /var/kube-config/docker-ready

echo "Starting config server.."
supervisorctl -c /etc/supervisord.conf start config-serve

# start cluster
echo "Starting Kubernetes.."
supervisorctl -c /etc/supervisord.conf start kubelet

sleep 5
START_TIME=$(date +%s)
while true; do
    CURRENT_TIME=$(date +%s)
    if [[ $((CURRENT_TIME-300)) -gt $START_TIME ]]; then
        echo "Startup timeout, didn't become healthy after 2 mins.. details:"
        kubectl get po -n kube-system -o=custom-columns=NAME:.metadata.name --no-headers | xargs -I % sh -c 'kubectl -n kube-system describe po %; kubectl -n kube-system logs %' || true
        kubectl get po  || true
        exit 1
    fi

    echo "Checking startup status.."
    POD_STATES=$(kubectl get po -n kube-system -o jsonpath='{.items[*].status.containerStatuses[*].state}' | tr ' ' '\n' | cut -d'[' -f 2 | cut -d':' -f 1 | sort | uniq)
    POD_READINESS=$(kubectl get po -n kube-system -o jsonpath='{.items[*].status.containerStatuses[*].ready}' | tr ' ' '\n' | sort | uniq)
    POD_COUNT=$(kubectl get po -n kube-system | wc -l)
    if [ "$POD_READINESS" == "true" ] && [ "$POD_STATES" == "running" ] && [ $POD_COUNT -gt 7 ]; then
        echo "startup successful"
        break
    fi
    sleep 5
done
kubectl get po --all-namespaces

# ready
touch /var/kube-config/kubernetes-ready
echo "Kubernetes ready"