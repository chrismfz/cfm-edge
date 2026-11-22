# cfm-edge builder. Every pin comes from versions.env (valid make syntax too),
# so nothing here repeats a version.
#
# ONE package for every EL: it is built on EL8 (the oldest glibc we serve,
# 2.28; glibc is backward compatible) and the SAME rpm is tested on EL8, EL9
# and EL10. No dist tag, and Release is the build time (UTC):
# cfm-edge-1.31.9-20261119.182233.x86_64.rpm, not .el8 on an EL10 box.
#
#   make help         every target, one line each
#   make doctor       does this host have what a build needs?
#   make package      THE shipped rpm: built in AlmaLinux 8 -> dist/el8/
#   make test-all     smoke + cfm-conf of that rpm on EL8, EL9 and EL10
#   make sync         upload that rpm to repo.nixpal.com (only if test-all passed)
#
#   make check        report which pins are behind upstream (changes nothing)
#   make update       rewrite versions.env to the newest pins (then review the diff)
#
#   The release ritual:  make update && make package test-all && make sync
#
#   make sources      fetch + verify every input into SOURCES/
#   make rpm          build the rpm on THIS host (EL with rpm-build)
#   make rpm-el9      build inside an AlmaLinux 9 container (also -el8 / -el10)
#   make rpms         all three
#   make smoke-el9    install the el9 rpm in a clean container and smoke it
#   make cfm-conf-el9 run CFM's real edge config + Lua on it (CFM_DIR=../cfm)
#   make lint         bash -n + shellcheck + py_compile
include versions.env

SHELL        := /bin/bash

# --- Remote sync (same target as cfm's `make sync`) ---
# Lands in chris@repo.nixpal.com:~/packages/rpm, where root's repos-update.sh
# signs it and publishes it to https://repo.nixpal.com/el/ (createrepo).
REMOTE_USER ?= chris
REMOTE_HOST ?= repo.nixpal.com
REMOTE_PORT ?= 65535
REMOTE_DIR  ?= ~/packages/
RSYNC_FLAGS ?= -av --partial --inplace
SSH_CMD     ?= ssh -p $(REMOTE_PORT)
PKG_DIR     := dist/el8
TOPDIR       := $(CURDIR)/build/rpmbuild
CHANGELOG_DATE := $(shell LC_ALL=C date -u '+%a %b %d %Y')
# The package Release: build time in UTC, computed ONCE here on the host and
# exported, so the container's own `make rpm` uses the same value (and
# `BUILD_STAMP=... make package` really rebuilds that exact release).
# cfm-edge-1.31.9-20261119.182233.x86_64.rpm sorts newer than every earlier
# build, so a fixed rebuild is an update dnf sees.
ifndef BUILD_STAMP
BUILD_STAMP := $(shell date -u +%Y%m%d.%H%M%S)
endif
export BUILD_STAMP
# Container engine for tools/container-build.sh: docker if present, else podman
# (the devbox has only podman). ENGINE= overrides.
ENGINE ?= $(shell command -v docker >/dev/null 2>&1 && echo docker || echo podman)
export ENGINE
# SOURCE_DATE_EPOCH clamps file mtimes on EL10; use the build time, not a
# changelog date (the lesson CFM's own spec learnt).
export SOURCE_DATE_EPOCH ?= $(shell date -u +%s)

RPM_DEFINES := \
  --define "_topdir $(TOPDIR)" \
  --define "nginx_version $(NGINX_VERSION)" \
  --define "build_stamp $(BUILD_STAMP)" \
  --define "openssl_version $(OPENSSL_VERSION)" \
  --define "luajit_version $(LUAJIT_VERSION)" \
  --define "ndk_version $(NDK_VERSION)" \
  --define "lua_nginx_module_version $(LUA_NGINX_MODULE_VERSION)" \
  --define "lua_resty_core_version $(LUA_RESTY_CORE_VERSION)" \
  --define "lua_resty_lrucache_version $(LUA_RESTY_LRUCACHE_VERSION)" \
  --define "lua_cjson_version $(LUA_CJSON_VERSION)" \
  --define "lua_resty_string_version $(LUA_RESTY_STRING_VERSION)" \
  --define "lua_resty_http_version $(LUA_RESTY_HTTP_VERSION)" \
  --define "lua_resty_maxminddb_version $(LUA_RESTY_MAXMINDDB_VERSION)" \
  --define "edge_changelog_date $(CHANGELOG_DATE)" \
  --define "dist %{nil}"

# A bare `make` shows the help (it used to fetch the sources: `make sources`).
.DEFAULT_GOAL := help

.PHONY: help sources stage rpm srpm rpms rpm-el8 rpm-el9 rpm-el10 package test-all doctor check update sync smoke-el8 smoke-el9 smoke-el10 cfm-conf-el8 cfm-conf-el9 cfm-conf-el10 lint clean distclean release


# `make help`: every target with its `## description`, as cfm's Makefile does.
help: ## Show this help
	@echo "cfm-edge targets:"
	@grep -E '^[a-zA-Z0-9 _-]+:.*## ' $(firstword $(MAKEFILE_LIST)) | \
	  awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-40s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "Release: make update && make release && make sync"
	@echo "         (then, as root on repo.nixpal.com: /root/repos-update.sh --rpm-only)"

sources: ## Fetch + verify every pinned input into SOURCES/ (sha256, PGP, git pins)
	tools/fetch-sources.sh SOURCES

# rpmbuild's SOURCES: the verified inputs, the packaging files, and each
# patches/<component>/<file> as <component>-<file> (the spec's PatchNNN names).
stage: sources ## Lay out an rpmbuild tree in build/ (used by rpm / srpm)
	rm -rf $(TOPDIR) && mkdir -p $(TOPDIR)/{SOURCES,SPECS,BUILD,RPMS,SRPMS}
	cp -p SOURCES/*.tar.gz $(TOPDIR)/SOURCES/
	cp -p packaging/rpm/cfm-edge.service packaging/rpm/cfm-edge.logrotate packaging/rpm/nginx.conf packaging/rpm/cfm-edge-upgrade-restart.sh packaging/rpm/elf-hardening-check.sh $(TOPDIR)/SOURCES/
	for p in patches/*/*.patch; do cp -p "$$p" "$(TOPDIR)/SOURCES/$$(basename $$(dirname $$p))-$$(basename $$p)"; done
	cp -p packaging/rpm/cfm-edge.spec $(TOPDIR)/SPECS/

rpm: stage ## Build the rpm on THIS host (an EL with rpm-build)
	rpmbuild -ba $(RPM_DEFINES) $(TOPDIR)/SPECS/cfm-edge.spec
	mkdir -p dist && find $(TOPDIR)/RPMS $(TOPDIR)/SRPMS -name '*.rpm' -exec cp -p {} dist/ \;
	@ls -1 dist/

srpm: stage ## Build the source rpm on this host
	rpmbuild -bs $(RPM_DEFINES) $(TOPDIR)/SPECS/cfm-edge.spec

rpm-el8 rpm-el9 rpm-el10: sources ## Build inside an AlmaLinux 8 / 9 / 10 container
	tools/container-build.sh $(subst rpm-el,,$@) build

rpms: rpm-el8 rpm-el9 rpm-el10 ## Build on all three (diagnostics; the shipped rpm is el8)

package: rpm-el8 ## THE shipped rpm: built on EL8 -> dist/el8/

# The el8-built rpm, installed into each image (IMAGE= overrides the image,
# not which rpm: tools/container-build.sh 8 reads dist/el8).
test-all: ## Smoke + CFM config tests of that rpm on EL8, EL9 and EL10 (stamps .tested)
	rm -f $(PKG_DIR)/.tested
	for img in 8 9 10; do \
	  IMAGE=quay.io/almalinuxorg/almalinux:$$img tools/container-build.sh 8 smoke && \
	  IMAGE=quay.io/almalinuxorg/almalinux:$$img tools/container-build.sh 8 cfm-conf || exit 1; \
	done
	@# Stamp exactly the bytes that passed: sync refuses anything else.
	cd $(PKG_DIR) && sha256sum cfm-edge-[0-9]*.x86_64.rpm > .tested
	@echo "tested: $$(cat $(PKG_DIR)/.tested)"

# One command for the whole pre-publish run, in order: lint, the EL8 build
# (its check section enforces the ELF/OpenSSL hardening), then smoke +
# cfm-conf on EL8/9/10, which stamp the rpm for sync. Sub-makes, so the order
# holds under -j; BUILD_STAMP is exported, so all three see one stamp.
release: ## lint + package + test-all: the tested rpm make sync uploads
	$(MAKE) lint
	$(MAKE) package
	$(MAKE) test-all

# What a build host needs (a new test VM: run this first). Everything that
# compiles (gcc, rpm-build, perl, pcre2/zlib headers) lives in the AlmaLinux
# containers; the host only fetches + verifies sources and drives containers.
doctor: ## Does this host have what a build needs?
	@miss=0; \
	command -v $(ENGINE) >/dev/null && echo "✓ container engine: $(ENGINE)" \
	  || { echo "✗ container engine $(ENGINE): install podman or docker (or set ENGINE=)"; miss=1; }; \
	for t in make git curl gpg gpgv gzip sha256sum python3; do \
	  command -v $$t >/dev/null && echo "✓ $$t" || { echo "✗ $$t   (build: make sources / check-deps)"; miss=1; }; done; \
	for t in ssh rsync; do \
	  command -v $$t >/dev/null && echo "✓ $$t" || echo "• $$t   (only for make sync)"; done; \
	command -v shellcheck >/dev/null && echo "✓ shellcheck" || echo "• shellcheck   (only for make lint)"; \
	for u in https://nginx.org/download/ https://quay.io https://repo.almalinux.org/almalinux/; do \
	  curl -fsI -o /dev/null --max-time 10 "$$u" && echo "✓ reach $$u" || { echo "✗ reach $$u"; miss=1; }; done; \
	git ls-remote https://github.com/openresty/luajit2 HEAD >/dev/null 2>&1 \
	  && echo "✓ git over https to github.com" || { echo "✗ git over https to github.com (modules are git-pinned)"; miss=1; }; \
	. ./versions.env; curl -fsL -o /dev/null --max-time 20 \
	  "https://github.com/openssl/openssl/releases/download/openssl-$$OPENSSL_VERSION/openssl-$$OPENSSL_VERSION.tar.gz.sha256" \
	  && echo "✓ GitHub release downloads (OpenSSL)" || { echo "✗ GitHub release downloads (OpenSSL tarball)"; miss=1; }; \
	cfm="$(or $(CFM_DIR),../cfm)"; [ -f "$$cfm/configs/openresty.conf" ] && echo "✓ cfm checkout: $$cfm" \
	  || { echo "✗ no cfm checkout at $$cfm (clone chrismfz/cfm there, or CFM_DIR=): test-all runs CFM's real edge config"; miss=1; }; \
	[ $$miss = 0 ] && echo "ready: make package test-all   (ENGINE=$(ENGINE))" || { echo "missing pieces above"; exit 1; }

# Pins: `check` only reports; `update` rewrites versions.env (exit 3 = bumped,
# 4 = an nginx SECURITY fix: both are success here). Review
# `git diff versions.env`, then build, test and sync.
check: ## Report which pins are behind upstream (changes nothing)
	@python3 tools/check-deps.py; rc=$$?; \
	case $$rc in 0) echo "all pins current";; 3) echo "behind: run make update";; \
	  4) echo "SECURITY: nginx security fix available: run make update";; *) exit $$rc;; esac

update: ## Rewrite versions.env to the newest pins (then review the diff)
	@python3 tools/check-deps.py --bump; rc=$$?; \
	case $$rc in 0) echo "all pins current, nothing changed";; \
	  3|4) echo; if git diff --quiet -- versions.env; then \
	         echo "behind$$( [ $$rc = 4 ] && echo ' (SECURITY)' ), but nothing to bump automatically: see the notes above (a newer nginx line is a manual move)"; \
	       else git --no-pager diff --stat -- versions.env; \
	         echo "pins updated$$( [ $$rc = 4 ] && echo ' (SECURITY)' ): review git diff versions.env, then make package test-all sync"; fi;; \
	  *) exit $$rc;; esac

# Upload THE rpm (not debuginfo/src). Refuses an rpm whose exact bytes did not
# pass test-all, and a filename the repo already has (a build stamp reused
# through BUILD_STAMP= would silently change a published package). FORCE=1
# overrides both, knowingly.
sync: ## Upload the tested rpm to repo.nixpal.com (refuses an untested one)
	@set -euo pipefail; \
	RPM_FILE="$$(ls -1 $(PKG_DIR)/cfm-edge-[0-9]*.x86_64.rpm 2>/dev/null | head -n1 || true)"; \
	[ -n "$$RPM_FILE" ] || { echo "❌ No rpm in $(PKG_DIR): run make package test-all"; exit 1; }; \
	NAME="$$(basename "$$RPM_FILE")"; \
	if [ "$(FORCE)" != 1 ]; then \
	  ( cd $(PKG_DIR) && sha256sum -c --quiet .tested 2>/dev/null ) \
	    || { echo "❌ $$NAME has not passed make test-all (or was rebuilt since): run make test-all"; exit 1; }; \
	  if $(SSH_CMD) $(REMOTE_USER)@$(REMOTE_HOST) "test -e $(REMOTE_DIR)/rpm/$$NAME" \
	     || curl -sfI "https://$(REMOTE_HOST)/el/$$NAME" >/dev/null; then \
	    echo "❌ $(REMOTE_HOST) already has $$NAME: rebuild (a new build gets a new stamp)"; exit 1; fi; \
	fi; \
	( cd $(PKG_DIR) && sha256sum "$$NAME" > cfm-edge-checksums.txt ); \
	echo "🌐 Syncing to $(REMOTE_USER)@$(REMOTE_HOST):$(REMOTE_DIR)"; \
	$(SSH_CMD) $(REMOTE_USER)@$(REMOTE_HOST) "mkdir -p $(REMOTE_DIR)/rpm"; \
	echo "→ Upload: $$RPM_FILE -> $(REMOTE_DIR)/rpm/"; \
	rsync $(RSYNC_FLAGS) -e "$(SSH_CMD)" "$$RPM_FILE" "$(REMOTE_USER)@$(REMOTE_HOST):$(REMOTE_DIR)/rpm/"; \
	echo "→ Upload: cfm-edge-checksums.txt -> $(REMOTE_DIR)/"; \
	rsync $(RSYNC_FLAGS) -e "$(SSH_CMD)" $(PKG_DIR)/cfm-edge-checksums.txt "$(REMOTE_USER)@$(REMOTE_HOST):$(REMOTE_DIR)/"; \
	echo "✅ Uploaded. To publish: on $(REMOTE_HOST) run (as root) /root/repos-update.sh --rpm-only"

smoke-el8 smoke-el9 smoke-el10: ## Smoke the rpm built for that EL (dist/elN) in a clean container
	tools/container-build.sh $(subst smoke-el,,$@) smoke

# CFM's real edge config + Lua against the built rpm (CFM_DIR=../cfm by default)
cfm-conf-el8 cfm-conf-el9 cfm-conf-el10: ## CFM's real edge config + Lua on that EL's rpm (CFM_DIR=../cfm)
	tools/container-build.sh $(subst cfm-conf-el,,$@) cfm-conf

lint: ## bash -n + shellcheck + py_compile + the upgrade-restart test
	for f in tools/*.sh tests/*.sh; do bash -n "$$f"; done
	shellcheck -S warning tools/*.sh tests/*.sh packaging/rpm/*.sh
	python3 -m py_compile tools/*.py
	bash tests/upgrade-restart_test.sh

clean: ## Remove build/ and dist/
	rm -rf build dist

distclean: clean ## clean + the fetched SOURCES/ (the next build fetches and verifies again)
	rm -rf SOURCES
