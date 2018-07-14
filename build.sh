#!/bin/bash
# KUBERNETES_VERSION="v1.10.0"
# MINIKUBE_VERSION="v0.28.0"
IMAGE="$1"

if [ -z "$DOCKER_IMAGE" ]; then
	DOCKER_IMAGE="stable-dind"
	echo "Defaulting Docker image to 'stable-dind'"
fi

if [ -z "$MINIKUBE_VERSION" ]; then
	MINIKUBE_VERSION="v0.28.0"
	echo "Defaulting Minikube version to 'v0.28.0'"
fi

if [ -z "$KUBERNETES_VERSION" ]; then
	KUBERNETES_VERSION="v1.10.5"
	echo "Defaulting Kubernetes version to 'v1.10.0'"
fi

if [ -z "$STATIC_IP" ]; then
	STATIC_IP="172.99.99.1"
	echo "Defaulting static IP to '172.99.99.1'"
fi

function finish {
  echo "Cleanup"
  docker rm -f $CONTAINER_ID
  docker volume prune -f
}
trap finish EXIT

set -ex

echo "Starting dind"
CONTAINER_ID=$(docker run --privileged -d --rm docker:$DOCKER_IMAGE)
docker cp resources/setup.sh $CONTAINER_ID:/setup.sh
docker cp resources/start.sh $CONTAINER_ID:/start.sh
docker cp resources/kubelet.sh $CONTAINER_ID:/kubelet.sh
docker cp resources/supervisord.conf $CONTAINER_ID:/etc/supervisord.conf
docker cp images.sh $CONTAINER_ID:/images.sh

echo "Starting setup"
docker exec $CONTAINER_ID /setup.sh $KUBERNETES_VERSION $MINIKUBE_VERSION $STATIC_IP $REGISTRY_TOKEN
echo "Commiting new container"
docker commit \
	-c 'CMD ["/usr/bin/supervisord", "--nodaemon", "-c", "/etc/supervisord.conf"]' \
	-c 'ENV PATH /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' \
	$CONTAINER_ID $IMAGE