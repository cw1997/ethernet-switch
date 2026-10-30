# ============================================================================
#  File        : ci/toolchain/Dockerfile
#  Description : The EDA toolchain image the lint and test jobs run in.
#
#                This image *is* the toolchain pin.  The runner is a machine
#                that is kept, not an image that is thrown away, so the tools
#                that grade the RTL cannot be "whatever is on the host today":
#                they are whatever this file builds, and the versions are
#                asserted against the contract in ci/check-toolchain.sh the
#                first thing every job does.
#
#                Build it on the runner host (the machine registered with the
#                `[self-hosted, linux, x64]` labels) and re-build it only on a
#                toolchain contract change:
#
#                    docker build -t sw-toolchain:26.04 ci/toolchain/
#
#                The jobs reference the image by that tag.  A container job
#                cannot be told "use a local image, do not pull", so the tag
#                must exist in the runner's local Docker store before the job
#                starts; the jobs fail with a pull error otherwise, which is the
#                intended failure mode: it names the missing image.
#
#  Base        : Ubuntu 26.04 LTS, the distribution the contract in
#                ci/check-toolchain.sh is written against (EXPECTED_OS).
#
#  Contents    : iverilog (the simulator), verilator (the linter),
#                yosys (the synthesis frontend), plus git / bash / make, which
#                the job steps and the actions they run need on PATH.  The
#                image must be glibc-based: a container job runs its JavaScript
#                action steps inside the image using a Node binary bind-mounted
#                in from the runner, and that binary does not start against musl.
#                (Alpine's failure there is a dynamic-loader error in the first
#                step of the job, which reads like a broken runner.)
# ============================================================================
FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash \
      ca-certificates \
      git \
      iverilog \
      make \
      verilator \
      yosys \
 && rm -rf /var/lib/apt/lists/*
