#!/bin/sh
set -e
mkdir -p /var/kube-config
echo $KUBERNETES_VERSION > /var/kube-config/kubernetes-version
KUBERNETES_MAJOR_MINOR_VERSION="$(echo ${KUBERNETES_VERSION:1} | cut -d. -f 1-2)"
echo $MINIKUBE_VERSION > /var/kube-config/minikube-version
echo $STATIC_IP > /var/kube-config/static-ip
echo "Building against kubernetes $KUBERNETES_VERSION"

# start docker daemon, useful to check how it starts, we want it to be using overlay2 and not show errors etc.
docker info

# add deps
apk add --update sudo curl ca-certificates bash less findutils supervisor tzdata socat lz4 conntrack-tools sed

# add a static / known ip to the existing default network interface so that we can configure kube component to use that IP, and can re-use that IP again at boot time.
ORIG_IP=$(hostname -i)
ip addr add $STATIC_IP/32 dev eth0
echo "$STATIC_IP control-plane.minikube.internal" >> /etc/hosts

# create fake systemctl so minikube / kubeadm doesn't crack it
echo "#!/bin/sh" > /usr/local/bin/systemctl
chmod +x /usr/local/bin/systemctl

# add glibc as kube/minikube/things need it
curl -Lo glibc.apk https://github.com/sgerrand/alpine-pkg-glibc/releases/download/2.28-r0/glibc-2.28-r0.apk
# avoid this error - https://github.com/sgerrand/alpine-pkg-glibc/issues/51
apk del libc6-compat || true
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
minikube start --vm-driver=none --kubernetes-version $KUBERNETES_VERSION --bootstrapper kubeadm --apiserver-ips $STATIC_IP,127.0.0.1 --apiserver-name minikube --extra-config=apiserver.advertise-address=$STATIC_IP --extra-config=kubeadm.ignore-preflight-errors=FileContent--proc-sys-net-bridge-bridge-nf-call-iptables,Service-Docker $MINIKUBE_EXTRA_ARGS || true
if [ ! -f /usr/bin/kubeadm ]; then
    ln -s /var/lib/minikube/binaries/$KUBERNETES_VERSION/kubeadm /usr/bin/kubeadm
fi
if [ ! -f /usr/bin/kubelet ]; then
    ln -s /var/lib/minikube/binaries/$KUBERNETES_VERSION/kubelet /usr/bin/kubelet
fi

# fix minikube generated configs, this shouldn't be required if minikube behaved itself / had args for all the things
replaceHost

# try and start kubelet in the background, keep restarting it as it will fail until kubeadm runs.
{
    while [ ! -f /tmp/setup-done ]; do
        sleep 5
        echo "(Re)starting kubelet.."
        # ensure replace host is run before kubelet is fired, can't exactly time when kubeadm creates configs
        replaceHost

        # some versions of minikube put certs in different places, so align
        if [ ! -f /var/lib/localkube/certs/ca.crt ]; then
            mkdir -p /var/lib/localkube/certs
            cp /var/lib/minikube/certs/ca.crt /var/lib/localkube/certs/ca.crt || true
        fi

        /kubelet.sh || true
    done
} &

# run kubeadm to create cluster - ignore preflights as there will be failures because of swap, systemd, lots of things..
if [ ! -f /var/lib/kubeadm.yaml ]; then
    if [ -f /var/tmp/minikube/kubeadm.yaml ]
    then
      cp /var/tmp/minikube/kubeadm.yaml /var/lib/kubeadm.yaml
    elif [ -f /var/tmp/minikube/kubeadm.yaml.new ]
    then
      cp /var/tmp/minikube/kubeadm.yaml.new /var/lib/kubeadm.yaml
    fi
fi
/usr/bin/kubeadm config migrate --old-config /var/lib/kubeadm.yaml --new-config /var/lib/kubeadm.yaml
/usr/bin/kubeadm init --config /var/lib/kubeadm.yaml --ignore-preflight-errors=all

# use kube-config that contains the certs, rather than referencing files
mkdir -p /root/.kube
cp /etc/kubernetes/admin.conf /root/.kube/config

# fix scheduler auth
/usr/local/bin/kubectl create rolebinding -n kube-system kube-scheduler --role=extension-apiserver-authentication-reader --serviceaccount=kube-system:kube-scheduler || true

# workaround for https://github.com/kubernetes/kubernetes/issues/50787 and related 'conntrack' errors, kubeadm config should work but it doesn't for some reason.
/usr/local/bin/kubectl -n kube-system get cm kube-proxy -o yaml | sed 's|maxPerCore: .*|maxPerCore: 0|g' > kube-proxy-cm.yaml
/usr/local/bin/kubectl -n kube-system delete cm kube-proxy
/usr/local/bin/kubectl -n kube-system create -f kube-proxy-cm.yaml
rm -f kube-proxy-cm.yaml

# workaround for https://github.com/bsycorp/kind/issues/19
/usr/local/bin/kubectl -n kube-system get cm coredns -o yaml | sed 's|/etc/resolv.conf|8.8.8.8 9.9.9.9|g' > coredns-cm.yaml
/usr/local/bin/kubectl -n kube-system delete cm coredns
/usr/local/bin/kubectl -n kube-system create -f coredns-cm.yaml
rm -f coredns-cm.yaml

# force storage provisioner, as its not default in later versions, need both or yaml isn't downloaded
/usr/local/bin/minikube addons enable storage-provisioner || true
/usr/local/bin/kubectl apply -f /etc/kubernetes/addons/storage-provisioner.yaml || true
# setup default storage class if its missing
if [ -z "$(/usr/local/bin/kubectl get storageclass -o jsonpath='{.items[*].metadata.name}')" ]; then
    echo "Creating a default storage class as its missing, and required"
    cat <<EOF | /usr/local/bin/kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
  name: standard
provisioner: k8s.io/minikube-hostpath
reclaimPolicy: Delete
volumeBindingMode: Immediate
EOF
fi

# disable unneeded stuff
minikube addons disable dashboard || true
/usr/local/bin/kubectl -n kube-system delete deploy kubernetes-dashboard || true

# mark single node as node, as well as master, remove master taint or things might not schedule.
/usr/local/bin/kubectl label node minikube node-role.kubernetes.io/node= || true
/usr/local/bin/kubectl taint node minikube node-role.kubernetes.io/master:NoSchedule- || true

# tweak cluster naming in config so it is identifiable as kind to test clients
sed -i "s|kubernetes-admin@kubernetes|kind|g" /root/.kube/config
sed -i "s|kubernetes-admin@mk|kind|g" /root/.kube/config
sed -i "s|kubernetes-admin|kind|g" /root/.kube/config
sed -i "s|: mk|: kind|g" /root/.kube/config
sed -i "s|control-plane.minikube.internal|$STATIC_IP|g" /root/.kube/config
cp /root/.kube/config /var/kube-config/config
chmod 644 /var/kube-config/*

# fire after cluster hook, can be used for image pull / addon enabling whatevs
source /after-cluster.sh

if ! kubectl wait --for=condition=ready --timeout 2m pod --all --all-namespaces; then
    echo "Startup timeout, didn't become healthy after 2 mins.. details:"
    /usr/local/bin/kubectl get po -n kube-system
    exit 1
fi

# quick check
/usr/local/bin/kubectl get no
/usr/local/bin/kubectl get po --all-namespaces

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

# cleanup extra binaries
rm -f /usr/local/bin/minikube
rm -f /usr/bin/kubeadm
rm -rf ~/.minikube/
rm -rf /*-cluster.sh
