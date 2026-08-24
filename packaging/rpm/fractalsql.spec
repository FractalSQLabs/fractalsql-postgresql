%global         pg_major %{?pg_major}%{!?pg_major:16}
%global         pg_libdir     %{_libdir}/pgsql
%global         pg_extensiondir %{_datadir}/pgsql/extension

# Caller passes --define "pg_major 16|17|18" to pick the matching
# prebuilt .so from dist/${arch}/fractalsql_pg${pg_major}.so.

Name:           postgresql-%{pg_major}-fractalsql
Version:        1.0.0
Release:        1%{?dist}
Summary:        Stochastic Fractal Search extension for PostgreSQL %{pg_major}

License:        Apache-2.0
URL:            https://github.com/FractalSQLabs/fractalsql-postgresql
Source0:        %{name}-%{version}.tar.gz

BuildRequires:  gcc, make, postgresql%{pg_major}-devel
Requires:       postgresql%{pg_major}-server
# Soname capability (provided by both libcurl and libcurl-minimal) so we
# don't conflict with the libcurl-minimal that ships in RHEL/Rocky base.
Requires:       libcurl.so.4()(64bit)

%description
FractalSQL registers the fractal_search() and fractal_search_explore()
functions — a pure-C Stochastic Fractal Search optimizer for
high-diversity vector search inside PostgreSQL %{pg_major}, with an
optional LLM reasoning plugin (fractalsql-reasoning-http, which links
libcurl).

%prep
%setup -q

%build
# The per-PG-version .so is produced out-of-band by build.sh on a Docker
# builder; this spec just stages it into the RPM.
test -f dist/fractalsql_pg%{pg_major}.so

%install
install -Dm0755 dist/fractalsql_pg%{pg_major}.so \
    %{buildroot}/usr/pgsql-%{pg_major}/lib/fractalsql.so
install -Dm0644 fractalsql.control \
    %{buildroot}/usr/pgsql-%{pg_major}/share/extension/fractalsql.control
install -Dm0644 sql/fractalsql--1.0.sql \
    %{buildroot}/usr/pgsql-%{pg_major}/share/extension/fractalsql--1.0.sql
# Dependent fractalsql_agents extension (pure PL/pgSQL; requires='fractalsql',
# no .so). Ships the .control + install SQL alongside the base extension so
# `CREATE EXTENSION fractalsql_agents` works once the base is loaded.
install -Dm0644 fractalsql_agents/fractalsql_agents.control \
    %{buildroot}/usr/pgsql-%{pg_major}/share/extension/fractalsql_agents.control
install -Dm0644 fractalsql_agents/sql/fractalsql_agents--1.0.sql \
    %{buildroot}/usr/pgsql-%{pg_major}/share/extension/fractalsql_agents--1.0.sql

%files
%license LICENSE
%license THIRD-PARTY-NOTICES.md
/usr/pgsql-%{pg_major}/lib/fractalsql.so
/usr/pgsql-%{pg_major}/share/extension/fractalsql.control
/usr/pgsql-%{pg_major}/share/extension/fractalsql--1.0.sql
/usr/pgsql-%{pg_major}/share/extension/fractalsql_agents.control
/usr/pgsql-%{pg_major}/share/extension/fractalsql_agents--1.0.sql

%changelog
* Sat Apr 18 2026 FractalSQLabs <ops@fractalsqlabs.io> - 1.0.0-1
- Initial Factory-standardized release for PostgreSQL 16 / 17 / 18.
