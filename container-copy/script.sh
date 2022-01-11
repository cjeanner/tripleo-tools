#!/bin/bash
# https://developers.redhat.com/blog/2019/08/14/best-practices-for-running-buildah-in-a-container

curl -s -o /etc/yum.repos.d/delorean-deps.repo https://trunk.rdoproject.org/centos${OSBASE}-${RELEASE}/delorean-deps.repo
curl -s -o /etc/yum.repos.d/delorean.repo https://trunk.rdoproject.org/centos${OSBASE}-${RELEASE}/current-tripleo/delorean.repo

dnf install -y dnf-plugins-core
if [ -n "$OSBASE" ] && [ $OSBASE == "9" ]; then
  dnf config-manager --enable crb highavailability
  dnf reinstall -y tzdata
  dnf install -y ansible-core
  baseimage="centos:stream9"
  NAMESPACE="tripleo${RELEASE}centos9"
else
  dnf config-manager --enable ha
  dnf install -y ansible
  baseimage="ubi8"
  NAMESPACE="tripleo${RELEASE}"
fi

dnf install -y --exclude container-selinux wget fuse-overlayfs buildah sudo

ansible-galaxy collection install community.general
ansible-galaxy collection install containers.podman
ansible-galaxy collection install tripleo.operator

mkdir -p /var/lib/shared/overlay-images /var/lib/shared/overlay-layers
touch /var/lib/shared/overlay-images/images.lock
touch /var/lib/shared/overlay-layers/layers.lock
test -f /root/ansible.log && truncate -s0 /root/ansible.log
test -f /root/container-prepare.log && truncate -s0 /root/container-prepare.log
find /root/ -mtime 5 -name "*.log.*" -delete
rm -rf /tmp/container-builds/*

CT_TAG=$(curl -s https://trunk.rdoproject.org/centos${OSBASE}-${RELEASE}/current-tripleo/delorean.repo.md5)

cat <<EOF > /root/.ansible.cfg
[defaults]
command_warnings = False
retry_files_enabled = False
log_path = /root/ansible.log
display_args_to_stdout = True
EOF

cat <<EOF >/root/playbook.yml
- hosts: localhost
  gather_facts: false
  collections:
    - tripleo.operator
  vars:
    tripleo_generate_scripts: true
    container_prepare_overrides:
      namespace: "trunk.registry.rdoproject.org/${NAMESPACE}"
      name_prefix: "openstack"
      tag: "${CT_TAG}"
      name_suffix: ""
      rhel_containers: "false"
    tripleo_lab_container_overrides:
      ceph_namespace: "${REGISTRY}/ceph"
      ceph_alertmanager_namespace: "${REGISTRY}/prometheus"
      ceph_grafana_namespace: "${REGISTRY}/prometheus"
      namespace: "${REGISTRY}/${NAMESPACE}"
      name_prefix: "openstack"
      tag: "${CT_TAG}"
      name_suffix: ""
      rhel_containers: "false"
  tasks:
    - name: Gather needed facts
      setup:
        gather_subset:
          - '!all'
          - '!any'
          - 'min'
    - name: Set mount program for container storage
      community.general.ini_file:
        path: /etc/containers/storage.conf
        section: 'storage.options.overlay'
        option: mount_program
        value: '"/usr/bin/fuse-overlayfs"'
        backup: false
    - name: Set additionalimage for container storage
      community.general.ini_file:
        path: /etc/containers/storage.conf
        section: 'storage.options'
        option: 'additionalimagestores'
        value: '[ "/var/lib/shared",]'
        backup: false
    - name: Correct crappy ini format
      ansible.builtin.command:
        cmd: sed -i 's/^]//' /etc/containers/storage.conf
    - name: Install tripleoclient
      dnf:
        name: python3-tripleoclient
        state: latest
    - name: Generate tripleo-lab container-override
      copy:
        dest: "/root/tripleo-lab-override-${NAMESPACE}.yaml"
        content: "{{ {'container_prepare_overrides': tripleo_lab_container_overrides} | to_nice_yaml }}"
      register: generate_override

    - name: Exit early
      when: generate_override is not changed
      meta: end_play

    - name: Get default container-prepare
      include_role:
        name: tripleo_container_image_prepare_default
    - name: Convert to yaml
      set_fact:
        f_container_image_prepare: "{{ tripleo_container_image_prepare_default_output|from_yaml }}"
    - name: Shorten content
      set_fact:
        fcip: "{{ f_container_image_prepare['parameter_defaults']['ContainerImagePrepare'][0] }}"
    - name: Inject registry
      set_fact:
        fcip: "{{ fcip |combine({'push_destination': '${REGISTRY}', 'excludes': ['prometheus', 'node-exporter'] }) }}"
    - name: Update default entries
      set_fact:
        fcip: "{{ fcip |combine({'set': {item.key: item.value}}, recursive=True) }}"
      loop: "{{ container_prepare_overrides|dict2items }}"
      loop_control:
        label: "{{ item.key }}"
    - name: Create yml
      set_fact:
        yml: "{'parameter_defaults': {'DockerInsecureRegistryAddress': ['${REGISTRY}'],'ContainerImagePrepareDebug': true,'ContainerImagePrepare': [{{fcip}}]} }"
    - name: Output the generated parameter file
      copy:
        dest: /root/container-overrides.yaml
        content: "{{ yml | to_nice_yaml }}"
    - name: Copy Overcloud containers to registry
      include_role:
        name: tripleo_container_image_prepare
      vars:
        tripleo_container_image_prepare_environment_files: /root/container-overrides.yaml
        tripleo_container_image_prepare_output_env_file: /root/oc-container-prepare.yaml
        tripleo_container_image_prepare_log_file: /root/container-prepare.log
        tripleo_container_image_prepare_roles_file: /usr/share/openstack-tripleo-heat-templates/roles_data.yaml
    - name: Copy Undercloud containers to registry
      include_role:
        name: tripleo_container_image_prepare
      vars:
        tripleo_container_image_prepare_environment_files: /root/container-overrides.yaml
        tripleo_container_image_prepare_output_env_file: /root/uc-container-prepare.yaml
        tripleo_container_image_prepare_log_file: /root/container-prepare.log
        tripleo_container_image_prepare_roles_file: /usr/share/openstack-tripleo-heat-templates/roles_data_undercloud.yaml

EOF

ansible-playbook -c local -i localhost, /root/playbook.yml
