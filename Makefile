# Copyright 2019 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
SHELL := /bin/bash
PYTHON3 ?= python3
MAKEFILE_DIR := $(realpath $(dir $(lastword $(MAKEFILE_LIST))))
PY3_VER ?= $(shell $(PYTHON3) -c "import sys;print('%d%d' % sys.version_info[:2])")
OS := $(shell uname -s)

# Allowed CPU values: k8, armv7a, aarch64, darwin

ifeq ($(filter $(CPU), aarch64 ),)
$(error CPU must be aarch64 )
endif

# Allowed COMPILATION_MODE values: opt, dbg
COMPILATION_MODE ?= opt
ifeq ($(filter $(COMPILATION_MODE),opt dbg),)
$(error COMPILATION_MODE must be opt or dbg)
endif

BAZEL_OUT_DIR :=  $(MAKEFILE_DIR)/bazel-out/$(CPU)-$(COMPILATION_MODE)/bin
BAZEL_BUILD_FLAGS_Linux := --crosstool_top=@crosstool//:toolchains \
                           --compiler=gcc \
                           --linkopt=-l:libedgetpu.so.1
BAZEL_BUILD_FLAGS_Darwin := --linkopt=-ledgetpu.1

ifeq ($(COMPILATION_MODE), opt)
BAZEL_BUILD_FLAGS_Linux += --linkopt=-Wl,--strip-all
endif

ifeq ($(CPU),aarch64)
BAZEL_BUILD_FLAGS_Linux += --copt=-ffp-contract=off
SWIG_WRAPPER_NAME := _edgetpu_cpp_wrapper.cpython-$(PY3_VER)m-aarch64-linux-gnu.so
endif

BAZEL_BUILD_FLAGS := --compilation_mode=$(COMPILATION_MODE) \
                     --copt=-DNPY_NO_DEPRECATED_API=NPY_1_7_API_VERSION \
                     --verbose_failures \
                     --sandbox_debug \
                     --subcommands \
                     --define PY3_VER=$(PY3_VER) \
                     --cpu=$(CPU) \
                     --linkopt=-L$(MAKEFILE_DIR)/libedgetpu/direct/$(CPU) \
                     --experimental_repo_remote_exec
BAZEL_BUILD_FLAGS += $(BAZEL_BUILD_FLAGS_$(OS))

BAZEL_QUERY_FLAGS := --experimental_repo_remote_exec

# $(1): pattern, $(2) destination directory
define copy_out_files
pushd $(BAZEL_OUT_DIR); \
for f in `find . -name $(1) -type f`; do \
	mkdir -p $(2)/`dirname $$f`; \
	cp -f $(BAZEL_OUT_DIR)/$$f $(2)/$$f; \
done; \
popd
endef

EXAMPLES_OUT_DIR    := $(MAKEFILE_DIR)/out/$(CPU)/examples

examples:
	bazel build $(BAZEL_BUILD_FLAGS) //src/cpp/examples:minimal
	mkdir -p $(EXAMPLES_OUT_DIR)
	cp -f $(BAZEL_OUT_DIR)/src/cpp/examples/minimal \
	      $(EXAMPLES_OUT_DIR)

clean:
	rm -rf $(MAKEFILE_DIR)/bazel-* \
	       $(MAKEFILE_DIR)/build \
	       $(MAKEFILE_DIR)/dist \
	       $(MAKEFILE_DIR)/edgetpu.egg-info \
	       $(MAKEFILE_DIR)/edgetpu/swig/*.so \
	       $(MAKEFILE_DIR)/edgetpu/swig/edgetpu_cpp_wrapper.py \
	       $(MAKEFILE_DIR)/out

DOCKER_WORKSPACE=$(MAKEFILE_DIR)
DOCKER_CPUS=aarch64
DOCKER_TAG_BASE=coral-edgetpu
#include $(MAKEFILE_DIR)/docker.mk
DOCKER_MK_DIR := $(realpath $(dir $(lastword $(MAKEFILE_LIST))))

# Docker
#DOCKER_CPUS ?= k8 armv7a armv6 aarch64
DOCKER_CPUS ?= aarch64
DOCKER_TARGETS ?=
DOCKER_IMAGE ?= debian:stretch
DOCKER_TAG_BASE ?= "bazel-cross"
DOCKER_TAG := "$(DOCKER_TAG_BASE)-$(subst :,-,$(DOCKER_IMAGE))"
DOCKER_SHELL_COMMAND ?=

ifndef DOCKER_WORKSPACE
$(error DOCKER_WORKSPACE is not defined)
endif

WORKSPACE := /workspace
MAKE_COMMAND := \
for cpu in $(DOCKER_CPUS); do \
    make CPU=\$${cpu} -C /workspace $(DOCKER_TARGETS) || exit 1; \
done

define run_command
chmod a+w /; \
groupadd --gid $(shell id -g) $(shell id -g -n); \
useradd -m -e '' -s /bin/bash --gid $(shell id -g) --uid $(shell id -u) $(shell id -u -n); \
echo '$(shell id -u -n) ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers; \
su $(shell id -u -n) $(if $(1),-c '$(1)',)
endef

docker-image:
	docker build $(DOCKER_IMAGE_OPTIONS) -t $(DOCKER_TAG) \
	    --build-arg IMAGE=$(DOCKER_IMAGE) $(DOCKER_MK_DIR)

docker-shell: docker-image
	docker run --rm -i --tty -v $(DOCKER_WORKSPACE):$(WORKSPACE) --workdir $(WORKSPACE) \
	    $(DOCKER_TAG) /bin/bash -c "$(call run_command,$(DOCKER_SHELL_COMMAND))"

docker-build: docker-image
	docker run --rm -i $(shell tty -s && echo --tty) -v $(DOCKER_WORKSPACE):$(WORKSPACE) \
	    $(DOCKER_TAG) /bin/bash -c "$(call run_command,$(MAKE_COMMAND))"



help:
	@echo "make examples          - Build all C++ examples"
	@echo "make clean             - Remove generated files"
	@echo "make help              - Print help message"

# Debugging util, print variable names. For example, `make print-ROOT_DIR`.
print-%:
	@echo $* = $($*)
