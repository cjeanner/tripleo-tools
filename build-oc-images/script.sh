#!/bin/bash
# https://developers.redhat.com/blog/2019/08/14/best-practices-for-running-buildah-in-a-container

dnf upgrade -y --refresh
# Clean all repos, and add some with fixed baseurl
rm -f /etc/yum.repos.d/*.repo

if [ -n "$OSBASE" ] && [ $OSBASE == "9" ]; then
  baseuri='http://mirror.stream.centos.org/9-stream'
else
  baseuri='http://mirror.centos.org/centos/8-stream'
fi

cat <<EOF > /etc/yum.repos.d/centos.repo
[baseos]
name=CentOS Stream \$releasever - BaseOS
baseurl=${baseuri}/BaseOS/\$basearch/os/
gpgcheck=0
repo_gpgcheck=0
metadata_expire=6h
countme=1
enabled=1

[appstream]
name=CentOS Stream \$releasever - AppStream
baseurl=${baseuri}/AppStream/\$basearch/os/
gpgcheck=0
repo_gpgcheck=0
metadata_expire=6h
countme=1
enabled=1

[HighAvailability]
name=CentOS Stream \$releasever - HA
baseurl=${baseuri}/HighAvailability/\$basearch/os/
gpgcheck=0
repo_gpgcheck=0
metadata_expire=6h
countme=1
enabled=1
EOF
if [ -n "$OSBASE" ] && [ $OSBASE == "9" ]; then
  cat <<EOF >> /etc/yum.repos.d/centos.repo
[crb]
name=CentOS Stream \$releasever - CRB
baseurl=${baseuri}/CRB/\$basearch/os/
gpgcheck=0
repo_gpgcheck=0
metadata_expire=6h
countme=1
enabled=1
EOF
fi

curl -s -o /etc/yum.repos.d/delorean-deps.repo https://trunk.rdoproject.org/centos${OSBASE}-master/delorean-deps.repo
curl -s -o /etc/yum.repos.d/delorean.repo https://trunk.rdoproject.org/centos${OSBASE}-master/tripleo-ci-testing/delorean.repo
dnf clean metadata
dnf install -y dnf-plugins-core
if [ -n "$OSBASE" ] && [ $OSBASE == "9" ]; then
  dnf config-manager --enable crb highavailability
  dnf reinstall -y tzdata
  dnf install -y ansible-core
else
  dnf config-manager --enable ha
  dnf install -y ansible
fi

dnf install --setopt=install_weak_deps=False -y wget git sudo patch \
  diskimage-builder openstack-ironic-python-agent-builder \
  python3-tripleoclient openstack-tripleo-image-elements \
  openstack-tripleo-puppet-elements cpio

ansible-galaxy collection install community.general

test -f /root/ansible.log && truncate -s0 /root/ansible.log
find /root/ -mtime 5 -name "*.log.*" -delete

mkdir -p /root/.ansible/roles
if [ -d /root/zuul-jobs ]; then
  pushd /root/zuul-jobs
  git reset --hard HEAD
  git pull --rebase
else
  git clone https://opendev.org/zuul/zuul-jobs /root/zuul-jobs
fi

rm -f /root/.ansible/roles/*
ln -s /root/zuul-jobs/roles/* /root/.ansible/roles/

if [ -d /root/tripleo-ci ]; then
  pushd /root/tripleo-ci
  git reset --hard HEAD
  git pull --rebase
  popd
else
  git clone https://opendev.org/openstack/tripleo-ci /root/tripleo-ci
fi

CT_TAG=$(curl -s https://trunk.rdoproject.org/centos${OSBASE}-master/current-tripleo/delorean.repo.md5)

mkdir -p /root/outputs/${CT_TAG}

cat <<EOF > /root/.ansible.cfg
[defaults]
command_warnings = False
retry_files_enabled = False
log_path = /root/ansible.log
display_args_to_stdout = True
EOF

cat <<EOF >/root/tripleo-ci/oc-image-build.yml
- hosts: localhost
  gather_facts: false
  collections:
    - tripleo.operator
  vars:
    tripleo_image_type: overcloud-full
    openstack_git_root: "{{ ansible_user_dir }}/openstack"
    workspace: "{{ ansible_user_dir }}/workspace/${CT_TAG}"
    ## related to operators only
    tripleo_generate_scripts: true
    tripleo_overcloud_image_build_config_files:
      - /usr/share/openstack-tripleo-common/image-yaml/overcloud-images-python3.yaml
      - /usr/share/openstack-tripleo-common/image-yaml/overcloud-images-centos${OSBASE}.yaml
    tripleo_overcloud_image_build_image_names:
      - overcloud-full
    tripleo_overcloud_image_build_output_directory: /root/workspace/${CT_TAG}
    tripleo_overcloud_image_build_log: /root/build.log
    tripleo_overcloud_image_build_dib_local_image: /root/centos-${OSBASE}.qcow2
    tripleo_overcloud_image_build_dib_yum_repo_conf: '/etc/yum.repos.d/*.repo'
  tasks:
    - name: Gather needed facts
      ansible.builtin.setup:
        gather_subset:
          - '!all'
          - '!any'
          - 'min'
    - name: Create directory
      register: workdir
      file:
        path: "{{ tripleo_overcloud_image_build_output_directory }}"
        state: directory
    - name: Clone needed repositories
      ansible.builtin.git:
        dest: "{{ openstack_git_root }}/{{ item }}"
        force: true
        repo: "https://opendev.org/openstack/{{ item }}"
      loop:
        - tripleo-image-elements
        - diskimage-builder
        - tripleo-common
        - tripleo-ansible
        - python-tripleoclient
        - requirements
        - ironic-python-agent-builder
        - heat-agents
        - tripleo-puppet-elements
    - name: Run prep tasks
      vars:
        dib_yum_repo_conf:
          - /etc/yum.repos.d/*.repo
      include_role:
        name: oooci-build-images
        tasks_from: pre.yaml

    - name: Remove 03-reset-bls-entries
      file:
        path: "{{ workspace }}/venv/lib/python3.9/site-packages/diskimage_builder/elements/centos/pre-install.d/03-reset-bls-entries"
        state: absent
    - name: Get patchset for 826205
      ansible.builtin.uri:
        url: "https://review.opendev.org/changes/openstack%2Ftripleo-common~826205/revisions/1/patch?download"
        return_content: true
      register: patch_826205
    - name: Save patch content
      copy:
        dest: "{{ workspace }}/venv/share/tripleo-common/826205.patch"
        content: "{{ patch_826205.content | b64decode }}"
    - name: Apply patch to tripleo-common content
      ansible.posix.patch:
        src: "{{ workspace }}/venv/share/tripleo-common/826205.patch"
        basedir: "{{ workspace }}/venv/share/tripleo-common"
        strip: 1
    - name: Get patch for 826078
      ansible.builtin.uri:
        url: "https://review.opendev.org/plugins/gitiles/openstack/tripleo-ci/+/refs/changes/78/826078/1/roles/oooci-build-images/vars/centos-9.yaml?format=TEXT"
        return_content: true
      register: patch_826078
    - name: Override centos-9.yaml
      copy:
        dest: "/root/tripleo-ci/roles/oooci-build-images/vars/centos-9.yaml"
        content: "{{ patch_826078.content | b64decode }}"
    - name: Get patch from 825728
      ansible.builtin.uri:
        url: "https://review.opendev.org/plugins/gitiles/openstack/tripleo-ci/+/refs/changes/28/825728/4/roles/oooci-build-images/tasks/remove_redfish.yaml?format=TEXT"
        return_content: true
      register: patch_825728
    - name: Override remove_redfish.yaml
      copy:
        dest: "/root/tripleo-ci/roles/oooci-build-images/tasks/remove_redfish.yaml"
        content: "{{ patch_825728.content | b64decode }}"
    - name: Get patch_1 for 825752
      ansible.builtin.uri:
        url: "https://review.opendev.org/plugins/gitiles/openstack/tripleo-ci/+/refs/changes/52/825752/1/roles/oooci-build-images/defaults/main.yaml?format=TEXT"
        return_content: true
      register: patch_825752_1
    - name: Override defaults_main.yaml
      copy:
        dest: "/root/tripleo-ci/roles/oooci-build-images/defaults/main.yaml"
        content: "{{ patch_825752_1.content | b64decode }}"
    - name: Get patch_2 for 825752
      ansible.builtin.uri:
        url: "https://review.opendev.org/plugins/gitiles/openstack/tripleo-ci/+/refs/changes/52/825752/1/roles/oooci-build-images/tasks/main.yaml?format=TEXT"
        return_content: true
      register: patch_825752_2
    - name: Override defaults_main.yaml
      copy:
        dest: "/root/tripleo-ci/roles/oooci-build-images/tasks/main.yaml"
        content: "{{ patch_825752_2.content | b64decode }}"

    - name: Build images
      vars:
        oooci_image_build_archive_dest: "/root/outputs/${CT_TAG}"
        tripleo_image_type: "{{ item }}"
        image_sanity: false
        dib_yum_repo_conf:
          - /etc/yum.repos.d/*.repo
      include_role:
        name: oooci-build-images
      loop:
        - ironic-python-agent
        - overcloud-full
EOF

ansible-playbook -c local -i localhost, /root/tripleo-ci/oc-image-build.yml
