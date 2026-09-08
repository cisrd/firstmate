#!/usr/bin/env bash
set -eu
ROOT=$PWD
D="$ROOT/.test-tmp/demo"
mkdir -p "$D/home/data" "$D/home/projects"
export GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=user.name GIT_CONFIG_VALUE_0=Test GIT_CONFIG_KEY_1=user.email GIT_CONFIG_VALUE_1=test@example.invalid
export FM_HOME="$D/home" FM_GATE_REFUSE_BYPASS=1
W="$D/upstream"; C="$FM_HOME/projects/project_code_zero"
git init -q -b main "$W"
printf 'initial\n' > "$W/base.txt"
git -C "$W" add .; git -C "$W" commit -qm initial
git -C "$W" branch develop
git clone -q --bare "$W" "$D/origin.git"
git -C "$W" remote add origin "$D/origin.git"
git clone -q "$D/origin.git" "$C"
git -C "$C" checkout -q develop
printf -- '- project_code_zero [no-mistakes integration-branch=develop] - fixture\n' > "$FM_HOME/data/projects.md"
git -C "$W" checkout -q develop
printf 'merged feature\n' > "$W/feature.txt"
git -C "$W" add .; git -C "$W" commit -qm 'merged feature on develop'; git -C "$W" push -q origin develop
printf 'Remote default: '; git -C "$C" symbolic-ref refs/remotes/origin/HEAD
printf '\n$ fm-fleet-sync.sh project_code_zero\n'
bash "$ROOT/bin/fm-fleet-sync.sh" project_code_zero
printf 'Checked-out branch: '; git -C "$C" branch --show-current
printf 'Delivered content: '; git -C "$C" show HEAD:feature.txt
test "$(git -C "$C" rev-parse HEAD)" = "$(git -C "$W" rev-parse develop)"
printf '\n$ fm-fleet-sync.sh project_code_zero (repeat)\n'
bash "$ROOT/bin/fm-fleet-sync.sh" project_code_zero
for declaration in missing ..bad ''; do
 printf -- '- project_code_zero [no-mistakes integration-branch=%s] - fixture\n' "$declaration" > "$FM_HOME/data/projects.md"
 printf '\n$ fm-fleet-sync.sh project_code_zero (declaration=%s)\n' "$declaration"
 before=$(git -C "$C" rev-parse HEAD)
 bash "$ROOT/bin/fm-fleet-sync.sh" project_code_zero
 test "$before" = "$(git -C "$C" rev-parse HEAD)"
done
printf '\nLegacy registry (prose mentions develop, no declaration):\n'
printf -- '- project_code_zero [no-mistakes] - develop mentioned only in prose\n' > "$FM_HOME/data/projects.md"
git -C "$C" checkout -q main
bash "$ROOT/bin/fm-fleet-sync.sh" project_code_zero
printf 'Legacy branch: '; git -C "$C" branch --show-current
