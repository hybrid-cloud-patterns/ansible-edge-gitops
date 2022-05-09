#!/usr/bin/env ansible-playbook
---
- name: "Install manifest on AAP controller"
  become: false
  connection: local
  hosts: localhost
  gather_facts: false
  vars:
    values_secret: "{{ lookup('env', 'HOME') }}/values-secret.yaml"
    kubeconfig: "{{ lookup('env', 'KUBECONFIG') }}"
  tasks:
    - name: Parse "{{ values_secret }}"
      ansible.builtin.set_fact:
        all_values: "{{ lookup('file', values_secret) | from_yaml }}"

    - name: Set files fact
      ansible.builtin.set_fact:
        manifest_file_ref: "{{ all_values['files']['manifest'] }}"

    - name: Load manifest into variable
      local_action:
        module: slurp
        src: '{{ manifest_file_ref }}'
      register: manifest_file
      become: false

    - name: Wait for API/UI route to deploy
      kubernetes.core.k8s_info:
        kind: Route
        namespace: ansible-automation-platform
        name: controller
      register: aap_host
      retries: 20
      delay: 5
      until: aap_host.resources | length > 0

    - name: Retrieve API hostname for AAP
      kubernetes.core.k8s_info:
        kind: Route
        namespace: ansible-automation-platform
        name: controller
      register: aap_host
      failed_when: aap_host.resources | length == 0

    - name: Set ansible_host
      set_fact:
        ansible_host: '{{ aap_host.resources[0].spec.host }}'

    - name: Retrieve admin password for AAP
      kubernetes.core.k8s_info:
        kind: Secret
        namespace: ansible-automation-platform
        name: controller-admin-password
      register: admin_pw
      failed_when: admin_pw.resources | length == 0

    - name: Set admin_password fact
      set_fact:
        admin_password: '{{ admin_pw.resources[0].data.password | b64decode }}'

    - name: Wait for API to become available
      retries: 20
      delay: 5
      register: api_status
      until: api_status.status == 200
      uri:
        url: https://{{ ansible_host }}/api/v2/config/
        method: GET
        user: admin
        password: "{{admin_password}}"
        body_format: json
        validate_certs: false
        force_basic_auth: true
      no_log: true

    - name: Post manifest file
      uri:
        url: https://{{ ansible_host }}/api/v2/config/
        method: POST
        user: admin
        password: "{{admin_password}}"
        body: '{ "eula_accepted": true, "manifest": "{{ manifest_file.content }}" }'
        body_format: json
        validate_certs: false
        force_basic_auth: true
      no_log: true

    - name: Report AAP Endpoint
      debug:
        msg: 'AAP Endpoint: https://{{ ansible_host }}'

    - name: Report AAP User
      debug:
        msg: 'AAP Admin User: admin'

    - name: Report AAP Admin Password
      debug:
        msg: 'AAP Admin Password: {{ admin_password }}'

    - name: Load Project
      ansible.builtin.include_role:
        name: redhat_cop.controller_configuration.projects
      vars:
        controller_hostname: 'https://{{ ansible_host }}'
        controller_username: admin
        controller_password: '{{ admin_password }}'
        controller_projects:
          - name: "HMI Demo"
            #organization: "Default"
            scm_branch: 'main'
            scm_clean: "no"
            scm_delete_on_update: "no"
            scm_type: "git"
            scm_update_on_launch: "no"
            scm_url: "https://github.com/stolostron/hmi-demo.git"
            validate_certs: false