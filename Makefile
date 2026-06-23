# IBM MQ Native HA demo — operational Makefile.
#
# Two areas:
#   1. MQ deployment   (targets prefixed  mq-*)   — namespace ibm-mq
#   2. Producer/consumer tests (targets prefixed test-*) — namespace mq-test
#
# All targets assume `oc` is already logged into the target cluster.
# Override any variable on the command line, e.g.  make mq-restart KUBECTL=kubectl

KUBECTL       ?= oc

# --- MQ deployment ----------------------------------------------------------
MQ_NS         ?= ibm-mq
MQ_DIR        ?= manifests
QM            ?= mq-nativeha
QM_NAME       ?= mqnativeha
QM_STS        ?= mq-nativeha-ibm-mq
QM_ROUTE      ?= mq-nativeha-ibm-mq-qm
QM_LABEL      ?= app.kubernetes.io/instance=mq-nativeha

# --- Tests ------------------------------------------------------------------
TEST_NS       ?= mq-test
TEST_DIR      ?= mq-test/manifests
TEST_LABEL    ?= app in (mq-test-producer,mq-test-consumer)

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

# ============================================================================
# 1. MQ deployment
# ============================================================================

.PHONY: mq-deploy
mq-deploy: ## Apply all MQ manifests in order (operator, CAs, certs, QM)
	@for f in $$(ls $(MQ_DIR)/*.yaml | sort); do \
	  echo ">> applying $$f"; $(KUBECTL) apply -f $$f; \
	done

.PHONY: mq-status
mq-status: ## Show QueueManager, pods and Native HA roles
	$(KUBECTL) get queuemanager $(QM) -n $(MQ_NS)
	$(KUBECTL) get pods -n $(MQ_NS) -l $(QM_LABEL) -o wide
	@for p in $$($(KUBECTL) get pods -n $(MQ_NS) -l $(QM_LABEL) -o name); do \
	  echo "--- $$p ---"; \
	  $(KUBECTL) exec -n $(MQ_NS) $$(basename $$p) -- dspmq -o nativeha 2>/dev/null | head -1; \
	done

.PHONY: mq-route
mq-route: ## Print the queue manager Route hostname (for MQ_HOST)
	@$(KUBECTL) get route $(QM_ROUTE) -n $(MQ_NS) -o jsonpath='{.spec.host}'; echo

.PHONY: mq-restart
mq-restart: ## Roll the QM via the operator (bump a CR annotation) after an ini/MQSC change
	$(KUBECTL) annotate queuemanager $(QM) -n $(MQ_NS) \
	  mq.ibm.com/restartedAt="$$(date -u +%FT%TZ)" --overwrite

.PHONY: mq-chlauth
mq-chlauth: ## Show the active SSLPEERMAP (OU -> MCAUSER) records on the leader
	@LEADER=$$(for p in 0 1 2; do \
	  $(KUBECTL) exec -n $(MQ_NS) $(QM_STS)-$$p -- bash -c \
	    'dspmq -o nativeha 2>/dev/null | grep -q "ROLE(Active)" && echo $(QM_STS)-'$$p 2>/dev/null; \
	  done | head -1); \
	echo ">> leader: $$LEADER"; \
	$(KUBECTL) exec -n $(MQ_NS) $$LEADER -- bash -c \
	  "echo 'DIS CHLAUTH(TEST.SVRCONN) TYPE(SSLPEERMAP) ALL' | runmqsc $(QM_NAME)" \
	  | grep -E 'SSLPEER|MCAUSER'

.PHONY: mq-logs
mq-logs: ## Follow the leader pod's queue manager log
	$(KUBECTL) logs -n $(MQ_NS) -l $(QM_LABEL) -f --max-log-requests=3

.PHONY: mq-undeploy
mq-undeploy: ## Delete the QueueManager CR (keeps the operator and CAs)
	$(KUBECTL) delete -f $(MQ_DIR)/16-queuemanager.yaml --ignore-not-found

# ============================================================================
# 2. Producer / consumer tests
# ============================================================================

.PHONY: test-deploy
test-deploy: ## Apply all mq-test manifests (namespace, build, certs, config, apps)
	@for f in $$(ls $(TEST_DIR)/*.yaml | sort); do \
	  echo ">> applying $$f"; $(KUBECTL) apply -f $$f; \
	done

.PHONY: test-build
test-build: ## Build the client image in-cluster from the mq-test/ directory
	$(KUBECTL) start-build mq-test -n $(TEST_NS) --from-dir=mq-test --follow

.PHONY: test-restart
test-restart: ## Restart producer/consumer (reload certs/keystore after re-issue)
	$(KUBECTL) rollout restart deployment/mq-test-producer deployment/mq-test-consumer -n $(TEST_NS)
	$(KUBECTL) rollout status deployment/mq-test-producer -n $(TEST_NS) --timeout=120s
	$(KUBECTL) rollout status deployment/mq-test-consumer -n $(TEST_NS) --timeout=120s

.PHONY: test-status
test-status: ## Show producer/consumer pods
	$(KUBECTL) get pods -n $(TEST_NS) -l '$(TEST_LABEL)'

.PHONY: test-logs
test-logs: ## Tail the last messages of both producer and consumer
	@echo "=== producer ==="; $(KUBECTL) logs -n $(TEST_NS) deployment/mq-test-producer --tail=20
	@echo "=== consumer ==="; $(KUBECTL) logs -n $(TEST_NS) deployment/mq-test-consumer --tail=20

.PHONY: test-failover
test-failover: ## Delete the current Native HA leader to trigger a failover
	@LEADER=$$($(KUBECTL) get pods -n $(MQ_NS) -l $(QM_LABEL) \
	  -o jsonpath='{range .items[?(@.status.containerStatuses[0].ready==true)]}{.metadata.name}{end}'); \
	echo ">> deleting leader pod: $$LEADER"; \
	$(KUBECTL) delete pod $$LEADER -n $(MQ_NS)

.PHONY: test-verify
test-verify: ## Check the consumed sequence for gaps / out-of-order transitions
	@$(KUBECTL) logs -n $(TEST_NS) deployment/mq-test-consumer | grep RECEIVED | \
	  sed -n 's/.*seq=\([0-9]*\).*/\1/p' | python3 -c "import sys; \
	seqs=[int(x) for x in sys.stdin]; \
	print('received:', len(seqs), 'range:', (min(seqs) if seqs else '-'), '-', (max(seqs) if seqs else '-')); \
	bad=[(seqs[i],seqs[i+1]) for i in range(len(seqs)-1) if seqs[i+1]!=seqs[i]+1]; \
	print('gaps/out-of-order transitions:', bad)"

.PHONY: test-undeploy
test-undeploy: ## Delete the producer/consumer deployments
	$(KUBECTL) delete -f $(TEST_DIR)/05-producer.yaml -f $(TEST_DIR)/06-consumer.yaml --ignore-not-found
