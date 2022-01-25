#!/bin/bash
if [ "$#" -ne 1 ]; then
  echo "Usage: $(basename $0) <release>"
  echo "Example: $(basename $0) 9"
  exit 1
fi
basedir='/srv/build-oc-images'
ct_name="build-oc-${1}"

mkdir -p ${basedir}/cache-${1} \
  ${basedir}/dnf-cache-${1} \
  ${basedir}/builder-data

echo "  Check for ${ct_name} availability"
podman ps -a | grep -q ${ct_name}
if [ $? == 0 ]; then
  echo "  Start container ${ct_name}"
  podman start ${ct_name}
else
  echo "  Create and run ${ct_name}"
  podman run \
  --privileged \
  --systemd true \
  -v /dev:/dev \
  -v ${basedir}/script.sh:/bootstrap.sh:ro \
  -v ${basedir}/dnf-cache-${1}:/var/cache/dnf:z \
  -v ${basedir}/builder-data:/root:z \
  -v /etc/dnf/dnf.conf:/etc/dnf/dnf.conf:ro \
  -e OSBASE="${1}" \
  --name ${ct_name} \
  quay.io/centos/centos:stream${1} ./bootstrap.sh
fi
echo "Job for ${ct_name} ended"
