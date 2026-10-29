#!/usr/bin/env bash
# Offline tests for pin-release-checksums.sh, with a fake gh.
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
HASH=$(printf 'a%.0s' {1..64})
cat > "$tmp/gh" <<FAKE
#!/usr/bin/env bash
case "\$2" in
  *releases/tags/v1.0.0) echo "sha256:$HASH" ;;
  *releases/tags/v2.0.0) echo "null" ;;
  *releases/tags/v3.0.0) echo "sha1:abc" ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$tmp/gh"
fails=0
pkg() { # pkg <name> <pkgver> <source-line> <sums-line>
  mkdir -p "$tmp/$1"
  printf 'pkgbase=demo\npkgver=%s\n%s\n%s\n' "$2" "$3" "$4" > "$tmp/$1/PKGBUILD"
}
run() { GH="$tmp/gh" bash "$here/pin-release-checksums.sh" "$tmp/$1" >/dev/null 2>&1; }
expect() { # expect <label> <got-rc> <want-rc> <name> <grep-pattern-or-empty>
  local ok=1
  [[ "$2" == "$3" ]] || ok=0
  [[ -z "${5:-}" ]] || grep -qF -- "$5" "$tmp/$4/PKGBUILD" || ok=0
  if [[ $ok == 1 ]]; then echo "ok   $1"; else echo "FAIL $1 (rc $2, want $3)"; fails=1; fi
}
asset='source=("${pkgbase}-${pkgver}.tar.gz::https://github.com/bopp-os/demo/releases/download/v${pkgver}/${pkgbase}-${pkgver}.tar.gz")'

pkg a 1.0.0 "$asset" "sha256sums=('SKIP')";            run a; expect "pins the asset digest" $? 0 a "sha256sums=('$HASH')"
pkg b 1.0.0 "$asset" "sha256sums=('$HASH')";           run b; expect "leaves a pinned sum alone" $? 0 b "sha256sums=('$HASH')"
pkg c 2.0.0 "$asset" "sha256sums=('SKIP')";            run c; expect "asset not published: rc 3, file untouched" $? 3 c "SKIP"
pkg d 9.9.9 "$asset" "sha256sums=('SKIP')";            run d; expect "no such release: rc 3" $? 3 d "SKIP"
pkg e 3.0.0 "$asset" "sha256sums=('SKIP')";            run e; expect "unexpected digest type: rc 1" $? 1 e "SKIP"
pkg f 1.0.0 'source=("https://example.com/x.tar.gz")' "sha256sums=('SKIP')"; run f; expect "other hosts untouched" $? 0 f "SKIP"
pkg g 1.0.0 'source=("https://github.com/someone/else/releases/download/v1.0.0/x.tar.gz")' "sha256sums=('SKIP')"
run g; expect "other orgs untouched" $? 0 g "SKIP"
pkg h 1.0.0 'source=("a.tar.gz::https://github.com/bopp-os/demo/releases/download/v1.0.0/a.tar.gz" "b.patch")' "sha256sums=('SKIP' 'SKIP')"
run h; expect "several sources untouched" $? 0 h "SKIP' 'SKIP"
pkg i 1.0.0 'source=("https://github.com/bopp-os/demo/releases/download/v$pkgrel/x.tar.gz")' "sha256sums=('SKIP')"
run i; expect "unknown variables untouched" $? 0 i "SKIP"
mkdir -p "$tmp/j"; printf 'pkgname=demo\npkgver=1.0.0\nsource=("https://example.com/x.tar.gz")\nsha256sums=(SKIP)\n' > "$tmp/j/PKGBUILD"
run j; expect "no pkgbase= line: rc 0, untouched" $? 0 j "SKIP"
exit $fails
