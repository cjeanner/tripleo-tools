#!/bin/bash
if [ "$#" -ne 3 ]; then
  echo "Usage: $(basename $0) <os> <release> <registry>"
  echo "Example: $(basename $0) 8 master 10.10.1.1:5000"
  exit 1
fi
basedir='/srv/tripleobuilder'
ct_name="tripleobuilder-${1}-${2}"

echo "Starting job for ${ct_name}"
mkdir -p ${basedir}/cache-${ct_name} \
  ${basedir}/dnf-cache-${ct_name} \
  ${basedir}/container-builds-${ct_name} \
  ${basedir}/persistent-${ct_name}

echo "  Check for ${ct_name} availability"
podman ps -a | grep -q ${ct_name}
if [ $? == 0 ]; then
  echo "  Start container ${ct_name}"
  podman start ${ct_name}
else
  echo "  Create and run ${ct_name}"
  podman run \
    --privileged \
    -v ${basedir}/script.sh:/bootstrap.sh:ro \
    -v ${basedir}/cache-${ct_name}:/root/.cache:z \
    -v ${basedir}/persistent-${ct_name}:/root/persistent:z \
    -v ${basedir}/container-builds-${ct_name}:/tmp/container-builds:z \
    -v ${basedir}/dnf-cache-${ct_name}:/var/cache/dnf:z \
    -v /etc/dnf/dnf.conf:/etc/dnf/dnf.conf:ro \
    -e BUILDAH_ISOLATION=chroot \
    -e _BUILDAH_STARTED_IN_USERNS="" \
    -e OSBASE="${1}" \
    -e RELEASE=${2} \
    -e REGISTRY="${3}" \
    --name $ct_name \
    quay.io/centos/centos:stream${1} /bootstrap.sh
fi
echo "Job for ${ct_name} ended"
