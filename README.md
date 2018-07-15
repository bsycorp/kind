`kind`, like `docker:dind` but aims to make a full Kubernetes cluster available to test against in your CI pipeline. It is fast to startup and totally ephemeral, so you get a clean start for each CI run.

## Why?

We run workloads in Kubernetes, and run our CI on Kubernetes too, but in our CI pipeline we wanted a way to have a quick and reliable way of having the current code under test, built, deployed and tested but then have the environment be torn down after testing. We initially considered deploying to a proper cluster but the overhead of pushing images to a registry just for a CI test, and the setup / teardown of resources was too much, we wanted something totally ephemeral so building on top of docker's dind made sense.

## Isn't this solved already?

Not from what we can see, there are examples of other solutions to this problem, it seems mostly from the Kubernetes devs themselves, as a way to automate development of integrations or Kubernetes itself. We wanted something that was both ephemeral and really fast, none of the available options gave us all of that.

Other discussion:
- https://github.com/kubernetes/minikube/tree/master/deploy/docker
- https://github.com/kubernetes-sigs/kubeadm-dind-cluster/
- https://github.com/kubernetes/test-infra/tree/master/dind
- http://callistaenterprise.se/blogg/teknik/2017/12/20/kubernetes-on-docker-in-docker/

## How does it work?

tl;dr; Building on docker-in-docker it uses `minikube` and `kubeadm` to bootstrap and pre-configure a cluster at build time that works at runtime.

The simplest way to get a Kubernetes cluster running in CI is to use `minikube` and start with `--vm-driver none`, this uses `kubeadm` to bootstrap a set of local processes to start Kubernetes. This doesn't work out of the box in `dind` as `kubeadm` assumes it is running in a SystemD environment, which alpine is not. It also downloads binaries and bootstraps the cluster everytime it is run which depending on your network and resources takes around 4 minutes.

To make this process fast, `kind` aims to move all the cluster bootstrapping to the container build phase, so when you run `kind` it is already bootstrapped and is effectively just starting the `kubelet` process with a preconfigured `etcd`, `apiserver` etc. To achieve this we need to initially configure `kubeadm` with a static IP that will be routable both during the build phase, and the run phase, we have arbitrarily chosen `172.99.99.1` for that address.

During the build phase `kind` adds `172.99.99.1` to the default network interface for the container `eth0` and forces `kubeadm` and friends to use this address when bootstrapping the cluster. During the container run phase (when you are running `kind` in your environment) this static IP address is again attached to the default network interface `eth0` for the container so when `kubelet` is run the IP that it has been configured against is still routable.

Doing this network trickery means we can move all the hard work into the build phase, and `kind` can startup fast. In our CI environment using `kind` a single node cluster comes up and is ready to use in 30 seconds, down from 4 minutes in the simple minikube implementation (3+ minutes is a lot in a CI pipeline!).

A further optimisation is to have the build phase `docker pull` any dependent images your Kubernetes resources will require, so when your CI process is deploying your Kubernetes resources it doesn't have to pull in any images over the network. To do this you will need to build your own version of `kind` and just overwrite the `/images.sh` file with the images your want to pull in.

## How to use?

`kind` is a docker image that only runs as `--privileged`, that is designed to be run as a CI service, where by it is accessible over a known interface, normally `localhost`. Much like `docker:dind` on which it is based.

Running it as a service means the container running your tests needs to know when `kind` is ready, and how to get the `kubectl` config to make cli calls. This is achieved via the config endpoint. By default this is exposed over port `10080` and is just a simple http server hosting files. 

There are few important events that `kind` exposes:
- When the docker host is ready, `http://localhost:10080/docker-ready` will return 200
- When the Kubernetes is ready, `http://localhost:10080/kubernetes-ready` will return 200
- When kubectl config is ready, `http://localhost:10080/config` will return 200

As you want your docker images you want to test to be built into `kind` docker host, the general process is to wait for `.../docker-ready` before doing `docker build..`, then wait for `.../kubernetes-ready` before deploy, then test.

An example Gitlab CI YAML would be :

```
integration-test:
  services:
    - bsycorp/kind:latest-1.9
  image: alpine
  stage: build
  script:
    - wait-for-kind.sh
    - test.sh
```

https://docs.gitlab.com/ee/ci/docker/using_docker_images.html#define-image-and-services-from-gitlab-ci-yml

To use generated kube config:

```
wget http://localhost:10080/config
cp config ~/.kube/config
kubectl get nodes
```

To create/add custom local kube config with creds:

```
wget http://localhost:10080/ca.crt 
wget http://localhost:10080/client.crt
wget http://localhost:10080/client.key

kubectl config set-cluster kind-cluster --server=https://localhost:8443 \
    --certificate-authority=ca.crt

kubectl config set-credentials kind-admin \
    --certificate-authority=ca.pem \
    --client-key=client.key \
    --client-certificate=client.crt

kubectl config set-context kind --cluster=kind-cluster --user=kind-admin
kubectl config use-context kind
kubectl get nodes
```

## How to build for myself?

Pre-built images are available on dockerhub (https://hub.docker.com/r/bsycorp/kind/), but if you want to bake in your own images to make it as fast as possible, you will want to built it yourself.

Run `./build.sh <image name>` to build the image. Add your custom images to `/images.sh` to have them be available at runtime. These environment variables are available to configure the build:

- DOCKER_IMAGE: defaults to `stable-dind`
- MINIKUBE_VERSION: defaults to `v0.28.0`
- KUBERNETES_VERSION: defaults to `v1.10.5`
- STATIC_IP: defaults to `172.99.99.1`

We use git submodules to pull in this project and then add images and CI configuration around it, but there are other ways to do it.
