#!/bin/sh
set -e
KUBERNETES_VERSION="$1"
MINIKUBE_VERSION="$2"
STATIC_IP="$3"

mkdir -p /var/kube-config
echo $KUBERNETES_VERSION > /var/kube-config/kubernetes-version
echo $MINIKUBE_VERSION > /var/kube-config/minikube-version
echo $STATIC_IP > /var/kube-config/static-ip

# start docker daemon, useful to check how it starts, we want it to be using overlay2 and not show errors etc.
docker info

# add deps
apk add --update sudo curl ca-certificates bash less findutils supervisor tzdata socat lz4

# add a static / known ip to the existing default network interface so that we can configure kube component to use that IP, and can re-use that IP again at boot time.
ORIG_IP=$(hostname -i)
ip addr add $STATIC_IP/32 dev eth0
echo "minikube $STATIC_IP" >> /etc/hosts

# create fake systemctl so minikube / kubeadm doesn't crack it
echo "#!/bin/sh" > /usr/local/bin/systemctl
chmod +x /usr/local/bin/systemctl

# add glibc as kube/minikube/things need it
curl -Lo glibc.apk https://github.com/sgerrand/alpine-pkg-glibc/releases/download/2.28-r0/glibc-2.28-r0.apk
apk add glibc.apk
rm -f glibc.apk

# fire before cluster hook
source /before-cluster.sh
    
# get kube binaries
curl -Lo /usr/local/bin/minikube https://storage.googleapis.com/minikube/releases/$MINIKUBE_VERSION/minikube-linux-amd64 && chmod +x /usr/local/bin/minikube
curl -Lo /usr/local/bin/kubectl https://storage.googleapis.com/kubernetes-release/release/$KUBERNETES_VERSION/bin/linux/amd64/kubectl && chmod +x /usr/local/bin/kubectl

function replaceHost(){
    find /var /etc /root -type f -not -path "/etc/hosts" -not -size +1M -exec grep -il "$ORIG_IP" {} \; | xargs sed -i "s|$ORIG_IP|$STATIC_IP|g" || true
}

# start minikube, will fail, but s'ok is just for downloading things
minikube start --vm-driver=none --kubernetes-version $KUBERNETES_VERSION --bootstrapper kubeadm --apiserver-ips $STATIC_IP,127.0.0.1 --apiserver-name minikube --extra-config=apiserver.advertise-address=$STATIC_IP || true

# fix minikube generated configs, this shouldn't be required if minikube behaved itself / had args for all the things
replaceHost

# some versions of minikube put certs in different places, so align
if [ ! -f /var/lib/localkube/certs/ca.crt ]; then
    mkdir -p /var/lib/localkube/certs
    cp /var/lib/minikube/certs/ca.crt /var/lib/localkube/certs/ca.crt || true
fi

# try and start kubelet in the background, keep restarting it as it will fail until kubeadm runs.
{
    while [ ! -f /tmp/setup-done ]; do
        sleep 5
        echo "(Re)starting kubelet.."
        # ensure replace host is run before kubelet is fired, can't exactly time when kubeadm creates configs 
        replaceHost 
        /kubelet.sh || true
    done
} &

# run kubeadm to create cluster - ignore preflights as there will be failures because of swap, systemd, lots of things..
/usr/bin/kubeadm init --config /var/lib/kubeadm.yaml --ignore-preflight-errors=all

# use kube-config that contains the certs, rather than referencing files
cp /etc/kubernetes/admin.conf /root/.kube/config

# disable unneeded stuff
minikube addons disable dashboard || true
kubectl -n kube-system delete deploy kubernetes-dashboard || true

# mark single node as node, as well as master, remove master taint or things might not schedule.
kubectl label node minikube node-role.kubernetes.io/node= || true
kubectl taint node minikube node-role.kubernetes.io/master:NoSchedule- || true

# workaround for https://github.com/kubernetes/kubernetes/issues/50787 and related 'conntrack' errors, kubeadm config should work but it doesn't for some reason.
kubectl -n kube-system get cm kube-proxy -o yaml | sed 's|maxPerCore: [0-9]*|maxPerCore: 0|g' > kube-proxy-cm.yaml
kubectl -n kube-system delete cm kube-proxy
kubectl -n kube-system create -f kube-proxy-cm.yaml
rm -f kube-proxy-cm.yaml

# workaround for https://github.com/bsycorp/kind/issues/19
kubectl -n kube-system get cm coredns -o yaml | sed 's|loop||g' > coredns-cm.yaml
kubectl -n kube-system delete cm coredns
kubectl -n kube-system create -f coredns-cm.yaml
rm -f coredns-cm.yaml

# expose kube config so external consumers can call in
cp /root/.minikube/client.crt /var/kube-config/client.crt
cp /root/.minikube/client.key /var/kube-config/client.key
cp /root/.minikube/ca.crt /var/kube-config/ca.crt
# tweak cluster naming in config so it is identifiable as kind to test clients
sed -i "s|kubernetes\|kubernetes-admin@kubernetes|kind|g" /root/.kube/config
cp /root/.kube/config /var/kube-config/config
chmod 644 /var/kube-config/*

# fire after cluster hook, can be used for image pull / addon enabling whatevs
source /after-cluster.sh

# wait for pod start
START_TIME=$(date +%s)
while true; do
    CURRENT_TIME=$(date +%s)
    if [[ $((CURRENT_TIME-300)) -gt $START_TIME ]]; then
        echo "Startup timeout, didn't become healthy after 2 mins.. details:"
        kubectl get po -n kube-system
        exit 1
    fi

    echo "Checking startup status.."
    POD_PHASES=$(kubectl get po -n kube-system -o jsonpath='{.items[*].status.phase}' | tr ' ' '\n' | sort | uniq)
    POD_STATES=$(kubectl get po -n kube-system -o jsonpath='{.items[*].status.containerStatuses[*].state}' | tr ' ' '\n' | cut -d'[' -f 2 | cut -d':' -f 1 | sort | uniq)
    POD_READINESS=$(kubectl get po -n kube-system -o jsonpath='{.items[*].status.containerStatuses[*].ready}' | tr ' ' '\n' | sort | uniq)
    POD_COUNT=$(kubectl get po -n kube-system --no-headers | wc -l)
    if [ "$POD_READINESS" == "true" ] && [ "$POD_STATES" == "running" ] && [ "$POD_PHASES" == "Running" ] && [ $POD_COUNT -gt 7 ]; then
        echo "startup successful"
        break
    fi
    sleep 5
done

# quick check
kubectl get no
kubectl get po --all-namespaces

# kill background kubelet to allow process to complete, kill running containers and prune their disk usage
echo "1" > /tmp/setup-done
killall kubelet
sleep 5
docker rm -f $(docker ps -q)
docker container prune -f

# create cache of docker images used so far.
tar -c -C /var/lib/docker ./ | lz4 -3 > /docker-cache.tar.lz4

# cleanup
rm -f /setup.sh
rm -f /images.sh

# cleanup extra binaries
rm -f /usr/local/bin/minikube
rm -f /usr/bin/kubeadm
rm -rf ~/.minikube/
rm -rf /*-cluster.sh
