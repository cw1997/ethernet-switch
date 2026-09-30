#!/usr/bin/env bash
# ============================================================================
#  File        : ci/check-toolchain.sh
#  Description : Assert that the EDA toolchain on this machine is the one this
#                repository's CI contract is written against.
#
#                Why this exists
#                ---------------
#                The linter, the simulator and the synthesis frontend come from
#                the toolchain container image declared in
#                `.github/workflows/ci.yml`, not from a pinned artefact, which is
#                deliberate: it means the flow uses distribution builds with
#                security updates, and it means there is no third-party
#                repository in the supply path.
#
#                The cost of that choice is that the tool versions are a property
#                of the *image*, not of this repository.  That image is pinned by
#                tag, and this script is what makes the pin real: if the image is
#                rebuilt on a different base distribution and a tool crosses a
#                major version, the job fails here with a message that says which
#                tool and which version, rather than a job that goes red
#                somewhere inside `make lint` with a warning nobody can
#                attribute.  For the same reason the base distribution is
#                asserted (see ASSERT_OS below) rather than merely reported: a
#                tag that is repointed at, say, the next Ubuntu release is the
#                most likely way for this contract to be broken by accident.
#
#                This is not hypothetical for this design.  Verilator 5.020
#                reports `WIDTHEXPAND` for `3'(8 - beat_left)`; 5.032 and later
#                report nothing at all for the same line.  A silent major bump
#                therefore *weakens* the lint gate rather than failing it, which
#                is precisely the kind of change that must not pass unnoticed.
#                See AGENTS.md section 2.2.
#
#                Usage      : ci/check-toolchain.sh
#                             ASSERT_OS=1 ci/check-toolchain.sh
#                                                    ^ also assert the base
#                                                      distribution; CI does,
#                                                      a local run does not
#                Requires   : the three tools on PATH.  Each is probed, not
#                             assumed, so a partially installed toolchain is
#                             reported as a missing tool rather than as a
#                             version mismatch.
#  Language    : POSIX-ish bash (runs inside the CI toolchain container, on a
#                bare Ubuntu host, and in WSL)
# ============================================================================
set -euo pipefail

# ----------------------------------------------------------------------------
# The contract.  These are the versions the gates in `Makefile` are written
# against, and the versions CI is expected to provide.  Override an entry in the
# environment to test the script itself, e.g.
#
#     IVERILOG_MAJOR=13 ci/check-toolchain.sh      # expect a clean failure
#
# ----------------------------------------------------------------------------
readonly IVERILOG_MAJOR="${IVERILOG_MAJOR:-12}"
readonly VERILATOR_MAJOR="${VERILATOR_MAJOR:-5}"
readonly YOSYS_MIN="${YOSYS_MIN:-0.33}"

# The base distribution the toolchain is expected to have been built on, as the
# `/etc/os-release` `VERSION_ID`.  CI sets ASSERT_OS=1, which turns a mismatch
# into a failure; a local run leaves it off, because a WSL distribution is not
# a CI toolchain and should not have to masquerade as one.  A local run still
# gets the answer, printed as `not asserted`.
readonly EXPECTED_OS="${EXPECTED_OS:-24.04}"
readonly ASSERT_OS="${ASSERT_OS:-0}"

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

# Print "<tool> <expected> <found> <verdict>" as one aligned table row.
row() {
  printf '  %-10s %-12s %-12s %s\n' "$1" "$2" "$3" "$4"
}

# $1 >= $2, version-number aware (5.9 < 5.20 < 6.0).  `sort -V` is in coreutils
# on every Linux image and distribution; a lexicographic comparison would get
# 5.020 vs 5.20 wrong in exactly the way that matters here.
version_ge() {
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}

fail() {
  printf '\n%s\n' "$1" >&2
  exit 1
}

# ----------------------------------------------------------------------------
# Probe
# ----------------------------------------------------------------------------
missing=0

command -v iverilog >/dev/null 2>&1 || { printf 'iverilog: NOT FOUND on PATH\n' >&2; missing=1; }
command -v verilator >/dev/null 2>&1 || { printf 'verilator: NOT FOUND on PATH\n' >&2; missing=1; }
command -v yosys    >/dev/null 2>&1 || { printf 'yosys: NOT FOUND on PATH\n' >&2; missing=1; }

[ "$missing" -eq 0 ] || fail "check-toolchain: install the missing tools before checking versions."

# Each tool prints its version in a different shape, so each gets its own
# extraction, and each pattern is anchored at the start of the line and takes
# the *first* number token.  A greedy `s/.*[^0-9]\([0-9.]*\).*/\1/p` looks like it
# works and does not: against
#
#     Verilator 5.032 2025-01-01 rev (Debian 5.032-1)
#
# it reports "1", because the last number on the line is the revision.
#
# The banners are captured into variables first rather than piped straight into
# `head`, so that a tool which writes more than one pipe buffer cannot take
# SIGPIPE and turn a successful probe into a `pipefail` abort.
banner() { "$@" 2>&1 || true; }

iverilog_version=$(banner iverilog -V    | head -1 | sed -nE 's/.*version ([0-9][0-9.]*).*/\1/p')
verilator_version=$(banner verilator --version | head -1 | sed -nE 's/^Verilator ([0-9][0-9.]*).*/\1/p')
yosys_version=$(banner yosys -V         | head -1 | sed -nE 's/^Yosys ([0-9][0-9.]*).*/\1/p')

# A probe that extracted nothing is a parsing failure, not a version mismatch,
# and the two need different fixes.
for pair in "iverilog -V:$iverilog_version" "verilator --version:$verilator_version" "yosys -V:$yosys_version"; do
  if [ -z "${pair#*:}" ]; then
    printf 'check-toolchain: could not parse a version out of `%s`\n' "${pair%%:*}" >&2
    fail "check-toolchain: the tool banner changed shape; update the extraction above."
  fi
done

# ----------------------------------------------------------------------------
# Report
# ----------------------------------------------------------------------------
os_version=$( (. /etc/os-release 2>/dev/null && printf '%s' "${VERSION_ID:-unknown}") || printf 'unknown' )

printf '\n'
printf 'Toolchain\n'
printf '  %-10s %-12s %-12s %s\n' tool expected found verdict
printf '  %-10s %-12s %-12s %s\n' '--------' '------------' '------------' '--------'

rc=0

if [ "$(printf '%s' "$iverilog_version" | cut -d. -f1)" = "$IVERILOG_MAJOR" ]; then
  row iverilog "major $IVERILOG_MAJOR" "$iverilog_version" ok
else
  row iverilog "major $IVERILOG_MAJOR" "$iverilog_version" "MISMATCH"
  rc=1
fi

if [ "$(printf '%s' "$verilator_version" | cut -d. -f1)" = "$VERILATOR_MAJOR" ]; then
  row verilator "major $VERILATOR_MAJOR" "$verilator_version" ok
else
  row verilator "major $VERILATOR_MAJOR" "$verilator_version" "MISMATCH"
  rc=1
fi

# yosys is versioned 0.x, so a major-version lock would be "major 0" and would
# pass for any release since 2005.  A minimum is the only meaningful constraint.
if version_ge "$yosys_version" "$YOSYS_MIN"; then
  row yosys ">= $YOSYS_MIN" "$yosys_version" ok
else
  row yosys ">= $YOSYS_MIN" "$yosys_version" "TOO OLD"
  rc=1
fi

# The base distribution.  Under CI this is the toolchain *image*'s base, and a
# mismatch means the tag in ci.yml now points at a different build than the one
# this contract was written against - which is a plausible accident and a silent
# one, because the tool versions are printed right above it and may well still
# satisfy the contract by luck.  A local run only reports.
if [ "$os_version" = "$EXPECTED_OS" ]; then
  row 'base OS' "$EXPECTED_OS" "$os_version" ok
elif [ "$ASSERT_OS" = "1" ]; then
  row 'base OS' "$EXPECTED_OS" "$os_version" 'MISMATCH'
  rc=1
else
  row 'base OS' "$EXPECTED_OS" "$os_version" 'not asserted'
fi
printf '\n'

if [ "$rc" -ne 0 ]; then
  cat >&2 <<'EOF'
check-toolchain: the toolchain does not match the contract in ci/check-toolchain.sh.

  This is a deliberate gate, not an inconvenience.  One of three things is true:

    1. The toolchain image moved - a different base distribution, or a rebuilt
       tag - and a tool crossed a major version.  The gates in `Makefile` were
       written against the old major.  Either the new one is compatible - in
       which case raise the expected version here and say so in the commit
       message - or it is not, in which case the regression found by a newer
       major is a real one and the RTL needs the fix.

    2. The expected version here is wrong.  Correct it against what the image
       actually ships.

    3. Only the base distribution row failed, with every tool version still
       matching.  Then nothing has broken *yet*: the image is simply not the
       one this contract was written against, and the versions it happens to
       ship today are not a promise about tomorrow.  Re-point EXPECTED_OS in
       the workflow only after checking what the new base actually ships - a
       distribution that is merely newer is not evidence of a newer Verilator.

  Do not widen a gate to make this check pass.  Verilator in particular gets
  *quieter* across majors, so a silent bump removes findings rather than adding
  them; see the header of this file and AGENTS.md section 2.2.
EOF
  exit 1
fi

printf 'toolchain matches the CI contract\n'
