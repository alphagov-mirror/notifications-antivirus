.DEFAULT_GOAL := help
SHELL := /bin/bash
DATE = $(shell date +%Y-%m-%dT%H:%M:%S)

APP_VERSION_FILE = app/version.py

GIT_COMMIT ?= $(shell git rev-parse HEAD 2> /dev/null || cat commit || echo "")

BUILD_TAG ?= notifications-antivirus-manual
BUILD_NUMBER ?= manual
BUILD_URL ?= manual
DEPLOY_BUILD_NUMBER ?= ${BUILD_NUMBER}

DOCKER_CONTAINER_PREFIX = ${USER}-${BUILD_TAG}

NOTIFY_CREDENTIALS ?= ~/.notify-credentials
CF_MANIFEST_FILE ?= manifest-${CF_SPACE}.yml

NOTIFY_APP_NAME ?= notify-antivirus

CODEDEPLOY_PREFIX ?= notifications-antivirus

CF_API ?= api.cloud.service.gov.uk
CF_ORG ?= govuk-notify
CF_HOME ?= ${HOME}
$(eval export CF_HOME)
CF_SPACE ?= sandbox

DOCKER_IMAGE = govuknotify/notifications-antivirus
DOCKER_IMAGE_TAG = ${CF_SPACE}
DOCKER_IMAGE_NAME = ${DOCKER_IMAGE}:${DOCKER_IMAGE_TAG}
DOCKER_TTY ?= $(if ${JENKINS_HOME},,t)

.PHONY: help
help:
	@cat $(MAKEFILE_LIST) | grep -E '^[a-zA-Z_-]+:.*?## .*$$' | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

.PHONY: sandbox
sandbox: ## Set environment to sandbox
	$(eval export CF_SPACE=sandbox)
	@true

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

.PHONY: _generate-version-file
_generate-version-file:
	@echo -e "__commit__ = \"${GIT_COMMIT}\"\n__time__ = \"${DATE}\"\n__jenkins_job_number__ = \"${BUILD_NUMBER}\"\n__jenkins_job_url__ = \"${BUILD_URL}\"" > ${APP_VERSION_FILE}

.PHONY: _test-dependencies
_test-dependencies:
	pip install -r requirements_for_test.txt

.PHONY: _test
_test: _test-dependencies
	./scripts/run_tests.sh

define run_docker_container
	docker run -i${DOCKER_TTY} --rm \
		--name "${DOCKER_CONTAINER_PREFIX}-${1}" \
		-e STATSD_PREFIX=${STATSD_PREFIX} \
		-e NOTIFICATION_QUEUE_PREFIX=${NOTIFICATION_QUEUE_PREFIX} \
		-e NOTIFY_ENVIRONMENT=${NOTIFY_ENVIRONMENT} \
		-e FLASK_APP=${FLASK_APP} \
		-e FLASK_DEBUG=${FLASK_DEBUG} \
		-e WERKZEUG_DEBUG_PIN=${WERKZEUG_DEBUG_PIN} \
		-e AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID} \
		-e AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY} \
	    -e NOTIFY_LOG_PATH=${NOTIFY_LOG_PATH} \
		${DOCKER_IMAGE_NAME} \
		${2}
endef


# ---- DOCKER COMMANDS ---- #

.PHONY: run-with-docker
run-with-docker: prepare-docker-build-image ## Build inside a Docker container
	$(call run_docker_container,build, make _run)

.PHONY: bash-with-docker
bash-with-docker: prepare-docker-build-image ## Build inside a Docker container
	$(call run_docker_container,build, bash)

.PHONY: test-with-docker
# always run tests against the sandbox image
test-with-docker: export DOCKER_IMAGE_TAG = sandbox
test-with-docker: prepare-docker-test-build-image ## Run tests inside a Docker container
	$(call run_docker_container,test, make _test)

.PHONY: clean-docker-containers
clean-docker-containers: ## Clean up any remaining docker containers
	docker rm -f $(shell docker ps -q -f "name=${DOCKER_CONTAINER_PREFIX}") 2> /dev/null || true

.PHONY: upload-to-dockerhub
upload-to-dockerhub: prepare-docker-build-image ## Upload the current version of the docker image to dockerhub
	$(if ${CF_SPACE},,$(error Must specify CF_SPACE - which is the tag to push to dockerhub with))
	$(if ${DOCKERHUB_USERNAME},,$(error Must specify DOCKERHUB_USERNAME))
	$(if ${DOCKERHUB_PASSWORD},,$(error Must specify DOCKERHUB_PASSWORD))
	@docker login -u ${DOCKERHUB_USERNAME} -p ${DOCKERHUB_PASSWORD}
	docker push ${DOCKER_IMAGE_NAME}

.PHONY: prepare-docker-build-image
prepare-docker-build-image: ## Build docker image
	docker build -f docker/Dockerfile \
		--build-arg http_proxy="${http_proxy}" \
		--build-arg https_proxy="${https_proxy}" \
		--build-arg NO_PROXY="${NO_PROXY}" \
		--build-arg CI_NAME=${CI_NAME} \
		--build-arg CI_BUILD_NUMBER=${BUILD_NUMBER} \
		--build-arg CI_BUILD_URL=${BUILD_URL} \
		-t ${DOCKER_IMAGE_NAME} \
		.

.PHONY: prepare-docker-test-build-image
prepare-docker-test-build-image: ## Build docker image which will be used for testing
	docker build -f docker/Dockerfile_for_test \
		--build-arg http_proxy="${http_proxy}" \
		--build-arg https_proxy="${https_proxy}" \
		--build-arg NO_PROXY="${NO_PROXY}" \
		--build-arg CI_NAME=${CI_NAME} \
		--build-arg CI_BUILD_NUMBER=${BUILD_NUMBER} \
		--build-arg CI_BUILD_URL=${BUILD_URL} \
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

	@./scripts/generate_manifest.py ${CF_MANIFEST_FILE} \
	    <(${DECRYPT_CMD} ${NOTIFY_CREDENTIALS}/credentials/${CF_SPACE}/paas/environment-variables.gpg)

.PHONY: cf-deploy
cf-deploy: ## Deploys the app to Cloud Foundry
	$(if ${CF_SPACE},,$(error Must specify CF_SPACE))
	cf target -s ${CF_SPACE}
	@cf app --guid notify-antivirus || exit 1
	cf rename notify-antivirus notify-antivirus-rollback
	cf push notify-antivirus -f <(make -s generate-manifest) --docker-image ${DOCKER_IMAGE_NAME}
	cf scale -i $$(cf curl /v2/apps/$$(cf app --guid notify-antivirus-rollback) | jq -r ".entity.instances" 2>/dev/null || echo "1") notify-antivirus
	cf stop notify-antivirus-rollback
	cf delete -f notify-antivirus-rollback

.PHONY: cf-rollback
cf-rollback: ## Rollbacks the app to the previous release
	cf target -s ${CF_SPACE}
	@cf app --guid notify-antivirus-rollback || exit 1
	@[ $$(cf curl /v2/apps/`cf app --guid notify-antivirus-rollback` | jq -r ".entity.state") = "STARTED" ] || (echo "Error: rollback is not possible because notify-antivirus-rollback is not in a started state" && exit 1)
	cf delete -f notify-antivirus || true
	cf rename notify-antivirus-rollback notify-antivirus

.PHONY: build-paas-artifact
build-paas-artifact: ## Build the deploy artifact for PaaS
	rm -rf target
	mkdir -p target
	$(if ${GIT_COMMIT},echo ${GIT_COMMIT} > commit)
	zip -y -q -r -x@deploy-exclude.lst target/antivirus.zip ./


.PHONY: upload-paas-artifact ## Upload the deploy artifact for PaaS
upload-paas-artifact:
	$(if ${DEPLOY_BUILD_NUMBER},,$(error Must specify DEPLOY_BUILD_NUMBER))
	$(if ${JENKINS_S3_BUCKET},,$(error Must specify JENKINS_S3_BUCKET))
	aws s3 cp --region eu-west-1 --sse AES256 target/antivirus.zip s3://${JENKINS_S3_BUCKET}/build/${CODEDEPLOY_PREFIX}/${DEPLOY_BUILD_NUMBER}.zip