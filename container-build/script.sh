#!/bin/bash
# https://developers.redhat.com/blog/2019/08/14/best-practices-for-running-buildah-in-a-container

curl -s -o /etc/yum.repos.d/delorean-deps.repo https://trunk.rdoproject.org/centos${OSBASE}-${RELEASE}/delorean-deps.repo

dnf install -y dnf-plugins-core
if [ -n "$OSBASE" ] && [ $OSBASE == "9" ]; then
  dnf config-manager --enable crb highavailability
  dnf reinstall -y tzdata
  baseimage="centos:stream9"
  dnf install -y ansible-core
else
  dnf config-manager --enable ha
  baseimage="ubi8"
  dnf install -y ansible
fi

dnf install -y --exclude container-selinux wget fuse-overlayfs buildah sudo

ansible-galaxy collection install community.general
ansible-galaxy collection install containers.podman
ansible-galaxy collection install tripleo.operator

mkdir -p /var/lib/shared/overlay-images /var/lib/shared/overlay-layers
touch /var/lib/shared/overlay-images/images.lock
touch /var/lib/shared/overlay-layers/layers.lock
test -f /root/persistent/ansible.log && truncate -s0 /root/persistent/ansible.log
find /root/persistent/ -mtime 5 -name "*.log.*" -delete
rm -rf /tmp/container-builds/*

cat <<EOF > /root/.ansible.cfg
[defaults]
command_warnings = False
retry_files_enabled = False
log_path = /root/persistent/ansible.log
display_args_to_stdout = True
EOF

cat <<EOF >/root/persistent/playbook.yml
- hosts: localhost
  gather_facts: false
  collections:
    - tripleo.operator
  vars:
    tripleo_container_image_build_registry: '${REGISTRY}'
    tripleo_generate_scripts: true
    tripleo_container_image_build_push: true
    tripleo_container_image_build_home_dir: /root/persistent
    tripleo_container_image_build_volumes:
      - "/srv/container-dnf:/etc/dnf/:z"
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
    - name: CS8 means tripleo-repos
      when: ${OSBASE} == 8
      import_role:
        name: tripleo.operator.tripleo_repos
      vars:
        tripleo_repos_branch: ${RELEASE}
        tripleo_repos_stream: true
        tripleo_repos_repos:
          - current-tripleo
          - ceph
    - name: CS9 means manual repo setup
      when: ${OSBASE} == 9
      block:
        - name: Get delorean.repo
          get_url:
            url: "https://trunk.rdoproject.org/centos${OSBASE}-${RELEASE}/current/delorean.repo"
            dest: /etc/yum.repos.d/delorean.repo
        - name: Get/update delorean-deps.repo
          get_url:
            url: "https://trunk.rdoproject.org/centos${OSBASE}-${RELEASE}/delorean-deps.repo"
            dest: /etc/yum.repos.d/delorean-deps.repo
    - name: Install tripleoclient
      dnf:
        name: python3-tripleoclient
        state: latest
    - name: Copy dnf directory to a safe location
      copy:
        dest: /srv/container-dnf
        remote_src: true
        src: /etc/dnf/
    - name: Get hash from delorean.repo
      register: delorean_hash
      uri:
        url: "https://trunk.rdoproject.org/centos${OSBASE}-${RELEASE}/current-tripleo/delorean.repo.md5"
        return_content: yes
    - name: "Check if tag exists and build if needed"
      block:
        - name: "Fetch a container"
          containers.podman.podman_image:
            name: "{{ tripleo_container_image_build_registry }}/centos${OSBASE}-${RELEASE}/openstack-nova-base"
            tag: "{{ delorean_hash.content }}"
            validate_certs: false
        - name: "No build is needing"
          set_fact:
            need_build: false
            build_ok: true
      rescue:
        - name: "Clear host error"
          meta: clear_host_errors
        - name: Need to build containers
          set_fact:
            need_build: true
    - name: "Catch build error and move forward"
      when: need_build|bool
      block:
        - name: "Build and push containers"
          include_role:
            name: tripleo.operator.tripleo_container_image_build
          vars:
            tripleo_container_image_build_tag: "{{ delorean_hash.content }}"
            tripleo_container_image_build_base: "${baseimage}"
            tripleo_container_image_build_namespace: "centos${OSBASE}-${RELEASE}"
            tripleo_container_image_build_tcib_extras:
              - "tcib_release={{ ansible_distribution_major_version }}"
              - "tcib_python_version={{ (ansible_distribution_major_version|int < 9) | ternary ('3.6', '3.9') }}"

        - name: Flag success
          set_fact:
            build_ok: true
      rescue:
        - name: "Clear host error"
          meta: clear_host_errors

        - name: Flag failure
          set_fact:
            build_ok: false
    - name: Output existing containers
      command: podman ps -a
      register: podman_ps_a
    - name: "Cleanup containers"
      failed_when: false
      command: podman rm -af
    - name: "Cleanup images"
      failed_when: false
      command: podman rmi -a
    - name: Fail if build_ok is false
      when:
        - build_ok is defined
        - not build_ok
      fail:
        msg: "Failed to build containers, check logs!"
    - name: Generate container prepare override
      copy:
        dest: /root/persistent/container-prepare-overrides.yaml
        content: |
          ---
          container_prepare_overrides:
            namespace: {{ tripleo_container_image_build_registry }}/centos${OSBASE}-${RELEASE}
            tag: {{ delorean_hash.content }}
EOF

ansible-playbook -c local -i localhost, /root/persistent/playbook.yml
