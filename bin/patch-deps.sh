#!/usr/bin/env bash
# bin/patch-deps.sh — 修补上游依赖在 Elixir 1.20+ 下的编译警告
# 幂等：重复执行不产生额外 diff
# 覆盖：x509 / cbor / wax_ / asn1_compiler 的 pin 警告与 deprecated xref
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

patch_file() {
  local file="$1"
  if [ ! -f "$file" ]; then
    echo "skip missing $file"
    return 0
  fi
}

echo "[patch-deps] patching deps for Elixir 1.20+"

# 1. x509/mix.exs : xref -> elixirc_options
if [ -f deps/x509/mix.exs ]; then
  sed -i 's/xref: \[exclude: \[IEx, :epp_dodger\]\]/elixirc_options: [no_warn_undefined: [IEx, :epp_dodger]]/' deps/x509/mix.exs || true
fi

# 2. x509 certificate.ex : size -> ^size
if [ -f deps/x509/lib/x509/certificate.ex ]; then
  sed -i 's/<<i::unsigned-size(size)-unit(8)>> = :crypto.strong_rand_bytes(size)/<<i::unsigned-size(^size)-unit(8)>> = :crypto.strong_rand_bytes(size)/' deps/x509/lib/x509/certificate.ex || true
fi

# 3. cbor decoder.ex
if [ -f deps/cbor/lib/cbor/decoder.ex ]; then
  sed -i 's/<<value::binary-size(len), new_rest::binary>> = rest/<<value::binary-size(^len), new_rest::binary>> = rest/' deps/cbor/lib/cbor/decoder.ex || true
  sed -i 's/<<value::binary-size(len), new_rest::binary>> = mid_rest/<<value::binary-size(^len), new_rest::binary>> = mid_rest/' deps/cbor/lib/cbor/decoder.ex || true
  sed -i 's/<<res::unsigned-integer-size(size)-unit(8)>> = bytes/<<res::unsigned-integer-size(^size)-unit(8)>> = bytes/g' deps/cbor/lib/cbor/decoder.ex || true
fi

# 4. wax jws.ex
if [ -f deps/wax_/lib/wax/utils/jws.ex ]; then
  sed -i 's/<<r::size(size)-unit(8), s::size(size)-unit(8)>> = raw/<<r::size(^size)-unit(8), s::size(^size)-unit(8)>> = raw/' deps/wax_/lib/wax/utils/jws.ex || true
fi

# 5. wax cose_key.ex
if [ -f deps/wax_/lib/wax/cose_key.ex ]; then
  sed -i 's/<<n_int::unsigned-big-integer-size(nb_bytes_n)-unit(8)>> = n/<<n_int::unsigned-big-integer-size(^nb_bytes_n)-unit(8)>> = n/' deps/wax_/lib/wax/cose_key.ex || true
  sed -i 's/<<e_int::unsigned-big-integer-size(nb_bytes_e)-unit(8)>> = e/<<e_int::unsigned-big-integer-size(^nb_bytes_e)-unit(8)>> = e/' deps/wax_/lib/wax/cose_key.ex || true
fi

# 6. wax tpm.ex
if [ -f deps/wax_/lib/wax/attestation_statement_format/tpm.ex ]; then
  sed -i 's/attested_name_hash::binary-size(hash_length)/attested_name_hash::binary-size(^hash_length)/' deps/wax_/lib/wax/attestation_statement_format/tpm.ex || true
fi

# 7. wax apple_anonymous.ex : remove unused require Logger
if [ -f deps/wax_/lib/wax/attestation_statement_format/apple_anonymous.ex ]; then
  # 删除单独一行的 require Logger
  sed -i '/^[[:space:]]*require Logger$/d' deps/wax_/lib/wax/attestation_statement_format/apple_anonymous.ex || true
fi

# 8. asn1_compiler : silence :asn1ct warning
if [ -f deps/asn1_compiler/lib/mix/tasks/compile.asn1.ex ]; then
  if ! grep -q '@compile {:no_warn_undefined, :asn1ct}' deps/asn1_compiler/lib/mix/tasks/compile.asn1.ex; then
    sed -i '/defmodule Mix.Tasks.Compile.Asn1 do/a \  @compile {:no_warn_undefined, :asn1ct}' deps/asn1_compiler/lib/mix/tasks/compile.asn1.ex || true
  fi
fi

echo "[patch-deps] done"
