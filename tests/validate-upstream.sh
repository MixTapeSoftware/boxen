#!/usr/bin/env bash
set -euo pipefail
project="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project/tests/validator"
go run . "$project"/kits/* "$project"/agents/*
