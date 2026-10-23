TF := terraform -chdir=terraform/proxmox

.PHONY: init plan apply baseline-check baseline scan

init:
	$(TF) init

plan:
	$(TF) plan -out=tfplan

apply:
	$(TF) apply tfplan

baseline-check:
	cd ansible && ansible-playbook playbooks/baseline.yml --limit $(or $(HOST),sectools) --check --diff

baseline:
	cd ansible && ansible-playbook playbooks/baseline.yml --limit $(or $(HOST),sectools)

scan:
	pre-commit run --all-files
