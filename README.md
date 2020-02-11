`kind`, like `docker:dind` but aims to make a full Kubernetes cluster available to test against in your CI pipeline. It is fast to startup and totally ephemeral, so you get a clean start for each CI run.

[![Build Status](https://travis-ci.org/bsycorp/kind.svg?branch=master)](https://travis-ci.org/bsycorp/kind)

## Quickstart

Use prebuilt images from Dockerhub: https://hub.docker.com/r/bsycorp/kind/

Run:

`docker run -it --privileged -p 8443:8443 -p 10080:10080 bsycorp/kind:latest-1.12`

Or more likely run CI in, [see examples](https://github.com/bsycorp/kind#can-i-use-it-on-my-cloud-cicd-provider)

## Why?

We run workloads in Kubernetes, and run our CI on Kubernetes too, but in our CI pipeline we wanted a way to have a quick and reliable way of having the current code under test, built, deployed and tested but then have the environment be torn down after testing. We initially considered deploying to a proper cluster but the overhead of pushing images to a registry just for a CI test, and the setup / teardown of resources was too much, we wanted something totally ephemeral so building on top of docker's dind made sense.

## Isn't this solved already?

Sort of, but not optimised for a fast-starting single-node cluster. There are examples of other solutions to this problem, it seems mostly from the Kubernetes devs themselves, as a way to automate development of integrations or Kubernetes itself. We wanted something that was both ephemeral, reliable and really fast, none of the available options gave us all of that.

Other projects:
1. https://github.com/kubernetes/minikube/tree/master/deploy/docker (Deprecated)
2. https://github.com/kubernetes/test-infra/tree/master/dind (Replaces no.1)
3. https://github.com/kubernetes-sigs/kubeadm-dind-cluster/ (more info: http://callistaenterprise.se/blogg/teknik/2017/12/20/kubernetes-on-docker-in-docker/)

Excluding no.1 which uses `localkube` (which is deprecated), both no.2 and no.3 create a proper cluster, with separate instances for a master and node(s). Because they start a multi node cluster they need to use `dind` inside `dind`, creating docker in docker in docker. As you can imagine adding another levels of abstraction can change how things behave, so disk access can be even slower than normal as we are two levels deep. Depending on the setup this can be caused because a fast storage driver like overlay2 can't be used _on_ overlay2, so docker will fall back to slower / more compatiable choices like AUFS (depends on Docker version). It can also have an impact on reliability, if you are hitting docker+kernel edge cases that trigger strange behaviour, it is likely you will see more strange behaviour with docker in docker in docker.

As an applcation sitting on top of kubernetes, we don't really need a full multi-node cluster to run our CI tests, we just need a single node+master. Since we only need a single instance, we don't need the complexity of docker-in-docker-in-docker, docker-in-docker is just fine (as we only have 1 instance vs 2+). This should make disk access faster (only 1 `dind`, so can use `overlay2`) which should help make our kube deploy and tests fast and it should be easier and more reliable to prime/bootstrap everything during build time and just start it up at runtime.

## How does `kind` work?

tl;dr; Building on docker-in-docker it uses `minikube` and `kubeadm` to bootstrap and pre-configure a cluster at build time that works at runtime.

The simplest way to get a Kubernetes cluster running in CI is to use `minikube` and start with `--vm-driver none`, this uses `kubeadm` to bootstrap a set of local processes to start Kubernetes. This doesn't work out of the box in `dind` as `kubeadm` assumes it is running in a systemd environment, which alpine is not. It also downloads binaries and bootstraps the cluster everytime it is run which depending on your network and resources takes around 4 minutes.

To make this process fast, `kind` aims to move all the cluster bootstrapping to the container build phase, so when you run `kind` it is already bootstrapped and is effectively just starting the `kubelet` process with a preconfigured `etcd`, `apiserver` etc. To achieve this we need to initially configure `kubeadm` with a static IP that will be routable both during the build phase, and the run phase, we have arbitrarily chosen `172.30.99.1` for that address.

During the build phase `kind` adds `172.30.99.1` to the default network interface for the container `eth0` and forces `kubeadm` and friends to use this address when bootstrapping the cluster. During the container run phase (when you are running `kind` in your environment) this static IP address is again attached to the default network interface `eth0` for the container so when `kubelet` is run the IP that it has been configured against is still routable.

Doing this network trickery means we can move all the hard work into the build phase, and `kind` can startup fast. In our CI environment using `kind` a single node cluster comes up and is ready to use in 30 seconds, down from 4 minutes in the simple minikube implementation (3+ minutes is a lot in a CI pipeline!).

A further optimisation is to have the build phase `docker pull` any dependent images your Kubernetes resources will require, so when your CI process is deploying your Kubernetes resources it doesn't have to pull in any images over the network. To do this you will need to build your own version of `kind` and update the `/after-cluster.sh` file with the images you want to pull in.

## How do I use this?

`kind` is a docker image that only runs as `--privileged`, that is designed to be run as a CI service, where by it is accessible over a known interface, normally `localhost`. Much like `docker:dind` on which it is based.

Running it as a service means the container running your tests needs to know when `kind` is ready, and how to get the `kubectl` config to make cli calls. This is achieved via the config endpoint. By default this is exposed over port `10080` and is just a simple http server hosting files.

There are few important events that `kind` exposes:
- When the docker host is ready, `http://localhost:10080/docker-ready` will return 200
- When the Kubernetes is ready, `http://localhost:10080/kubernetes-ready` will return 200
- When kubectl config is ready, `http://localhost:10080/config` will return 200

As you want your docker images you want to test to be built into `kind` docker host, the general process is to wait for `.../docker-ready` before doing `docker build..`, then wait for `.../kubernetes-ready` before deploy, then test.

## Can I use it on my Cloud CI/CD provider?

Not sure as we are running this in an on-premise GitLab install, but interested to hear feedback from people where it does or doesn't work. As above it is designed to be like `docker:dind` but with Kubernetes, so in theory anywhere `docker:dind` runs this should run, and like `docker:dind` it requires the container be launched as `--privileged` which generally cloud providers don't like.

Tested an known to Work:
- GitLab On-Premise (CE or EE*) ([example](https://github.com/bsycorp/kind-gitlab-example))
- CircleCI `machine` executors ([example](https://github.com/bsycorp/kind-circleci-example))
- Travis CI ([example](https://github.com/bsycorp/kind-travis-example))

These should work:
- GitLab.com with BYO Docker or Kubenetes runners
- Codeship Pro

Unlikely to work:
- Bitbucket Pipelines, has a magic `docker: true` flag so will likely not work

## How do I build this for myself?

Pre-built images are available on dockerhub (https://hub.docker.com/r/bsycorp/kind/), but if you want to bake in your own images to make it as fast as possible, you will want to built it yourself.

Run `./build.sh <image name>` to build the image. Add your custom images to `/images.sh` to have them be available at runtime. These environment variables are available to configure the build:

- DOCKER_IMAGE: defaults to `19.03.5-dind`
- MINIKUBE_VERSION: defaults to `v1.0.1`
- KUBERNETES_VERSION: defaults to `v1.14.8`
- STATIC_IP: defaults to `172.30.99.1`

We use git submodules to pull in this project and then add images and CI configuration around it, but there are other ways to do it.

## Build hooks

There are two hooks available during the `kind` build, `before-cluster.sh` and `after-cluster.sh`. As their names suggest they are run directly before and after the kube cluster is created.

Examples of this scripts exist in the repo already, but they can be overwritten / extended to add extra functionality.

## kubectl client configuraiton

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

## How do I pull images from a private registry?

Depending how you authenticate to your registry this can be a bit tricky. As the `./build.sh` script actually starts a docker container and configures it, because of this the container running your build hook scripts won't have access to all the environment variables / binaries it normally would. To work around this we just write out the build hook script in our outer CI process dynamically during the build.

Your `kind` CI  build script might look like:

```
echo "$(aws ecr get-login --no-include-email --region some-region)" >> ./kind/before-cluster.sh
echo "docker pull 12345.ecr.amazonaws.com/smth:latest" >> ./kind/before-cluster.sh

or

echo "docker login -u username -p $REGISTRY_TOKEN_FROM_CI registry.smth.com" >> ./kind/before-cluster.sh
echo "docker pull registry.smth.com/app:latest" >> ./kind/before-cluster.sh
```

Then the `before-cluster.sh` hook will fire during the build and have all the details it needs to login and pull the private images.

or dynamically supply the credentials when running the image:

```
docker run --privileged \
  -e REGISTRY="registry.smth.com" \
  -e REGISTRY_USER="username" \
  -e REGISTRY_PASSWORD='$REGISTRY_TOKEN' \
  bsycorp/kind:latest-1.10
```
