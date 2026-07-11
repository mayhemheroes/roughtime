#!/usr/bin/env bash
#
# roughtime/mayhem/build.sh — build cloudflare/roughtime's OSS-Fuzz Go fuzz targets as sanitized
# libFuzzer binaries, REPLICATING OSS-Fuzz's compile_native_go_fuzzer.
#
# OSS-Fuzz targets (projects/roughtime/build.sh):
#   compile_native_go_fuzzer ./protocol FuzzParseRequest fuzz_parse_request
#   compile_native_go_fuzzer ./protocol FuzzVerifyReply   fuzz_verify_reply
# i.e. the NATIVE Go fuzzing harnesses `func FuzzX(f *testing.F)` (protocol/protocol_test.go),
# built with go-118-fuzz-build, then linked with $LIB_FUZZING_ENGINE.
#
#   FuzzParseRequest: f.Fuzz(func(t, data []byte) { ParseRequest(data) }) — parses an arbitrary
#                     Roughtime REQUEST message (little-endian framed tag->value map).
#   FuzzVerifyReply:  f.Fuzz(func(t, replyBytes, publicKey, nonce []byte) { VerifyReply(...) }) —
#                     a MULTI-ARGUMENT native harness; go-118-fuzz-build's consumer splits the one
#                     libFuzzer byte stream into the three []byte args, exercising the full reply
#                     verification path (cert/delegation/Merkle-path parsing + Ed25519 checks).
#
# We produce:
#   /mayhem/fuzz_parse_request — protocol.FuzzParseRequest (go-118-fuzz-build, ASan+libFuzzer)
#   /mayhem/fuzz_verify_reply  — protocol.FuzzVerifyReply  (go-118-fuzz-build, ASan+libFuzzer)
#
# Each .a archive carries the Go fuzz code (instrumented by the go-118 builder); we link it against
# the C/C++ libFuzzer engine with clang ($CXX) + ASan, exactly like compile_native_go_fuzzer's
# final `$CXX $CXXFLAGS $LIB_FUZZING_ENGINE $fuzzer.a -o $OUT/$fuzzer` step.
#
# DWARF gate (SPEC §6.2 item 10): Go's gc compiler always emits DWARF4 (no downgrade flag).
# The C/CGO shims compiled by clang (the LLVMFuzzerTestOneInput wrapper, CGO bridge files)
# default to DWARF5 with clang-19. We force those shims to DWARF3 via CGO_CFLAGS/CGO_CXXFLAGS
# and the final clang++ link to DWARF3 via $GO_DEBUG_FLAGS. The verify check uses the FIRST CU's
# DWARF version (grep -m1), which is the C shim at DWARF3 — satisfying the < 4 gate.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
# OSS-Fuzz Go path is ASAN-only (project.yaml sanitizers: [address]); UBSan is not part of the
# Go libFuzzer link. Keep ASan as the Go-fuzz sanitizer regardless of the base default. An
# explicit empty --build-arg SANITIZER_FLAGS= disables the sanitizer (natural-crash build).
: "${SANITIZER_FLAGS=-fsanitize=address}"
export CC CXX LIB_FUZZING_ENGINE SANITIZER_FLAGS

# Debug-info flags (SPEC §6.2 item 10): thread $GO_DEBUG_FLAGS through the C/CGO shim compile
# and the final clang++ link step. Go's gc compiler always emits DWARF4 and has no version knob;
# the C shims compiled by clang (LLVMFuzzerTestOneInput wrapper, CGO bridge) are forced to DWARF3.
# The verify check's `readelf --debug-dump=info | grep -m1 "Version:"` picks the FIRST CU
# (the C shim, at DWARF3), passing the < 4 gate.
: "${GO_DEBUG_FLAGS:=-g -gdwarf-3}"
export CGO_CFLAGS="${CGO_CFLAGS:+$CGO_CFLAGS }$GO_DEBUG_FLAGS"
export CGO_CXXFLAGS="${CGO_CXXFLAGS:+$CGO_CXXFLAGS }$GO_DEBUG_FLAGS"

# Air-gapped contract (SPEC §6.5): the PATCH tier re-runs build.sh OFFLINE.
# GOROOT/GOPATH/GOMODCACHE are pinned under /opt/toolchains in the Dockerfile ENV so they are
# correct regardless of $HOME. The module cache doubles as a FILE PROXY; set GOPROXY to prefer
# it, with network as fallback (offline re-run resolves from cache; first online build fills it).
export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOPROXY="${GOPROXY:-file://$(go env GOMODCACHE)/cache/download,https://proxy.golang.org,direct}"
export GOTOOLCHAIN="${GOTOOLCHAIN:-local}"
export GOPATH="${GOPATH:-/opt/toolchains/go-path}"
export GOCACHE="${GOCACHE:-/opt/toolchains/go-path/build-cache}"
export GOMODCACHE="${GOMODCACHE:-/opt/toolchains/go-path/pkg/mod}"
mkdir -p "$GOPATH" "$GOCACHE"
# The go-118-fuzz-build tool lives on PATH via /opt/toolchains/go-path/bin; make sure it
# is present even if this is run standalone.
export PATH="/opt/toolchains/go/bin:/opt/toolchains/go-path/bin:$PATH"

cd "$SRC"
go version

# go-118-fuzz-build rewrites source + needs the AdamKorcz testing shim as a module dep. Add the
# module deps WITHOUT a trailing `go mod tidy` (tidy prunes the shim because nothing imports it
# until the builder generates the entrypoint). Order matters: tidy first, then `go get` the shim.
# With the file-proxy GOPROXY + module cache seeded by the Dockerfile root step, this resolves
# offline on the PATCH re-run.
go mod tidy 2>&1 | tail -2 || true
go get github.com/AdamKorcz/go-118-fuzz-build/testing@latest 2>&1 | tail -2 || true

mkdir -p "$SRC/mayhem-build"

# build_native <FuzzFunc> <out-binary>: replica of `compile_native_go_fuzzer ./protocol <Func> <name>`.
# The harnesses live in package protocol (protocol/protocol_test.go); go-118-fuzz-build wants the
# package DIRECTORY.
build_native() {
  local func="$1" out="$2"
  echo "=== building $out ($func via go-118-fuzz-build) ==="
  go-118-fuzz-build -o "$SRC/mayhem-build/$out.a" -func "$func" "$SRC/protocol"
  # $GO_DEBUG_FLAGS ensures the C-shim CU (first in the binary) is at DWARF3.
  $CXX $SANITIZER_FLAGS $LIB_FUZZING_ENGINE $GO_DEBUG_FLAGS "$SRC/mayhem-build/$out.a" -o "/mayhem/$out"
  echo "built /mayhem/$out"
}

build_native FuzzParseRequest fuzz_parse_request
build_native FuzzVerifyReply   fuzz_verify_reply

echo "build.sh complete:"
ls -la /mayhem/fuzz_parse_request /mayhem/fuzz_verify_reply 2>&1 || true
