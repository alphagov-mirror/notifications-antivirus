.DEFAULT_GOAL := help
SHELL := /bin/bash
DATE = $(shell date +%Y-%m-%dT%H:%M:%S)

APP_VERSION_FILE = app/version.py

GIT_COMMIT ?= $(shell git rev-parse HEAD)

NOTIFY_CREDENTIALS ?= ~/.notify-credentials

CF_APP ?= notify-antivirus
CF_MANIFEST_TEMPLATE_PATH ?= manifest$(subst notify-antivirus,,${CF_APP}).yml.j2
CF_MANIFEST_PATH ?= /tmp/manifest.yml

CF_API ?= api.cloud.service.gov.uk
CF_ORG ?= govuk-notify
CF_SPACE ?= development

DOCKER_USER_NAME = govuknotify
DOCKER_IMAGE = ${DOCKER_USER_NAME}/notifications-antivirus
DOCKER_IMAGE_TAG = $(shell git describe --always --dirty)
DOCKER_IMAGE_NAME = ${DOCKER_IMAGE}:${DOCKER_IMAGE_TAG}
DOCKER_CONTAINER_PREFIX = ${USER}-notifications-antivirus-manual


.PHONY: help
help:
	@cat $(MAKEFILE_LIST) | grep -E '^[a-zA-Z_-]+:.*?## .*$$' | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

.PHONY: preview
preview: ## Set environment to preview
	$(eval export CF_SPACE=preview)
	@true

.PHONY: staging
staging: ## Set environment to staging
	$(eval export CF_SPACE=staging)
	@true

.PHONY: production
production: ## Set environment to production
	$(eval export CF_SPACE=production)
	@true

# ---- LOCAL FUNCTIONS ---- #
# should only call these from inside docker or this makefile

.PHONY: _run
_run:
	# since we're inside docker container, assume the dependencies are already run
	./scripts/run_celery.sh

_run_app:
	./scripts/run_app.sh

.PHONY: _generate-version-file
_generate-version-file:
	@echo -e "__commit__ = \"${GIT_COMMIT}\"\n__time__ = \"${DATE}\"" > ${APP_VERSION_FILE}

.PHONY: _test-dependencies
_test-dependencies:
	pip install -r requirements_for_test.txt

.PHONY: _test
_test: _test-dependencies
	./scripts/run_tests.sh

.PHONY: freeze-requirements
freeze-requirements:
	rm -rf venv-freeze
	virtualenv -p python3 venv-freeze
	$$(pwd)/venv-freeze/bin/pip install -r requirements-app.txt
	echo '# This file is autogenerated. Do not edit it manually.' > requirements.txt
	cat requirements-app.txt >> requirements.txt
	echo '' >> requirements.txt
	$$(pwd)/venv-freeze/bin/pip freeze -r <(sed '/^--/d' requirements-app.txt) | sed -n '/The following requirements were added by pip freeze/,$$p' >> requirements.txt
	rm -rf venv-freeze

.PHONY: test-requirements
test-requirements:
	@diff requirements-app.txt requirements.txt | grep '<' \
	    && { echo "requirements.txt doesn't match requirements-app.txt."; \
	         echo "Run 'make freeze-requirements' to update."; exit 1; } \
|| { echo "requirements.txt is up to date"; exit 0; }

define run_docker_container
	docker run -it --rm \
		--name "${DOCKER_CONTAINER_PREFIX}-${1}" \
		-e NOTIFICATION_QUEUE_PREFIX=${NOTIFICATION_QUEUE_PREFIX} \
		-e NOTIFY_ENVIRONMENT=${NOTIFY_ENVIRONMENT} \
		-e FLASK_APP=${FLASK_APP} \
		-e FLASK_DEBUG=${FLASK_DEBUG} \
		-e WERKZEUG_DEBUG_PIN=${WERKZEUG_DEBUG_PIN} \
		-e AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID} \
		-e AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY} \
		-e NOTIFY_LOG_PATH=${NOTIFY_LOG_PATH} \
		${3} \
		${DOCKER_IMAGE_NAME} \
		${2}
endef


# ---- DOCKER COMMANDS ---- #

.PHONY: run-with-docker
run-with-docker: prepare-docker-build-image ## Build inside a Docker container
	$(call run_docker_container,celery-build, make _run)

.PHONY: run-app-with-docker
run-app-with-docker: prepare-docker-build-image ## Build inside a Docker container
	$(call run_docker_container,app-build, make _run_app, -p 6016:6016)

.PHONY: bash-with-docker
bash-with-docker: prepare-docker-build-image ## Build inside a Docker container
	$(call run_docker_container,build, bash)

.PHONY: test-with-docker
test-with-docker: prepare-docker-test-build-image ## Run tests inside a Docker container
	$(call run_docker_container,test, make _test)

.PHONY: clean-docker-containers
clean-docker-containers: ## Clean up any remaining docker containers
	docker rm -f $(shell docker ps -q -f "name=${DOCKER_CONTAINER_PREFIX}") 2> /dev/null || true

.PHONY: upload-to-dockerhub
upload-to-dockerhub: prepare-docker-build-image ## Upload the current version of the docker image to dockerhub
	$(if ${DOCKERHUB_USERNAME},,$(error Must specify DOCKERHUB_USERNAME))
	$(if ${DOCKERHUB_PASSWORD},,$(error Must specify DOCKERHUB_PASSWORD))
	@docker login -u ${DOCKERHUB_USERNAME} -p ${DOCKERHUB_PASSWORD}
	docker push ${DOCKER_IMAGE_NAME}

.PHONY: prepare-docker-build-image
prepare-docker-build-image: ## Build docker image
	docker build -f docker/Dockerfile \
		-t ${DOCKER_IMAGE_NAME} \
		.

.PHONY: prepare-docker-test-build-image
prepare-docker-test-build-image: ## Build docker image which will be used for testing
	docker build -f docker/Dockerfile \
		--target test \
		-t ${DOCKER_IMAGE_NAME} \
		.

# ---- PAAS COMMANDS ---- #

.PHONY: cf-login
cf-login: ## Log in to Cloud Foundry
	$(if ${CF_USERNAME},,$(error Must specify CF_USERNAME))
	$(if ${CF_PASSWORD},,$(error Must specify CF_PASSWORD))
	$(if ${CF_SPACE},,$(error Must specify CF_SPACE))
	@echo "Logging in to Cloud Foundry on ${CF_API}"
	@cf login -a "${CF_API}" -u ${CF_USERNAME} -p "${CF_PASSWORD}" -o "${CF_ORG}" -s "${CF_SPACE}"

.PHONY: generate-manifest
generate-manifest:
	$(if ${CF_SPACE},,$(error Must specify CF_SPACE))
	$(if $(shell which gpg2), $(eval export GPG=gpg2), $(eval export GPG=gpg))
	$(if ${GPG_PASSPHRASE_TXT}, $(eval export DECRYPT_CMD=echo -n $$$${GPG_PASSPHRASE_TXT} | ${GPG} --quiet --batch --passphrase-fd 0 --pinentry-mode loopback -d), $(eval export DECRYPT_CMD=${GPG} --quiet --batch -d))

	@jinja2 --strict ${CF_MANIFEST_TEMPLATE_PATH} \
	    -D environment=${CF_SPACE} --format=yaml \
	    <(${DECRYPT_CMD} ${NOTIFY_CREDENTIALS}/credentials/${CF_SPACE}/paas/environment-variables.gpg) 2>&1

.PHONY: cf-deploy
cf-deploy: ## Deploys the app to Cloud Foundry
	$(if ${CF_SPACE},,$(error Must specify CF_SPACE))
	$(if ${CF_APP},,$(error Must specify CF_APP))
	cf target -o ${CF_ORG} -s ${CF_SPACE}
	@cf app --guid ${CF_APP} || exit 1

	# cancel any existing deploys to ensure we can apply manifest (if a deploy is in progress you'll see ScaleDisabledDuringDeployment)
	cf cancel-deployment ${CF_APP} || true
	make -s generate-manifest > ${CF_MANIFEST_PATH}
	# fails after 5 mins if deploy doesn't work
	cf push ${CF_APP} --strategy=rolling -f ${CF_MANIFEST_PATH} --docker-image ${DOCKER_IMAGE_NAME} --docker-username ${DOCKER_USER_NAME}
	rm -f ${CF_MANIFEST_PATH}

.PHONY: cf-rollback
cf-rollback: ## Rollbacks the app to the previous release
	$(if ${CF_APP},,$(error Must specify CF_APP))
	cf cancel-deployment ${CF_APP}
	rm -f ${CF_MANIFEST_PATH}
