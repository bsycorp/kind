#!/bin/bash
set -e
error_trap() {
    echo "Error on line $1"
    echo "Startup timeout, didn't become healthy after 3 mins.. details:"
    kubectl get po -n kube-system -o=custom-columns=NAME:.metadata.name --no-headers | xargs -I % sh -c 'kubectl -n kube-system describe po %; kubectl -n kube-system logs %' || true
    kubectl get po  || true
}
trap 'error_trap $LINENO' ERR

KUBERNETES_VERSION=$(cat /var/kube-config/kubernetes-version)
STATIC_IP=$(cat /var/kube-config/static-ip)
echo "$STATIC_IP control-plane.minikube.internal" >> /etc/hosts

echo "Clean up.." # cleanup stuff that might be left over from build-phase, sometimes throws Resource busy errors on build phase cleanup so needs to be done here.
rm -rf /var/run/docker*
rm -rf /var/lib/kubelet

echo "Setting up networking.." # use hard-coded IP to make kube happy (all the things are configured against it, otherwise we need to bootstrap kube everytime)
ip addr add $STATIC_IP/32 dev eth0

echo "Extracting cache.." # extract the tarred up docker images from build phase, we do this so when dind starts again in run phase we have all our stuff still, and its fast.
(mkdir -p /var/lib/docker; cd /var/lib/docker; lz4 -d /docker-cache.tar.lz4 | tar -x)

supervisorctl -c /etc/supervisord.conf start dockerd
sleep 2
docker info
echo "Docker ready"
touch /var/kube-config/docker-ready

echo "Logging into docker-registry $REGISTRY with user $REGISTRY_USER"
if [[ -n "${REGISTRY}" ]] && [[ -n "${REGISTRY_USER}" ]] && [[ -n "${REGISTRY_PASSWORD}" ]]; then
    docker login -u "$REGISTRY_USER" -p "$REGISTRY_PASSWORD" $REGISTRY || echo "WARN: Login Failed!"
else
    echo "no docker-registry/-credentials supplied"
fi

echo "Starting config server.."
supervisorctl -c /etc/supervisord.conf start config-serve

# start cluster
echo "Starting Kubernetes.."
supervisorctl -c /etc/supervisord.conf start kubelet

sleep 5
kubectl wait --for=condition=ready --timeout 3m pod --all --all-namespaces
kubectl get po --all-namespaces

# ready
touch /var/kube-config/kubernetes-ready
echo "Kubernetes ready"
if [ -f "/kubernetes-ready.sh" ]; then
   /bin/bash /kubernetes-ready.sh
fi
