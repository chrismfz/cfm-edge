# cfm-edge.spec: stock nginx.org nginx + the Lua stack CFM's edge needs,
# under its own name, so it never conflicts with openresty, angie or ea-nginx.
#
# Build it with `make rpm` (or `make rpm-el9` etc. in a container): the
# Makefile reads versions.env and passes every pin as a --define, so the pins
# live in ONE file. Sources are fetched and verified by tools/fetch-sources.sh,
# never by rpmbuild.
#
# RPM SPEC RULE (see CLAUDE.md): never write a bare percent-macro in a comment.
# EL's redhat macros expand them inside comments; escape as a double percent.

%{!?nginx_version:%{error:nginx_version undefined: build through the Makefile (make rpm)}}

# No LTO: LuaJIT's VM is hand-written assembly plus C that LTO is known to
# miscompile (Fedora's own luajit package turns it off), and one switch for
# the whole build keeps nginx, LuaJIT and cjson compiled the same way.
%global _lto_cflags %{nil}

# Private files under /usr/lib/cfm-edge, NOT the EL-only /usr/lib64: the paths
# are compiled into the binary (RPATH, Lua cpath), and ONE binary built on
# EL8 (glibc 2.28 floor) serves EL8/9/10 and, packaged as a .deb, Debian 10+
# and Ubuntu 20.04+, where /usr/lib64 does not exist.
%global edge_libdir      %{_prefix}/lib/cfm-edge
%global luajit_prefix    %{edge_libdir}/luajit
%global clualib_dir      %{edge_libdir}/lualib
%global lualib_dir       %{_datadir}/cfm-edge/lualib
%global site_lualib_dir  %{_datadir}/cfm-edge/site/lualib
%global edge_confdir     %{_sysconfdir}/cfm-edge
%global edge_logdir      %{_localstatedir}/log/cfm-edge
%global edge_statedir    %{_localstatedir}/lib/cfm-edge

Name:           cfm-edge
Version:        %{nginx_version}
Release:        %{edge_release}%{?dist}
Summary:        CFM edge proxy: nginx with the CFM Lua stack
License:        BSD-2-Clause AND MIT AND Apache-2.0
URL:            https://github.com/chrismfz/cfm-edge

Source0:        nginx-%{nginx_version}.tar.gz
Source1:        openssl-%{openssl_version}.tar.gz
Source2:        luajit2-%{luajit_version}.tar.gz
Source3:        ngx_devel_kit-%{ndk_version}.tar.gz
Source4:        lua-nginx-module-%{lua_nginx_module_version}.tar.gz
Source5:        lua-resty-core-%{lua_resty_core_version}.tar.gz
Source6:        lua-resty-lrucache-%{lua_resty_lrucache_version}.tar.gz
Source7:        lua-cjson-%{lua_cjson_version}.tar.gz
Source8:        lua-resty-http-%{lua_resty_http_version}.tar.gz
Source9:        lua-resty-maxminddb-%{lua_resty_maxminddb_version}.tar.gz
Source10:       lua-resty-string-%{lua_resty_string_version}.tar.gz
Source20:       cfm-edge.service
Source21:       cfm-edge.logrotate
Source22:       nginx.conf

# Our own patches, one change each (patches/<component>/ in the repo).
Patch100:       lua-resty-maxminddb-0001-load-runtime-soname.patch

BuildRequires:  gcc
BuildRequires:  make
BuildRequires:  pcre2-devel
BuildRequires:  zlib-devel
# OpenSSL's Configure is perl, and EL's minimal perl lacks the modules it uses.
BuildRequires:  perl-interpreter
BuildRequires:  perl(IPC::Cmd)
BuildRequires:  perl(FindBin)
BuildRequires:  perl(File::Compare)
BuildRequires:  perl(File::Copy)
BuildRequires:  perl(Time::Piece)
BuildRequires:  perl(lib)
BuildRequires:  systemd
%if 0%{?rhel} >= 9 || 0%{?fedora}
BuildRequires:  systemd-rpm-macros
%endif

# resty.maxminddb reaches libmaxminddb through the LuaJIT FFI (no ELF link,
# so rpm's automatic requires cannot see it).
Requires:       libmaxminddb
Requires:       logrotate
Requires(post):   systemd
Requires(preun):  systemd
Requires(postun): systemd

# The private LuaJIT is ours: never satisfy another package's luajit
# requirement, and never let rpm think we need a system one.
%global __provides_exclude_from ^%{edge_libdir}/.*$
%global __requires_exclude ^libluajit-5\\.1\\.so.*$

%description
cfm-edge is the in-path edge proxy of CFM, built from the pristine nginx.org
release: nginx with lua-nginx-module, ngx_devel_kit, OpenResty's LuaJIT2,
lua-resty-core/lrucache/string, lua-cjson, lua-resty-http and
lua-resty-maxminddb,
statically linked against a private OpenSSL 3.5 LTS (QUIC/HTTP/3).

It installs as /usr/sbin/cfm-edge with its own config (/etc/cfm-edge), logs,
state and systemd unit, and conflicts with nothing: it can sit next to an
OpenResty or Angie edge, and the CFM install script switches between them.

%prep
%setup -q -c -n cfm-edge-%{version} -a 1 -a 2 -a 3 -a 4 -a 5 -a 6 -a 7 -a 8 -a 9 -a 10

pushd lua-resty-maxminddb-%{lua_resty_maxminddb_version}
%patch -P 100 -p1
popd

# Compile CFM's default Lua search path into ngx_lua (what OpenResty's own
# configure does): the trailing ";;" in CFM's lua_package_path then resolves to
# this package's lualib instead of LuaJIT's empty defaults.
cat >> lua-nginx-module-%{lua_nginx_module_version}/config <<'EOF'

echo '
#ifndef LUA_DEFAULT_PATH
#define LUA_DEFAULT_PATH "%{site_lualib_dir}/?.lua;%{site_lualib_dir}/?/init.lua;%{lualib_dir}/?.lua;%{lualib_dir}/?/init.lua"
#endif
#ifndef LUA_DEFAULT_CPATH
#define LUA_DEFAULT_CPATH "%{clualib_dir}/?.so"
#endif
' >> "$ngx_addon_dir/src/ngx_http_lua_autoconf.h"
EOF

%build
top="$PWD"
stage="$top/.luajit-stage"

# --- LuaJIT2: a private shared library under %%{luajit_prefix}. Built first
# and installed into a staging root only so nginx can link against it; the
# real install happens in the install section.
make -C luajit2-%{luajit_version} %{?_smp_mflags} \
    PREFIX=%{luajit_prefix} Q= E=@: TARGET_STRIP=: CCDEBUG=-g \
    XCFLAGS='-DLUAJIT_ENABLE_LUA52COMPAT' \
    CFLAGS="%{optflags}" LDFLAGS="%{build_ldflags}"
make -C luajit2-%{luajit_version} install PREFIX=%{luajit_prefix} DESTDIR="$stage" Q= E=@:
export LUAJIT_LIB="$stage%{luajit_prefix}/lib"
export LUAJIT_INC="$stage%{luajit_prefix}/include/luajit-2.1"

# --- lua-cjson (C module, loaded by the LuaJIT above)
make -C lua-cjson-%{lua_cjson_version} %{?_smp_mflags} \
    LUA_INCLUDE_DIR="$LUAJIT_INC" CC=gcc \
    CFLAGS="%{optflags} -DNDEBUG" LDFLAGS="%{build_ldflags}"

# --- nginx. Only the modules CFM's edge uses; every module left out is attack
# surface nobody audits for us (the list lives in README "What is built").
cd nginx-%{nginx_version}
./configure \
    --prefix=%{_datadir}/cfm-edge \
    --sbin-path=%{_sbindir}/cfm-edge \
    --modules-path=%{edge_libdir}/modules \
    --conf-path=%{edge_confdir}/nginx.conf \
    --error-log-path=%{edge_logdir}/error.log \
    --http-log-path=%{edge_logdir}/access.log \
    --pid-path=/run/cfm-edge.pid \
    --lock-path=/run/lock/cfm-edge.lock \
    --http-client-body-temp-path=%{edge_statedir}/client_body \
    --http-proxy-temp-path=%{edge_statedir}/proxy \
    --build="cfm-edge-%{version}-%{release}" \
    --with-threads \
    --with-file-aio \
    --with-compat \
    --with-pcre-jit \
    --with-http_ssl_module \
    --with-http_v2_module \
    --with-http_v3_module \
    --with-http_realip_module \
    --with-http_auth_request_module \
    --with-http_stub_status_module \
    --without-http_auth_basic_module \
    --without-http_fastcgi_module \
    --without-http_uwsgi_module \
    --without-http_scgi_module \
    --without-http_grpc_module \
    --without-http_memcached_module \
    --without-http_ssi_module \
    --without-http_autoindex_module \
    --without-http_userid_module \
    --without-http_mirror_module \
    --without-http_empty_gif_module \
    --without-http_split_clients_module \
    --with-openssl="$top/openssl-%{openssl_version}" \
    --with-openssl-opt="-fPIC no-weak-ssl-ciphers no-tests no-docs" \
    --add-module="$top/ngx_devel_kit-%{ndk_version}" \
    --add-module="$top/lua-nginx-module-%{lua_nginx_module_version}" \
    --with-cc-opt="%{optflags} -DNGX_LUA_ABORT_AT_PANIC" \
    --with-ld-opt="%{build_ldflags} -Wl,-rpath,%{luajit_prefix}/lib"
%make_build

%install
top="$PWD"

# LuaJIT (library, the luajit CLI for CFM's Lua selftests, jit.* modules).
make -C luajit2-%{luajit_version} install PREFIX=%{luajit_prefix} DESTDIR=%{buildroot} Q= E=@:
rm -f %{buildroot}%{luajit_prefix}/lib/libluajit-5.1.a
rm -rf %{buildroot}%{luajit_prefix}/lib/pkgconfig %{buildroot}%{luajit_prefix}/share/man

# nginx itself; drop the sample configs we do not use.
make -C nginx-%{nginx_version} install DESTDIR=%{buildroot}
rm -f %{buildroot}%{edge_confdir}/*.default
rm -f %{buildroot}%{edge_confdir}/{fastcgi,fastcgi.conf,fastcgi_params,scgi_params,uwsgi_params,koi-utf,koi-win,win-utf}
install -p -m 0644 %{SOURCE22} %{buildroot}%{edge_confdir}/nginx.conf
# No sample html: CFM's config uses none, and nginx's 50x.html signs itself
# "Faithfully yours, nginx."
rm -rf %{buildroot}%{_datadir}/cfm-edge/logs %{buildroot}%{_datadir}/cfm-edge/html

# Lua libraries: pure Lua into lualib, the C module into the arch dir.
install -d %{buildroot}%{lualib_dir} %{buildroot}%{site_lualib_dir} %{buildroot}%{clualib_dir}
cp -a lua-resty-core-%{lua_resty_core_version}/lib/.           %{buildroot}%{lualib_dir}/
cp -a lua-resty-lrucache-%{lua_resty_lrucache_version}/lib/.   %{buildroot}%{lualib_dir}/
cp -a lua-resty-string-%{lua_resty_string_version}/lib/.       %{buildroot}%{lualib_dir}/
cp -a lua-resty-http-%{lua_resty_http_version}/lib/.           %{buildroot}%{lualib_dir}/
cp -a lua-resty-maxminddb-%{lua_resty_maxminddb_version}/lib/. %{buildroot}%{lualib_dir}/
install -p -m 0755 lua-cjson-%{lua_cjson_version}/cjson.so %{buildroot}%{clualib_dir}/cjson.so
# lua-cjson's pure-Lua helper (cjson.util) is not used by CFM; not shipped.

install -d -m 0755 %{buildroot}%{edge_logdir}
install -d -m 0755 %{buildroot}%{edge_statedir}
install -D -p -m 0644 %{SOURCE20} %{buildroot}%{_unitdir}/cfm-edge.service
install -D -p -m 0644 %{SOURCE21} %{buildroot}%{_sysconfdir}/logrotate.d/cfm-edge

%check
bin=%{buildroot}%{_sbindir}/cfm-edge
# The binary must find its private LuaJIT through its own RPATH, and carry the
# hardening the distro gives its own nginx (PIE, full RELRO, BIND_NOW).
LD_LIBRARY_PATH=%{buildroot}%{luajit_prefix}/lib "$bin" -V 2>&1 | tee version.txt
grep -q "nginx/%{nginx_version}" version.txt
grep -q "OpenSSL %{openssl_version}" version.txt
grep -q -- "--add-module=.*lua-nginx-module" version.txt
readelf -h "$bin" | grep -q 'Type:.*DYN'
readelf -l "$bin" | grep -q GNU_RELRO
readelf -d "$bin" | grep -qE 'BIND_NOW|FLAGS.*NOW'
readelf -d "$bin" | grep -E 'R(UN)?PATH' | grep -q "%{luajit_prefix}/lib"
# (no "! cmd" here: an inverted command never trips sh -e)
if readelf -d "$bin" | grep -E 'R(UN)?PATH' | grep -q "luajit-stage"; then echo "staging RPATH leaked" >&2; exit 1; fi

%post
%systemd_post cfm-edge.service

%preun
%systemd_preun cfm-edge.service

# No restart on upgrade: this is the in-path edge. A stop+start drops every
# connection, and if the new binary's -t refuses the live config the edge
# stays DOWN. The new binary takes over only when the operator or CFM's
# install script runs -t and restarts (or USR2-upgrades) it, after a canary.
%postun
%systemd_postun cfm-edge.service

%files
%license nginx-%{nginx_version}/LICENSE
%doc nginx-%{nginx_version}/CHANGES
%{_sbindir}/cfm-edge
%dir %{edge_confdir}
%config(noreplace) %{edge_confdir}/nginx.conf
%config(noreplace) %{edge_confdir}/mime.types
%config(noreplace) %{_sysconfdir}/logrotate.d/cfm-edge
%{_unitdir}/cfm-edge.service
%{edge_libdir}
%{_datadir}/cfm-edge
%dir %attr(0755,root,root) %{edge_logdir}
%dir %attr(0755,root,root) %{edge_statedir}

%changelog
* %{edge_changelog_date} cfm-edge builder <noreply@nixpal.com> - %{version}-%{release}
- Built by the Makefile from versions.env (see git log for what changed).
