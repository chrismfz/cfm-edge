# cfm-edge builder. Every pin comes from versions.env (valid make syntax too),
# so nothing here repeats a version.
#
# ONE package for every EL: it is built on EL8 (the oldest glibc we serve,
# 2.28; glibc is backward compatible) and the SAME rpm is tested on EL8, EL9
# and EL10. No dist tag: cfm-edge-1.31.9-1.x86_64.rpm, not .el8 on an EL10 box.
#
#   make package      THE shipped rpm: built in AlmaLinux 8 -> dist/el8/
#   make test-all     smoke + cfm-conf of that rpm on EL8, EL9 and EL10
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
TOPDIR       := $(CURDIR)/build/rpmbuild
CHANGELOG_DATE := $(shell LC_ALL=C date -u '+%a %b %d %Y')
# SOURCE_DATE_EPOCH clamps file mtimes on EL10; use the build time, not a
# changelog date (the lesson CFM's own spec learnt).
export SOURCE_DATE_EPOCH ?= $(shell date -u +%s)

RPM_DEFINES := \
  --define "_topdir $(TOPDIR)" \
  --define "nginx_version $(NGINX_VERSION)" \
  --define "edge_release $(EDGE_RELEASE)" \
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

.PHONY: sources stage rpm srpm rpms rpm-el8 rpm-el9 rpm-el10 package test-all smoke-el8 smoke-el9 smoke-el10 cfm-conf-el8 cfm-conf-el9 cfm-conf-el10 lint clean

sources:
	tools/fetch-sources.sh SOURCES

# rpmbuild's SOURCES: the verified inputs, the packaging files, and each
# patches/<component>/<file> as <component>-<file> (the spec's PatchNNN names).
stage: sources
	rm -rf $(TOPDIR) && mkdir -p $(TOPDIR)/{SOURCES,SPECS,BUILD,RPMS,SRPMS}
	cp -p SOURCES/*.tar.gz $(TOPDIR)/SOURCES/
	cp -p packaging/rpm/cfm-edge.service packaging/rpm/cfm-edge.logrotate packaging/rpm/nginx.conf $(TOPDIR)/SOURCES/
	for p in patches/*/*.patch; do cp -p "$$p" "$(TOPDIR)/SOURCES/$$(basename $$(dirname $$p))-$$(basename $$p)"; done
	cp -p packaging/rpm/cfm-edge.spec $(TOPDIR)/SPECS/

rpm: stage
	rpmbuild -ba $(RPM_DEFINES) $(TOPDIR)/SPECS/cfm-edge.spec
	mkdir -p dist && find $(TOPDIR)/RPMS $(TOPDIR)/SRPMS -name '*.rpm' -exec cp -p {} dist/ \;
	@ls -1 dist/

srpm: stage
	rpmbuild -bs $(RPM_DEFINES) $(TOPDIR)/SPECS/cfm-edge.spec

rpm-el8 rpm-el9 rpm-el10: sources
	tools/container-build.sh $(subst rpm-el,,$@) build

rpms: rpm-el8 rpm-el9 rpm-el10

package: rpm-el8

# The el8-built rpm, installed into each image (IMAGE= overrides the image,
# not which rpm: tools/container-build.sh 8 reads dist/el8).
test-all:
	for img in 8 9 10; do \
	  IMAGE=quay.io/almalinuxorg/almalinux:$$img tools/container-build.sh 8 smoke && \
	  IMAGE=quay.io/almalinuxorg/almalinux:$$img tools/container-build.sh 8 cfm-conf || exit 1; \
	done

smoke-el8 smoke-el9 smoke-el10:
	tools/container-build.sh $(subst smoke-el,,$@) smoke

# CFM's real edge config + Lua against the built rpm (CFM_DIR=../cfm by default)
cfm-conf-el8 cfm-conf-el9 cfm-conf-el10:
	tools/container-build.sh $(subst cfm-conf-el,,$@) cfm-conf

lint:
	for f in tools/*.sh tests/*.sh; do bash -n "$$f"; done
	shellcheck -S warning tools/*.sh tests/*.sh
	python3 -m py_compile tools/*.py

clean:
	rm -rf build dist
