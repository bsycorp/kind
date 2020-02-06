#!/bin/bash
# KUBERNETES_VERSION="v1.10.0"
# MINIKUBE_VERSION="v0.28.2"
TAG_LATEST="$1"
TAG_VERSION="$2"

if [ -z "$DOCKER_IMAGE" ]; then
	DOCKER_IMAGE="19.03.5-dind"
	echo "Defaulting Docker image to $DOCKER_IMAGE"
fi

if [ -z "$MINIKUBE_VERSION" ]; then
	MINIKUBE_VERSION="v1.3.0"
	echo "Defaulting Minikube version to $MINIKUBE_VERSION"
fi

if [ -z "$KUBERNETES_VERSION" ]; then
	KUBERNETES_VERSION="v1.15.1"
	echo "Defaulting Kubernetes version to $KUBERNETES_VERSION"
fi

if [ -z "$STATIC_IP" ]; then
	STATIC_IP="172.30.99.1"
	echo "Defaulting static IP to $STATIC_IP"
fi

if [ -z "$NETWORK" ]; then
	NETWORK="default"
	echo "Defaulting docker network to $NETWORK"
fi

function finish {
  echo "Cleanup"
  docker rm -f $CONTAINER_ID
  docker volume prune -f | true
}
trap finish EXIT

set -e

echo "Starting dind"
CONTAINER_ID=$(docker run --network $NETWORK --privileged -d --rm docker:$DOCKER_IMAGE dockerd)
echo $CONTAINER_ID
docker cp resources/entrypoint.sh $CONTAINER_ID:/entrypoint.sh
docker cp resources/setup.sh $CONTAINER_ID:/setup.sh
docker cp resources/start.sh $CONTAINER_ID:/start.sh
docker cp resources/kubelet.sh $CONTAINER_ID:/kubelet.sh
docker cp resources/supervisord.conf $CONTAINER_ID:/etc/supervisord.conf
docker cp resources/sgerrand.rsa.pub $CONTAINER_ID:/etc/apk/keys/sgerrand.rsa.pub
docker cp before-cluster.sh $CONTAINER_ID:/before-cluster.sh
docker cp after-cluster.sh $CONTAINER_ID:/after-cluster.sh

echo "Starting setup"
sleep 3
docker exec $CONTAINER_ID /setup.sh $KUBERNETES_VERSION $MINIKUBE_VERSION $STATIC_IP
echo "Commiting new container"
docker commit \
	-c 'ENTRYPOINT ["/entrypoint.sh"]' \
	-c 'CMD ["/usr/bin/supervisord", "--nodaemon", "-c", "/etc/supervisord.conf"]' \
	-c 'ENV PATH /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' \
	-c 'EXPOSE 2375/tcp' \
	-c 'EXPOSE 8443/tcp' \
	-c 'EXPOSE 10080/tcp' \
	$CONTAINER_ID $TAG_LATEST

docker tag $TAG_LATEST $TAG_VERSION
