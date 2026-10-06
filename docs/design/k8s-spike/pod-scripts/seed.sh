# regular init container (the "seed" of K§10.1, minus the network): builds the PrivateClone-shaped
# guard files in the shared `work` volume, as uid 10001 under hostUsers:false.
set -eu
echo "seed: id=$(id -u):$(id -g) uid_map=$(tr -s ' ' < /proc/self/uid_map | tr '\n' ';')"
W=/work/wt/.git
mkdir -p $W/hooks $W/objects/info $W/refs/heads /work/home /work/claude-config
printf '[core]\n\trepositoryformatversion = 0\n' > $W/config
printf '.\n' > $W/commondir
: > $W/objects/info/alternates
printf 'ref: refs/heads/main\n' > $W/HEAD
ls -ln $W
