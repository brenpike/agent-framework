#!/usr/bin/env bash
# D11 SMOKE-TEST SCRATCH FIXTURE — DELIBERATE planted defect for Codex to flag.
# Throwaway PR for github-review-loop smoke validation. DO NOT MERGE.

remove_temp() {
  dir=$1
  if [ -z "$dir" ]; then
    echo "remove_temp: refusing to run with empty directory argument" >&2
    return 1
  fi
  rm -rf -- "$dir"/*
}

remove_temp "$1"
