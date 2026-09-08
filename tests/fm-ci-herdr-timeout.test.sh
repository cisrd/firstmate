#!/usr/bin/env bash
# The required Herdr lane's hang tripwire is the family-run step bound, not
# the job cap. Parse YAML so nested with.name artifact keys cannot masquerade
# as the step contract.
set -u

if ! command -v ruby >/dev/null 2>&1; then
  printf 'skip: ruby absent; YAML assertion not run\n'
  exit 0
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ruby -ryaml -e '
doc = YAML.load_file(ARGV[0])
job = doc.fetch("jobs").fetch("tests-herdr")
step = job.fetch("steps").find { |s|
  s.is_a?(Hash) && s["name"] == "Run real-Herdr family (serial, required)"
}
raise "missing family-run step" if step.nil?
job_timeout = job.fetch("timeout-minutes")
step_timeout = step.fetch("timeout-minutes")
raise "tests-herdr job backstop must stay 75 minutes" unless job_timeout == 75
raise "family-run step timeout must be 20 minutes" unless step_timeout == 20
raise "family-run step timeout must be below the job backstop" unless step_timeout < job_timeout
' "$ROOT/.github/workflows/ci.yml" || fail "invalid tests-herdr timeout contract"
pass "Herdr CI family-run step times out at 20 min under a 75 min job backstop"
