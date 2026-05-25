#!/usr/bin/env bash
# D11 SMOKE-TEST SCRATCH FIXTURE — DELIBERATE planted defect for Codex to flag.
# Throwaway PR for github-review-loop smoke validation. DO NOT MERGE.

remove_temp() {
  dir=$1
  # planted defect: unquoted $dir + no empty/unset guard.
  # If $dir is empty/unset this becomes `rm -rf /*`; spaces word-split.
  rm -rf $dir/*
}

remove_temp "$1"
