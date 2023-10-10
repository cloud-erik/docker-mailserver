#!/bin/bash

# -eE         :: exit on error (do this in functions as well)
# -u          :: show (and exit) when using unset variables
# -o pipefail :: exit on error in pipes
set -eE -u -o pipefail

# shellcheck source=/dev/null
source /etc/os-release

# shellcheck source=../helpers/log.sh
source /usr/local/bin/helpers/log.sh

_log_level_is 'trace' && QUIET='-y' || QUIET='-qq'

function _pre_installation_steps() {
  _log 'info' 'Starting package installation'
  _log 'debug' 'Running pre-installation steps'

  _log 'trace' 'Updating package signatures'
  apt-get "${QUIET}" update

  _log 'trace' 'Installing packages that are needed early'
  apt-get "${QUIET}" install --no-install-recommends apt-utils ca-certificates curl gnupg 2>/dev/null

  if [[ $(uname --machine) == 'x86_64' ]]; then
    _log 'trace' 'Adding Rspamd PPA'
    curl -sSfL https://rspamd.com/apt-stable/gpg.key | gpg --dearmor >/etc/apt/trusted.gpg.d/rspamd.gpg
    echo "deb [arch=amd64 signed-by=/etc/apt/trusted.gpg.d/rspamd.gpg] http://rspamd.com/apt-stable/ ${VERSION_CODENAME} main" >/etc/apt/sources.list.d/rspamd.list
    apt-get "${QUIET}" update
  fi

  _log 'trace' 'Upgrading packages'
  apt-get "${QUIET}" upgrade
}

function _install_postfix() {
  _log 'debug' 'Installing Postfix'

  _log 'warn' 'Applying workaround for Postfix bug (see https://github.com/docker-mailserver/docker-mailserver/issues/2023#issuecomment-855326403)'

  # Debians postfix package has a post-install script that expects a valid FQDN hostname to work:
  mv /bin/hostname /bin/hostname.bak
  echo "echo 'docker-mailserver.invalid'" >/bin/hostname
  chmod +x /bin/hostname
  apt-get "${QUIET}" install --no-install-recommends postfix
  mv /bin/hostname.bak /bin/hostname

  # Irrelevant - Debian's default `chroot` jail config for Postfix needed a separate syslog socket:
  rm /etc/rsyslog.d/postfix.conf
}

function _install_packages() {
  _log 'debug' 'Installing all packages now'

  local ANTI_VIRUS_SPAM_PACKAGES=(
    amavisd-new clamav clamav-daemon
    fail2ban pyzor razor
    rspamd redis-server spamassassin
  )

  local CODECS_PACKAGES=(
    altermime arj bzip2
    cabextract cpio file
    gzip lhasa liblz4-tool
    lrzip lzop nomarch
    p7zip-full pax rpm2cpio
    unrar-free unzip xz-utils
  )

  local MISCELLANEOUS_PACKAGES=(
    apt-transport-https bind9-dnsutils binutils bsd-mailx
    dbconfig-no-thanks dumb-init ed iproute2 iputils-ping
    libdate-manip-perl libldap-common
    libmail-spf-perl libnet-dns-perl
    locales logwatch netcat-openbsd
    nftables rsyslog supervisor
    uuid whois
  )

  local POSTFIX_PACKAGES=(
    pflogsumm postgrey postfix-ldap
    postfix-pcre postfix-policyd-spf-python postsrsd
  )

  local MAIL_PROGRAMS_PACKAGES=(
    fetchmail getmail6 opendkim opendkim-tools
    opendmarc libsasl2-modules sasl2-bin
  )

  apt-get "${QUIET}" --no-install-recommends install \
    "${ANTI_VIRUS_SPAM_PACKAGES[@]}" \
    "${CODECS_PACKAGES[@]}" \
    "${MISCELLANEOUS_PACKAGES[@]}" \
    "${POSTFIX_PACKAGES[@]}" \
    "${MAIL_PROGRAMS_PACKAGES[@]}"
}

function _install_dovecot() {
  local DOVECOT_PACKAGES=(
    dovecot-core dovecot-imapd
    dovecot-ldap dovecot-lmtpd dovecot-managesieved
    dovecot-pop3d dovecot-sieve dovecot-solr
  )

  # if [[ ${DOVECOT_COMMUNITY_REPO} -eq 1 ]]; then
  #   _log 'trace' 'Using Dovecot community repository'
  #   curl https://repo.dovecot.org/DOVECOT-REPO-GPG | gpg --import
  #   gpg --export ED409DA1 > /etc/apt/trusted.gpg.d/dovecot.gpg
  #   echo "deb https://repo.dovecot.org/ce-2.3-latest/debian/bullseye bullseye main" >/etc/apt/sources.list.d/dovecot.list

  #   _log 'trace' 'Updating Dovecot package signatures'
  #   apt-get "${QUIET}" update
  # fi

  _log 'debug' 'Installing Dovecot'
  apt-get "${QUIET}" --no-install-recommends install "${DOVECOT_PACKAGES[@]}"

  # dependency for fts_xapian
  apt-get "${QUIET}" --no-install-recommends install libxapian30
}

function _post_installation_steps() {
  _log 'debug' 'Running post-installation steps (cleanup)'
  _log 'trace' 'Deleting sensitive files (secrets)'
  rm /etc/postsrsd.secret
  _log 'trace' 'Deleting default logwatch cronjob'
  rm /etc/cron.daily/00logwatch
  _log 'trace' 'Removing leftovers from APT'
  apt-get "${QUIET}" clean
  rm -rf /var/lib/apt/lists/*

  _log 'debug' 'Patching Fail2ban to enable network bans'
  # Enable network bans
  # https://github.com/docker-mailserver/docker-mailserver/issues/2669
  sedfile -i -r 's/^_nft_add_set = .+/_nft_add_set = <nftables> add set <table_family> <table> <addr_set> \\{ type <addr_type>\\; flags interval\\; \\}/' /etc/fail2ban/action.d/nftables.conf
}

_pre_installation_steps
_install_postfix
_install_packages
_install_dovecot
_post_installation_steps
