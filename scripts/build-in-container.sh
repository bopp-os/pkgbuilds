#!/usr/bin/env bash
# build-in-container.sh — build one package. Runs INSIDE the rootless build container, as the container's root
# (a subuid on the host, so it owns nothing there). Used by the build job in build-repo.yml and by test-build.sh.
#
# Usage: build-in-container.sh <package-dir> <output-dir> [<keys-dir>]
#
# Root only does what needs it: add the bopp-os repository, `pacman -Syu`, install dependencies, check key fingerprints.
# The PKGBUILD's own code (sourcing, check-sources, gpg import, makepkg) runs as the unprivileged `builder` user, which has
# no way to escalate. It is uid 1000, which the caller maps to the runner's host user (--userns=keep-id), so everything written to a
# mounted folder belongs to the runner and the runner can delete it again.
# Not signed here: the build job runs PKGBUILD code and never sees the signing key. The publish job signs.
set -euo pipefail

pkgdir=${1:?usage: $0 <package-dir> <output-dir> [<keys-dir>]}
out=${2:?usage: $0 <package-dir> <output-dir> [<keys-dir>]}
keys=${3:-/keys}
here=$(dirname "$(readlink -f "$0")")
pkg=$(basename "$pkgdir")

# Fingerprint of the repository signing key (also pinned in bopp-os/cachyos scripts/setup_pacman_repos.sh).
want=3806768589376830FEA123D6CF30985CE903D47C

# pacman 7 downloads as a sandboxed user (Landlock), which does not work inside a rootless container.
pacman_opts=(--noconfirm)
if pacman -S --help 2>&1 | grep -q -- --disable-sandbox; then pacman_opts+=(--disable-sandbox); fi

add_bopp_repo() {
  # Packages here can depend on each other (litterbox-sandbox-addons needs litterbox-sandbox), and `makepkg -s` only
  # installs dependencies from the repositories pacman knows. Appended last so Arch and CachyOS packages keep priority.
  # The key comes from this checkout (keys/boppos.gpg), not from the network, and packages must be signed by it.
  # Best effort: if the repository cannot be had, the job carries on exactly as before and only a package that really
  # needs something from this repository fails.
  local fpr
  if grep -q '^\[bopp-os\]' /etc/pacman.conf; then echo "bopp-os repository already configured"; return 0; fi
  fpr=$(gpg --with-colons --show-keys "$keys/boppos.gpg" | awk -F: '/^fpr/ {print $10; exit}')
  if [[ "$fpr" != "$want" ]]; then
    echo "::warning::bopp-os repository key is $fpr, expected $want; building without that repository"; return 0
  fi
  if ! pacman-key --add "$keys/boppos.gpg" || ! pacman-key --lsign-key "$fpr"; then
    echo "::warning::could not import the bopp-os repository key; building without that repository"; return 0
  fi
  printf '\n[bopp-os]\nSigLevel = Required DatabaseOptional\nServer = https://repo.ripps.me\n' >> /etc/pacman.conf
  echo "Added the bopp-os repository (key $fpr)"
}

add_bopp_repo
pacman -Syu "${pacman_opts[@]}" base-devel git

# makepkg refuses root, and the PKGBUILD is untrusted code: run it as an unprivileged user with no way to escalate.
uid=${BUILDER_UID:-1000}
if getent passwd "$uid" > /dev/null; then
  builder=$(getent passwd "$uid" | cut -d: -f1)
else
  useradd -m -u "$uid" builder
  builder=builder
fi
home=$(getent passwd "$builder" | cut -d: -f6)
install -d -o "$builder" "$home"
mkdir -p "$out"
as_builder() { runuser -u "$builder" -- env HOME="$home" "$@"; }

# Fail early and say why if the build user cannot write where makepkg and the output go (wrong owner, SELinux label, ...).
for d in "$pkgdir" "$out"; do
  if ! as_builder test -w "$d"; then
    echo "::error::$builder (uid $(id -u "$builder")) cannot write to $d"
    ls -ldnZ "$d" || ls -ldn "$d"
    cat /proc/self/uid_map
    exit 1
  fi
done

as_builder bash "$here/check-sources.sh" "$pkgdir"

# Upstream signing keys are committed in keys/pgp/<fingerprint>.asc and checked against that fingerprint here: no
# keyserver is involved, and a missing or mismatching key fails the build.
# The PKGBUILD is sourced, which runs its top-level code: as the unprivileged builder, like makepkg itself.
# shellcheck disable=SC2016  # the $ are meant for the inner shell
keyline=$(as_builder bash -c 'cd "$1"; source ./PKGBUILD; echo "${validpgpkeys[@]}"' _ "$pkgdir")
read -r -a pgpkeys <<< "$keyline"
for key in "${pgpkeys[@]}"; do
  file="$keys/pgp/$key.asc"
  if [[ ! -f "$file" ]]; then
    echo "::error::$pkg: validpgpkeys lists $key but keys/pgp/$key.asc is not in the repository"
    exit 1
  fi
  have=$(gpg --with-colons --show-keys "$file" | awk -F: '/^fpr/ {print $10; exit}')
  if [[ "$have" != "$key" ]]; then
    echo "::error::keys/pgp/$key.asc holds key $have, not $key"
    exit 1
  fi
  as_builder gpg --batch --import "$file"
done

# Dependencies: what `makepkg -s` would install through a privileged helper. Root installs them here, so makepkg itself never needs
# privileges (and finds nothing missing, so it never asks for any).
info=$(cd "$pkgdir" && as_builder makepkg --printsrcinfo)
mapfile -t own < <(awk -F' = ' '/^[[:space:]]*pkgname = / {print $2}' <<< "$info")
mapfile -t deps < <(awk -F' = ' -v arch="$(uname -m)" \
  '$1 ~ ("^[[:space:]]*(make|check)?depends(_" arch ")?$") {print $2}' <<< "$info" | sort -u)
if [[ ${#deps[@]} -gt 0 ]]; then
  mapfile -t missing < <(pacman -T "${deps[@]}" || true)  # exit 127 means "some are missing"
  names=()
  for dep in "${missing[@]}"; do
    dep=${dep%%[<>=]*}
    [[ -z "$dep" || " ${own[*]} " == *" $dep "* ]] && continue
    names+=("$dep")
  done
  if [[ ${#names[@]} -gt 0 ]]; then
    echo "Installing dependencies: ${names[*]}"
    pacman -S "${pacman_opts[@]}" --asdeps --needed "${names[@]}"
  fi
fi

mkdir -p "$out"
(
  cd "$pkgdir"
  as_builder makepkg -s --noconfirm --noprogressbar
  ls -la ./*.pkg.tar.zst
  as_builder cp ./*.pkg.tar.zst "$out/"
)
