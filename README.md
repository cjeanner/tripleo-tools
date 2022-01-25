# Tripleo Tools
A set of containerized tools for your own TripleO infra

## Dependencies
- podman
- proper sudo/root

## Words of Warning
Please note that it will create new containers, or re-use existing one with
a matching name. It will also create a bunch of persistent directories, you
want to check the location (in container-create.sh script), and ensure
you have enough storage.

Most of the time, the storage is created in /srv tree.

## Content

### container-build
Allows to build containers for the target distribution.
#### Dependencies
A container registry accessible from the host you're building on.

For instance:
```Bash
mkdir -p /srv/registry /srv/redis

podman pod create -n registry \
  -p 5000:5000

podman create --pod registry \
  --name redis \
  -v /srv/redis:/data:z \
  docker.io/library/redis:latest

podman create --pod registry \
  --name service \
  --restart=always \
  --pidfile /run/container-registry.pid \
  -v /srv/registry:/var/lib/registry:z \
  --conmon-pidfile /run/container-registry.pid \
  -e REGISTRY_LOG_LEVEL=debug \
  -e REGISTRY_STORAGE_FILESYSTEM_MAXTHREADS=1024 \
  -e REGISTRY_HTTP_SECRET=SOME_SECRET_YOU_WANT_TO_UPDATE \
  -e REGISTRY_REDIS_ADDR=localhost:6379 \
  docker.io/library/registry

podman pod start registry
```
It will create a pod, with 2 containers, and expose the registry on port 5000.

#### Usage
```Bash
sudo ./container-create.sh <os> <release> <registry>
sudo ./container-create.sh 9 wallaby 10.10.1.1:5000
```

### container-copy
Copy all the containers in your own registry.
#### Dependencies
A container registry, accessible from the computer you're running this script.

#### Usage
```Bash
sudo ./container-create.sh <os> <release> <registry>
sudo ./container-create.sh 9 wallaby 10.10.1.1:5000
```

### build-oc-images
Build OC images

#### Dependencies
A bunch of disk space.

#### Usage
```Bash
sudo ./container-create.sh <os>
sudo ./container-create.sh 9
```
