#!/bin/bash
# Downloads both exl3 quants into models/. Expects the ~/.venvs/hf-dl venv from README.md.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

source ~/.venvs/hf-dl/bin/activate
for rev in 3.00bpw 3.50bpw; do
  hf download turboderp/Qwen3.8-27B-exl3 --revision "$rev" --local-dir "models/Qwen3.8-27B-exl3_$rev"
done
