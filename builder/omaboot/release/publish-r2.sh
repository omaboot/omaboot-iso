#!/bin/bash
# Upload a verified OmaBoot? release to Cloudflare R2 and keep the current release plus the two before
# it per edition (LIVE-PLAN §20). Called by .github/workflows/publish.yml after verify-sums.sh --all.
#   publish-r2.sh DIR EDITION TAG
# Layout in the bucket: <edition>/<tag>/<files> and <edition>/releases.json (newest first), which
# the download page reads. A release already in the bucket is never overwritten.
# Environment: R2_ACCOUNT_ID, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_BUCKET; R2_KEEP (default 3).
set -euo pipefail
dir=${1:?usage: publish-r2.sh DIR EDITION TAG} edition=${2:?} tag=${3:?}
: "${R2_ACCOUNT_ID:?}" "${R2_ACCESS_KEY_ID:?}" "${R2_SECRET_ACCESS_KEY:?}" "${R2_BUCKET:?}"
keep=${R2_KEEP:-3}
name_re='^[A-Za-z0-9][A-Za-z0-9._-]*$'
[[ $edition =~ $name_re && $tag =~ $name_re ]] || { echo "publish-r2: bad edition or tag" >&2; exit 1; }
export AWS_ACCESS_KEY_ID=$R2_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY=$R2_SECRET_ACCESS_KEY AWS_DEFAULT_REGION=auto
# R2 doesn't take the AWS CLI's newer default checksum headers on every call
export AWS_REQUEST_CHECKSUM_CALCULATION=when_required AWS_RESPONSE_CHECKSUM_VALIDATION=when_required
endpoint=https://$R2_ACCOUNT_ID.r2.cloudflarestorage.com
s3() { aws --endpoint-url "$endpoint" "$@"; }

if s3 s3api head-object --bucket "$R2_BUCKET" --key "$edition/$tag/SHA256SUMS" >/dev/null 2>&1; then
  echo "publish-r2: $edition/$tag is in the bucket already; not overwriting it" >&2
  exit 1
fi

# 1. The files: everything SHA256SUMS lists, then the checksums and their signature (last, so a
# half-finished upload never looks complete), and the signers file to check them with.
mapfile -t files < <(awk '{ sub(/^\*/, "", $2); print $2 }' "$dir/SHA256SUMS")
for f in "${files[@]}" SHA256SUMS SHA256SUMS.sig; do
  [[ $f =~ $name_re ]] || { echo "publish-r2: odd file name '$f'" >&2; exit 1; }
  s3 s3 cp --no-progress "$dir/$f" "s3://$R2_BUCKET/$edition/$tag/$f"
done
"$(dirname "$0")/verify-sums.sh" --signers >"$dir/allowed_signers"
s3 s3 cp --no-progress "$dir/allowed_signers" "s3://$R2_BUCKET/$edition/$tag/allowed_signers"

# 2. The index: this release first, then the ones kept.
if ! s3 s3 cp --no-progress "s3://$R2_BUCKET/$edition/releases.json" "$dir/releases.old.json" 2>/dev/null; then
  echo '{"releases": []}' >"$dir/releases.old.json"
fi
python3 -I - "$dir" "$edition" "$tag" "$keep" <<'EOF'
import json, os, sys, time
d, edition, tag, keep = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
info = json.load(open(os.path.join(d, 'build-info.json')))
sums = dict(reversed(l.split(None, 1)) for l in open(os.path.join(d, 'SHA256SUMS')).read().splitlines() if l.strip())
sums = {k.lstrip('*').strip(): v for k, v in sums.items()}
old = [r for r in json.load(open(os.path.join(d, 'releases.old.json'))).get('releases', []) if r.get('tag') != tag]
new = {'tag': tag, 'published': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()), 'omarchy': info['omarchy'],
       'iso': info['iso'], 'iso_bytes': info['iso_bytes'], 'iso_sha256': sums[info['iso']],
       'path': f'{edition}/{tag}/', 'files': sorted(sums) + ['SHA256SUMS', 'SHA256SUMS.sig', 'allowed_signers']}
releases = [new] + old
json.dump({'edition': edition, 'current': tag, 'releases': releases[:keep]}, open(os.path.join(d, 'releases.json'), 'w'), indent=2)
open(os.path.join(d, 'dropped.txt'), 'w').write(''.join(r['tag'] + '\n' for r in releases[keep:]))
EOF
s3 s3 cp --no-progress --content-type application/json --cache-control 'max-age=300' "$dir/releases.json" "s3://$R2_BUCKET/$edition/releases.json"
cat "$dir/releases.json"

# 3. Older releases leave the bucket (the GitHub releases keep their checksums and signatures).
while read -r old_tag; do
  [[ -n $old_tag && $old_tag =~ $name_re && $old_tag != "$tag" ]] || continue
  echo "publish-r2: removing $edition/$old_tag/ (more than $keep releases)"
  s3 s3 rm --recursive "s3://$R2_BUCKET/$edition/$old_tag/"
done <"$dir/dropped.txt"
